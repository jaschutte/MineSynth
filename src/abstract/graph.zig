const std = @import("std");
const nl = @import("../netlist.zig");
const physical = @import("../physical.zig");
const id = @import("id.zig");

pub const GateGraph = Graph(nl.GatePtr);
pub const GateNode = Node(nl.GatePtr);
pub const GateEdge = Edge(nl.GatePtr);

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

        children: std.ArrayList(NodeId),
        body: NodeBody,
        id: NodeId,
        metadata: MetadataKind,

        // pub fn area(self: *Self, netlist: *const nl.Netlist) u64 {
        //     return switch (self.content) {
        //         .gate => |gate_ptr| netlist.get_gate(gate_ptr).kind.size().area(),
        //     };
        // }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.children.deinit(allocator);
        }
    };
}

pub fn Edge(comptime NodeBody: type) type {
    return struct {
        pub const Body = switch (NodeBody) {
            nl.GatePtr => struct {
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
    pub fn from_netlist(gpa: std.mem.Allocator, netlist: *const nl.Netlist) !GateGraph {
        var index2id = std.AutoArrayHashMap(usize, NodeId).init(gpa);
        defer _ = index2id.deinit();
        var nodes = std.ArrayList(GateNode).empty;
        for (0..netlist.gates.items.len) |gate_ptr| {
            const node_id = id.get_id();
            try index2id.put(gate_ptr, node_id);
            try nodes.append(gpa, GateNode{
                .metadata = .none,
                .children = .empty,
                .id = node_id,
                .body = gate_ptr,
            });
        }

        var edges = std.ArrayList(GateEdge).empty;
        var edge_exists = std.AutoArrayHashMap(struct { a: NodeId, b: NodeId }, void).init(gpa);
        defer _ = edge_exists.deinit();
        for (0..netlist.nets.items.len) |net_ptr| {
            const net = netlist.get_net(net_ptr);
            for (net.binds.items) |a| {
                for (net.binds.items) |b| {
                    const a_id = index2id.get(a).?;
                    const b_id = index2id.get(b).?;
                    if (a_id == b_id) continue;
                    if (edge_exists.contains(.{ .a = a, .b = b })) continue;
                    if (edge_exists.contains(.{ .a = b, .b = a })) continue;
                    try edge_exists.put(.{ .a = a, .b = b }, undefined);
                    try edges.append(gpa, GateEdge{
                        .a = a_id,
                        .b = b_id,
                        .id = id.get_id(),
                        .body = .{ .net_id = net_ptr },
                    });
                }
            }
        }

        return GateGraph.new(gpa, nodes, edges, .{
            .netlist = netlist,
        });
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
            const index = self.id2edge_idx.get(edge) orelse return;
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
        }

        // NOTE: when adding edges, **ALWAYS** make sure to have ALL NODES OF THE EDGE registered
        pub fn add_edge(self: *Self, edge: Edge(NodeBody)) !void {
            try self.edges.append(self.gpa, edge);
            try self.id2edge_idx.put(edge.id, self.edges.items.len - 1);
            try self.node2edges.getPtr(edge.a).?.append(self.gpa, edge.id);
            try self.node2edges.getPtr(edge.b).?.append(self.gpa, edge.id);
        }

        pub fn remove_edge(self: *Self, edge: EdgeId) !void {
            const index = self.id2node_idx.get(edge).?;
            self.edges.swapRemove(index);
            try self.id2edge_idx.put(self.edges.items[index].id, index);

            const node_a = self.node2edges.getPtr(edge.a).?;
            if (std.mem.indexOf(u64, node_a.items, edge.id)) |node_a_pos| {
                node_a.swapRemove(node_a_pos);
            }
            const node_b = self.node2edges.getPtr(edge.b).?;
            if (std.mem.indexOf(u64, node_b.items, edge.id)) |node_b_pos| {
                node_b.swapRemove(node_b_pos);
            }
        }

        pub fn remove_node(self: *Self, node: NodeId) !void {
            const index = self.id2node_idx.get(node).?;
            self.nodes.swapRemove(index);
            try self.id2node_idx.put(self.nodes.items[index].id, index);

            // Ew, big loop
            // But we have to remove all references to this node if we erase it
            // At least, all references known to us
            var remove_ids = std.ArrayList(usize).empty;
            defer _ = remove_ids.deinit(self.gpa);
            for (self.nodes.items) |*parent| {
                remove_ids.clearRetainingCapacity();
                for (parent.children.items) |child_id| {
                    if (child_id == node) {
                        try remove_ids.append(self.gpa, child_id);
                    }
                }
                parent.children.orderedRemoveMany(remove_ids.items);
            }

            // Also remove all edges related to this node
            self.edges.orderedRemoveMany(self.node2edges.get(node).?.items);
            self.node2edges.remove(node);
        }

        pub fn deinit(self: *Self) void {
            var val_iter = self.node2edges.valueIterator();
            while (val_iter.next()) |arr| {
                arr.deinit(self.gpa);
            }

            for (self.nodes.items) |*node| {
                node.deinit(self.gpa);
            }

            self.nodes.deinit(self.gpa);
            self.edges.deinit(self.gpa);
            self.node2edges.deinit();
            self.id2edge_idx.deinit();
            self.id2node_idx.deinit();
        }

        pub const node_size = switch (NodeBody) {
            GateNode => struct {
                fn size(self: *const Self, node: *const Node(NodeBody)) physical.Size {
                    return self.source.netlist.get_gate(node).kind.size();
                }
            }.size,
            else => @compileError("Invalid node body"),
        };

        pub const node_area = switch (NodeBody) {
            GateNode => struct {
                fn area(self: *const Self, node: *const Node(NodeBody)) u64 {
                    return self.node_size(node).area();
                }
            }.area,
            else => @compileError("Invalid node body"),
        };

        /// Edges should NOT contain duplicates! This means if you have edge <A, B>, you may NOT have edge <B, A>!!!
        pub fn new(gpa: std.mem.Allocator, nodes: std.ArrayList(Node(NodeBody)), edges: std.ArrayList(Edge(NodeBody)), source: Source) !Self {
            var graph = Self{
                .gpa = gpa,
                .nodes = nodes,
                .edges = edges,
                .node2edges = .init(gpa),
                .id2node_idx = .init(gpa),
                .id2edge_idx = .init(gpa),
                .source = source,
            };

            for (0.., nodes.items) |index, *node| {
                try graph.id2node_idx.put(node.id, index);
            }
            for (0.., edges.items) |index, *edge| {
                try graph.id2edge_idx.put(edge.id, index);
            }

            for (edges.items) |*edge| {
                const entry_a = try graph.node2edges.getOrPutValue(edge.a, .empty);
                try entry_a.value_ptr.append(gpa, edge.id);
                const entry_b = try graph.node2edges.getOrPutValue(edge.b, .empty);
                try entry_b.value_ptr.append(gpa, edge.id);
            }

            for (edges.items) |*edge| {
                const a = graph.get_node(edge.a).?;
                const b = graph.get_node(edge.b).?;
                try a.children.append(gpa, b.id);
                try b.children.append(gpa, a.id);
            }

            return graph;
        }
    };
}
