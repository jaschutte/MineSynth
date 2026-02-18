const std = @import("std");

// FORMAT:
// https://fmv.jku.at/aiger/FORMAT
//
// EXAMPLES:
// https://fmv.jku.at/papers/Biere-FMV-TR-07-1.pdf

const AigerError = error{
    MissingHeader,
    NoMagic,
    UnsupportedVersion,
    TooManyLiterals,
    CommentsNotSupported,
};

const AigerHeader = struct {
    max_var_index: u64,
    inputs: u64,
    latches: u64,
    outputs: u64,
    and_gates: u64,

    fn new(line: []const u8) !AigerHeader {
        if (!std.mem.startsWith(u8, line, "aag ")) {
            return AigerError.NoMagic;
        }

        var words = std.mem.splitScalar(u8, line[4..], ' ');
        var counts: [5]u64 = undefined;

        var index: usize = 0;
        while (words.next()) |word| {
            // Aiger 1.9+ has more arguments
            // We do not support this
            if (index >= 5) {
                return AigerError.UnsupportedVersion;
            }
            counts[index] = try std.fmt.parseInt(u64, word, 10);
            index += 1;
        }

        return AigerHeader{
            .max_var_index = counts[0],
            .inputs = counts[1],
            .latches = counts[2],
            .outputs = counts[3],
            .and_gates = counts[4],
        };
    }
};

const LiteralType = enum {
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

const AigerType = enum {
    input,
    output,
    latch,
    // output input_a input_b
    // 'output' must be unnegated literal
    and_gate,
};

const Expression = union(AigerType) {
    input: Literal,
    output: Literal,
    latch: Literal,
    and_gate: struct { a: Literal, b: Literal, out: Literal },

    fn parse(line: []const u8, expects: AigerType) !Expression {
        var words = std.mem.splitScalar(u8, line, ' ');
        var literals: [3]Literal = undefined;
        var index: usize = 0;
        while (words.next()) |word| {
            if (index >= 3) {
                return AigerError.TooManyLiterals;
            }
            literals[index] = try Literal.parse(word);
            index += 1;
        }

        if (index > 1 and (expects == AigerType.input or expects == AigerType.output or expects == AigerType.latch)) {
            return AigerError.TooManyLiterals;
        }

        return switch (expects) {
            AigerType.input => Expression{ .input = literals[0] },
            AigerType.output => Expression{ .output = literals[0] },
            AigerType.latch => Expression{ .latch = literals[0] },
            AigerType.and_gate => Expression{ .and_gate = .{
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

const Aiger = struct {
    header: AigerHeader,
    expressions: []const Expression,
    allocator: std.mem.Allocator,

    fn deinit(self: *const Aiger) void {
        self.allocator.free(self.expressions);
    }

    pub fn parse_aag(allocator: std.mem.Allocator, content: []const u8) !Aiger {
        var lines = std.mem.splitScalar(u8, content, '\n');
        const header_line = prepare_line(lines.next() orelse return AigerError.MissingHeader);
        const header = try AigerHeader.new(header_line);

        var phase = AigerType.input;
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
                        AigerType.input => {
                            phase = AigerType.latch;
                            max_lines = header.latches;
                        },
                        AigerType.latch => {
                            phase = AigerType.output;
                            max_lines = header.outputs;
                        },
                        AigerType.output => {
                            phase = AigerType.and_gate;
                            max_lines = header.and_gates;
                        },
                        AigerType.and_gate => {
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

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const content = try std.fs.cwd().readFileAlloc(allocator, "aiger-examples/half-adder.aag", std.math.maxInt(usize));
    defer _ = allocator.free(content);

    const aiger = try Aiger.parse_aag(allocator, content);
    defer _ = aiger.deinit();
    std.debug.print("{any}\n", .{aiger});
}
