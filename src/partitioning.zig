const std = @import("std");
const nl = @import("netlist.zig");
const physical = @import("physical.zig");

pub const NodeKind = enum {
    gate,
};

pub const NodeContent = union(NodeKind) {
    gate: nl.GatePtr,
};

pub const Node = struct {
    connects: std.ArrayList(*Node),
    content: NodeContent,

    pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        self.connects.deinit(allocator);
    }
};

pub const Module = struct {
    const Self = @This();

    nodes: []Node,
    netlist: ?*const nl.Netlist,

    pub fn area(self: *const Self) ?u64 {
        const netlist = self.netlist orelse return null;

        var sum: u64 = 0;
        for (self.nodes) |*node| {
            switch (node.content) {
                .gate => |gate_ptr| sum += netlist.get_gate_size(gate_ptr).area(),
            }
        }
        return sum;
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        for (self.nodes) |*node| {
            node.deinit(allocator);
        }
        allocator.free(self.nodes);
    }

    pub fn from_netlist(allocator: std.mem.Allocator, netlist: *const nl.Netlist) !Self {
        var nodes = std.ArrayList(Node).empty;
        defer _ = nodes.deinit(allocator);
        for (0..netlist.gates.items.len) |index| {
            const node = Node{
                .connects = .empty,
                .content = NodeContent{ .gate = index },
            };

            // Important! Nodes must be inserted the same order as gates
            // This is because `GatePtr`'s are just indices to the array
            // Later on we *assume* the order between our nodes and the netlist buffer is the same
            try nodes.append(allocator, node);
        }
        const self = Self{
            .nodes = try nodes.toOwnedSlice(allocator),
            .netlist = netlist,
        };

        for (self.nodes) |*node| {
            const gate_ptr = node.content.gate;
            const gate = netlist.get_gate(gate_ptr);
            for (gate.inputs.items) |net_ptr| {
                const net = netlist.get_net(net_ptr);
                for (net.binds.items) |connected_gate_ptr| {
                    if (connected_gate_ptr == gate_ptr) continue;

                    // Here we assume the netlist buffer order matches our node buffer
                    // If this is not the case, shit explodes
                    try node.connects.append(allocator, &self.nodes[connected_gate_ptr]);
                }
            }
            for (gate.outputs.items) |net_ptr| {
                const net = netlist.get_net(net_ptr);
                for (net.binds.items) |connected_gate_ptr| {
                    if (connected_gate_ptr == gate_ptr) continue;

                    // Here we assume the netlist buffer order matches our node buffer
                    // If this is not the case, shit explodes
                    try node.connects.append(allocator, &self.nodes[connected_gate_ptr]);
                }
            }
        }

        return self;
    }

    pub fn pretty_print(self: *const Self) void {
        std.debug.print("\nMODULE (area: {any})\n", .{self.area()});
        for (self.nodes) |*node| {
            std.debug.print("\n NODE: {any}\n", .{node.content});
            for (node.connects.items) |connects| {
                std.debug.print("  -> {any}\n", .{connects.content});
            }
        }
    }
};
