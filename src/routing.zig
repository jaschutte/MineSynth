const std = @import("std");
const phys = @import("physical.zig");
const nbt = @import("nbt.zig");
const comp = @import("components/components.zig");
const ms = @import("abstract/structures.zig");

// some renames
const WorldCoord = ms.WorldCoord;
const Allocator = std.mem.Allocator;
const ForbiddenZone = ms.ForbiddenZone;
const Block = ms.AbsBlock;

pub const Router = @This();

pub const Config = struct {
    max_iterations: u32 = 20,
    violation_cost_multiplier: f16 = 10,
    max_length: u32 = 1000,
    max_astar_iterations: u32 = 10000,
};

config: Config = .{},
a: Allocator = undefined,
pairs: []RoutePair = undefined,
route_infos: []RouteInfo = undefined,
route_results: []RoutingResult = undefined,

pub const RoutePair = struct {
    from: WorldCoord,
    to: WorldCoord,
};

const RouteInfo = struct {
    id: usize,
    dest: WorldCoord,
    origins: std.ArrayList(WorldCoord),
    sister_routes: std.ArrayList(usize),
};

pub fn vecEq(a: WorldCoord, b: WorldCoord) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2];
}

/// Calculates the Manhattan distance between two WorldCoord points.
/// Manhattan distance = |x1 - x2| + |y1 - y2| + |z1 - z2|
pub fn manhattanDistance(coord1: WorldCoord, coord2: WorldCoord) u32 {
    const dx = if (coord1[0] > coord2[0]) coord1[0] - coord2[0] else coord2[0] - coord1[0];
    const dy = if (coord1[1] > coord2[1]) coord1[1] - coord2[1] else coord2[1] - coord1[1];
    const dz = if (coord1[2] > coord2[2]) coord1[2] - coord2[2] else coord2[2] - coord1[2];

    return @as(u32, @intCast(dx + dy + dz));
}

pub const Violation = struct {
    loc: WorldCoord,
    violated_routes: std.ArrayList(usize),
};

pub const RoutingResult = struct {
    blocks: std.ArrayList(Block),
    cost: f16,
    delay: u32,
    length: u32,
    violations: std.ArrayList(Violation),

    pub fn deinit(self: *RoutingResult, allocator: Allocator) void {
        self.blocks.deinit(allocator);
        self.violations.deinit(allocator);
    }
};

fn sortPairsManhattan(descending: bool, a: RoutePair, b: RoutePair) bool {
    const distA = manhattanDistance(a.from, a.to);
    const distB = manhattanDistance(b.from, b.to);
    return if (descending) distA > distB else distA < distB;
}

pub fn routeAll(
    router: *Router,
    a: Allocator,
    seed: u32,
    pairs: []RoutePair,
    forbidden_zone: *ForbiddenZone,
) !RoutingResult {
    var arena = std.heap.ArenaAllocator.init(a);
    const arena_a = arena.allocator();
    defer arena.deinit();
    router.a = arena_a;

    // initiate rng
    var rng = std.Random.DefaultPrng.init(seed);
    rng.fill(&.{});

    // sort pairs
    std.sort.block(RoutePair, pairs, true, sortPairsManhattan);

    // allocate routeinfo for each pair
    router.route_infos = try arena_a.alloc(RouteInfo, pairs.len);
    router.route_results = try arena_a.alloc(RoutingResult, pairs.len);
    for (pairs, 0..) |pair, i| {
        router.route_infos[i] = RouteInfo{
            .id = i,
            .dest = pair.to,
            .origins = .empty,
            .sister_routes = .empty,
        };
        // add the primary origin for this route
        try router.route_infos[i].origins.append(arena_a, pair.from);
        // add routes that have the same origin to sister_routes
        for (pairs, 0..) |other_pair, j| {
            if (i != j and vecEq(pair.from, other_pair.from))
                try router.route_infos[i].sister_routes.append(arena_a, j);
        }
    }

    // initial route pass
    for (pairs, 0..) |pair, i| {
        _ = pair; // autofix
        const result = try routeAStar(router, arena_a, router.route_infos[i], forbidden_zone);
        // once a result is geneated, let the sister routes know that they can use any point along the path as an origin
        for (result.blocks.items) |block| {
            for (router.route_infos[i].sister_routes.items) |sister_index| {
                try router.route_infos[sister_index].origins.append(arena_a, block.loc);
            }
        }
        router.route_results[i] = result;
    }

    var total_result = RoutingResult{
        .blocks = .empty,
        .cost = 0,
        .delay = 0,
        .length = 0,
        .violations = .empty,
    };
    for (router.route_results) |result| {
        try total_result.blocks.appendSlice(a, result.blocks.items);
        total_result.cost += result.cost;
        total_result.delay = @max(total_result.delay, result.delay);
        total_result.length += result.length;
        for (result.violations.items) |violation| {
            try total_result.violations.append(a, violation);
        }
    }

    return total_result;
}

