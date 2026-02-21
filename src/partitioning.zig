const std = @import("std");
const nl = @import("netlist.zig");
const physical = @import("physical.zig");

pub fn array_contains(comptime T: type, array: []T, find: T) bool {
    for (array) |elem| {
        if (elem == find) {
            return true;
        }
    }
    return false;
}

pub const NodeKind = enum {
    gate,
};

pub const NodeContent = union(NodeKind) {
    gate: nl.GatePtr,
};

pub const Node = struct {
    const Self = @This();

    connects: std.ArrayList(*Node),
    content: NodeContent,
    fixed: bool,

    pub fn area(self: *Self, netlist: *const nl.Netlist) u64 {
        return switch (self.content) {
            .gate => |gate_ptr| netlist.get_gate(gate_ptr).kind.size().area(),
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.connects.deinit(allocator);
    }

    pub fn pretty_print(self: *const Self) void {
        std.debug.print("\n NODE: {any} (fixed: {})\n", .{ self.content, self.fixed });
        for (self.connects.items) |connects| {
            std.debug.print("  -> {any}\n", .{connects.content});
        }
    }
};

pub const PartitionData = struct {
    const Self = @This();

    pub const State = enum {
        Real,
        Pretending,
    };

    // Referred to as 'A' in the book
    left: std.AutoHashMap(*Node, void),
    // Referred to as 'B' in the book
    right: std.AutoHashMap(*Node, void),

    left_backup: ?std.AutoHashMap(*Node, void),
    right_backup: ?std.AutoHashMap(*Node, void),
    state: State,

    // TODO: actually check the state so that nothing happens
    // or don't, if it works, it works.

    pub fn deinit(self: *Self) void {
        self.left.deinit();
        self.right.deinit();
        if (self.left_backup != null) {
            self.left_backup.?.deinit();
        }
        if (self.right_backup != null) {
            self.right_backup.?.deinit();
        }
    }

    pub fn clone(self: *const Self) !Self {
        const left = try self.left.clone();
        const right = try self.right.clone();
        return Self{
            .left = left,
            .right = right,
            .left_backup = null,
            .right_backup = null,
            .state = State.Real,
        };
    }

    pub const Criticality = struct {
        critical: bool,
        delta: i64,
    };

    pub fn net_criticality(self: *Self, root: *Node, net: []*Node) Criticality {
        var left: u64 = 0;
        var right: u64 = 0;
        for (net) |node| {
            left += @intFromBool(self.left.contains(node));
            right += @intFromBool(self.right.contains(node));
        }
        const is_left = self.left.contains(root);
        const dominant = switch (is_left) {
            true => left,
            false => right,
        };
        const delta: i64 = switch (dominant) {
            0 => 1,
            1 => -1,
            else => 0,
        };
        return Criticality{
            .critical = (is_left and left <= 1) or (!is_left and right <= 1),
            .delta = delta,
        };
    }

    pub fn pretend(self: *Self) !void {
        self.left_backup = try self.left.clone();
        self.right_backup = try self.right.clone();
        self.state = State.Pretending;
    }

    pub fn commit(self: *Self) void {
        self.left_backup.?.deinit();
        self.right_backup.?.deinit();
        self.left_backup = null;
        self.right_backup = null;
        self.state = State.Real;
    }

    pub fn restore(self: *Self) void {
        self.left.deinit();
        self.right.deinit();
        self.left = self.left_backup.?;
        self.right = self.right_backup.?;
        self.left_backup = null;
        self.right_backup = null;
        self.state = State.Real;
    }

    pub fn move_to_other(self: *Self, node: *Node) !void {
        if (self.left.contains(node)) {
            _ = self.left.remove(node);
            try self.right.put(node, undefined);
        }
        if (self.right.contains(node)) {
            _ = self.right.remove(node);
            try self.left.put(node, undefined);
        }
    }

    pub fn area_left(self: *const Self, netlist: *const nl.Netlist) i64 {
        var sum: i64 = 0;
        var key_iter = self.left.keyIterator();
        while (key_iter.next()) |node| {
            sum += @intCast(node.*.area(netlist));
        }
        return sum;
    }

    pub fn bounds(self: *const Self, netlist: *const nl.Netlist) Partition.AreaBounds {
        var area_l: f32 = 0.0;
        var area_r: f32 = 0.0;
        var area_max: f32 = 0.0;
        var key_iter = self.left.keyIterator();
        while (key_iter.next()) |node| {
            const area: f32 = @floatFromInt(node.*.area(netlist));
            area_l += area;
            area_max = @max(area_max, area);
        }
        key_iter = self.right.keyIterator();
        while (key_iter.next()) |node| {
            const area: f32 = @floatFromInt(node.*.area(netlist));
            area_r += area;
            area_max = @max(area_max, area);
        }
        const total_area = area_l + area_r;
        const ratio = area_l / total_area;
        return Partition.AreaBounds{
            .optimal = @intFromFloat(ratio * total_area),
            .lower = @intFromFloat(ratio * total_area - area_max),
            .upper = @intFromFloat(ratio * total_area + area_max),
        };
    }
};

pub const Partition = struct {
    const Self = @This();

    pub const AreaBounds = struct {
        optimal: i64,
        lower: i64,
        upper: i64,
    };

    data: PartitionData,
    all: []*Node,
    node_to_index: std.AutoHashMap(*Node, usize),
    owner: *Module,

    // // Moving force
    // pub fn fs(self: *const Self, node: *const Node) u64 {
    //
    // }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.data.deinit();
        self.node_to_index.deinit();
        allocator.free(self.all);
    }

    pub fn pretty_print(self: *const Self) void {
        std.debug.print("\nPARTITION {}\n", .{self.data.bounds(self.owner.netlist.?)});
        std.debug.print(" *- {}\n", .{self.data.area_left(self.owner.netlist.?)});
        std.debug.print(" ::LEFT::", .{});
        var iterator = self.data.left.keyIterator();
        while (iterator.next()) |node| {
            node.*.pretty_print();
        }
        std.debug.print(" ::RIGHT::", .{});
        iterator = self.data.right.keyIterator();
        while (iterator.next()) |node| {
            node.*.pretty_print();
        }
    }

    pub fn calculate_node_gain(self: *const Self, node: *const Node) i64 {
        const nets = self.owner.edges.get(@constCast(node)).?;
        var status: struct { cut: i64, uncut: i64 } = .{ .cut = 0, .uncut = 0 };
        const is_left = self.data.left.contains(@constCast(node));
        for (nets.items) |net| {
            var left: u64 = 0;
            var right: u64 = 0;
            for (net) |other| {
                if (other == node) continue;
                left += @intFromBool(self.data.left.contains(@constCast(other)));
                right += @intFromBool(self.data.right.contains(@constCast(other)));
            }
            if (is_left) {
                status.cut += @intFromBool(left == 0);
                status.uncut += @intFromBool(left != 0);
            } else {
                status.cut += @intFromBool(right == 0);
                status.uncut += @intFromBool(right != 0);
            }
        }
        return status.cut - status.uncut;
    }

    pub const NodeGain = struct {
        area: i64,
        gain: i64,
        node: *Node,
    };

    pub fn find_highest_gain_cell(self: *Self, gain: []i64, bounds: AreaBounds) !?NodeGain {
        var highest_node: ?*Node = null;
        var highest_gain: i64 = std.math.minInt(i64);
        var best_area: i64 = std.math.minInt(i64);
        for (0.., self.all) |index, node| {
            if (node.fixed) continue;
            if (gain[index] < highest_gain) continue;
            if (gain[index] == highest_gain) {
                try self.data.pretend();
                try self.data.move_to_other(node);
                const area: i64 = @intCast(self.data.area_left(self.owner.netlist.?));
                self.data.restore();

                // It mustn't disturb the balence criteria
                if (area < bounds.lower or area > bounds.upper) continue;

                // Break the tie by determining which has an area is closer to the 'optimal' area
                const new_distance = @abs(area - bounds.optimal);
                const old_distance = @abs(best_area - bounds.optimal);
                if (new_distance > old_distance) continue;
            }
            highest_node = node;
            highest_gain = gain[index];

            try self.data.pretend();
            try self.data.move_to_other(node);
            best_area = @intCast(self.data.area_left(self.owner.netlist.?));
            self.data.restore();
        }
        if (highest_node) |node| {
            return NodeGain{
                .node = node,
                .gain = highest_gain,
                .area = best_area,
            };
        }
        return null;
    }

    // // Fiduccia–Mattheyses Algorithm
    // // See Chapter 2.4.3 of 2nd edition of the book
    pub fn fm_algorithm(self: *Self, allocator: std.mem.Allocator) !void {
        const bounds = self.data.bounds(self.owner.netlist.?);
        var gain: i64 = std.math.maxInt(i64);
        while (gain > 0) {
            gain = try self.fm_step(allocator, bounds);
            std.debug.print("PASS GAIN {}\n", .{gain});
        }
    }

    pub fn fm_step(self: *Self, allocator: std.mem.Allocator, bounds: AreaBounds) !i64 {
        // Leaks on error
        // Just don't error
        var order = std.ArrayList(NodeGain).empty;
        var gain = std.ArrayList([]i64).empty;
        try gain.append(allocator, try allocator.alloc(i64, self.all.len));
        const initial_state = try self.data.clone();

        var gain_index: usize = 0;

        for (0.., self.all) |index, node| {
            gain.items[gain_index][index] = self.calculate_node_gain(node);
            node.fixed = false;
        }
        std.debug.print("GAIN INIT {any}\n", .{gain.items[gain_index]});
        try gain.append(allocator, try allocator.dupe(i64, gain.items[gain_index]));

        // The main loop
        // Try moving nodes with the highest gain, until all nodes are fixed / fail balance criteria
        while (try self.find_highest_gain_cell(gain.items[gain_index], bounds)) |best_node_gain| {
            try self.data.move_to_other(best_node_gain.node);
            best_node_gain.node.fixed = true;

            const nets = self.owner.edges.get(best_node_gain.node).?;
            for (nets.items) |net| {
                const criticality = self.data.net_criticality(best_node_gain.node, net);
                if (!criticality.critical) continue;

                for (net) |node| {
                    if (node == best_node_gain.node) continue;
                    if (node.fixed) continue;

                    const index = self.node_to_index.get(node).?;
                    gain.items[gain_index + 1][index] += criticality.delta;
                }
            }

            try order.append(allocator, best_node_gain);
            try gain.append(allocator, try allocator.dupe(i64, gain.items[gain_index]));
            std.debug.print("GAIN.{} :: {any}\n", .{gain_index, gain.items[gain_index]});
            gain_index += 1;
        }

        // Replay all the sequences, find out which (sub)sequence has the best total gain
        var best_m: usize = 0;
        var best_g: i64 = 0; // Has to be zero, or it won't swap nodes for zero gain passes
        var best_distance: u64 = 0;
        var sum_g: i64 = 0;
        var apply_m = false;
        for (0.., order.items) |index, node_gain| {
            const new_distance = @abs(node_gain.area - bounds.optimal);
            sum_g += node_gain.gain;
            if (sum_g > best_g) {
                best_g = sum_g;
                best_m = index;
                best_distance = new_distance;
                apply_m = true;
                continue;
            }
            if (sum_g == best_g) {
                if (new_distance > best_distance) continue;
                best_g = sum_g;
                best_m = index;
                best_distance = new_distance;
                apply_m = true;
            }
        }

        self.data.deinit();
        self.data = initial_state;
        if (apply_m) {
            for (0..best_m) |index| {
                try self.data.move_to_other(order.items[index].node);
            }
        }

        // Clean up :)
        for (gain.items) |column| {
            allocator.free(column);
        }
        gain.deinit(allocator);
        order.deinit(allocator);

        return best_g;
    }
};

