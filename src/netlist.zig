const std = @import("std");
const aiger = @import("aiger.zig");
const physical = @import("physical.zig");
const structures = @import("abstract/structures.zig");

const Error = error{
    MalorderedAiger,
};

pub const Net = struct {
    literal: aiger.Literal,
    tag: u64,
    binds: std.ArrayList(GatePtr),
    has_inverted_net: bool,

    fn deinit(self: *Net, gpa: std.mem.Allocator) void {
        self.binds.deinit(gpa);
    }

    fn createFromLiteral(literal: aiger.Literal) Net {
        const tag = Net.tagFromLiteral(literal);
        return Net{
            .literal = literal,
            .tag = tag,
            .binds = .empty,
            .has_inverted_net = false,
        };
    }

    fn tagFromLiteral(literal: aiger.Literal) u64 {
        return switch (literal) {
            .false => 0,
            .true => 1,
            .negated => |item| item.value << 1,
            .unnegated => |item| (item.value << 1) | 0b1,
        };
    }
};

pub const GateType = enum {
    inverter,
    and_gate,
    or_gate,
    input,
    output,

    pub inline fn size(self: GateType) physical.Size {
        return switch (self) {
            .input => physical.Size{
                .w = 1,
                .h = 1,
            },
            .output => physical.Size{
                .w = 1,
                .h = 1,
            },
            .inverter => physical.Size{
                .w = 1,
                .h = 3,
            },
            .and_gate => physical.Size{
                .w = 3,
                .h = 3,
            },
            .or_gate => physical.Size{
                .w = 3,
                .h = 1,
            },
        };
    }

    pub inline fn delay(self: GateType) physical.Delay {
        return switch (self) {
            .input => 0,
            .output => 0,
            .inverter => 2,
            .and_gate => 3,
            .or_gate => 1,
        };
    }

    // assuming the default orientation (.north)
    pub inline fn inputPositionsRelative(self: GateType) physical.InputPositionsRelative {
        return switch (self) {
            .input => .{ .{ 0, 1, 0 }, null },
            .output => .{ .{ 0, 1, -1 }, null },
            .inverter => .{ .{ 0, 1, -1 }, null },
            .and_gate => .{ .{ 0, 1, -1 }, .{ 2, 1, -1 } },
            .or_gate => .{ .{ -1, 1, 0 }, .{ 3, 1, 0 } },
        };
    }

    // assuming the default orientation (.north)
    pub inline fn outputPositionsRelative(self: GateType) physical.OutputPositionsRelative {
        return switch (self) {
            .input => .{ 0, 1, 1 },
            .output => .{ 0, 1, 0 },
            .inverter => .{ 0, 1, 3 },
            .and_gate => .{ 1, 1, 3 },
            .or_gate => .{ 1, 1, 0 },
        };
    }

    pub inline fn outputPowerLevel() physical.PowerLevel {
        return 15;
    }

    pub inline fn inputPowerLevel(self: GateType) physical.PowerLevel {
        return switch (self) {
            .input => 1,
            .output => 1,
            .inverter => 1,
            .and_gate => 1,
            .or_gate => 1,
        };
    }

    pub inline fn blockArray(self: GateType) []const structures.SchemBlock {
        return switch (self) {
            .input => &inputBlocks,
            .output => &outputBlocks,
            .inverter => &inverterBlocks,
            .and_gate => &andGateBlocks,
            .or_gate => &orGateBlocks,
        };
    }

    // requires negative offsets, so we use worldcoord but it is still a relative position
    pub inline fn forbiddenCoordsRelative(self: GateType) []const structures.WorldCoord {
        return switch (self) {
            .input => &computeForbiddenZone(&inputForbiddenCords, @Vector(3, u32){ size(.input).w, 2, size(.input).h }),
            .output => &computeForbiddenZone(&outputForbiddenCords, @Vector(3, u32){ size(.output).w, 2, size(.output).h }),
            .inverter => &computeForbiddenZone(&inverterForbiddenCords, @Vector(3, u32){ size(.inverter).w, 4, size(.inverter).h }),
            .and_gate => &computeForbiddenZone(&andGateForbiddenCoords, @Vector(3, u32){ size(.and_gate).w, 4, size(.and_gate).h }),
            .or_gate => &computeForbiddenZone(&orGateForbiddenCoords, @Vector(3, u32){ size(.or_gate).w, 2, size(.or_gate).h }),
        };
    }
};