const AStarQueue = std.PriorityQueue(AStarQueueItem, *Router, AStarQueueItem.compare);
const AStarQueueItem = struct {
    coord: WorldCoord,
    signal_strength: u8,
    g_cost: f16,
    f_cost: f16,

    pub fn compare(router: *Router, self: AStarQueueItem, other: AStarQueueItem) std.math.Order {
        _ = router; // autofix
        return std.math.order(self.f_cost, other.f_cost);
    }
};

const ParentInfo = struct {
    parent: WorldCoord,
    move: Move,
    violation: ?Violation,
};

// Single struct to hold all node information, reducing hash map lookups
const AStarNode = struct {
    visited: bool = false,
    cost_so_far: f16 = std.math.inf(f16),
    parent: ?ParentInfo = null,
};

const Validity = union(enum) {
    valid,
    invalid,
    violation: Violation,
};

fn moveValidity(router: *Router, move: Move, forbidden_zone: *ForbiddenZone, current_route_id: usize) Validity {
    const conflict = forbidden_zone.get(move.to) orelse return .valid;
    if (conflict.ftype == .gate) return .invalid;

    // Allow passage if the current route (or a sister route) already owns this coordinate
    for (conflict.route_ids.items) |id| {
        if (id == current_route_id) return .valid;

        // Optional: If sister routes are allowed to cross, check them here
        for (router.route_infos[current_route_id].sister_routes.items) |sister_id| {
            if (id == sister_id) return .valid;
        }
    }

    // find out who is being violated
    var violation = Violation{
        .loc = move.to,
        .violated_routes = .empty,
    };
    for (conflict.route_ids.items) |id| {
        violation.violated_routes.append(router.a, router.route_infos[id].id) catch @panic("oom");
    }
    // append own id
    violation.violated_routes.append(router.a, current_route_id) catch @panic("oom");
    return .{ .violation = violation };
}

