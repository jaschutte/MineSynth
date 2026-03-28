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
    violation_cost_multiplier: f16 = 5.0,
    violation_cost_increase: f16 = 1.0,
    max_length: u32 = 1000,
    max_astar_iterations: u32 = 100000,
    astar_iterations_increase: u32 = 100000,
    path_length_bound_multiplier: f16 = 8.0,
};

config: Config = .{},
var_config: Config = .{},
a: Allocator = undefined,
external_a: Allocator = undefined,
pairs: []RoutePair = undefined,
route_infos: []RouteInfo = undefined,
route_results: []RoutingResult = undefined,

const MIN_Y = 1;
const MAX_Y = 10;

pub const RoutePair = struct {
    from: WorldCoord,
    to: WorldCoord,
};

pub const Origin = struct {
    loc: WorldCoord,
    signal: u8, // The forward signal strength available at this point
};

const RouteInfo = struct {
    id: usize,
    src: WorldCoord,
    dest: WorldCoord,
    origins: std.ArrayList(Origin),
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
    moves: std.ArrayList(Move),
    cost: f16,
    delay: u32,
    length: u32,
    failed: bool,
    violations: std.ArrayList(Violation),

    pub fn deinit(self: *RoutingResult, allocator: Allocator) void {
        self.blocks.deinit(allocator);
        self.violations.deinit(allocator);

        self.moves.deinit(allocator);
    }
};