// nicely comptime:
fn computeForbiddenZone(
    comptime additionalCords: []const structures.WorldCoord,
    comptime size: @Vector(3, u32),
) [additionalCords.len + (size[0] * size[1] * size[2])]structures.WorldCoord {
    var result: [additionalCords.len + (size[0] * size[1] * size[2])]structures.WorldCoord = undefined;

    // Copy array1
    inline for (additionalCords, 0..) |v, i| {
        result[i] = v;
    }

    // Generate rectangle coordinates
    var idx: usize = additionalCords.len;

    inline for (0..size[0]) |x| {
        inline for (0..size[1]) |y| {
            inline for (0..size[2]) |z| {
                result[idx] = .{
                    @as(structures.WorldCoordNum, @intCast(x)),
                    @as(structures.WorldCoordNum, @intCast(y)),
                    @as(structures.WorldCoordNum, @intCast(z)),
                };
                idx += 1;
            }
        }
    }

    return result;
}

const inputBlocks = [_]structures.SchemBlock{
    .{
        .block = .dust,
        .loc = .{ 0, 1, 0 },
        .rot = .center,
    },
    .{
        .block = .block,
        .loc = .{ 0, 0, 0 },
        .rot = .center,
    },
};

const inputForbiddenCords = [_]structures.WorldCoord{};

const outputBlocks = [_]structures.SchemBlock{
    .{
        .block = .dust,
        .loc = .{ 0, 1, 0 },
        .rot = .center,
    },
    .{
        .block = .block,
        .loc = .{ 0, 0, 0 },
        .rot = .center,
    },
};

const outputForbiddenCords = [_]structures.WorldCoord{};

const inverterBlocks = [_]structures.SchemBlock{
    .{
        .block = .repeater,
        .loc = .{ 0, 1, 0 },
        .rot = .south,
    },
    .{
        .block = .block,
        .loc = .{ 0, 0, 0 },
        .rot = .east,
    },
    .{
        .block = .block2,
        .loc = .{ 0, 1, 1 },
        .rot = .center,
    },
    .{
        .block = .torch,
        .loc = .{ 0, 1, 2 },
        .rot = .south,
    },
};

const inverterForbiddenCords = [_]structures.WorldCoord{
    .{ -1, 1, 1 }, // left of torch
    .{ -1, 1, 2 }, // left of powered block
    .{ 1, 1, 1 }, // right of torch
    .{ 1, 1, 2 }, // right of powered block
    .{ 0, 0, 2 }, // below torch
    .{ 0, 0, 1 }, // below powered block
    .{ 0, 2, 2 }, // above torch
};

const andGateBlocks = [_]structures.SchemBlock{
    .{
        .block = .repeater,
        .loc = .{ 0, 1, 0 },
        .rot = .south,
    },
    .{
        .block = .block,
        .loc = .{ 0, 0, 0 },
        .rot = .east,
    },
    .{
        .block = .repeater,
        .loc = .{ 2, 1, 0 },
        .rot = .south,
    },
    .{
        .block = .block,
        .loc = .{ 2, 0, 0 },
        .rot = .east,
    },
    .{
        .block = .block,
        .loc = .{ 0, 1, 1 },
        .rot = .center,
    },
    .{
        .block = .block,
        .loc = .{ 1, 1, 1 },
        .rot = .center,
    },
    .{
        .block = .block,
        .loc = .{ 2, 1, 1 },
        .rot = .center,
    },
    .{
        .block = .torch,
        .loc = .{ 1, 1, 2 },
        .rot = .south,
    },
    .{
        .block = .dust,
        .loc = .{ 1, 2, 1 },
        .rot = .center,
    },
    .{
        .block = .torch,
        .loc = .{ 0, 2, 1 },
        .rot = .center,
    },
    .{
        .block = .torch,
        .loc = .{ 2, 2, 1 },
        .rot = .center,
    },
};

const andGateForbiddenCoords = [_]structures.WorldCoord{
    .{ -1, 1, 1 }, // left of powered block
    .{ -1, 0, 1 }, // left of torch
    .{ -1, 1, 3 }, // right of powered block
    .{ -1, 1, 3 }, // right of torch
};

const orGateBlocks = [_]structures.SchemBlock{
    .{ // in1
        .block = .repeater,
        .loc = .{ 0, 1, 0 },
        .rot = .east,
    },
    .{
        .block = .block,
        .loc = .{ 0, 0, 0 },
        .rot = .center,
    },
    .{
        .block = .dust,
        .loc = .{ 1, 1, 0 },
        .rot = .center,
    },
    .{
        .block = .block,
        .loc = .{ 1, 0, 0 },
        .rot = .center,
    },
    .{
        .block = .repeater,
        .loc = .{ 2, 1, 0 },
        .rot = .west,
    },
    .{
        .block = .block,
        .loc = .{ 2, 0, 0 },
        .rot = .center,
    },
};