fn routeAStar(router: *Router, a: Allocator, info: RouteInfo, forbidden_zone: *ForbiddenZone) !RoutingResult {

    // Set up A* data structures
    var queue = AStarQueue.init(a, router);
    defer queue.deinit();

    // Single hash map to hold all node information - reduces lookups from 3 maps to 1
    var nodes = std.AutoHashMap(WorldCoord, AStarNode).init(a);
    defer nodes.deinit();

    std.log.info("Routing from {any} to {any} with {d} origins and {d} sister routes", .{ info.dest, info.origins.items[0], info.origins.items.len, info.sister_routes.items.len });

    var result = RoutingResult{
        .blocks = .empty,
        .cost = 0,
        .delay = 0,
        .length = 0,
        .violations = .empty,
    };

    // Initialize with destination (working backwards from destination to any origin)
    try queue.add(.{
        .coord = info.dest,
        .g_cost = 0,
        .f_cost = 0, // heuristic is 0 for the destination
        .signal_strength = 15, // start with max signal strength at the destination, will decay as we move towards origins
    });
    try nodes.put(info.dest, AStarNode{ .cost_so_far = 0 });

    var iterations: u32 = 0;
    var found_path = false;
    var final_coord: WorldCoord = undefined;

    // Main A* loop
    while (queue.count() > 0 and iterations < router.config.max_astar_iterations) {
        iterations += 1;

        const current = queue.remove();

        // Get or create node info with single lookup
        const node_result = try nodes.getOrPut(current.coord);
        const current_node = node_result.value_ptr;

        // Skip if we've already visited this node with a better path
        if (current_node.visited) continue;
        current_node.visited = true;

        // Check if we've reached any origin point
        var reached_origin = false;

        // Check if current position is in the origins list
        for (info.origins.items) |origin| {
            if (vecEq(current.coord, origin)) {
                reached_origin = true;
                break;
            }
        }

        if (reached_origin) {
            found_path = true;
            final_coord = current.coord;
            break;
        }

        // Get neighbors of current position
        const moves = getMoves(current.coord);
        for (moves) |move| {
            const neighbor_coord = current.coord + move.offset;

            // Get or create neighbor node info with single lookup
            const neighbor_result = try nodes.getOrPutValue(neighbor_coord, AStarNode{});
            const neighbor_node = neighbor_result.value_ptr;

            // Skip if already visited
            if (neighbor_node.visited) continue;

            const new_signal_strength = switch (move.signal_behavior) {
                .decay => if (current.signal_strength > 0) current.signal_strength - 1 else 0,
                .reset => 15, // reset to max signal strength when using a via
                .via => 14, // no change in signal strength for normal moves
            };
            if (new_signal_strength == 0) continue; // skip if signal strength has decayed to 0

            // check validity
            const validity = moveValidity(router, move, forbidden_zone, info.id);
            if (validity == .invalid) continue; // skip invalid moves

            // Calculate movement cost
            const calculated_cost = calculateMovementCost(current.coord, neighbor_coord, move, forbidden_zone);
            const movement_cost = if (validity == .violation) calculated_cost * router.config.violation_cost_multiplier else calculated_cost;
            const new_cost = current.g_cost + movement_cost;

            // Skip if we've found a better path to this neighbor already
            if (new_cost >= neighbor_node.cost_so_far) continue;

            // Update neighbor with better path
            neighbor_node.cost_so_far = new_cost;
            neighbor_node.parent = .{
                .parent = current.coord,
                .move = move,
                .violation = if (validity == .violation) validity.violation else null,
            };

            // Calculate heuristic (distance to nearest origin)
            const heuristic = calculateHeuristic(neighbor_coord, info.origins.items);
            const estimated_total = new_cost + heuristic;

            // Add to queue
            try queue.add(.{
                .coord = neighbor_coord,
                .g_cost = new_cost,
                .f_cost = estimated_total,
                .signal_strength = new_signal_strength,
            });
        }
    }

    // Reconstruct path if found
    if (found_path) {
        if (nodes.get(final_coord)) |final_node| {
            result.cost = final_node.cost_so_far;
        }

        // 1. Add final destination block and its padding
        for (comp.components[0].build_blocks) |build_block| {
            const loc = final_coord + build_block.offset;
            try result.blocks.append(a, Block{
                .loc = loc,
                .block = build_block.cat,
                .rot = build_block.rot,
            });
            try markForbidden(forbidden_zone, a, loc, .wire, info.id);
        }
        for (comp.components[0].padding) |pad_offset| {
            const pad_loc = final_coord + pad_offset;
            try markForbidden(forbidden_zone, a, pad_loc, .wire_padding, info.id);
        }
        result.length += 1;

        // 2. Build path back to destination
        var current_coord = final_coord;

        while (!vecEq(current_coord, info.dest)) {
            if (nodes.get(current_coord)) |current_node| {
                if (current_node.parent) |parent_info| {
                    const component = parent_info.move.def;
                    const heading = parent_info.move.heading;

                    // check violating
                    if (parent_info.violation) |v| {
                        try result.violations.append(a, v);
                    }

                    for (component.build_blocks) |build_block| {
                        const rotated_offset = comp.rotateCoord(build_block.offset, heading);
                        const loc = parent_info.parent + rotated_offset;

                        try result.blocks.append(a, Block{
                            .loc = loc,
                            .block = build_block.cat,
                            .rot = comp.rotateOrientation(build_block.rot, heading),
                        });
                        try markForbidden(forbidden_zone, a, loc, .wire, info.id);
                    }

                    for (component.padding) |pad_offset| {
                        const rotated_offset = comp.rotateCoord(pad_offset, heading);
                        const loc = parent_info.parent + rotated_offset;
                        try markForbidden(forbidden_zone, a, loc, .wire_padding, info.id);
                    }

                    result.length += 1;
                    current_coord = parent_info.parent;
                } else {
                    break;
                }
            } else {
                break;
            }
        }
    }

    std.log.info("A* iterations: {d}, found path: {any}, final coord: {any}, cost: {d}, delay: {d}, num_blocks: {d}, violations: {d}", .{
        iterations,
        found_path,
        final_coord,
        result.cost,
        result.delay,
        result.blocks.items.len,
        result.violations.items.len,
    });

    return result;
}

