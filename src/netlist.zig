const std = @import("std");
const aiger = @import("aiger.zig");
const physical = @import("physical.zig");

const Error = error{
    MalorderedAiger,
};

const Net = struct {
    symbol: aiger.Symbol,
    tag: u64,
    binds: std.ArrayList(GatePtr),
    has_inverted_net: bool,

    fn deinit(self: *Net, gpa: std.mem.Allocator) void {
        self.binds.deinit(gpa);
    }

    fn create_from_literal(literal: aiger.Literal) Net {
        const symbol = literal.get_symbol();
        const tag = Net.tag_from_literal(literal);
        return Net{
            .symbol = symbol,
            .tag = tag,
            .binds = .empty,
            .has_inverted_net = false,
        };
    }

    fn tag_from_literal(literal: aiger.Literal) u64 {
        return switch (literal) {
            .false => 0,
            .true => 1,
            .negated => |item| item.value << 1,
            .unnegated => |item| (item.value << 1) | 0b1,
        };
    }

    // Indicates negated status, or literal
    fn symbol_extra(self: *const Net) []const u8 {
        return switch (self.tag) {
            0 => "=False",
            1 => "=True",
            else => |tag| if (tag & 0b1 == 0b1)
                ""
            else
                "#",
        };
    }
};

const GateType = enum {
    inverter,
    and_gate,

    pub inline fn size(self: GateType) physical.Size {
        return switch (self) {
            .inverter => physical.Size {
                .w = 1,
                .h = 3,
            },
            .and_gate => physical.Size {
                .w = 6,
                .h = 3,
            },
        };
    }
};

const Gate = struct {
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

    fn new_gate_symbol(allocator: std.mem.Allocator) aiger.Symbol {
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

    pub inline fn get_net(self: *const Self, ptr: NetPtr) *Net {
        return @ptrCast(self.nets.items.ptr + ptr);
    }

    pub inline fn get_gate(self: *const Self, ptr: GatePtr) *Gate {
        return @ptrCast(self.gates.items.ptr + ptr);
    }

    pub inline fn get_gate_size(self: *const Self, ptr: GatePtr) physical.Size {
        return self.gates.items[ptr].kind.size();
    }

    // Creates a net if it does not exist yet, if the net does exist, simply return the pointer to it
    fn add_or_get_net(self: *Self, literal: aiger.Literal) !NetPtr {
        const tag = Net.tag_from_literal(literal);
        if (self.nets_check.get(tag)) |net| {
            return net;
        }
        try self.nets.append(self.allocator, Net.create_from_literal(literal));

        const net_ptr = self.nets.items.len - 1;
        try self.nets_check.put(tag, net_ptr);
        return net_ptr;
    }

    // Creates the negated net of a literal, ensuring an inverter (and only 1!) gets placed between
    // the base and negated net
    fn add_negated_net(self: *Self, base_literal: aiger.Literal) !void {
        const inv_literal = (base_literal.get_inverted()) orelse return;

        const base_ptr = try self.add_or_get_net(base_literal);
        const negated_ptr = try self.add_or_get_net(inv_literal);
        const base = self.get_net(base_ptr);
        const negated = self.get_net(negated_ptr);
        // Don't create gates if we already have them
        if (base.has_inverted_net) {
            return;
        }

        var inverter = Gate.new(GateType.inverter, Gate.new_gate_symbol(self.allocator));
        try inverter.inputs.append(self.allocator, base_ptr);
        try inverter.outputs.append(self.allocator, negated_ptr);
        try self.gates.append(self.allocator, inverter);
        const gate_ptr: GatePtr = self.gates.items.len - 1;

        base.has_inverted_net = true;
        try base.binds.append(self.allocator, gate_ptr);
        negated.has_inverted_net = true;
        try negated.binds.append(self.allocator, gate_ptr);
    }

    fn has_literal(self: *const Self, literal: aiger.Literal) ?*Net {
        const tag = Net.tag_from_literal(literal);
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

    pub fn from_aiger(allocator: std.mem.Allocator, aig: aiger.Aiger) !Self {
        var netlist = Netlist{
            .allocator = allocator,
            .nets = .empty,
            .nets_check = .init(allocator),
            .gates = .empty,
        };
        for (aig.inputs) |item| {
            _ = try netlist.add_or_get_net(item.input);
        }
        for (aig.outputs) |item| {
            _ = try netlist.add_or_get_net(item.output);
        }
        for (aig.and_gates) |item| {
            const out_ptr = try netlist.add_or_get_net(item.and_gate.out);
            const a_ptr = try netlist.add_or_get_net(item.and_gate.a);
            const b_ptr = try netlist.add_or_get_net(item.and_gate.b);

            // Both inputs may be negated
            // Note that the AIGER format does not allow an output to be negated
            try netlist.add_negated_net(item.and_gate.a);
            try netlist.add_negated_net(item.and_gate.b);

            var and_gate = Gate.new(GateType.and_gate, Gate.new_gate_symbol(allocator));
            try and_gate.outputs.append(allocator, out_ptr);
            try and_gate.inputs.append(allocator, a_ptr);
            try and_gate.inputs.append(allocator, b_ptr);
            try netlist.gates.append(allocator, and_gate);

            const gate_ptr = netlist.gates.items.len - 1;
            try netlist.get_net(a_ptr).binds.append(allocator, gate_ptr);
            try netlist.get_net(b_ptr).binds.append(allocator, gate_ptr);
            try netlist.get_net(out_ptr).binds.append(allocator, gate_ptr);
        }
        return netlist;
    }

    pub fn print_nets(self: *const Self) void {
        for (self.nets.items) |*net| {
            std.debug.print("\nNET {s}{s}:\n", .{ net.symbol, net.symbol_extra() });
            for (net.binds.items) |gate_ptr| {
                const gate = self.get_gate(gate_ptr);
                std.debug.print(" -> {s}: {any}\n", .{ gate.symbol, gate.kind });
            }
        }
    }

    pub fn print_gates(self: *const Self) void {
        for (self.gates.items) |*gate| {
            std.debug.print("\nGATE {s} ({any}):\n", .{ gate.symbol, gate.kind });
            std.debug.print(" INPUTS:\n", .{});
            for (gate.inputs.items) |net_ptr| {
                const net = self.get_net(net_ptr);
                std.debug.print(" -> {s}{s}\n", .{net.symbol, net.symbol_extra()});
            }
            std.debug.print(" OUTPUTS:\n", .{});
            for (gate.outputs.items) |net_ptr| {
                const net = self.get_net(net_ptr);
                std.debug.print(" -> {s}{s}\n", .{net.symbol, net.symbol_extra()});
            }
        }
    }
};
