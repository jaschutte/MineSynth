const std = @import("std");
const nl = @import("../netlist.zig");
const physical = @import("../physical.zig");
const id = @import("id.zig");

pub const GateBody = nl.GatePtr;
pub const GateGraph = Graph(GateBody);
pub const GateNode = Node(GateBody);
pub const GateEdge = Edge(GateBody);

pub const NodeId = id.Id;
pub const EdgeId = id.Id;

pub fn Node(comptime NodeBody: type) type {
    return struct {
        const Self = @This();

        pub const MetadataKind = enum {
            none,
            partitioning,
        };

        pub const Metadata = union(MetadataKind) {
            none: void,
            partitioning: struct {
                fixed: bool,
            },
        };

        body: NodeBody,
        id: NodeId,
        metadata: MetadataKind,
        // Only null when the node is detached from any graph
        owner: ?*Graph(NodeBody),

        pub const edge_relation = switch (NodeBody) {
            GateBody => struct {
                pub const EdgeRelation = enum {
                    none,
                    input,
                    output,
                    inout,
                };

                fn relation(self: *const Self, edge_id: EdgeId) EdgeRelation {
                    const edge = self.owner.?.get_edge(edge_id).?;
                    const gate = self.get_gate();
                    const in: u2 = @intFromBool(std.mem.containsAtLeastScalar(usize, gate.inputs.items, 1, edge.body.net_id));
                    const out: u2 = @intFromBool(std.mem.containsAtLeastScalar(usize, gate.outputs.items, 1, edge.body.net_id));
                    return switch ((in << 1) | out) {
                        0b11 => .inout,
                        0b10 => .input,
                        0b01 => .output,
                        0b00 => .none,
                    };
                }
            }.relation,
            else => @compileError("NodeBody does not support retrieving the gate"),
        };

        pub const get_gate = switch (NodeBody) {
            GateBody => struct {
                fn gate(self: *const Self) *nl.Gate {
                    return self.owner.?.source.netlist.get_gate(self.body);
                }
            }.gate,
            else => @compileError("NodeBody does not support retrieving the gate"),
        };

        pub const get_size = switch (NodeBody) {
            GateBody => struct {
                fn size(self: *const Self) physical.Size {
                    return self.owner.?.source.netlist.get_gate_size(self.body);
                }
            }.size,
            else => @compileError("NodeBody does not support retrieving its size"),
        };

        pub const get_delay = switch (NodeBody) {
            GateBody => struct {
                fn delay(self: *const Self) physical.Delay {
                    return self.owner.?.source.netlist.get_gate_delay(self.body);
                }
            }.size,
            else => @compileError("NodeBody does not support retrieving its delay"),
        };

        pub const get_area = switch (NodeBody) {
            GateBody => struct {
                fn area(self: *const Self) physical.Area {
                    return self.size().area();
                }
            }.area,
            else => @compileError("NodeBody does not support retrieving its area"),
        };
    };
}

pub fn Edge(comptime NodeBody: type) type {
    return struct {
        const Self = @This();

        pub const Body = switch (NodeBody) {
            GateBody => struct {
                net_id: nl.NetPtr,
            },
            else => @compileError("Invalid node body"),
        };

        a: NodeId,
        b: NodeId,
        id: EdgeId,
        body: Body,
    };
}

pub const GraphConstructors = struct {
    pub fn from_netlist(gpa: std.mem.Allocator, netlist: *const nl.Netlist) !*GateGraph {
        var graph = try GateGraph.empty(gpa, .{
            .netlist = netlist,
        });

        var added_nodes = std.AutoHashMap(nl.GatePtr, NodeId).init(gpa);
        defer _ = added_nodes.deinit();
        var added_edges = std.AutoHashMap([2]nl.NetPtr, EdgeId).init(gpa);
        defer _ = added_edges.deinit();

        for (0..netlist.nets.items.len) |net_ptr| {
            const net = netlist.get_net(net_ptr);

            for (net.binds.items) |gate_ptr| {
                if (added_nodes.contains(gate_ptr)) continue;

                const node_id = id.get_id();
                try added_nodes.put(gate_ptr, node_id);
                try graph.add_node(GateNode{
                    .id = node_id,
                    .body = gate_ptr,
                    .metadata = .none,
                    .owner = graph,
                });
            }

            for (net.binds.items) |from_ptr| {
                for (net.binds.items) |to_ptr| {
                    if (from_ptr == to_ptr) continue;
                    if (added_edges.contains([2]nl.NetPtr{ from_ptr, to_ptr })) continue;
                    if (added_edges.contains([2]nl.NetPtr{ to_ptr, from_ptr })) continue;
                    try added_edges.put(.{ to_ptr, from_ptr }, undefined);

                    const edge_id = id.get_id();
                    try graph.add_edge(GateEdge{
                        .body = .{ .net_id = net_ptr },
                        .id = edge_id,
                        .a = added_nodes.get(from_ptr).?,
                        .b = added_nodes.get(to_ptr).?,
                    });
                }
            }
        }

        return graph;
    }
};