const orGateForbiddenCoords = [_]structures.WorldCoord{
    .{ 1, 1, -1 }, // before powered dust
    .{ 1, 0, -1 }, // before powered block
};

pub const Gate = struct {
    inputs: std.ArrayList(NetPtr),
    outputs: std.ArrayList(NetPtr),
    symbol: aiger.Symbol,
    kind: GateType,

    var gate_number: u64 = 0;

    fn deinit(self: *Gate, gpa: std.mem.Allocator) void {
        self.inputs.deinit(gpa);
        self.outputs.deinit(gpa);
        gpa.free(self.symbol);
    }

    fn new(kind: GateType, symbol: ?aiger.Symbol) Gate {
        return Gate{
            .inputs = .empty,
            .outputs = .empty,
            .kind = kind,
            .symbol = symbol orelse "#UNNAMED_GATE",
        };
    }

    fn netInOutSymbol(gpa: std.mem.Allocator, input: bool, lit: aiger.Literal) !aiger.Symbol {
        var writer = std.io.Writer.Allocating.init(gpa);
        defer _ = writer.deinit();
        try writer.writer.print("{s}", .{switch (input) {
            true => "in.",
            false => "out.",
        }});
        try lit.writeSymbol(&writer.writer);
        return writer.toOwnedSlice();
    }

    fn newGateSymbol(allocator: std.mem.Allocator) aiger.Symbol {
        const symbol = std.fmt.allocPrint(allocator, "gate.{}", .{gate_number}) catch "gate.???";
        gate_number += 1;
        return symbol;
    }
};

pub const NetPtr = usize;
pub const GatePtr = usize;

