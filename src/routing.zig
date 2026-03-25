const std = @import("std");
const phys = @import("physical.zig");
const nbt = @import("nbt.zig");
const comp = @import("components/components.zig");
const ms = @import("abstract/structures.zig");

const Route = struct {
    // return value
    route: std.ArrayList(ms.AbsBlock) = .empty,
    footprints: std.ArrayList(WorldCoord) = .empty,
    delay: u32 = 0,
    length: u32 = 0,
    violating: bool, // whether the route violates another route
    pub fn deinit(self: *Route, allocator: std.mem.Allocator) void {
        self.route.deinit(allocator);
        self.footprints.deinit(allocator);
    }
};

const RouterConfig = struct {
    max_iterations: u32 = 20,
    violation_cost_multiplier: f32 = 30.0,
    heuristic_weight: f32 = 3.0,
    delay_cost_multiplier: f32 = 1.0,
    max_cost: f32 = 1000, // dont explore dumb paths
};

const WorldCoord = ms.WorldCoord;

const NodeState = struct {
    coord: WorldCoord,
    signal: u4,
};

const Parent = struct {
    prev: NodeState,
    def: *const comp.ComponentDef,
    violating: bool,
};

// 3D Manhattan distance towards the target acts as an admissible heuristic.
fn heuristic(curr: WorldCoord, target: WorldCoord) f32 {
    // const dx = @as(u32, @intCast(@abs(curr[0] - target[0])));
    // const dy = @as(u32, @intCast(@abs(curr[1] - target[1])));
    // const dz = @as(u32, @intCast(@abs(curr[2] - target[2])));
    const dx = @abs(curr[0] - target[0]);
    const dy = @abs(curr[1] - target[1]);
    const dz = @abs(curr[2] - target[2]);
    const manhattan = dx + dy + dz;

    // Admissible delay injection:
    // You cannot move more than 15 blocks without incurring at least 1 tick of delay.
    // Cost scales by 100 per delay tick.
    const min_unavoidable_delay_cost = (manhattan / 15) * 20;

    return @floatFromInt(manhattan + min_unavoidable_delay_cost);
}

const SURROUNDING_OFFSETS = blk: {
    var arr: [27]WorldCoord = undefined;
    var i: usize = 0;
    for ([_]i32{ -1, 0, 1 }) |x| {
        for ([_]i32{ -1, 0, 1 }) |y| {
            for ([_]i32{ -1, 0, 1 }) |z| {
                arr[i] = .{ x, y, z };
                i += 1;
            }
        }
    }
    break :blk arr;
};

const MaxMoveBlocks = 12;
const MAX_COMPONENT_RADIUS = 5;
const MoveFootprint = struct {
    blocks: [MaxMoveBlocks]WorldCoord,
    count: usize,
};

fn getMoveFootprint(u: WorldCoord, move: Move) MoveFootprint {
    var fp: MoveFootprint = .{ .blocks = undefined, .count = 0 };
    for (move.def.build_blocks) |bb| {
        fp.blocks[fp.count] = u + rotateCoord(bb.offset, move.dir);
        fp.count += 1;
    }
    return fp;
}

fn moveIntersectsPath(new_u: WorldCoord, new_move: Move, start_state: NodeState, parents: *const std.AutoHashMap(NodeState, Parent)) bool {

    //SKIP DUST FOR NOW
    if (new_move.def.weight <= 1.1) return false;

    const new_fp = getMoveFootprint(new_u, new_move);
    const new_coord = new_u + new_move.dir;

    var curr = start_state;
    var is_immediate_parent = true;

    while (true) {
        // 1. Check for node overlap
        if (coordEq(curr.coord, new_coord)) return true;

        // 2. Check for physical edge volume overlap
        if (parents.get(curr)) |p| {
            const prev_u = p.prev.coord;
            const past_move = Move{
                .dir = curr.coord - prev_u,
                .def = p.def,
            };
            const dx = @abs(curr.coord[0] - new_coord[0]);
            const dy = @abs(curr.coord[1] - new_coord[1]);
            const dz = @abs(curr.coord[2] - new_coord[2]);
            const manhattan = dx + dy + dz;

            if (manhattan > MAX_COMPONENT_RADIUS * 2) {
                // Too far to possibly intersect, skip footprint calculation
                curr = p.prev;
                is_immediate_parent = false;
                continue;
            }
            const past_fp = getMoveFootprint(prev_u, past_move);

            for (new_fp.blocks[0..new_fp.count]) |b1| {
                for (past_fp.blocks[0..past_fp.count]) |b2| {
                    if (coordEq(b1, b2)) {
                        // Allow the new move to share a node and its supporting block with its immediate parent edge
                        const block_below = new_u + WorldCoord{ 0, -1, 0 };
                        if (is_immediate_parent and (coordEq(b1, new_u) or coordEq(b1, block_below))) {
                            continue;
                        }
                        return true;
                    }
                }
            }
            curr = p.prev;
            is_immediate_parent = false;
        } else {
            break;
        }
    }

    return false;
}