const Move = struct {
    from: WorldCoord,
    to: WorldCoord,
    def: *const comp.ComponentDef,
    offset: WorldCoord,
    signal_behavior: comp.SignalBehavior,
    heading: WorldCoord,
};

inline fn getMoves(from: WorldCoord) [4 * comp.components.len]Move {
    var moves: [4 * comp.components.len]Move = undefined;
    var index: usize = 0;

    for (&comp.components) |*component| {
        for ([_]WorldCoord{ .{ 1, 0, 0 }, .{ 0, 0, 1 }, .{ -1, 0, 0 }, .{ 0, 0, -1 } }) |cdir| {
            moves[index] = .{
                .from = from,
                .to = from + cdir,
                .offset = comp.rotateCoord(component.base_dir, cdir),
                .heading = cdir,
                .signal_behavior = component.signal_behavior,
                .def = component,
            };
            index += 1;
        }
    }

    return moves;
}

/// Calculate the cost of moving from one coordinate to another
/// This is a placeholder that can be customized based on routing requirements
fn calculateMovementCost(from: WorldCoord, to: WorldCoord, move: Move, forbidden_zone: *ForbiddenZone) f16 {
    _ = from; // autofix
    _ = to; // autofix
    _ = forbidden_zone; // autofix

    // Basic movement cost - can be enhanced later with:
    // - Forbidden zone penalties
    // - Direction change penalties
    // - Congestion costs
    // - Layer change costs
    // etc.
    const cost = move.def.delay + move.def.length; // base cost from component definition
    return @as(f16, @floatFromInt(cost));
}

/// Calculate heuristic (estimated cost to reach any origin)
/// This uses the minimum Manhattan distance to any origin point
fn calculateHeuristic(coord: WorldCoord, origins: []WorldCoord) f16 {
    if (origins.len == 0) {
        return 0; // No origins, so heuristic is 0
    }

    var min_distance: u32 = std.math.maxInt(u32);

    for (origins) |origin| {
        const distance = manhattanDistance(coord, origin);
        if (distance < min_distance) {
            min_distance = distance;
        }
    }

    return @as(f16, @floatFromInt(min_distance));
}

fn markForbidden(
    forbidden_zone: *ForbiddenZone,
    allocator: Allocator,
    loc: WorldCoord,
    ftype: ms.ForbiddenZoneType,
    route_id: usize,
) !void {
    const entry = try forbidden_zone.getOrPut(loc);
    if (!entry.found_existing) {
        entry.value_ptr.* = .{
            .ftype = ftype,
            .route_ids = .empty,
        };
    } else if (entry.value_ptr.ftype != .gate) {
        // A physical wire overrides wire_padding for the cell's primary type
        if (ftype == .wire and entry.value_ptr.ftype == .wire_padding) {
            entry.value_ptr.ftype = .wire;
        }
    }

    // Append the route_id if it isn't already in the list
    for (entry.value_ptr.route_ids.items) |existing_id| {
        if (existing_id == route_id) return;
    }
    try entry.value_ptr.route_ids.append(allocator, route_id);
}
