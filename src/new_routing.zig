pub const std = @import("std");
pub const glib = @import("abstract/graph.zig");
pub const plc = @import("placement.zig");

pub const RoutingCell = struct {
    const Self = @This();

    g: i64,
    h: i64,
    f: i64,

    position: Coord,
    parent: Coord,

    overlap: u8,
    node_origin: ?glib.NodeId,
    padding: bool,
    forbidden: bool,

    fn reset(self: *Self) void {
        self.g = 0;
        self.h = 0;
        self.f = std.math.maxInt(i64) - 1; // Do not remove this 1
    }
};

const Coord = @Vector(3, i64);

pub fn coordExact(a: Coord, b: Coord) bool {
    return a[0] == b[0] and
        a[1] == b[1] and
        a[2] == b[2];
}

pub fn coordManhattenDistance2D(a: Coord, b: Coord) u64 {
    const offsets = @abs(a - b);
    return offsets[0] + offsets[1] + offsets[2];
}

pub const Routing = struct {
    pub const Self = @This();

    const EdgeLocations = struct {
        a: @Vector(3, i64),
        b: @Vector(3, i64),

        pub fn manhattenDistance2D(self: *const EdgeLocations) u64 {
            return coordManhattenDistance2D(self.a, self.b);
        }
    };

    gpa: std.mem.Allocator,
    graph: *const glib.GateGraph,
    placement: *const plc.Placement,

    edge_locations: std.AutoArrayHashMap(glib.EdgeId, EdgeLocations),
    routing_grid: std.AutoArrayHashMap(Coord, RoutingCell),

    max_coord: Coord,
    min_coord: Coord,

    fn sortEdgesOnDistance(self: *const Self, a_id: glib.EdgeId, b_id: glib.EdgeId) bool {
        const a_dist = self.edge_locations.get(a_id).?.manhattenDistance2D();
        const b_dist = self.edge_locations.get(b_id).?.manhattenDistance2D();
        return a_dist > b_dist;
    }

    pub fn getCell(self: *Self, coord: Coord) *RoutingCell {
        errdefer @panic("OOM");

        const has_cell = self.routing_grid.getPtr(coord);
        if (has_cell) |existing| {
            return existing;
        }

        try self.routing_grid.put(coord, .{
            .g = 0,
            .h = 0,
            .f = std.math.maxInt(i64) - 1, // Do not remove this 1

            .position = coord,
            .parent = undefined,

            .overlap = 0,
            .node_origin = null,
            .padding = false,
            .forbidden = false,
        });
        return self.routing_grid.getPtr(coord).?;
    }

    pub fn withinBounds(self: *Self, coord: Coord) bool {
        return (coord[0] >= self.min_coord[0] and coord[0] <= self.max_coord[0]) and
            (coord[1] >= self.min_coord[1] and coord[1] <= self.max_coord[1]) and
            (coord[2] >= self.min_coord[2] and coord[2] <= self.max_coord[2]);
    }

    pub fn routeEdge(self: *Self, edge_id: glib.EdgeId) ?[]Coord {
        errdefer @panic("out of memory");
        std.log.info("Pathfinding for edge {}", .{edge_id});

        for (self.routing_grid.values()) |*cell| {
            cell.reset();
        }

        // Following:
        // https://www.geeksforgeeks.org/dsa/a-search-algorithm/

        const edge_locations = self.edge_locations.get(edge_id).?;
        // const edge = self.graph.getConstEdge(edge_id).?;

        const start_coord = edge_locations.a;
        const goal_coord = edge_locations.b;

        var open_list = std.array_list.Managed(Coord).init(self.gpa);
        var closed_list = std.array_list.Managed(Coord).init(self.gpa);
        defer open_list.deinit();
        defer closed_list.deinit();
        try open_list.append(start_coord);

        var found: ?Coord = null;
        open_list_loop: while (open_list.items.len != 0) {
            var q: Coord = undefined;
            var q_f: i64 = std.math.maxInt(i64);
            var q_index: usize = undefined;
            var q_g: i64 = undefined;
            for (0.., open_list.items) |index, candidate| {
                const cand_cell = self.getCell(candidate);
                if (cand_cell.f < q_f) {
                    q_f = cand_cell.f;
                    q = candidate;
                    q_index = index;
                    q_g = cand_cell.g;
                }
            }
            _ = open_list.swapRemove(q_index);

            if (coordExact(q, goal_coord)) {
                found = q;
                break :open_list_loop;
            }

            const successors = [4]Coord{
                q + Coord{ 1, 0, 0 },
                q + Coord{ -1, 0, 0 },
                q + Coord{ 0, 0, 1 },
                q + Coord{ 0, 0, -1 },
            };
            successor_loop: for (successors) |succ_coord| {
                if (!self.withinBounds(succ_coord)) continue :successor_loop;

                const successor = self.getCell(succ_coord);
                if (successor.forbidden) continue :successor_loop;

                // We can follow similar blocks coming from the same source for free
                const h: i64 = @intCast(coordManhattenDistance2D(succ_coord, goal_coord));
                // const g = q_g + @intFromBool(successor.node_origin != edge.id);
                const g = q_g + 1;
                const f = g + h;

                if (f < successor.f) {
                    successor.h = h;
                    successor.g = g;
                    successor.f = f;
                    successor.parent = q;

                    // Don't have duplicates in the open_list
                    for (open_list.items) |in_open| {
                        if (coordExact(in_open, succ_coord)) continue :successor_loop;
                    }
                    try open_list.append(succ_coord);
                }

                // If there's a cell in the same position as us which is better, then skip
                // TODO: Possible optimisation: maybe make the open_list a hashmap with position as key?
                // for (open_list.items) |check| {
                //     const check_cell = self.getCell(check);
                //     if (coordExact(check, succ_coord) and check_cell.f < f) {
                //         continue :successor_loop;
                //     }
                // }
                // for (closed_list.items) |check| {
                //     const check_cell = self.getCell(check);
                //     if (coordExact(check, succ_coord) and check_cell.f < f) {
                //         continue :successor_loop;
                //     }
                // }
            }

            try closed_list.append(q);
        }

        var trace = std.array_list.Managed(Coord).init(self.gpa);
        defer trace.deinit();

        var current = found orelse @panic("TODO: Impossible to route, provide proper feedback");

        std.log.info("Tracing back ID {}", .{edge_id});
        while (!coordExact(current, start_coord)) {
            try trace.append(current);
            current = self.getCell(current).parent;
        }
        std.log.info("[!] ROUTED WITH LEN {} FROM {} -> {}\n", .{ closed_list.items.len, start_coord, goal_coord });

        return try trace.toOwnedSlice();
    }

    pub fn route(self: *Self) [][]Coord {
        errdefer @panic("Buy more ram at <404 ram shortage>");

        const most_expensive_edges = try self.gpa.dupe(glib.EdgeId, self.graph.edges.keys());
        defer self.gpa.free(most_expensive_edges);
        std.mem.sort(glib.EdgeId, most_expensive_edges, self, sortEdgesOnDistance);

        var routes = std.array_list.Managed([]Coord).init(self.gpa);
        defer routes.deinit();
        for (most_expensive_edges) |edge_id| {
            const path = self.routeEdge(edge_id) orelse @panic("TODO");
            try routes.append(path);
        }

        return try routes.toOwnedSlice();
    }

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
            .routing_grid = .init(gpa),
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
