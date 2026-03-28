pub const std = @import("std");
pub const glib = @import("abstract/graph.zig");
pub const plc = @import("placement.zig");

pub const PersistentCell = struct {
    const Self = @This();

    node_origin: ?glib.NodeId,
    forbidden: bool,
    overlap: u8,
    padding: bool,

    pub fn passable(self: *const Self, our_source: glib.NodeId) bool {
        return !self.forbidden and (self.node_origin == null or self.node_origin == our_source);
    }
};

pub const JPSCell = struct {
    const Self = @This();

    g: i64,
    h: i64,
    f: i64,
    position: Coord,
    parent: ?Coord,

    pub fn new(g: i64, h: i64, pos: Coord, parent: ?Coord) Self {
        return .{ .h = h, .g = g, .f = h + g, .position = pos, .parent = parent };
    }

    pub fn compareFunc(_: void, a: Self, b: Self) std.math.Order {
        if (a.f == b.f) {
            return .eq;
        } else if (a.f > b.f) {
            return .gt;
        } else {
            return .lt;
        }
    }
};

const Coord = @Vector(3, i64);

const Direction = enum {
    const Self = @This();

    up,
    down,
    left,
    right,

    upleft,
    upright,
    downleft,
    downright,

    pub fn asUnitCoord(self: *const Self) Coord {
        return switch (self.*) {
            .up => Coord{ 0, 0, 1 },
            .down => Coord{ 0, 0, -1 },
            .left => Coord{ -1, 0, 0 },
            .right => Coord{ 1, 0, 0 },

            .upleft => Coord{ -1, 0, 1 },
            .upright => Coord{ 1, 0, 1 },
            .downleft => Coord{ -1, 0, -1 },
            .downright => Coord{ 1, 0, -1 },
        };
    }
};

pub fn coordExact(a: Coord, b: Coord) bool {
    return a[0] == b[0] and
        a[1] == b[1] and
        a[2] == b[2];
}

pub fn coordManhattenDistance2D(a: Coord, b: Coord) i64 {
    const offsets = @abs(a - b);
    return @intCast(offsets[0] + offsets[1] + offsets[2]);
}

