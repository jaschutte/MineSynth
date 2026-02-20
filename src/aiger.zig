const std = @import("std");

// FORMAT:
// https://fmv.jku.at/aiger/FORMAT
//
// EXAMPLES:
// https://fmv.jku.at/papers/Biere-FMV-TR-07-1.pdf

pub const Error = error{
    // No AIGER header found
    MissingHeader,
    // Missing the 'aag' magic numbers
    NoMagic,
    // This parser only supports AIGER <1.9
    // AIGER 1.9+ has more arguments in the header
    // Please adapt your AIGER format to one containing only 'aag M I L O A'
    UnsupportedVersion,
    // The expected expression has too many literals associated with it
    TooManyLiterals,
    // Empty lines are not supported by the AIGER format
    EmptyLine,
    // Symbols may only refer to inputs (i), outputs (o) or latches (l)
    InvalidSymbolTarget,
    // The symbol line is too small
    // Make sure symbols follow the following format: ['o' | 'i' | 'l'][index] [symbol name]
    SymbolTooShort,
    // The symbol has no input/output/latch index
    SymbolMissingIndex,
    // The symbol has no label
    SymbolMissingLabel,
    // The symbol index refers to a non-existing input/output/latch
    SymbolInvalidIndex,
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

pub const SymbolTarget = enum {
    input,
    output,
    latch,
};

pub const Symbol = []const u8;

fn parse_symbol_line(line: []const u8) !struct { target: SymbolTarget, index: usize, symbol: Symbol } {
    if (line.len < 2) {
        return Error.SymbolTooShort;
    }

    const target = switch (line[0]) {
        'i' => SymbolTarget.input,
        'o' => SymbolTarget.output,
        'l' => SymbolTarget.latch,
        else => return Error.InvalidSymbolTarget,
    };

    var words = std.mem.splitScalar(u8, line[1..], ' ');
    const index = try std.fmt.parseInt(usize, words.next() orelse return Error.SymbolMissingIndex, 10);
    // NOTE: this makes symbols for literals with spaces not possible
    // So just don't do that :)
    const label = words.next() orelse return Error.SymbolMissingLabel;
    return .{
        .target = target,
        .index = index,
        .symbol = label,
    };
}

pub const Literal = union(LiteralType) {
    const Self = @This();

    false: void,
    true: void,
    negated: struct { symbol: Symbol, value: u64 },
    unnegated: struct { symbol: Symbol, value: u64 },

    pub fn get_inverted(self: *const Self) ?Self {
        return switch (self.*) {
            .false => null,
            .true => null,
            .negated => |item| Self{ .unnegated = .{ .symbol = item.symbol, .value = item.value } },
            .unnegated => |item| Self{ .negated = .{ .symbol = item.symbol, .value = item.value } },
        };
    }

    pub fn get_symbol(self: *const Self) []const u8 {
        return switch (self.*) {
            .true => "TRUE",
            .false => "FALSE",
            .negated => self.negated.symbol,
            .unnegated => self.unnegated.symbol,
        };
    }

    fn set_symbol(self: *Self, new: Symbol) void {
        if (self.* == .negated) {
            self.negated.symbol = new;
        }
        if (self.* == .unnegated) {
            self.unnegated.symbol = new;
        }
    }

    fn parse(word: []const u8) !Self {
        const decimal = try std.fmt.parseInt(u64, word, 10);
        return switch (decimal) {
            0 => Self{ .false = undefined },
            1 => Self{ .true = undefined },
            else => if (decimal & 0b1 == 0b1)
                Self{ .negated = .{ .symbol = word, .value = decimal >> 1 } }
            else
                Self{ .unnegated = .{ .symbol = word, .value = decimal >> 1 } },
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

        if (index > 1 and (expects == .input or expects == .output or expects == .latch)) {
            return Error.TooManyLiterals;
        }

        return switch (expects) {
            .input => Expression{ .input = literals[0] },
            .output => Expression{ .output = literals[0] },
            .latch => Expression{ .latch = literals[0] },
            .and_gate => Expression{ .and_gate = .{
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
    inputs: []const Expression,
    outputs: []const Expression,
    latches: []const Expression,
    and_gates: []const Expression,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *const Aiger) void {
        self.allocator.free(self.inputs);
        self.allocator.free(self.outputs);
        self.allocator.free(self.latches);
        self.allocator.free(self.and_gates);
    }

    pub fn parse_aag(allocator: std.mem.Allocator, content: []const u8) !Aiger {
        var lines = std.mem.splitScalar(u8, content, '\n');
        const header_line = prepare_line(lines.next() orelse return Error.MissingHeader);
        const header = try Header.new(header_line);

        var phase = ExpressionType.input;
        var line_index: usize = 0;
        var max_lines: usize = header.inputs;
        var inputs: std.ArrayList(Expression) = .empty;
        defer _ = inputs.deinit(allocator);
        var outputs: std.ArrayList(Expression) = .empty;
        defer _ = outputs.deinit(allocator);
        var latches: std.ArrayList(Expression) = .empty;
        defer _ = latches.deinit(allocator);
        var and_gates: std.ArrayList(Expression) = .empty;
        defer _ = and_gates.deinit(allocator);
        var netlist_parsed = false;
        while (lines.next()) |unstripped_line| {
            const line = prepare_line(unstripped_line);
            if (line.len == 0) {
                continue;
            }

            if (!netlist_parsed) {
                switch (phase) {
                    .input => try inputs.append(allocator, try Expression.parse(line, phase)),
                    .output => try outputs.append(allocator, try Expression.parse(line, phase)),
                    .latch => try latches.append(allocator, try Expression.parse(line, phase)),
                    .and_gate => try and_gates.append(allocator, try Expression.parse(line, phase)),
                }
            } else {
                if (line[0] == 'c') {
                    break;
                }
                const sym_definition = try parse_symbol_line(line);
                switch (sym_definition.target) {
                    .input => {
                        if (sym_definition.index >= inputs.items.len) {
                            return Error.SymbolInvalidIndex;
                        }
                        inputs.items[sym_definition.index].input.set_symbol(sym_definition.symbol);
                    },
                    .output => {
                        if (sym_definition.index >= outputs.items.len) {
                            return Error.SymbolInvalidIndex;
                        }
                        outputs.items[sym_definition.index].output.set_symbol(sym_definition.symbol);
                    },
                    .latch => {
                        if (sym_definition.index >= latches.items.len) {
                            return Error.SymbolInvalidIndex;
                        }
                        latches.items[sym_definition.index].latch.set_symbol(sym_definition.symbol);
                    },
                }
            }

            line_index += 1;
            if (line_index >= max_lines) {
                line_index = 0;

                // Having 0 of a certain type is completely fine and normal
                // Make sure we deal with this properly and don't enter the wrong phase
                max_lines = 0;
                while (max_lines == 0) {
                    switch (phase) {
                        .input => {
                            phase = ExpressionType.latch;
                            max_lines = header.latches;
                        },
                        .latch => {
                            phase = ExpressionType.output;
                            max_lines = header.outputs;
                        },
                        .output => {
                            phase = ExpressionType.and_gate;
                            max_lines = header.and_gates;
                        },
                        .and_gate => {
                            netlist_parsed = true;
                            max_lines = std.math.maxInt(usize);
                            break;
                        },
                    }
                }
            }
        }
        return Aiger{
            .header = header,
            .inputs = try inputs.toOwnedSlice(allocator),
            .outputs = try outputs.toOwnedSlice(allocator),
            .latches = try latches.toOwnedSlice(allocator),
            .and_gates = try and_gates.toOwnedSlice(allocator),
            .allocator = allocator,
        };
    }
};