// any formless volume
const Volume = ms.OrderedSet(WorldCoord);

fn coordEq(a: WorldCoord, b: WorldCoord) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2];
}

const QueueItem = struct {
    state: NodeState,
    g: f32,
    f: f32,
};

fn queueOrder(context: void, a: QueueItem, b: QueueItem) std.math.Order {
    _ = context;
    const f_order = std.math.order(a.f, b.f);
    if (f_order == .eq) {
        // Tie-breaker: If f is equal, prioritize the node with the higher g-cost
        // because it has a smaller h-cost and is deeper in the search tree (closer to goal).
        return std.math.order(a.g, b.g).invert();
    }
    return f_order;
}

const DistanceMetric = struct {
    distance: u32,
    signal_strength: u4,
};

const Move = struct {
    dir: WorldCoord,
    def: *const comp.ComponentDef,
};

const MoveValidity = union(enum) {
    valid,
    invalid,
    violation: u32,
};

fn check_validity(coord: WorldCoord, forbidden_zone: ms.ForbiddenZone) MoveValidity {
    if (forbidden_zone.get(coord)) |conflict| {
        if (conflict.ftype == .gate) return .invalid;
        if (conflict.ftype == .wire) return .{ .violation = conflict.ref_count };
    }
    return .valid;
}

fn isMoveValid(u: WorldCoord, move: Move, forbidden_zone: ms.ForbiddenZone) MoveValidity {
    const target_coord = u + move.dir;
    if (target_coord[1] > phys.MAX_Y_LEVEL or target_coord[1] < phys.MIN_Y_LEVEL) return .invalid;

    var total_refs: u32 = 0;
    for (move.def.build_blocks) |bb| {
        const rotated = rotateCoord(bb.offset, move.dir);
        switch (check_validity(u + rotated, forbidden_zone)) {
            .invalid => return .invalid,
            .valid => {},
            .violation => |refs| total_refs += refs,
        }
    }

    if (total_refs > 0) return .{ .violation = total_refs };
    return .valid;
}

const Net = struct {
    from: WorldCoord,
    to: WorldCoord,
    route: ?Route,
    failures: u32,
    is_violating: bool = false, // Track global violations
};

// Heuristic for REORDER(): Route nets with the most failures first.
// Tie-breaker: Route physically longer nets first.
fn sortNetPtrsDescending(_: void, lhs: *Net, rhs: *Net) bool {
    if (lhs.failures == rhs.failures) {
        const dist_lhs = heuristic(lhs.from, lhs.to);
        const dist_rhs = heuristic(rhs.from, rhs.to);
        return dist_lhs > dist_rhs;
    }
    return lhs.failures > rhs.failures;
}

fn ripUp(net: *Net, forbidden_zone: *ms.ForbiddenZone, a: std.mem.Allocator) void {
    if (net.route) |*r| {
        for (r.footprints.items) |coord| {
            for (SURROUNDING_OFFSETS) |offset| {
                const target = coord + offset;

                if (forbidden_zone.getPtr(target)) |existing| {
                    if (existing.ftype == .wire) {
                        existing.ref_count -= 1;
                        if (existing.ref_count == 0) {
                            _ = forbidden_zone.remove(target);
                        }
                    }
                }
            }
        }
        r.deinit(a);
        net.route = null;
    }
}

