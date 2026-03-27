pub const std = @import("std");
pub const glib = @import("abstract/graph.zig");
pub const plc = @import("placement.zig");

pub const RoutingCell = union(enum) { forbidden, regular: struct { overlap: u8, node_origin: glib.NodeId, padding: bool } };

pub const Routing = struct {
    pub const Self = @This();

    const EdgeLocations = struct {
        a: @Vector(3, i64),
        b: @Vector(3, i64),

        pub fn manhatten_distance_2d(self: *EdgeLocations) i64 {
            const offsets = @abs(self.a - self.b);
            return offsets[0] + offsets[1] + offsets[2];
        }
    };

    gpa: std.mem.Allocator,
    graph: *const glib.GateGraph,
    placement: *const plc.Placement,
    edge_locations: std.AutoArrayHashMap(glib.EdgeId, EdgeLocations),

    max_coord: @Vector(3, i64),
    min_coord: @Vector(3, i64),

    pub fn deinit(self: *Self) void {
        self.edge_locations.deinit();
    }

    pub fn new(gpa: std.mem.Allocator, graph: *const glib.GateGraph, placement: *const plc.Placement) Self {
        errdefer @panic("Don't panic, it's just an OOM error... actually do panic!");

        var self = Self{
            .gpa = gpa,
            .graph = graph,
            .placement = placement,

            .min_coord = @Vector(3, i64){ std.math.maxInt(i64), std.math.maxInt(i64), std.math.maxInt(i64) },
            .max_coord = @Vector(3, i64){ std.math.minInt(i64), std.math.minInt(i64), std.math.minInt(i64) },

            .edge_locations = .init(gpa),
        };

        // Calculate the maximum bounding box, so that A* has limits
        for (self.graph.nodes.values()) |*node| {
            const position = self.placement.locations.get(node.id) orelse @panic("Node not placed");
            const size = node.body.kind.size();
            const w: i64 = @intCast(@as(u63, @truncate(size.w)));
            const h: i64 = @intCast(@as(u63, @truncate(size.h)));
            self.min_coord = @min(self.min_coord, @Vector(3, i64){ position.x, 0, position.y });
            self.max_coord = @max(self.max_coord, @Vector(3, i64){ position.x + w, 0, position.y + h });
        }
        // Some spacing for extra wires
        self.min_coord -= @splat(12);
        self.max_coord += @splat(12);

        // Assign positions to each node connection for all edges
        // This simplifies the algorithm, a LOT

        var input_filled_slots = std.AutoArrayHashMap(glib.NodeId, usize).init(gpa);
        defer input_filled_slots.deinit();

        for (graph.edges.values()) |*edge| {
            const a = graph.getConstNode(edge.a).?;
            const b = graph.getConstNode(edge.b).?;

            // TODO: support orientation!!!
            const a_position = placement.locations.get(a.id) orelse @panic("Node A has no location assigned, run placement first?");
            const b_position = placement.locations.get(b.id) orelse @panic("Node B has no location assigned, run placement first?");

            var a_loc = @Vector(3, i64){ a_position.x, 0, a_position.y };
            var b_loc = @Vector(3, i64){ b_position.x, 0, b_position.y };

            if (edge.a_relation == .input and edge.b_relation == .output) {
                const possible_a_locations = a.body.kind.inputPositionsRelative();
                const filled_slots = input_filled_slots.get(a.id) orelse 0;

                // TODO: support orientation!!!
                a_loc += possible_a_locations[filled_slots] orelse @panic("Gate has more than two inputs, system is currently not built to handle such cases");
                b_loc += b.body.kind.outputPositionsRelative();

                try input_filled_slots.put(a.id, filled_slots + 1);
            } else if (edge.b_relation == .input and edge.a_relation == .output) {
                const possible_b_locations = b.body.kind.inputPositionsRelative();
                const filled_slots = input_filled_slots.get(b.id) orelse 0;

                // TODO: support orientation!!!
                a_loc += a.body.kind.outputPositionsRelative();
                b_loc += possible_b_locations[filled_slots] orelse @panic("Gate has more than two inputs, system is currently not built to handle such cases");

                try input_filled_slots.put(b.id, filled_slots + 1);
            } else {
                @panic("Invalid graph, there must be no edges with input-input or output-output edges");
            }

            try self.edge_locations.putNoClobber(edge.id, .{
                .a = a_loc,
                .b = b_loc,
            });
        }

        for (input_filled_slots.keys()) |node_id| {
            const amount = input_filled_slots.get(node_id).?;
            const node = graph.getConstNode(node_id).?;
            if (amount != 2 and node.body.kind == .and_gate) {
                std.debug.print("Node ID {} ({s}) has {}\n", .{ node_id, node.body.symbol, amount });
            }
        }

        return self;
    }
};
