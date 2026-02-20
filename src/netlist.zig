const std = @import("std");
const aiger = @import("aiger.zig");

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
};

const GateType = enum {
    inverter,
    and_gate,
};

const Gate = struct {
    inputs: std.ArrayList(NetPtr),
    outputs: std.ArrayList(NetPtr),
    kind: GateType,

    fn deinit(self: *Gate, gpa: std.mem.Allocator) void {
        self.inputs.deinit(gpa);
        self.outputs.deinit(gpa);
    }

    fn new(kind: GateType) Gate {
        return Gate{
            .inputs = .empty,
            .outputs = .empty,
            .kind = kind,
        };
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

    pub fn get_net(self: *Self, ptr: NetPtr) *Net {
        return @ptrCast(self.nets.items.ptr + ptr);
    }

    pub fn get_gate(self: *Self, ptr: GatePtr) *Gate {
        return @ptrCast(self.gates.items.ptr + ptr);
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

        var inverter = Gate.new(GateType.inverter);
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

            var and_gate = Gate.new(GateType.and_gate);
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
};