pub fn ripUp(router: *Router, a: Allocator, route_id: usize, forbidden_zone: *ForbiddenZone) !void {
    const result = &router.route_results[route_id];

    // 1. Remove this route's footprint from the forbidden zone
    var keys_to_remove: std.ArrayList(WorldCoord) = .empty;
    defer keys_to_remove.deinit(a);

    var fz_it = forbidden_zone.iterator();
    while (fz_it.next()) |entry| {
        var ids = &entry.value_ptr.route_ids;
        var removed_this_route = false;

        for (ids.items, 0..) |id, idx| {
            if (id == route_id) {
                _ = ids.orderedRemove(idx);
                removed_this_route = true;
                break;
            }
        }

        if (removed_this_route and ids.items.len == 0 and entry.value_ptr.ftype != .gate) {
            try keys_to_remove.append(a, entry.key_ptr.*);
        }
    }

    for (keys_to_remove.items) |key| {
        _ = forbidden_zone.remove(key);
    }

    // 2. Remove this route's ID from violations recorded by other routes
    for (router.route_results, 0..) |*other_result, other_id| {
        if (other_id == route_id) continue;

        var v: usize = 0;
        while (v < other_result.violations.items.len) {
            var v_route_ids = &other_result.violations.items[v].violated_routes;
            for (v_route_ids.items, 0..) |vid, idx| {
                if (vid == route_id) {
                    _ = v_route_ids.orderedRemove(idx);
                    break;
                }
            }

            if (v_route_ids.items.len == 0) {
                _ = other_result.violations.orderedRemove(v);
            } else {
                v += 1;
            }
        }
    }

    // 3. Reset origins cleanly (sisters will be handled by their own ripUp calls)
    router.route_infos[route_id].origins.clearRetainingCapacity();
    try router.route_infos[route_id].origins.append(a, Origin{
        .loc = router.route_infos[route_id].src,
        .signal = 15,
    });

    // 4. Reset the routing result
    result.deinit(a);
    result.* = RoutingResult{
        .blocks = .empty,
        .moves = .empty,
        .cost = 0,
        .delay = 0,
        .length = 0,
        .violations = .empty,
        .failed = false,
    };
}

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
    router.external_a = a;
    router.var_config = router.config; // copy config to mutable var

    // initiate rng
    var rng = std.Random.DefaultPrng.init(seed);
    const random = rng.random();

    // sort pairs
    std.sort.block(RoutePair, pairs, false, sortPairsManhattan);

    // allocate routeinfo for each pair
    router.route_infos = try arena_a.alloc(RouteInfo, pairs.len);
    router.route_results = try arena_a.alloc(RoutingResult, pairs.len);
    for (pairs, 0..) |pair, i| {
        router.route_infos[i] = RouteInfo{
            .id = i,
            .src = pair.from,
            .dest = pair.to,
            .origins = .empty,
            .sister_routes = .empty,
        };
        // add the primary origin for this route
        try router.route_infos[i].origins.append(arena_a, Origin{
            .loc = pair.from,
            .signal = 15,
        });
        // add routes that have the same origin to sister_routes
        for (pairs, 0..) |other_pair, j| {
            if (i != j and vecEq(pair.from, other_pair.from)) {
                try router.route_infos[i].sister_routes.append(arena_a, j);
                std.log.info("Route {} and Route {} are sisters (shared origin: {any})", .{ i, j, pair.from });
            }
        }
    }

    // initial route pass
    for (pairs, 0..) |pair, i| {
        const result = try routeAStar(router, arena_a, router.route_infos[i], forbidden_zone);
        if (result) |r| {
            // once a result is generated, let the sister routes know that they can use any point along the path as an origin
            for (r.blocks.items) |block| {
                for (router.route_infos[i].sister_routes.items) |sister_index| {
                    try router.route_infos[sister_index].origins.append(arena_a, Origin{
                        .loc = block.loc,
                        .signal = 15,
                    });
                }
            }
            router.route_results[i] = r;
        } else {
            // create a dummy route with .block3 at beginning and end
            const from = pair.from;
            const to = pair.to;
            router.route_results[i] = RoutingResult{
                .failed = true,
                .blocks = .empty,
                .moves = .empty,
                .cost = 0,
                .delay = 0,
                .length = 0,
                .violations = .empty,
            };
            try router.route_results[i].blocks.append(arena_a, Block{
                .loc = from,
                .block = .block3,
                .rot = .center,
            });
            try router.route_results[i].blocks.append(arena_a, Block{
                .loc = to,
                .block = .block3,
                .rot = .center,
            });
            router.route_results[i].failed = true;
        }
    }

    // Rip-up and reroute loop
    var iteration: u32 = 0;
    while (iteration < router.config.max_iterations) : (iteration += 1) {
        var violating_set = std.AutoArrayHashMap(usize, void).init(arena_a);
        defer violating_set.deinit();
        var raw_violations: usize = 0;

        for (router.route_results, 0..) |result, i| {
            if (result.violations.items.len > 0 or result.failed) {
                raw_violations += 1;

                // Flag the violating route
                try violating_set.put(i, {});

                // Atomically flag ALL sister routes to prevent orphaning
                for (router.route_infos[i].sister_routes.items) |sister_idx| {
                    try violating_set.put(sister_idx, {});
                }
            }
        }

        if (raw_violations == 0) {
            std.log.info("Convergence reached: 0 violations after {d} iterations.", .{iteration});
            break;
        }

        std.log.info("Iteration {d}: Rerouting {d} sub-nets...", .{ iteration, violating_set.count() });

        // Phase 1: Teardown
        // Rip up EVERYTHING that is flagged before any routing begins
        var it = violating_set.iterator();
        while (it.next()) |entry| {
            const route_id = entry.key_ptr.*;
            if (!router.route_results[route_id].failed) {
                try ripUp(router, arena_a, route_id, forbidden_zone);
            }
        }

        // Extract to array for shuffling
        var routes_to_reroute: std.ArrayList(usize) = .empty;
        var keys_it = violating_set.iterator();
        while (keys_it.next()) |entry| {
            try routes_to_reroute.append(arena_a, entry.key_ptr.*);
        }

        // Randomly shuffle the order of routes to reroute to prevent deterministic loops
        random.shuffle(usize, routes_to_reroute.items);

        // Phase 2: Rebuild
        for (routes_to_reroute.items) |route_id| {
            const new_result = try routeAStar(router, arena_a, router.route_infos[route_id], forbidden_zone);

            if (new_result) |r| {
                router.route_results[route_id] = r;

                // Update sister routes with new valid origins
                for (r.blocks.items) |block| {
                    for (router.route_infos[route_id].sister_routes.items) |sister_index| {
                        try router.route_infos[sister_index].origins.append(arena_a, Origin{
                            .loc = block.loc,
                            .signal = 15,
                        });
                    }
                }
            } else {
                // Fallback to dummy route if rerouting fails completely
                const from = pairs[route_id].from;
                const to = pairs[route_id].to;
                router.route_results[route_id] = RoutingResult{
                    .blocks = .empty,
                    .moves = .empty,
                    .cost = 0,
                    .delay = 0,
                    .length = 0,
                    .violations = .empty,
                    .failed = true,
                };
                try router.route_results[route_id].blocks.append(arena_a, Block{ .loc = from, .block = .block3, .rot = .center });
                try router.route_results[route_id].blocks.append(arena_a, Block{ .loc = to, .block = .block3, .rot = .center });
            }
        }
    }

    var total_result = RoutingResult{
        .blocks = .empty,
        .moves = .empty,
        .cost = 0,
        .delay = 0,
        .length = 0,
        .violations = .empty,
        .failed = false,
    };

    for (router.route_results) |result| {
        try total_result.blocks.appendSlice(a, result.blocks.items);
        total_result.cost += result.cost;
        total_result.delay = @max(total_result.delay, result.delay);
        total_result.length += result.length;
        for (result.moves.items) |move| {
            try total_result.moves.append(a, move);
        }
        if (result.failed) {
            total_result.failed = true;
        }
    }

    std.log.info("Final Result: Cost = {}, Delay = {d}, Length = {d}, Violations = {d}, Failed Routes = {}", .{
        total_result.cost,
        total_result.delay,
        total_result.length,
        total_result.violations.items.len,
        total_result.failed,
    });

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
    var violation: ?Violation = null;

    for (move.def.build_blocks) |build_block| {
        const rotated_offset = comp.rotateCoord(build_block.offset, move.heading);
        const loc = move.from + rotated_offset;

        const conflict = forbidden_zone.get(loc) orelse continue;

        if (conflict.ftype == .gate) return .invalid;

        for (conflict.route_ids.items) |id| {
            if (id == current_route_id) continue;

            var is_sister = false;
            for (router.route_infos[current_route_id].sister_routes.items) |sister_id| {
                if (id == sister_id) {
                    is_sister = true;
                    break;
                }
            }

            if (is_sister) {
                // Condition A: Conflict is with the sister's padding
                if (conflict.ftype == .wire_padding) {
                    continue;
                }

                // Condition B: Conflict is with a sister's block AND is on the route
                if (conflict.ftype == .wire) {
                    var on_route = false;
                    for (router.route_results[id].moves.items) |sister_move| {
                        if (vecEq(loc, sister_move.to)) {
                            on_route = true;
                            break;
                        }
                    }
                    if (on_route) {
                        continue;
                    }
                }
            }

            // Initialize violation lazily on first conflict
            if (violation == null) {
                violation = Violation{
                    .loc = move.to, // Keep move.to as the representative A* step coordinate
                    .violated_routes = .empty,
                };
                violation.?.violated_routes.append(router.a, current_route_id) catch @panic("oom");
            }

            // Add unique violated route IDs
            var already_added = false;
            for (violation.?.violated_routes.items) |existing_id| {
                if (existing_id == id) {
                    already_added = true;
                    break;
                }
            }

            if (!already_added) {
                violation.?.violated_routes.append(router.a, id) catch @panic("oom");
            }
        }
    }

    if (violation) |v| {
        return .{ .violation = v };
    }

    return .valid;
}

