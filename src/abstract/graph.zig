const std = @import("std");
const nl = @import("../netlist.zig");
const physical = @import("../physical.zig");
const id = @import("id.zig");

pub const GateBody = struct {
    kind: nl.GateType,
    symbol: []const u8,
};
pub const GateGraph = Graph(GateBody);

pub const NodeId = id.Id;
pub const EdgeId = id.Id;

pub const GraphConstructors = struct {
    pub fn fromNetlist(gpa: std.mem.Allocator, netlist: *const nl.Netlist) *GateGraph {
        errdefer @panic("Ran out of memory lmao");

        var graph = GateGraph.empty(gpa, netlist);

        var added_nodes = std.AutoHashMap(nl.GatePtr, NodeId).init(gpa);
        defer _ = added_nodes.deinit();
        var added_edges = std.AutoHashMap([2]nl.GatePtr, EdgeId).init(gpa);
        defer _ = added_edges.deinit();

        for (0..netlist.nets.items.len) |net_ptr| {
            const net = netlist.getNet(net_ptr);

            for (net.binds.items) |gate_ptr| {
                if (added_nodes.contains(gate_ptr)) continue;

                const gate = netlist.getGate(gate_ptr);
                const node_id = graph.addNode(.{ .kind = gate.kind, .symbol = try gpa.dupe(u8, gate.symbol) }, .none);
                try added_nodes.put(gate_ptr, node_id);
            }

            for (net.binds.items) |from_ptr| {
                for (net.binds.items) |to_ptr| {
                    if (from_ptr == to_ptr) continue;
                    if (added_edges.contains([2]nl.GatePtr{ from_ptr, to_ptr })) continue;
                    if (added_edges.contains([2]nl.GatePtr{ to_ptr, from_ptr })) continue;
                    try added_edges.put(.{ to_ptr, from_ptr }, undefined);

                    const from_gate = netlist.getGate(from_ptr);
                    const from_in: u2 = @intFromBool(std.mem.containsAtLeastScalar(usize, from_gate.inputs.items, 1, net_ptr));
                    const from_out: u2 = @intFromBool(std.mem.containsAtLeastScalar(usize, from_gate.outputs.items, 1, net_ptr));
                    const from_relation = switch ((from_in << 1) | from_out) {
                        0b00 => continue,
                        0b10 => GateGraph.Edge.Relation.input,
                        0b01 => GateGraph.Edge.Relation.output,
                        0b11 => @panic("Gate output directly connected to input or vice versa"),
                    };

                    const to_gate = netlist.getGate(to_ptr);
                    const to_in: u2 = @intFromBool(std.mem.containsAtLeastScalar(usize, to_gate.inputs.items, 1, net_ptr));
                    const to_out: u2 = @intFromBool(std.mem.containsAtLeastScalar(usize, to_gate.outputs.items, 1, net_ptr));
                    const to_relation = switch ((to_in << 1) | to_out) {
                        0b00 => continue,
                        0b10 => GateGraph.Edge.Relation.input,
                        0b01 => GateGraph.Edge.Relation.output,
                        0b11 => @panic("Gate output directly connected to input or vice versa"),
                    };

                    var writer = std.io.Writer.Allocating.init(gpa);
                    defer writer.deinit();
                    try net.literal.writeSymbol(&writer.writer);

                    _ = graph.addEdge(added_nodes.get(from_ptr).?, from_relation, added_nodes.get(to_ptr).?, to_relation, .{
                        .symbol = try writer.toOwnedSlice(),
                        .negated = switch (net.literal.isNegated()) {
                            true => .negated,
                            false => .unnegated,
                        },
                    }, null);
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
            GateBody => *const nl.Netlist,
            else => void,
        };
        pub const Body = NodeBody;

        pub const Node = struct {
            const Self = @This();

            pub const MetadataKind = enum {
                none,
                partitioning,
                timing,
            };

            pub const Metadata = union(MetadataKind) {
                none: void,
                partitioning: struct {
                    fixed: bool,
                },
                timing: struct { actual_arrival: f32, required_arrival: f32, slack: f32 },
            };

            body: NodeBody,
            id: NodeId,
            metadata: Metadata,
            // Only null when the node is detached from any graph
            owner: ?*Graph(NodeBody),

            pub const edgeRelation = switch (NodeBody) {
                GateBody => struct {
                    fn relation(self: *const Node, edge_id: EdgeId) ?Edge.Relation {
                        const edge = (self.owner orelse return null).getEdge(edge_id) orelse return null;
                        if (edge.a == self.id) {
                            return edge.a_relation;
                        } else if (edge.b == self.id) {
                            return edge.b_relation;
                        } else {
                            return null;
                        }
                    }
                }.relation,
                else => @compileError("NodeBody does not support retrieving the gate"),
            };

            pub fn relatedNodes(self: *const Node, relation: Edge.Relation) []NodeId {
                const graph = self.owner.?;
                // Abusing the fact EdgeId and NodeIds are both 64 bits
                var edges = graph.getNodeEdges(self.id, relation);
                for (0.., edges) |index, edge_id| {
                    const opposite_id = graph.getEdge(edge_id).?.oppositeNode(self.id).?;
                    edges[index] = opposite_id;
                }
                return edges;
            }

            pub const getSize = switch (NodeBody) {
                GateBody => struct {
                    fn size(self: *const Node) physical.Size {
                        return self.owner.?.source.netlist.getGateSize(self.body);
                    }
                }.size,
                else => @compileError("NodeBody does not support retrieving its size"),
            };

            pub const getArea = switch (NodeBody) {
                GateBody => struct {
                    fn area(self: *const Node) physical.Area {
                        return self.size().area();
                    }
                }.area,
                else => @compileError("NodeBody does not support retrieving its area"),
            };

            pub fn deinit(self: *const Node, gpa: std.mem.Allocator) void {
                switch (NodeBody) {
                    GateBody => {
                        gpa.free(self.body.symbol);
                    },
                    else => {},
                }
            }
        };

        pub const Edge = struct {
            pub const Body = switch (NodeBody) {
                GateBody => struct {
                    pub const Negation = enum {
                        negated,
                        unnegated,
                        undefined,
                    };

                    symbol: []const u8,
                    negated: Negation,
                },
                else => void,
            };

            pub const Relation = enum {
                input,
                output,
            };

            body: Edge.Body,
            weight: f32,
            id: EdgeId,
            a: NodeId,
            a_relation: Relation,
            b: NodeId,
            b_relation: Relation,
            // Only null when the node is detached from any graph
            owner: ?*Graph(NodeBody),

            pub fn oppositeNode(self: *const Edge, this: NodeId) ?NodeId {
                if (self.a == this) {
                    return self.b;
                } else if (self.b == this) {
                    return self.a;
                } else {
                    return null;
                }
            }

            pub fn deinit(self: *const Edge, gpa: std.mem.Allocator) void {
                switch (NodeBody) {
                    GateBody => {
                        gpa.free(self.body.symbol);
                    },
                    else => {},
                }
            }
        };

        gpa: std.mem.Allocator,

        nodes: std.AutoArrayHashMap(NodeId, Node),
        edges: std.AutoArrayHashMap(EdgeId, Edge),
        node2edges: std.AutoArrayHashMap(NodeId, std.ArrayList(EdgeId)),

        source: Source,

        pub fn getEdge(self: *const Self, edge_id: EdgeId) ?*Edge {
            return self.edges.getPtr(edge_id);
        }

        pub fn getConstEdge(self: *const Self, edge_id: EdgeId) ?*const Edge {
            return self.edges.getPtr(edge_id);
        }

        pub fn getNode(self: *Self, node_id: NodeId) ?*Node {
            return self.nodes.getPtr(node_id);
        }

        pub fn getConstNode(self: *const Self, node_id: NodeId) ?*const Node {
            return self.nodes.getPtr(node_id);
        }

        pub fn getNodeEdges(self: *const Self, node_id: NodeId, filter: ?Edge.Relation) []EdgeId {
            errdefer @panic("Ran out of memory when retrieving node edges");

            const node = self.getConstNode(node_id) orelse @panic("Invalid node provided");

            var results = std.ArrayList(EdgeId).empty;
            if (self.node2edges.getPtr(node_id)) |edges| {
                if (filter) |f| {
                    for (edges.items) |edge_id| {
                        if (node.edgeRelation(edge_id) == f) {
                            try results.append(self.gpa, edge_id);
                        }
                    }
                } else {
                    try results.appendSlice(self.gpa, edges.items);
                }
            }

            return try results.toOwnedSlice(self.gpa);
        }

        pub fn addNode(self: *Self, body: Body, meta: Node.Metadata) NodeId {
            errdefer @panic("Ran out of memory when adding node");

            const node_id = id.getId();
            try self.nodes.putNoClobber(node_id, Node{
                .id = node_id,
                .body = body,
                .metadata = meta,
                .owner = self,
            });
            try self.node2edges.putNoClobber(node_id, .empty);
            return node_id;
        }

        // NOTE: when adding edges, **ALWAYS** make sure to have ALL NODES OF THE EDGE registered
        pub fn addEdge(self: *Self, a: NodeId, a_relation: Edge.Relation, b: NodeId, b_relation: Edge.Relation, body: Edge.Body, weight: ?f32) EdgeId {
            errdefer @panic("Ran out of memory when adding edge");

            const edge_id = id.getId();
            try self.edges.putNoClobber(edge_id, Edge{
                .weight = weight orelse 0,
                .body = body,
                .id = edge_id,
                .a = a,
                .a_relation = a_relation,
                .b = b,
                .b_relation = b_relation,
                .owner = self,
            });
            try self.node2edges.getPtr(a).?.append(self.gpa, edge_id);
            try self.node2edges.getPtr(b).?.append(self.gpa, edge_id);
            return edge_id;
        }

        pub fn removeEdge(self: *Self, edge_id: EdgeId) void {
            errdefer @panic("Ran out of memory when removing edge");

            self.edges.getPtr(edge_id).?.deinit(self.gpa);
            _ = self.edges.swapRemove(edge_id);

            for (self.node2edges.values()) |*node_edges| {
                var to_remove_indices = std.ArrayList(usize).empty;
                defer _ = to_remove_indices.deinit(self.gpa);

                for (0.., node_edges.items) |edge_index, ne_id| {
                    if (edge_id == ne_id) {
                        try to_remove_indices.append(self.gpa, edge_index);
                    }
                }
                node_edges.orderedRemoveMany(to_remove_indices.items);
            }
        }

        pub fn removeNode(self: *Self, node_id: NodeId) void {
            errdefer @panic("Ran out of memory when removing node");

            // The clone is required as `remove_edge` modifies the array whilst we iterate it
            // So we need a stable, non-moving array to iterate over
            var cloned = try self.node2edges.getPtr(node_id).?.clone(self.gpa);
            defer _ = cloned.deinit(self.gpa);
            for (cloned.items) |edge_id| {
                self.removeEdge(edge_id);
            }

            self.nodes.getPtr(node_id).?.deinit(self.gpa);
            _ = self.nodes.swapRemove(node_id);
            self.node2edges.getPtr(node_id).?.deinit(self.gpa);
            _ = self.node2edges.swapRemove(node_id);
        }

        pub fn deinit(self: *Self) void {
            for (self.node2edges.values()) |*node_edges| {
                node_edges.deinit(self.gpa);
            }

            for (self.nodes.values()) |*node| {
                node.deinit(self.gpa);
            }
            for (self.edges.values()) |*edge| {
                edge.deinit(self.gpa);
            }

            self.nodes.deinit();
            self.edges.deinit();
            self.node2edges.deinit();
            self.gpa.destroy(self);
        }

        pub fn empty(gpa: std.mem.Allocator, source: Source) *Self {
            errdefer @panic("Ran out of memory when creating empty graph");

            var graph = try gpa.create(Self);
            graph.gpa = gpa;
            graph.nodes = .init(gpa);
            graph.edges = .init(gpa);
            graph.node2edges = .init(gpa);
            graph.source = source;
            return graph;
        }

        const MarkState = enum {
            Unmarked,
            TempMark,
            PermMark,
        };

        // returns list of node id's in topological order.
        // output nodes are at the beginning of the array, input nodes are last.
        // so by iterating from the end of the array to the beginning we go from input to output.
        pub fn topologicalSort(self: *const Self) []NodeId {
            errdefer @panic("Ran out of memory during topological sort");
            var sorted = std.ArrayList(NodeId).empty;

            // perform depth first search:
            var marks = std.AutoHashMap(NodeId, MarkState).init(self.gpa);
            defer marks.deinit();
            var unmarked = std.ArrayList(NodeId).empty;
            defer unmarked.deinit(self.gpa);

            // add all to unmarked
            for (self.nodes.values()) |*node| {
                try marks.put(node.id, MarkState.Unmarked);
                try unmarked.append(self.gpa, node.id);
            }

            // permanently mark all nodes
            while (unmarked.items.len > 0) {
                if (!depthFirstSearchVisit(self, unmarked.items[0], &unmarked, &sorted, &marks)) return try sorted.toOwnedSlice(self.gpa);
                _ = unmarked.orderedRemove(0);
            }

            return try sorted.toOwnedSlice(self.gpa);
        }

        // returns whether to continue search
        // returns false when a cycle is found
        // marks the node according to the depth first search algorithm
        fn depthFirstSearchVisit(self: *const Self, node_id: NodeId, to_mark: *std.ArrayList(NodeId), sorted: *std.ArrayList(NodeId), marks: *std.AutoHashMap(NodeId, MarkState)) bool {
            errdefer @panic("Ran out of memory during topological sort");

            const m = marks.get(node_id) orelse {
                std.debug.print("ID not found\n", .{});
                return false;
            };
            // skip if already marked and abort if there is a cycle.
            switch (m) {
                .PermMark => return true,
                .TempMark => {
                    std.debug.print("cycle detected\n", .{});
                    return false;
                },
                .Unmarked => {},
            }
            try marks.put(node_id, MarkState.TempMark);
            // visit adjacent nodes
            const current_edges = self.getNodeEdges(node_id, .output);
            defer self.gpa.free(current_edges);
            for (current_edges) |edgeID| {
                var adjacent_node = self.getConstEdge(edgeID).?.b;
                if (adjacent_node == node_id) {
                    adjacent_node = self.getConstEdge(edgeID).?.a;
                }
                if (!depthFirstSearchVisit(self, adjacent_node, to_mark, sorted, marks)) return false;
            }
            try marks.put(node_id, MarkState.PermMark);
            try sorted.append(self.gpa, node_id);
            return true;
        }
    };
}