pub const RoutePair = struct {
    from: WorldCoord,
    to: WorldCoord,
};
const CellInfo = struct {
    first_net: *Net,
};

fn updateViolations(a: std.mem.Allocator, nets: []Net) !void {
    var owners = std.AutoHashMap(WorldCoord, CellInfo).init(a);
    defer owners.deinit();

    // 1. Initialize from A*'s baseline violation check (e.g., hitting static geometry)
    for (nets) |*net| {
        net.is_violating = if (net.route) |*r| r.violating else false;
    }

    // 2. Cross-check all routed nets for mutual intersections
    for (nets) |*net| {
        if (net.route) |*r| {
            for (r.footprints.items) |coord| {
                // Check direct footprint against the fattened owners map
                if (owners.getPtr(coord)) |info| {
                    if (info.first_net != net) {
                        info.first_net.is_violating = true;
                        net.is_violating = true;
                    }
                }

                // Fatten the volume for subsequent net checks
                for (SURROUNDING_OFFSETS) |offset| {
                    const target = coord + offset;
                    // Only insert if empty so we don't overwrite the true first_net
                    if (!owners.contains(target)) {
                        try owners.put(target, .{ .first_net = net });
                    }
                }
            }
        }
    }

    // 3. Sync flags back to the Route structs
    for (nets) |*net| {
        if (net.route) |*r| {
            r.violating = net.is_violating;
        }
    }
}

pub fn routeAll(a: std.mem.Allocator, pairs: []RoutePair, forbidden_zone: *ms.ForbiddenZone, config: RouterConfig) !Route {
    var nets = try a.alloc(Net, pairs.len);

    defer {
        for (nets) |*net| {
            if (net.route) |*r| r.deinit(a);
        }
        a.free(nets);
    }

    var v_nets: std.ArrayList(*Net) = .empty;
    defer v_nets.deinit(a);

    // Initial routing pass
    for (pairs, 0..) |pair, i| {
        nets[i] = .{
            .from = pair.from,
            .to = pair.to,
            .route = null,
            .failures = 0,
            .is_violating = false,
        };
        std.log.info("Routing net {} from {any} to {any}", .{ i, nets[i].from, nets[i].to });
        nets[i].route = try routeToUpdateForbiddenZone(a, nets[i].from, nets[i].to, forbidden_zone, config);
    }

    // Evaluate global collisions and populate v_nets
    try updateViolations(a, nets);
    for (nets) |*net| {
        std.log.info("Initial route for net from {any} to {any} has delay {d} and violating={any}", .{ net.from, net.to, net.route.?.delay, net.is_violating });
        if (net.is_violating) {
            try v_nets.append(a, net);
        }
    }

    var iters: u32 = 0;

    // Iterative rip-up and reroute
    while (v_nets.items.len > 0 and iters < config.max_iterations) : (iters += 1) {
        std.sort.block(*Net, v_nets.items, {}, sortNetPtrsDescending);
        const num_v_nets_this_pass = v_nets.items.len;

        std.log.info("Iteration {}: Routing {} violating nets", .{ iters, num_v_nets_this_pass });

        for (0..num_v_nets_this_pass) |_| {
            std.log.info("Re-routing net from {any} to {any} with {} failures", .{ v_nets.items[0].from, v_nets.items[0].to, v_nets.items[0].failures });
            var net = v_nets.orderedRemove(0);
            ripUp(net, forbidden_zone, a);
            net.route = try routeToUpdateForbiddenZone(a, net.from, net.to, forbidden_zone, config);
        }

        // Recalculate global collisions after all queued nets have re-routed
        try updateViolations(a, nets);

        // Rebuild v_nets queue based on the updated global intersection map
        v_nets.clearRetainingCapacity();
        for (nets) |*net| {
            if (net.is_violating) {
                net.failures += 1;
                try v_nets.append(a, net);
            }
        }
    }

    if (v_nets.items.len > 0) {
        std.log.warn("routeAll finished with {} unresolved violations after {} iterations.", .{ v_nets.items.len, config.max_iterations });
    }

    // Assemble final aggregate Route
    var final_route = Route{
        .route = .empty,
        .footprints = .empty,
        .delay = 0,
        .length = 0,
        .violating = v_nets.items.len > 0,
    };
    errdefer final_route.deinit(a);

    std.log.info("Assembling final route with total {} nets, {} violating.", .{ nets.len, v_nets.items.len });
    for (nets) |*net| {
        if (net.route) |*r| {
            try final_route.route.appendSlice(a, r.route.items);
            try final_route.footprints.appendSlice(a, r.footprints.items);
            final_route.delay += r.delay;
            final_route.length += r.length;
        }
    }

    return final_route;
}