pub const Module = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    nodes: []Node,
    edges: std.AutoHashMap(*Node, std.ArrayList([]*Node)),
    raw_edges: std.ArrayList([]*Node),
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

    pub fn deinit(self: *Self) void {
        var edge_list_iter = self.edges.valueIterator();
        while (edge_list_iter.next()) |list| {
            list.deinit(self.allocator);
        }
        self.edges.deinit();

        for (self.raw_edges.items) |edge| {
            self.allocator.free(edge);
        }
        self.raw_edges.deinit(self.allocator);

        for (self.nodes) |*node| {
            node.deinit(self.allocator);
        }
        self.allocator.free(self.nodes);
    }

    pub fn initial_partition(self: *Self) !Partition {
        // TODO: guard statement for modules with zero nodes
        // TODO: dont assume all the first node has children

        // For the initial partitioning, simply do a breath-first iteration of the nodes until we
        // have split approximately half of the nodes into two groups
        // var left = std.ArrayList(*Node).empty;
        // var right = std.ArrayList(*Node).empty;
        var left = std.AutoHashMap(*Node, void).init(self.allocator);
        var right = std.AutoHashMap(*Node, void).init(self.allocator);

        const threshold = self.nodes.len / 2;
        var index: usize = 0;
        var stack = std.ArrayList(*Node).empty;
        defer _ = stack.deinit(self.allocator);
        var visited = std.AutoHashMap(*Node, void).init(self.allocator);
        defer _ = visited.deinit();
        try stack.append(self.allocator, &self.nodes[0]);
        try visited.put(&self.nodes[0], undefined);

        while (stack.items.len != 0) {
            const node = stack.orderedRemove(0);

            for (node.connects.items) |connected| {
                if (!visited.contains(connected)) {
                    try visited.put(connected, undefined);
                    try stack.append(self.allocator, connected);
                }
            }

            if (index > threshold) {
                try left.put(node, undefined);
                // try left.append(self.allocator, node);
            } else {
                try right.put(node, undefined);
                // try right.append(self.allocator, node);
            }
            index += 1;
        }

        var all = try self.allocator.alloc(*Node, self.nodes.len);
        var node_to_index = std.AutoHashMap(*Node, usize).init(self.allocator);
        for (0.., self.nodes) |i, *node| {
            all[i] = node;
            try node_to_index.put(node, i);
        }

        return Partition{
            .data = PartitionData{
                .left = left,
                .right = right,
                .left_backup = null,
                .right_backup = null,
                .state = PartitionData.State.Real,
            },
            .all = all,
            .node_to_index = node_to_index,
            .owner = self,
        };
    }

    pub fn from_netlist(allocator: std.mem.Allocator, netlist: *const nl.Netlist) !Self {
        // TODO: easy optimisation, remove gates not connected to anything
        //       ^ issue: the netlist order != gate order, which will mess things up

        var nodes = std.ArrayList(Node).empty;
        defer _ = nodes.deinit(allocator);
        for (0..netlist.gates.items.len) |index| {
            const node = Node{
                .connects = .empty,
                .content = NodeContent{ .gate = index },
                .fixed = false,
            };

            // Important! Nodes must be inserted the same order as gates
            // This is because `GatePtr`'s are just indices to the array
            // Later on we *assume* the order between our nodes and the netlist buffer is the same
            try nodes.append(allocator, node);
        }
        var self = Self{
            .allocator = allocator,
            .nodes = try nodes.toOwnedSlice(allocator),
            .netlist = netlist,
            .edges = .init(allocator),
            .raw_edges = .empty,
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

            try self.edges.put(node, std.ArrayList([]*Node).empty);
        }

        for (netlist.nets.items) |*net| {
            var hyper_edge = std.ArrayList(*Node).empty;
            defer _ = hyper_edge.deinit(allocator);

            for (net.binds.items) |gate| {
                var possible_node: ?*Node = null;
                for (self.nodes) |*search| {
                    if (search.content.gate == gate) {
                        possible_node = search;
                        break;
                    }
                }
                if (possible_node) |node| {
                    try hyper_edge.append(allocator, node);
                }
            }
            if (hyper_edge.items.len >= 2) {
                const hyper_slice = try hyper_edge.toOwnedSlice(allocator);
                for (hyper_slice) |node| {
                    var edges = self.edges.getPtr(node).?;
                    try edges.append(allocator, hyper_slice);
                }
                try self.raw_edges.append(allocator, hyper_slice);
            }
        }

        // try self.recalculate_edges();

        return self;
    }

    pub fn pretty_print(self: *const Self) void {
        std.debug.print("\nMODULE (area: {any})\n", .{self.area()});
        for (self.nodes) |*node| {
            node.pretty_print();
        }
    }
};
