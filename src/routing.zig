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
    violation_cost_increase: f16 = 5.0,
    max_length: u32 = 1000,
    max_astar_iterations: u32 = 100000,
    astar_iterations_increase: u32 = 10000,
    path_length_bound_multiplier: f16 = 80.0,
    heuristic_weight: f16 = 1.0,
    directional_bias: f16 = 2.0,
};

config: Config = .{},
var_config: Config = .{},
a: Allocator = undefined,
external_a: Allocator = undefined,
pairs: []RoutePair = undefined,
route_infos: []RouteInfo = undefined,
route_results: []RoutingResult = undefined,

const MIN_Y = 1;
const MAX_Y = 20;

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
    path_origins: std.ArrayList(Origin),
    cost: f16,
    delay: u32,
    length: u32,
    failed: bool,
    violations: std.ArrayList(Violation),

    pub fn deinit(self: *RoutingResult, allocator: Allocator) void {
        self.blocks.deinit(allocator);
        self.violations.deinit(allocator);
        self.moves.deinit(allocator);
        self.path_origins.deinit(allocator);
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
        .path_origins = .empty,
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
    const buf: []u8 = a.alloc(u8, 10000 * 1024 * 1024) catch @panic("Failed to allocate arena buffer");
    defer a.free(buf);
    var sba = std.heap.FixedBufferAllocator.init(buf);
    const arena_a = sba.allocator();

    router.a = arena_a;
    router.external_a = a;
    router.var_config = router.config;

    var rng = std.Random.DefaultPrng.init(seed);
    const random = rng.random();

    std.log.info("Starting routing with seed {d} and {d} pairs", .{ seed, pairs.len });

    std.sort.block(RoutePair, pairs, false, sortPairsManhattan);

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
        try router.route_infos[i].origins.append(arena_a, Origin{
            .loc = pair.from,
            .signal = 15,
        });
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
            for (r.path_origins.items) |path_origin| {
                for (router.route_infos[i].sister_routes.items) |sister_index| {
                    try router.route_infos[sister_index].origins.append(arena_a, path_origin);
                }
            }
            router.route_results[i] = r;
        } else {
            const from = pair.from;
            const to = pair.to;
            router.route_results[i] = RoutingResult{
                .failed = true,
                .blocks = .empty,
                .moves = .empty,
                .path_origins = .empty,
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
                try violating_set.put(i, {});
                for (router.route_infos[i].sister_routes.items) |sister_idx| {
                    try violating_set.put(sister_idx, {});
                }
            }
        }

        if (raw_violations == 0) {
            std.log.info("Convergence reached: 0 violations after {d} iterations.", .{iteration});
            break;
        }

        std.log.info("Iteration {d}: Rerouting {d} sub-nets with vio cost {d} and max iter {d}...", .{ iteration, violating_set.count(), router.var_config.violation_cost_multiplier, router.var_config.max_astar_iterations });

        var it = violating_set.iterator();
        while (it.next()) |entry| {
            const route_id = entry.key_ptr.*;
            if (!router.route_results[route_id].failed) {
                try ripUp(router, arena_a, route_id, forbidden_zone);
            }
        }

        var routes_to_reroute: std.ArrayList(usize) = .empty;
        var keys_it = violating_set.iterator();
        while (keys_it.next()) |entry| {
            try routes_to_reroute.append(arena_a, entry.key_ptr.*);
        }

        random.shuffle(usize, routes_to_reroute.items);

        for (routes_to_reroute.items) |route_id| {
            const new_result = try routeAStar(router, arena_a, router.route_infos[route_id], forbidden_zone);

            if (new_result) |r| {
                router.route_results[route_id] = r;
                for (r.path_origins.items) |path_origin| {
                    for (router.route_infos[route_id].sister_routes.items) |sister_index| {
                        try router.route_infos[sister_index].origins.append(arena_a, path_origin);
                    }
                }
            } else {
                const from = pairs[route_id].from;
                const to = pairs[route_id].to;
                router.route_results[route_id] = RoutingResult{
                    .blocks = .empty,
                    .moves = .empty,
                    .path_origins = .empty,
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
        router.var_config.violation_cost_multiplier += router.config.violation_cost_increase;
        router.var_config.max_astar_iterations += router.config.astar_iterations_increase;
    }

    var total_result = RoutingResult{
        .blocks = .empty,
        .moves = .empty,
        .path_origins = .empty,
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
        for (result.path_origins.items) |po| {
            try total_result.path_origins.append(a, po);
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
    last_heading: WorldCoord,

    pub fn compare(router: *Router, self: AStarQueueItem, other: AStarQueueItem) std.math.Order {
        _ = router;
        return std.math.order(self.f_cost, other.f_cost);
    }
};

const ParentInfo = struct {
    parent: WorldCoord,
    move: Move,
    violation: ?Violation,
};

const AStarNode = struct {
    visited: bool = false,
    cost_so_far: f16 = std.math.inf(f16),
    parent: ?ParentInfo = null,
    last_heading: WorldCoord = .{ 0, 0, 0 },
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

        for (router.route_infos) |other_info| {
            if (other_info.id == current_route_id) continue;

            var is_sister = false;
            for (router.route_infos[current_route_id].sister_routes.items) |sister_id| {
                if (other_info.id == sister_id) {
                    is_sister = true;
                    break;
                }
            }

            if (!is_sister) {
                var dx = if (loc[0] > other_info.dest[0]) loc[0] - other_info.dest[0] else other_info.dest[0] - loc[0];
                var dy = if (loc[1] > other_info.dest[1]) loc[1] - other_info.dest[1] else other_info.dest[1] - loc[1];
                var dz = if (loc[2] > other_info.dest[2]) loc[2] - other_info.dest[2] else other_info.dest[2] - loc[2];

                if (dx <= 1 and dy <= 1 and dz <= 1) {
                    violation = .{
                        .loc = loc,
                        .violated_routes = .empty,
                    };
                    violation.?.violated_routes.append(router.a, other_info.id) catch @panic("oom");
                    return .{ .violation = violation.? };
                }

                dx = if (loc[0] > other_info.src[0]) loc[0] - other_info.src[0] else other_info.src[0] - loc[0];
                dy = if (loc[1] > other_info.src[1]) loc[1] - other_info.src[1] else other_info.src[1] - loc[1];
                dz = if (loc[2] > other_info.src[2]) loc[2] - other_info.src[2] else other_info.src[2] - loc[2];

                if (dx <= 1 and dy <= 1 and dz <= 1) {
                    violation = .{
                        .loc = loc,
                        .violated_routes = .empty,
                    };
                    violation.?.violated_routes.append(router.a, other_info.id) catch @panic("oom");
                    return .{ .violation = violation.? };
                }
            }
        }

        const conflict = forbidden_zone.get(loc) orelse continue;

        if (conflict.ftype == .gate) return .invalid;

        if (!vecEq(loc, move.from) and conflict.ftype == .wire_padding) {
            var on_route = false;
            for (conflict.route_ids.items) |id| {
                for (router.route_results[id].moves.items) |other_move| {
                    if (vecEq(loc, other_move.to)) {
                        on_route = true;
                        break;
                    }
                }
                if (on_route) {
                    continue;
                }
            }
            if (!on_route) continue;
        }

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
                if (conflict.ftype == .wire_padding) {
                    continue;
                }
                if (conflict.ftype == .wire) {
                    var compatible = false;
                    const expected_rot = comp.rotateOrientation(build_block.rot, move.heading);

                    // Check the actual blocks placed by the sister route
                    for (router.route_results[id].blocks.items) |sister_block| {
                        if (vecEq(loc, sister_block.loc)) {
                            // Only allow the overlap if the block types and rotations are identical
                            if (sister_block.block == build_block.cat and sister_block.rot == expected_rot) {
                                compatible = true;
                            }
                            break;
                        }
                    }

                    // var on_route = false;
                    // var cat = comp.ComponentType.dust;
                    // for (router.route_results[id].moves.items) |sister_move| {
                    //     if (vecEq(loc, sister_move.to)) {
                    //         on_route = true;
                    //         cat = sister_move.def.cat;
                    //         break;
                    //     }
                    // }
                    // if (on_route and cat == comp.ComponentType.dust and move.def.cat == comp.ComponentType.dust) {
                    //     continue;
                    // }
                    if (compatible) {
                        continue;
                    }
                }
            }

            if (violation == null) {
                violation = Violation{
                    .loc = loc,
                    .violated_routes = .empty,
                };
                violation.?.violated_routes.append(router.a, current_route_id) catch @panic("oom");
            }

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
    var queue = AStarQueue.init(a, router);
    defer queue.deinit();

    var nodes = std.AutoHashMap(WorldCoord, AStarNode).init(a);
    defer nodes.deinit();

    std.log.info("Routing from {any} to {any} with {d} origins and {d} sister routes", .{ info.dest, info.origins.items[0], info.origins.items.len, info.sister_routes.items.len });

    var result = RoutingResult{
        .blocks = .empty,
        .moves = .empty,
        .path_origins = .empty,
        .cost = 0,
        .delay = 0,
        .length = 0,
        .violations = .empty,
        .failed = false,
    };

    try queue.add(.{
        .coord = info.dest,
        .g_cost = 0,
        .f_cost = 0,
        .signal_strength = 15,
        .last_heading = .{ 0, 0, 0 },
    });
    try nodes.put(info.dest, AStarNode{ .cost_so_far = 0 });

    const min_heuristic = calculateHeuristic(router, info.dest, info.origins.items);
    const max_allowed_cost = @max(min_heuristic * router.config.path_length_bound_multiplier, 50.0);

    var iterations: u32 = 0;
    var found_path = false;
    var final_coord: WorldCoord = undefined;

    while (queue.count() > 0 and iterations < router.var_config.max_astar_iterations) {
        iterations += 1;

        const current = queue.remove();

        const node_result = try nodes.getOrPut(current.coord);
        const current_node = node_result.value_ptr;

        if (current_node.visited) continue;
        current_node.visited = true;

        var reached_origin = false;

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

        const moves = getMoves(current.coord);
        const is_at_dest = vecEq(current.coord, info.dest);
        for (moves) |move| {
            const neighbor_coord = current.coord + move.offset;
            if (neighbor_coord[1] < MIN_Y or neighbor_coord[1] > MAX_Y) continue;
            if (current.last_heading[0] != 0 or current.last_heading[1] != 0 or current.last_heading[2] != 0) {
                if (move.heading[0] + current.last_heading[0] == 0 and
                    move.heading[1] + current.last_heading[1] == 0 and
                    move.heading[2] + current.last_heading[2] == 0)
                {
                    continue;
                }
                if (move.def.cat == .staircase_up or move.def.cat == .staircase_down) {
                    if (!vecEq(move.heading, current.last_heading)) {
                        continue;
                    }
                }
            }

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

            const neighbor_result = try nodes.getOrPutValue(neighbor_coord, AStarNode{});
            const neighbor_node = neighbor_result.value_ptr;

            if (neighbor_node.visited) continue;

            const new_signal_strength = switch (move.signal_behavior) {
                .decay => if (current.signal_strength > 0) current.signal_strength - 1 else 0,
                .reset => 15,
                .via => 14,
            };
            if (new_signal_strength == 0) continue;
            if (is_at_origin) {
                const required_signal = 15 - new_signal_strength;
                if (available_origin_signal < required_signal) continue;
            }

            const validity = moveValidity(router, move, forbidden_zone, info.id);
            if (validity == .invalid) continue;

            if (checkSelfIntersection(&nodes, current.coord, move)) continue;

            const calculated_cost = calculateMovementCost(router, move, current_node, forbidden_zone);
            const movement_cost = if (validity == .violation) calculated_cost * router.var_config.violation_cost_multiplier else calculated_cost;
            const new_cost = current.g_cost + movement_cost;

            if (new_cost > max_allowed_cost) continue;
            if (new_cost >= neighbor_node.cost_so_far) continue;

            neighbor_node.cost_so_far = new_cost;
            neighbor_node.last_heading = move.heading;
            neighbor_node.parent = .{
                .parent = current.coord,
                .move = move,
                .violation = if (validity == .violation) validity.violation else null,
            };

            const heuristic = calculateHeuristic(router, neighbor_coord, info.origins.items);
            const estimated_total = new_cost + heuristic;

            try queue.add(.{
                .coord = neighbor_coord,
                .g_cost = new_cost,
                .f_cost = estimated_total,
                .signal_strength = new_signal_strength,
                .last_heading = move.heading,
            });
        }
    }

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

        var forward_signal: u8 = 15;
        for (info.origins.items) |o| {
            if (vecEq(o.loc, final_coord)) {
                forward_signal = o.signal;
                break;
            }
        }
        try result.path_origins.append(a, Origin{ .loc = final_coord, .signal = forward_signal });

        while (!vecEq(current_coord, info.dest)) {
            if (nodes.get(current_coord)) |current_node| {
                if (current_node.parent) |parent_info| {
                    const component = parent_info.move.def;
                    const heading = parent_info.move.heading;
                    const move = parent_info.move;
                    result.moves.append(a, move) catch @panic("oom");

                    forward_signal = switch (move.signal_behavior) {
                        .decay => if (forward_signal > 0) forward_signal - 1 else 0,
                        .reset => 15,
                        .via => forward_signal,
                    };
                    try result.path_origins.append(a, Origin{ .loc = parent_info.parent, .signal = forward_signal });

                    const is_violating = parent_info.violation != null;
                    if (parent_info.violation) |v| {
                        try result.violations.append(a, v);

                        for (v.violated_routes.items) |route_id| {
                            if (route_id == info.id) continue;
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
            const rotated_offset = comp.rotateCoord(component.base_dir, cdir);
            moves[index] = .{
                .from = from,
                .to = from + rotated_offset,
                .offset = rotated_offset,
                .heading = cdir,
                .signal_behavior = component.signal_behavior,
                .def = component,
            };
            index += 1;
        }
    }

    return moves;
}

fn calculateMovementCost(router: *Router, move: Move, current_node: *AStarNode, forbidden_zone: *ForbiddenZone) f16 {
    _ = forbidden_zone;
    var cost: f16 = @floatFromInt(move.def.delay + move.def.length);

    if (current_node.last_heading[0] != 0 or current_node.last_heading[1] != 0 or current_node.last_heading[2] != 0) {
        if (!vecEq(move.heading, current_node.last_heading)) {
            cost += router.config.directional_bias;
        }
    }
    return cost;
}

fn calculateHeuristic(router: *Router, coord: WorldCoord, origins: []Origin) f16 {
    if (origins.len == 0) {
        return 0;
    }

    var min_distance: u32 = std.math.maxInt(u32);

    for (origins) |origin| {
        const distance = manhattanDistance(coord, origin.loc);
        if (distance < min_distance) {
            min_distance = distance;
        }
    }

    return @as(f16, @floatFromInt(min_distance)) * router.config.heuristic_weight;
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
    } else if (entry.value_ptr.ftype == .wire_padding and ftype == .wire) {
        entry.value_ptr.ftype = .wire;
    }

    for (entry.value_ptr.route_ids.items) |existing_id| {
        if (existing_id == route_id) return;
    }
    try entry.value_ptr.route_ids.append(allocator, route_id);
}