pub fn routeToUpdateForbiddenZone(a: std.mem.Allocator, from: WorldCoord, to: WorldCoord, forbidden_zone: *ms.ForbiddenZone, config: RouterConfig) !Route {
    const route = try routeTo(a, from, to, forbidden_zone.*, config);

    for (route.footprints.items) |coord| {
        for (SURROUNDING_OFFSETS) |offset| {
            const target = coord + offset;

            if (forbidden_zone.getPtr(target)) |existing| {
                if (existing.ftype == .wire) {
                    existing.ref_count += 1;
                }
            } else {
                try forbidden_zone.put(target, .{ .ftype = .wire, .ref_count = 1 });
            }
        }
    }

    return route;
}

pub fn routeTo(a: std.mem.Allocator, from: WorldCoord, to: WorldCoord, forbidden_zone: ms.ForbiddenZone, config: RouterConfig) !Route {
    if (from[1] < phys.MIN_Y_LEVEL or from[1] > phys.MAX_Y_LEVEL or
        to[1] < phys.MIN_Y_LEVEL or to[1] > phys.MAX_Y_LEVEL)
    {
        return error.OutOfBounds;
    }

    var queue = std.PriorityQueue(QueueItem, void, queueOrder).init(a, {});
    defer queue.deinit();

    // Dictionaries now key on NodeState (Coord + Signal Strength)
    var parents = std.AutoHashMap(NodeState, Parent).init(a);
    defer parents.deinit();

    var distances = std.AutoHashMap(NodeState, f32).init(a);
    defer distances.deinit();

    const start_state = NodeState{ .coord = from, .signal = 15 };
    try distances.put(start_state, 0);
    try queue.add(.{ .state = start_state, .g = 0, .f = heuristic(from, to) });

    // Edge weights must be > 0. Scaled to reflect relative pathing delays/material costs.
    const moves = comptime blk: {
        var m: [comp.components.len * 4]Move = undefined;
        var idx = 0;
        for (&comp.components) |*def| {
            for ([_]WorldCoord{ .{ 1, 0, 0 }, .{ 0, 0, 1 }, .{ -1, 0, 0 }, .{ 0, 0, -1 } }) |cdir| {
                m[idx] = .{
                    .dir = rotateCoord(def.base_dir, cdir),
                    .def = def,
                };
                idx += 1;
            }
        }
        break :blk m;
    };

    var final_state: ?NodeState = null;

    var counter: usize = 0;
    while (queue.count() > 0) {
        counter += 1;
        const item = queue.removeOrNull().?;
        const u_state = item.state;
        const u = u_state.coord;

        const best_g = distances.get(u_state) orelse std.math.floatMax(f32);
        if (item.g > best_g) continue;

        if (coordEq(u, to)) {
            final_state = u_state;
            break;
        }
        for (moves) |move| {
            const coord = u + move.dir;
            if (moveIntersectsPath(u, move, u_state, &parents)) continue;
            const validity = isMoveValid(u, move, forbidden_zone);
            if (validity == .invalid) continue;

            // Data-driven signal calculation
            var next_signal = u_state.signal;
            if (next_signal < move.def.min_signal) continue;

            switch (move.def.signal_behavior) {
                .decay => {
                    if (next_signal == 1 and coordEq(coord, to)) continue;
                    next_signal -= move.def.min_signal;
                },
                .reset => next_signal = 15,
                .via => next_signal = 14,
            }

            const next_state = NodeState{ .coord = coord, .signal = next_signal };

            var move_cost = move.def.delay * config.delay_cost_multiplier + move.def.length;
            var is_violating = false;

            switch (validity) {
                .violation => |refs| {
                    // 200 bounds the map flood while still heavily deterring intersections.
                    // Scaling by refs ensures rip-up/reroute avoids highly contested blocks.
                    move_cost += config.violation_cost_multiplier * @as(f32, @floatFromInt(refs));
                    is_violating = true;
                },
                else => {},
            }

            const g_cost = item.g + move_cost;
            if (g_cost > config.max_cost) continue;

            const existing_g = distances.get(next_state);
            if (existing_g == null or g_cost < existing_g.?) {
                distances.put(next_state, g_cost) catch @panic("oom");
                parents.put(next_state, .{
                    .prev = u_state,
                    .def = move.def,
                    .violating = is_violating,
                }) catch @panic("oom");

                const f_cost = g_cost + heuristic(coord, to) * config.heuristic_weight;
                queue.add(.{
                    .state = next_state,
                    .g = g_cost,
                    .f = f_cost,
                }) catch @panic("oom");
            }
        }
    }
    std.log.info("A* completed with {d} iterations and final path cost of {any} if path found.", .{ counter, distances.get(final_state.?) });

    if (final_state == null) {
        std.log.err("Could not find a path to .{any}", .{to});
        return error.PathNotFound;
    }

    return try buildRouteBlocks(a, from, final_state.?, parents);
}