pub const Routing = struct {
    pub const Self = @This();

    const EdgeLocations = struct {
        a: @Vector(3, i64),
        b: @Vector(3, i64),

        pub fn manhattenDistance2D(self: *const EdgeLocations) i64 {
            return coordManhattenDistance2D(self.a, self.b);
        }
    };

    gpa: std.mem.Allocator,
    graph: *const glib.GateGraph,
    placement: *const plc.Placement,

    edge_locations: std.AutoArrayHashMap(glib.EdgeId, EdgeLocations),
    persistent_grid: std.AutoArrayHashMap(Coord, PersistentCell),

    max_coord: Coord,
    min_coord: Coord,

    current_goal: Coord,
    current_edge_id: glib.EdgeId,

    fn sortEdgesOnDistance(self: *const Self, a_id: glib.EdgeId, b_id: glib.EdgeId) bool {
        const a_dist = self.edge_locations.get(a_id).?.manhattenDistance2D();
        const b_dist = self.edge_locations.get(b_id).?.manhattenDistance2D();
        return a_dist > b_dist;
    }

    pub fn withinBounds(self: *Self, coord: Coord) bool {
        return (coord[0] >= self.min_coord[0] and coord[0] <= self.max_coord[0]) and
            (coord[1] >= self.min_coord[1] and coord[1] <= self.max_coord[1]) and
            (coord[2] >= self.min_coord[2] and coord[2] <= self.max_coord[2]);
    }

    pub fn getCell(self: *Self, coord: Coord) PersistentCell {
        if (self.persistent_grid.get(coord)) |found| {
            return found;
        } else {
            return .{
                .node_origin = null,
                .forbidden = false,
                .overlap = 0,
                .padding = false,
            };
        }
    }

    pub fn isCellPassable(self: *Self, coord: Coord) bool {
        return self.getCell(coord).passable(self.current_edge_id);
    }

    pub fn hasForcedNeighbour(self: *Self, from: Coord, direction: Direction) bool {
        const dir_unit = direction.asUnitCoord();
        if (dir_unit[0] != 0) {
            const direct_up = from + Coord{ 0, 0, 1 };
            const moved_up = from - dir_unit + Coord{ 0, 0, 1 };
            if (self.isCellPassable(direct_up) and !self.isCellPassable(moved_up)) return true;

            const direct_down = from + Coord{ 0, 0, -1 };
            const moved_down = from - dir_unit + Coord{ 0, 0, -1 };
            if (self.isCellPassable(direct_down) and !self.isCellPassable(moved_down)) return true;
        }
        if (dir_unit[2] != 0) {
            const direct_right = from + Coord{ 1, 0, 0 };
            const moved_right = from - dir_unit + Coord{ 1, 0, 0 };
            if (self.isCellPassable(direct_right) and !self.isCellPassable(moved_right)) return true;

            const direct_left = from + Coord{ -1, 0, 0 };
            const moved_left = from - dir_unit + Coord{ -1, 0, 0 };
            if (self.isCellPassable(direct_left) and !self.isCellPassable(moved_left)) return true;
        }
        return false;
    }

    pub fn jump(self: *Self, from: Coord) ?JPSCell {
        if (self.checkHorizontalVertical(from)) |found| return found;

        const diagonals = [4]Direction{ .upright, .upleft, .downright, .downleft };
        for (diagonals) |diagonal| {
            if (self.checkDiagonal(from, diagonal)) |found| return found;
        }

        return null;
    }

    pub fn checkHorizontalVertical(self: *Self, from: Coord) ?JPSCell {
        if (self.checkDirection(from, Direction.left)) |found| return found;
        if (self.checkDirection(from, Direction.right)) |found| return found;
        if (self.checkDirection(from, Direction.up)) |found| return found;
        if (self.checkDirection(from, Direction.down)) |found| return found;
        return null;
    }

    pub fn checkDiagonal(self: *Self, from: Coord, direction: Direction) ?JPSCell {
        var moving = from + direction.asUnitCoord();

        while (self.withinBounds(moving)) {
            if (!self.getCell(moving).passable(self.current_edge_id)) return null;
            if (self.checkHorizontalVertical(from)) |found| {
                return found;
                // return JPSCell.new(0, coordManhattenDistance2D(moving, self.current_goal), moving, null);
            }

            moving += direction.asUnitCoord();
        }

        return null;
    }

    pub fn checkDirection(self: *Self, from: Coord, direction: Direction) ?JPSCell {
        var moving = from + direction.asUnitCoord();

        while (self.withinBounds(moving)) {
            if (!self.getCell(moving).passable(self.current_edge_id)) return null;
            if (coordExact(moving, self.current_goal)) {
                return JPSCell.new(0, coordManhattenDistance2D(moving, self.current_goal), moving, null);
            }

            if (self.hasForcedNeighbour(moving, direction)) {
                return JPSCell.new(0, coordManhattenDistance2D(moving, self.current_goal), moving, null);
            }

            moving += direction.asUnitCoord();
        }
        return null;
    }

    pub fn routeEdge(self: *Self, edge_id: glib.EdgeId) ?[]Coord {
        // https://every-algorithm.github.io/2024/03/22/jump_point_search.html

        errdefer @panic("out of memory");

        const start = self.edge_locations.get(edge_id).?.a;
        const goal = self.edge_locations.get(edge_id).?.b;
        self.current_goal = goal;
        self.current_edge_id = edge_id;

        std.log.info("Pathfinding for edge {}, from {} to {}", .{ edge_id, start, goal });

        var open = std.PriorityQueue(JPSCell, void, JPSCell.compareFunc).init(self.gpa, undefined);
        var closed = std.AutoHashMap(Coord, JPSCell).init(self.gpa);

        try open.add(JPSCell.new(0, coordManhattenDistance2D(start, goal), start, null));

        var found: ?JPSCell = null;

        while (open.items.len > 0) {
            const current = open.remove();
            if (coordExact(current.position, goal)) {
                found = current;
                break;
            }
            try closed.put(current.position, current);
            std.debug.print("Considering {}\n", .{current.position});

            const directions = [8]Direction{ .left, .right, .up, .down, .upleft, .upright, .downleft, .downright };
            for (directions) |neighbour_dir| {
                const neighbour_coord = current.position + neighbour_dir.asUnitCoord();

                if (!self.withinBounds(neighbour_coord)) continue;
                if (closed.contains(neighbour_coord)) continue;

                var jump_cell = self.jump(neighbour_coord) orelse continue;
                if (closed.contains(jump_cell.position)) continue;
                jump_cell.parent = current.position;
                std.debug.print(" -> ADDING {} TO OPEN\n", .{jump_cell.position});
                try open.add(jump_cell);
            }
        }

        std.log.info("Found: {any}", .{found});

        var backtrack = found orelse @panic("TODO: No route found!");
        var trace = std.array_list.Managed(Coord).init(self.gpa);
        while (true) {
            std.debug.print("> {}\n", .{ backtrack.position });
            try trace.append(backtrack.position);
            if (backtrack.parent) |parent| {
                backtrack = closed.get(parent).?;
            }
            break;
        }

        for (0.., trace.items) |i, location| {
            std.log.info("  {}: {}", .{ i, location });
        }

        @panic(":)");
    }

    pub fn route(self: *Self) [][]Coord {
        errdefer @panic("Buy more ram at <404 ram shortage>");

        const most_expensive_edges = try self.gpa.dupe(glib.EdgeId, self.graph.edges.keys());
        defer self.gpa.free(most_expensive_edges);
        std.mem.sort(glib.EdgeId, most_expensive_edges, self, sortEdgesOnDistance);

        self.min_coord = Coord{ 0, 0, 0 };
        self.max_coord = Coord{ 20, 0, 20 };
        try self.edge_locations.put(69420, EdgeLocations{
            .a = Coord{ 2, 0, 5 },
            .b = Coord{ 8, 0, 6 },
        });
        _ = self.routeEdge(69420);

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
            .persistent_grid = .init(gpa),

            // teehee
            .current_goal = undefined,
            .current_edge_id = undefined,
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