pub const Netlist = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    nets: std.ArrayList(Net),
    nets_check: std.AutoHashMap(u64, NetPtr),
    gates: std.ArrayList(Gate),

    pub inline fn getNet(self: *const Self, ptr: NetPtr) *Net {
        return @ptrCast(self.nets.items.ptr + ptr);
    }

    pub inline fn getGate(self: *const Self, ptr: GatePtr) *Gate {
        return @ptrCast(self.gates.items.ptr + ptr);
    }

    pub inline fn getGateSize(self: *const Self, ptr: GatePtr) physical.Size {
        return self.gates.items[ptr].kind.size();
    }

    pub inline fn getGateDelay(self: *const Self, ptr: GatePtr) u8 {
        return self.gates.items[ptr].kind.delay();
    }

    // Creates a net if it does not exist yet, if the net does exist, simply return the pointer to it
    fn addOrGetNet(self: *Self, literal: aiger.Literal) !NetPtr {
        const tag = Net.tagFromLiteral(literal);
        if (self.nets_check.get(tag)) |net| {
            return net;
        }
        try self.nets.append(self.allocator, Net.createFromLiteral(literal));

        const net_ptr = self.nets.items.len - 1;
        try self.nets_check.put(tag, net_ptr);
        return net_ptr;
    }

    // Creates the negated net of a literal, ensuring an inverter (and only 1!) gets placed between
    // the base and negated net
    fn addNegatedNet(self: *Self, base_literal: aiger.Literal) !void {
        if (!base_literal.isNegated()) return undefined;
        const inv_literal = (base_literal.getInverted()) orelse return;

        const base_ptr = try self.addOrGetNet(base_literal);
        const negated_ptr = try self.addOrGetNet(inv_literal);
        const base = self.getNet(base_ptr);
        const negated = self.getNet(negated_ptr);
        // Don't create gates if we already have them
        if (base.has_inverted_net) {
            return;
        }

        var inverter = Gate.new(GateType.inverter, Gate.newGateSymbol(self.allocator));
        try inverter.outputs.append(self.allocator, base_ptr);
        try inverter.inputs.append(self.allocator, negated_ptr);
        try self.gates.append(self.allocator, inverter);
        const gate_ptr: GatePtr = self.gates.items.len - 1;

        base.has_inverted_net = true;
        try base.binds.append(self.allocator, gate_ptr);
        negated.has_inverted_net = true;
        try negated.binds.append(self.allocator, gate_ptr);
    }

    fn hasLiteral(self: *const Self, literal: aiger.Literal) ?*Net {
        const tag = Net.tagFromLiteral(literal);
        return self.nets_check.get(tag);
    }

    pub fn deinit(self: *Self) void {
        for (self.nets.items) |*net| {
            net.deinit(self.allocator);
        }
        for (self.gates.items) |*gate| {
            gate.deinit(self.allocator);
        }

        self.nets.deinit(self.allocator);
        self.nets_check.deinit();
        self.gates.deinit(self.allocator);
    }

    pub fn fromAiger(allocator: std.mem.Allocator, aig: aiger.Aiger) !Self {
        var netlist = Netlist{
            .allocator = allocator,
            .nets = .empty,
            .nets_check = .init(allocator),
            .gates = .empty,
        };
        for (aig.inputs) |item| {
            const input_ptr = try netlist.addOrGetNet(item.input);
            try netlist.addNegatedNet(item.input);

            var input = Gate.new(GateType.input, try Gate.netInOutSymbol(allocator, true, item.input));
            try input.outputs.append(allocator, input_ptr);
            try netlist.gates.append(allocator, input);
            const gate_ptr = netlist.gates.items.len - 1;
            try netlist.getNet(input_ptr).binds.append(allocator, gate_ptr);
        }
        for (aig.outputs) |item| {
            const output_ptr = try netlist.addOrGetNet(item.output);
            try netlist.addNegatedNet(item.output);

            var output = Gate.new(GateType.output, try Gate.netInOutSymbol(allocator, false, item.output));
            try output.inputs.append(allocator, output_ptr);
            try netlist.gates.append(allocator, output);
            const gate_ptr = netlist.gates.items.len - 1;
            try netlist.getNet(output_ptr).binds.append(allocator, gate_ptr);
        }

        for (aig.and_gates) |item| {
            const out_ptr = try netlist.addOrGetNet(item.and_gate.out);
            const a_ptr = try netlist.addOrGetNet(item.and_gate.a);
            const b_ptr = try netlist.addOrGetNet(item.and_gate.b);

            // Both inputs may be negated
            // Note that the AIGER format does not allow an output to be negated
            try netlist.addNegatedNet(item.and_gate.a);
            try netlist.addNegatedNet(item.and_gate.b);

            var and_gate = Gate.new(GateType.and_gate, Gate.newGateSymbol(allocator));
            try and_gate.outputs.append(allocator, out_ptr);
            try and_gate.inputs.append(allocator, a_ptr);
            try and_gate.inputs.append(allocator, b_ptr);
            try netlist.gates.append(allocator, and_gate);

            const gate_ptr = netlist.gates.items.len - 1;
            try netlist.getNet(a_ptr).binds.append(allocator, gate_ptr);
            try netlist.getNet(b_ptr).binds.append(allocator, gate_ptr);
            try netlist.getNet(out_ptr).binds.append(allocator, gate_ptr);
        }
        return netlist;
    }

    pub fn printNets(self: *const Self) !void {
        for (self.nets.items) |*net| {
            var writer = std.io.Writer.Allocating.init(self.allocator);
            defer _ = writer.deinit();
            try net.literal.writeSymbol(&writer.writer);
            std.debug.print("\nNET {s}:\n", .{writer.written()});
            for (net.binds.items) |gate_ptr| {
                const gate = self.getGate(gate_ptr);
                std.debug.print(" -> {s}: {any}\n", .{ gate.symbol, gate.kind });
                std.debug.print("Delay: {any}\n", .{self.getGateDelay(gate_ptr)});
            }
        }
    }

    pub fn printGates(self: *const Self) !void {
        for (self.gates.items) |*gate| {
            std.debug.print("\nGATE {s} ({any}):\n", .{ gate.symbol, gate.kind });
            std.debug.print(" INPUTS:\n", .{});
            for (gate.inputs.items) |net_ptr| {
                const net = self.getNet(net_ptr);
                var writer = std.io.Writer.Allocating.init(self.allocator);
                defer _ = writer.deinit();
                try net.literal.writeSymbol(&writer.writer);
                std.debug.print(" -> {s}:\n", .{writer.written()});
            }
            std.debug.print(" OUTPUTS:\n", .{});
            for (gate.outputs.items) |net_ptr| {
                const net = self.getNet(net_ptr);
                var writer = std.io.Writer.Allocating.init(self.allocator);
                defer _ = writer.deinit();
                try net.literal.writeSymbol(&writer.writer);
                std.debug.print(" -> {s}:\n", .{writer.written()});
            }
        }
    }
};