pub fn Graph(comptime NodeBody: type) type {
    return struct {
        const Self = @This();
        pub const Source = switch (NodeBody) {
            nl.GatePtr => struct {
                netlist: *const nl.Netlist,
            },
            else => @compileError("Invalid node body"),
        };
        pub const Body = NodeBody;

        gpa: std.mem.Allocator,

        nodes: std.ArrayList(Node(NodeBody)),
        edges: std.ArrayList(Edge(NodeBody)),

        node2edges: std.AutoHashMap(NodeId, std.ArrayList(EdgeId)),
        id2node_idx: std.AutoHashMap(NodeId, usize),
        id2edge_idx: std.AutoHashMap(EdgeId, usize),

        source: Source,

        pub fn get_edge(self: *Self, edge: EdgeId) ?*Edge(NodeBody) {
            const index = self.id2edge_idx.get(edge) orelse return undefined;
            return &self.edges.items[index];
        }

        pub fn get_node(self: *Self, node: NodeId) ?*Node(NodeBody) {
            const index = self.id2node_idx.get(node) orelse return undefined;
            return &self.nodes.items[index];
        }

        pub fn add_node(self: *Self, node: Node(NodeBody)) !void {
            try self.nodes.append(self.gpa, node);
            try self.id2node_idx.put(node.id, self.nodes.items.len - 1);
            try self.node2edges.putNoClobber(node.id, .empty);

            self.nodes.items[self.nodes.items.len - 1].owner = self;
        }

        // NOTE: when adding edges, **ALWAYS** make sure to have ALL NODES OF THE EDGE registered
        pub fn add_edge(self: *Self, edge: Edge(NodeBody)) !void {
            try self.edges.append(self.gpa, edge);
            try self.id2edge_idx.put(edge.id, self.edges.items.len - 1);
            try self.node2edges.getPtr(edge.a).?.append(self.gpa, edge.id);
            try self.node2edges.getPtr(edge.b).?.append(self.gpa, edge.id);
        }

        pub fn remove_edge(self: *Self, edge_id: EdgeId) !void {
            const index = self.id2edge_idx.get(edge_id).?;
            // const edge = self.get_edge(edge_id).?;
            _ = self.edges.swapRemove(index);
            if (index != self.edges.items.len) {
                try self.id2edge_idx.put(self.edges.items[index].id, index);
            }

            // const edges_a = self.node2edges.getPtr(edge.a).?;
            // if (std.mem.indexOfScalar(EdgeId, edges_a.items, edge.id)) |node_a_pos| {
            //     _ = edges_a.swapRemove(node_a_pos);
            // }
            // const edges_b = self.node2edges.getPtr(edge.b).?;
            // if (std.mem.indexOfScalar(EdgeId, edges_b.items, edge.id)) |node_b_pos| {
            //     _ = edges_b.swapRemove(node_b_pos);
            // }

            var n2e_iter = self.node2edges.valueIterator();
            while (n2e_iter.next()) |node_edges| {
                var to_remove_indices = std.ArrayList(usize).empty;
                defer _ = to_remove_indices.deinit(self.gpa);

                for (0.., node_edges.items) |node_index, ne_id| {
                    if (edge_id == ne_id) {
                        try to_remove_indices.append(self.gpa, node_index);
                    }
                }
                node_edges.orderedRemoveMany(to_remove_indices.items);
            }
        }

        pub fn remove_node(self: *Self, node: NodeId) !void {
            const index = self.id2node_idx.get(node).?;
            // In the case that someone is for some reason pointing to us rather than using IDs
            // Set the owner to null
            self.nodes.items[index].owner = null;
            self.nodes.swapRemove(index);
            try self.id2node_idx.put(self.nodes.items[index].id, index);

            // Also remove all edges related to this node
            self.node2edges.remove(node);
        }

        pub fn deinit(self: *Self) void {
            var val_iter = self.node2edges.valueIterator();
            while (val_iter.next()) |arr| {
                arr.deinit(self.gpa);
            }

            self.nodes.deinit(self.gpa);
            self.edges.deinit(self.gpa);
            self.node2edges.deinit();
            self.id2edge_idx.deinit();
            self.id2node_idx.deinit();
            self.gpa.destroy(self);
        }

        pub fn empty(gpa: std.mem.Allocator, source: Source) !*Self {
            var graph = try gpa.create(Self);
            graph.gpa = gpa;
            graph.nodes = .empty;
            graph.edges = .empty;
            graph.node2edges = .init(gpa);
            graph.id2node_idx = .init(gpa);
            graph.id2edge_idx = .init(gpa);
            graph.source = source;
            return graph;
        }

        /// Edges should NOT contain duplicates! This means if you have edge <A, B>, you may NOT have edge <B, A>!!!
        pub fn new(gpa: std.mem.Allocator, nodes: std.ArrayList(Node(NodeBody)), edges: std.ArrayList(Edge(NodeBody)), source: Source) !*Self {
            var graph = try gpa.create(Self);
            graph.gpa = gpa;
            graph.nodes = nodes;
            graph.edges = edges;
            graph.node2edges = .init(gpa);
            graph.id2node_idx = .init(gpa);
            graph.id2edge_idx = .init(gpa);
            graph.source = source;

            for (graph.nodes.items) |*node| {
                node.owner = graph;
            }

            for (0.., graph.nodes.items) |index, *node| {
                try graph.id2node_idx.put(node.id, index);
            }
            for (0.., graph.edges.items) |index, *edge| {
                try graph.id2edge_idx.put(edge.id, index);
            }

            for (graph.edges.items) |*edge| {
                if (graph.node2edges.getPtr(edge.a)) |edges_a| {
                    try edges_a.append(gpa, edge.id);
                } else {
                    try graph.node2edges.put(edge.a, .empty);
                }
                if (graph.node2edges.getPtr(edge.b)) |edges_b| {
                    try edges_b.append(gpa, edge.id);
                } else {
                    try graph.node2edges.put(edge.b, .empty);
                }
            }

            return graph;
        }
    };
}