fn checkSelfIntersection(nodes: *const std.AutoHashMap(WorldCoord, AStarNode), current_coord: WorldCoord, move: Move) bool {
    var move_footprint: [256]WorldCoord = undefined;
    var footprint_len: usize = 0;

    // Pre-calculate the absolute footprint of the new move
    for (move.def.build_blocks) |bb| {
        if (footprint_len >= move_footprint.len) break;
        move_footprint[footprint_len] = move.from + comp.rotateCoord(bb.offset, move.heading);
        footprint_len += 1;
    }
    for (move.def.padding) |pad| {
        if (footprint_len >= move_footprint.len) break;
        move_footprint[footprint_len] = move.from + comp.rotateCoord(pad, move.heading);
        footprint_len += 1;
    }

    var walk_coord = current_coord;
    var steps_back: u32 = 0;

    while (true) {
        const node = nodes.get(walk_coord) orelse break;
        const parent = node.parent orelse break;
        steps_back += 1;

        // Skip immediate predecessors (e.g. 1-2 steps) where segments naturally overlap to connect.
        // Adjust this threshold if you have particularly long base components.
        if (steps_back > 2) {
            const p_move = parent.move;

            for (p_move.def.build_blocks) |bb| {
                const loc = p_move.from + comp.rotateCoord(bb.offset, p_move.heading);
                for (move_footprint[0..footprint_len]) |mf| {
                    if (vecEq(loc, mf)) return true;
                }
            }
            for (p_move.def.padding) |pad| {
                const loc = p_move.from + comp.rotateCoord(pad, p_move.heading);
                for (move_footprint[0..footprint_len]) |mf| {
                    if (vecEq(loc, mf)) return true;
                }
            }
        }
        walk_coord = parent.parent;
    }
    return false;
}

