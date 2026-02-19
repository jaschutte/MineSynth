const std = @import("std");

// FORMAT:
// https://fmv.jku.at/aiger/FORMAT
//
// EXAMPLES:
// https://fmv.jku.at/papers/Biere-FMV-TR-07-1.pdf

pub const Error = error{
    MissingHeader,
    NoMagic,
    UnsupportedVersion,
    TooManyLiterals,
    CommentsNotSupported,
};

pub const Header = struct {
    max_var_index: u64,
    inputs: u64,
    latches: u64,
    outputs: u64,
    and_gates: u64,

    fn new(line: []const u8) !Header {
        if (!std.mem.startsWith(u8, line, "aag ")) {
            return Error.NoMagic;
        }

        var words = std.mem.splitScalar(u8, line[4..], ' ');
        var counts: [5]u64 = undefined;

        var index: usize = 0;
        while (words.next()) |word| {
            // Aiger 1.9+ has more arguments
            // We do not support this
            if (index >= 5) {
                return Error.UnsupportedVersion;
            }
            counts[index] = try std.fmt.parseInt(u64, word, 10);
            index += 1;
        }

        return Header{
            .max_var_index = counts[0],
            .inputs = counts[1],
            .latches = counts[2],
            .outputs = counts[3],
            .and_gates = counts[4],
        };
    }
};

pub const LiteralType = enum {
    // Constant 0
    false,
    // Constant 1
    true,
    // Negated values have the LSB set to '1', aka 'uneven' numbers are negated
    negated,
    // Unnegated values have the LSB set to '0', aka 'even' numbers are unnegated
    unnegated,
};

const Literal = union(LiteralType) {
    false: void,
    true: void,
    negated: u64,
    unnegated: u64,

    fn parse(word: []const u8) !Literal {
        const decimal = try std.fmt.parseInt(u64, word, 10);
        return switch (decimal) {
            0 => Literal{ .false = undefined },
            1 => Literal{ .true = undefined },
            else => if (decimal & 0b1 == 0b1)
                Literal{ .negated = decimal >> 1 }
            else
                Literal{ .unnegated = decimal >> 1 },
        };
    }
};

const ExpressionType = enum {
    input,
    output,
    latch,
    // output input_a input_b
    // 'output' must be unnegated literal
    and_gate,
};

pub const Expression = union(ExpressionType) {
    input: Literal,
    output: Literal,
    latch: Literal,
    and_gate: struct { a: Literal, b: Literal, out: Literal },

    fn parse(line: []const u8, expects: ExpressionType) !Expression {
        var words = std.mem.splitScalar(u8, line, ' ');
        var literals: [3]Literal = undefined;
        var index: usize = 0;
        while (words.next()) |word| {
            if (index >= 3) {
                return Error.TooManyLiterals;
            }
            literals[index] = try Literal.parse(word);
            index += 1;
        }

        if (index > 1 and (expects == ExpressionType.input or expects == ExpressionType.output or expects == ExpressionType.latch)) {
            return Error.TooManyLiterals;
        }

        return switch (expects) {
            ExpressionType.input => Expression{ .input = literals[0] },
            ExpressionType.output => Expression{ .output = literals[0] },
            ExpressionType.latch => Expression{ .latch = literals[0] },
            ExpressionType.and_gate => Expression{ .and_gate = .{
                .out = literals[0],
                .a = literals[1],
                .b = literals[2],
            } },
        };
    }
};

// Small preprocessing to properly parse a line
// This mainly strips anything after an '#', as those are marked as comments
// It also removes extra spaces, tabs and carriage returns at the end of a line
fn prepare_line(line: []const u8) []const u8 {
    var trimmed = line;
    if (std.mem.indexOf(u8, line, "#")) |index| {
        trimmed = line[0..index];
    }
    trimmed = std.mem.trim(u8, trimmed, " \t\r");
    return trimmed;
}

pub const Aiger = struct {
    header: Header,
    expressions: []const Expression,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *const Aiger) void {
        self.allocator.free(self.expressions);
    }

    pub fn parse_aag(allocator: std.mem.Allocator, content: []const u8) !Aiger {
        var lines = std.mem.splitScalar(u8, content, '\n');
        const header_line = prepare_line(lines.next() orelse return Error.MissingHeader);
        const header = try Header.new(header_line);

        var phase = ExpressionType.input;
        var line_index: usize = 0;
        var max_lines: usize = header.inputs;
        var expressions: std.ArrayList(Expression) = .empty;
        defer _ = expressions.deinit(allocator);
        while (lines.next()) |unstripped_line| {
            const line = prepare_line(unstripped_line);
            try expressions.append(allocator, try Expression.parse(line, phase));

            line_index += 1;
            if (line_index >= max_lines) {
                line_index = 0;

                // Having 0 of a certain type is completely fine and normal
                // Make sure we deal with this properly and don't enter the wrong phase
                max_lines = 0;
                var breakout = false;
                while (max_lines == 0) {
                    switch (phase) {
                        ExpressionType.input => {
                            phase = ExpressionType.latch;
                            max_lines = header.latches;
                        },
                        ExpressionType.latch => {
                            phase = ExpressionType.output;
                            max_lines = header.outputs;
                        },
                        ExpressionType.output => {
                            phase = ExpressionType.and_gate;
                            max_lines = header.and_gates;
                        },
                        ExpressionType.and_gate => {
                            breakout = true;
                            break;
                            // To simplify parsing, we do not support comment statements
                            // return AigerError.CommentsNotSupported;
                        },
                    }
                }
                if (breakout) {
                    break;
                }
            }
        }
        return Aiger{
            .header = header,
            .expressions = try expressions.toOwnedSlice(allocator),
            .allocator = allocator,
        };
    }
};
