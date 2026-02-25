const std = @import("std");
const nl = @import("../netlist.zig");
const physical = @import("../physical.zig");

pub const GateNode = Node(nl.GatePtr);

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

        children: std.ArrayList(*Self),
        body: NodeBody,
        metadata: MetadataKind,

        pub fn area(self: *Self, netlist: *const nl.Netlist) u64 {
            return switch (self.content) {
                .gate => |gate_ptr| netlist.get_gate(gate_ptr).kind.size().area(),
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.children.deinit(allocator);
        }
    };
}

pub fn Edge(comptime NodeBody: type) type {
    return [2]*Node(NodeBody);
}

pub const GraphConstructors = struct {
    pub fn from_netlist(gpa: std.mem.Allocator, netlist: nl.Netlist) Graph {
        var nodes = std.ArrayList(Node).empty;
        for (0..netlist.gates.items.len) |gate_ptr| {
            try nodes.append(gpa, GateNode{
                .metadata = .none,
                .children = .empty,
                .body = gate_ptr,
            });
        }
    }
};

pub fn Graph(comptime NodeBody: type) type {
    return struct {
        const Self = @This();
        const Source = switch (NodeBody) {
            GateNode => struct {
                netlist: *const nl.Netlist,
            },
            else => void,
        };

        gpa: std.mem.Allocator,

        nodes: []Node(NodeBody),
        edges: []Edge(NodeBody),

        node2edges: std.AutoHashMap(*Node, std.ArrayList(Edge(NodeBody))),

        source: Source,

        pub fn deinit(self: *Self) void {
            var val_iter = self.node2edges.valueIterator();
            while (val_iter.next()) |arr| {
                arr.deinit(self.gpa);
            }

            self.gpa.free(self.nodes);
            self.gpa.free(self.edges);
        }

        pub fn new(gpa: std.mem.Allocator, nodes: []Node, edges: []Edge) !Self {
            var graph = Self{
                .gpa = gpa,
                .nodes = nodes,
                .edges = edges,
                .node2edges = .init(gpa),
            };

            for (edges) |edge| {
                const entry0 = try graph.node2edges.getOrPutValue(edge[0], .empty);
                try entry0.value_ptr.append(gpa, edge);
                const entry1 = try graph.node2edges.getOrPutValue(edge[1], .empty);
                try entry1.value_ptr.append(gpa, edge);
            }

            return graph;
        }
    };
}