fn routeAStar(router: *Router, a: Allocator, info: RouteInfo, forbidden_zone: *ForbiddenZone) !?RoutingResult {

    // Set up A* data structures
    var queue = AStarQueue.init(a, router);
    defer queue.deinit();

    // Single hash map to hold all node information - reduces lookups from 3 maps to 1
    var nodes = std.AutoHashMap(WorldCoord, AStarNode).init(a);
    defer nodes.deinit();

    std.log.info("Routing from {any} to {any} with {d} origins and {d} sister routes", .{ info.dest, info.origins.items[0], info.origins.items.len, info.sister_routes.items.len });

    var result = RoutingResult{
        .blocks = .empty,
        .moves = .empty,
        .cost = 0,
        .delay = 0,
        .length = 0,
        .violations = .empty,
        .failed = false,
    };

    // Initialize with destination (working backwards from destination to any origin)
    try queue.add(.{
        .coord = info.dest,
        .g_cost = 0,
        .f_cost = 0, // heuristic is 0 for the destination
        .signal_strength = 15, // start with max signal strength at the destination, will decay as we move towards origins
    });
    try nodes.put(info.dest, AStarNode{ .cost_so_far = 0 });

    const min_heuristic = calculateHeuristic(info.dest, info.origins.items);
    const max_allowed_cost = @max(min_heuristic * router.config.path_length_bound_multiplier, 50.0);

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
            if (vecEq(current.coord, origin.loc)) {
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
        const is_at_dest = vecEq(current.coord, info.dest);
        for (moves) |move| {
            const neighbor_coord = current.coord + move.offset;
            if (neighbor_coord[1] < MIN_Y or neighbor_coord[1] > MAX_Y) continue; // skip out of bounds neighbors

            // Check if neighbor is an origin
            var is_at_origin = false;
            var available_origin_signal: u8 = 0;
            for (info.origins.items) |origin| {
                if (vecEq(neighbor_coord, origin.loc)) {
                    is_at_origin = true;
                    available_origin_signal = origin.signal;
                    break;
                }
            }
            const is_dust = move.def == &comp.components[0];
            if (is_at_dest and !is_dust) continue;
            if (is_at_origin and !is_dust) continue;

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
            if (is_at_origin) {
                const required_signal = 15 - new_signal_strength;
                if (available_origin_signal < required_signal) continue; // Deny merge
            }

            // check validity
            const validity = moveValidity(router, move, forbidden_zone, info.id);
            if (validity == .invalid) continue; // skip invalid moves

            if (checkSelfIntersection(&nodes, current.coord, move)) continue;

            // Calculate movement cost
            const calculated_cost = calculateMovementCost(move, forbidden_zone);
            const movement_cost = if (validity == .violation) calculated_cost * router.config.violation_cost_multiplier else calculated_cost;
            const new_cost = current.g_cost + movement_cost;

            if (new_cost > max_allowed_cost) continue;
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
            try markForbidden(forbidden_zone, router.a, loc, .wire, info.id);
        }
        for (comp.components[0].padding) |pad_offset| {
            const pad_loc = final_coord + pad_offset;
            try markForbidden(forbidden_zone, router.a, pad_loc, .wire_padding, info.id);
        }
        result.length += 1;

        // 2. Build path back to destination
        var current_coord = final_coord;

        while (!vecEq(current_coord, info.dest)) {
            if (nodes.get(current_coord)) |current_node| {
                if (current_node.parent) |parent_info| {
                    const component = parent_info.move.def;
                    const heading = parent_info.move.heading;
                    const move = parent_info.move;
                    result.moves.append(a, move) catch @panic("oom");

                    // check violating
                    const is_violating = parent_info.violation != null;
                    if (parent_info.violation) |v| {
                        try result.violations.append(a, v);
                        // add violation to violated routes

                        for (v.violated_routes.items) |route_id| {
                            if (route_id == info.id) continue; // skip self
                            const other_route = &router.route_results[route_id];
                            var already_added = false;
                            for (other_route.violations.items) |existing_violation| {
                                if (vecEq(existing_violation.loc, v.loc)) {
                                    already_added = true;
                                    break;
                                }
                            }
                            if (!already_added) {
                                try other_route.violations.append(a, .{
                                    .loc = v.loc,
                                    .violated_routes = .empty,
                                });
                                other_route.violations.items[other_route.violations.items.len - 1].violated_routes.append(a, info.id) catch @panic("oom");
                            } else {
                                // If this violation already exists in the other route, just add this route's ID to the violated_routes list
                                for (other_route.violations.items) |*existing_violation| {
                                    if (vecEq(existing_violation.loc, v.loc)) {
                                        existing_violation.violated_routes.append(a, info.id) catch @panic("oom");
                                        break;
                                    }
                                }
                            }
                        }
                    }

                    for (component.build_blocks) |build_block| {
                        const rotated_offset = comp.rotateCoord(build_block.offset, heading);
                        const loc = parent_info.parent + rotated_offset;

                        try result.blocks.append(a, Block{
                            .loc = loc,
                            .block = if (is_violating and build_block.cat == .block) .block3 else build_block.cat,
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
    } else {
        std.log.info("A* failed. iterations: {d}, found path: {any}", .{
            iterations,
            found_path,
        });
        result.failed = true;
        return null;
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
fn calculateMovementCost(move: Move, forbidden_zone: *ForbiddenZone) f16 {
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
fn calculateHeuristic(coord: WorldCoord, origins: []Origin) f16 {
    if (origins.len == 0) {
        return 0; // No origins, so heuristic is 0
    }

    var min_distance: u32 = std.math.maxInt(u32);

    for (origins) |origin| {
        const distance = manhattanDistance(coord, origin.loc);
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
