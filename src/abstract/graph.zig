const std = @import("std");
const nl = @import("../netlist.zig");
const physical = @import("../physical.zig");
const id = @import("id.zig");

pub const GateBody = nl.GatePtr;
pub const GateGraph = Graph(GateBody);

pub const NodeId = id.Id;
pub const EdgeId = id.Id;

pub const GraphConstructors = struct {
    pub fn fromNetlist(gpa: std.mem.Allocator, netlist: *const nl.Netlist) *GateGraph {
        errdefer @panic("Ran out of memory lmao");

        var graph = GateGraph.empty(gpa, netlist);

        var added_nodes = std.AutoHashMap(nl.GatePtr, NodeId).init(gpa);
        defer _ = added_nodes.deinit();
        var added_edges = std.AutoHashMap([2]nl.NetPtr, EdgeId).init(gpa);
        defer _ = added_edges.deinit();

        for (0..netlist.nets.items.len) |net_ptr| {
            const net = netlist.getNet(net_ptr);

            for (net.binds.items) |gate_ptr| {
                if (added_nodes.contains(gate_ptr)) continue;

                const node_id = graph.addNode(gate_ptr, .none);
                try added_nodes.put(gate_ptr, node_id);
            }

            for (net.binds.items) |from_ptr| {
                for (net.binds.items) |to_ptr| {
                    if (from_ptr == to_ptr) continue;
                    if (added_edges.contains([2]nl.NetPtr{ from_ptr, to_ptr })) continue;
                    if (added_edges.contains([2]nl.NetPtr{ to_ptr, from_ptr })) continue;
                    try added_edges.put(.{ to_ptr, from_ptr }, undefined);

                    _ = graph.addEdge(added_nodes.get(from_ptr).?, added_nodes.get(to_ptr).?, net_ptr);
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
            nl.GatePtr => *const nl.Netlist,
            else => void,
        };
        pub const Body = NodeBody;

        pub const Node = struct {
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

            pub const EdgeRelation = enum {
                none,
                input,
                output,
                inout,
            };

            body: NodeBody,
            id: NodeId,
            metadata: MetadataKind,
            // Only null when the node is detached from any graph
            owner: ?*Graph(NodeBody),

            pub const edgeRelation = switch (NodeBody) {
                GateBody => struct {
                    fn relation(self: *const Node, edge_id: EdgeId) EdgeRelation {
                        const edge = self.owner.?.getEdge(edge_id).?;
                        const gate = self.getGate();
                        const in: u2 = @intFromBool(std.mem.containsAtLeastScalar(usize, gate.inputs.items, 1, edge.body));
                        const out: u2 = @intFromBool(std.mem.containsAtLeastScalar(usize, gate.outputs.items, 1, edge.body));
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

            pub const getGate = switch (NodeBody) {
                GateBody => struct {
                    fn gate(self: *const Node) *nl.Gate {
                        return self.owner.?.source.getGate(self.body);
                    }
                }.gate,
                else => @compileError("NodeBody does not support retrieving the gate"),
            };

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
        };

        pub const Edge = struct {
            const Self = @This();

            pub const Body = switch (NodeBody) {
                GateBody => nl.NetPtr,
                else => void,
            };

            body: Edge.Body,
            id: EdgeId,
            a: NodeId,
            b: NodeId,
            // Only null when the node is detached from any graph
            owner: ?*Graph(NodeBody),
        };

        gpa: std.mem.Allocator,

        nodes: std.AutoArrayHashMap(NodeId, Node),
        edges: std.AutoArrayHashMap(EdgeId, Edge),
        node2edges: std.AutoArrayHashMap(NodeId, std.ArrayList(EdgeId)),

        source: Source,

        pub fn getEdge(self: *Self, edge_id: EdgeId) ?*Edge {
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

        pub fn getNodeEdges(self: *const Self, node_id: NodeId, filter: ?Node.EdgeRelation) []EdgeId {
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
        pub fn addEdge(self: *Self, a: NodeId, b: NodeId, body: Edge.Body) EdgeId {
            errdefer @panic("Ran out of memory when adding edge");

            const edge_id = id.getId();
            try self.edges.putNoClobber(edge_id, Edge{
                .body = body,
                .id = edge_id,
                .a = a,
                .b = b,
                .owner = self,
            });
            try self.node2edges.getPtr(a).?.append(self.gpa, edge_id);
            try self.node2edges.getPtr(b).?.append(self.gpa, edge_id);
            return edge_id;
        }

        pub fn removeEdge(self: *Self, edge_id: EdgeId) void {
            errdefer @panic("Ran out of memory when removing edge");

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
                try self.removeEdge(edge_id);
            }

            _ = self.nodes.swapRemove(node_id);
            self.node2edges.getPtr(node_id).?.deinit(self.gpa);
            _ = self.node2edges.swapRemove(node_id);
        }

        pub fn deinit(self: *Self) void {
            for (self.node2edges.values()) |*node_edges| {
                node_edges.deinit(self.gpa);
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
    };
}