fn buildRouteBlocks(a: std.mem.Allocator, from: WorldCoord, final_state: NodeState, parents: std.AutoHashMap(NodeState, Parent)) !Route {
    var abs_blocks: std.ArrayList(ms.AbsBlock) = .empty;
    var footprints: std.ArrayList(WorldCoord) = .empty;
    var length: u32 = 0;
    var delay: u32 = 0;
    var violating = false;

    // initialize
    try footprints.append(a, from);

    var curr_state = final_state;
    var vec = curr_state.coord;
    var prev_vec = vec;

    while (!coordEq(vec, from)) {
        const p = parents.get(curr_state) orelse return error.MissingParent;
        curr_state = p.prev;
        vec = curr_state.coord;

        if (p.violating) violating = true;
        const move_dir = prev_vec - vec;

        for (p.def.build_blocks) |block_def| {
            const rotated_coord = rotateCoord(block_def.offset, move_dir);
            const rotated_rot = rotateOrientation(block_def.rot, move_dir);

            try abs_blocks.append(a, .{
                .block = block_def.cat,
                .loc = vec + rotated_coord,
                .rot = rotated_rot,
            });

            // Track the footprint using the build_blocks offset
            try footprints.append(a, vec + rotated_coord);
        }

        length += p.def.length;
        delay += p.def.delay;
        prev_vec = vec;
    }

    try abs_blocks.append(a, .{ .block = .dust, .loc = final_state.coord, .rot = .center });
    try abs_blocks.append(a, .{ .block = .block, .loc = final_state.coord + WorldCoord{ 0, -1, 0 }, .rot = .center });

    try footprints.append(a, final_state.coord);
    try footprints.append(a, final_state.coord + WorldCoord{ 0, -1, 0 });

    return .{
        .route = abs_blocks,
        .footprints = footprints,
        .delay = delay,
        .length = length,
        .violating = violating,
    };
}

fn rotateCoord(coord: WorldCoord, dir: WorldCoord) WorldCoord {
    if (dir[0] > 0) return coord; // +X (East, base)
    if (dir[0] < 0) return .{ -coord[0], coord[1], -coord[2] }; // -X (West)
    if (dir[2] > 0) return .{ -coord[2], coord[1], coord[0] }; // +Z (South)
    return .{ coord[2], coord[1], -coord[0] }; // -Z (North)
}

fn rotateOrientation(rot: ms.Orientation, dir: WorldCoord) ms.Orientation {
    if (rot == .center) return .center;
    if (dir[0] > 0) return rot;

    if (dir[0] < 0) {
        return switch (rot) {
            .east => .west,
            .west => .east,
            .north => .south,
            .south => .north,
            else => rot,
        };
    }
    if (dir[2] > 0) {
        return switch (rot) {
            .east => .south,
            .west => .north,
            .north => .east,
            .south => .west,
            else => rot,
        };
    }

    return switch (rot) {
        .east => .north,
        .west => .south,
        .north => .west,
        .south => .east,
        else => rot,
    };
}
