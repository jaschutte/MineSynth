const std = @import("std");
const phys = @import("physical.zig");
const nbt = @import("nbt.zig");
const comp = @import("components/components.zig");
const ms = @import("abstract/structures.zig");

const Router = @This();

max_iterations: u32 = 20,
violation_cost_multiplier: f32 = 60.0,
heuristic_weight: f32 = 1.0,
delay_cost_multiplier: f32 = 1.0, // cost = this * delay + length
max_cost: f32 = 100000, // dont explore dumb paths

// typedefs
const WorldCoord = ms.WorldCoord;

// an A* node is a coord + signal so signal strength can be guaranteed
const NodeState = struct {
    coord: WorldCoord,
    signal: u4,
};

// parent node and associated metadata
const Parent = struct {
    prev: NodeState,
    def: *const comp.ComponentDef,
    violating: bool,
    heading: WorldCoord,
};

// return value
const Route = struct {
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

pub const RoutePair = struct {
    from: WorldCoord,
    to: WorldCoord,
};

// Utility functions
fn coordEq(a: WorldCoord, b: WorldCoord) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2];
}

// computed at comptime
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
        fp.blocks[fp.count] = u + rotateCoord(bb.offset, move.heading);
        fp.count += 1;
    }
    return fp;
}

fn moveIntersectsPath(new_u: WorldCoord, new_move: Move, start_state: NodeState, parents: *const std.AutoHashMap(NodeState, Parent)) bool {
    const new_fp = getMoveFootprint(new_u, new_move);
    const new_coord = new_u + new_move.dir;

    var curr = start_state;
    var is_immediate_parent = true;

    while (true) {
        // make sure it's not the same coord
        if (coordEq(curr.coord, new_coord)) return true;

        if (parents.get(curr)) |p| {
            const prev_u = p.prev.coord;
            const past_move = Move{
                .dir = curr.coord - prev_u,
                .heading = p.heading,
                .def = p.def,
            };
            const dx = @abs(prev_u[0] - new_u[0]);
            const dy = @abs(prev_u[1] - new_u[1]);
            const dz = @abs(prev_u[2] - new_u[2]);
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

const Move = struct {
    dir: WorldCoord,
    heading: WorldCoord,
    def: *const comp.ComponentDef,
};

const MoveValidity = union(enum) {
    valid,
    invalid,
    violation: u32,
};

fn check_validity(coord: WorldCoord, forbidden_zone: ms.ForbiddenZone, current_from: WorldCoord, is_first_move: bool, host_route_id: ?usize) MoveValidity {
    _ = current_from; // autofix
    if (forbidden_zone.get(coord)) |conflict| {
        if (conflict.ftype == .gate) return .invalid;

        if (is_first_move) return .valid;

        if (conflict.ftype == .wire_padding) {
            if (host_route_id != null and conflict.route_id == host_route_id.? and conflict.foreign_ref_count == 0) {
                // Exemption: Branches can safely step on their host's padding anywhere
                return .valid;
            }
            return .{ .violation = conflict.ref_count };
        }

        if (conflict.ftype == .wire) return .{ .violation = conflict.ref_count };
    }
    return .valid;
}

fn isMoveValid(u: WorldCoord, move: Move, forbidden_zone: ms.ForbiddenZone, current_from: WorldCoord, is_first_move: bool, host_route_id: ?usize) MoveValidity {
    const target_coord = u + move.dir;
    if (target_coord[1] > phys.MAX_Y_LEVEL or target_coord[1] < phys.MIN_Y_LEVEL) return .invalid;

    var total_refs: u32 = 0;
    for (move.def.build_blocks) |bb| {
        const rotated = rotateCoord(bb.offset, move.heading);
        switch (check_validity(u + rotated, forbidden_zone, current_from, is_first_move, host_route_id)) {
            .invalid => return .invalid,
            .valid => {},
            .violation => |refs| total_refs += refs,
        }
    }

    if (total_refs > 0) return .{ .violation = total_refs };
    return .valid;
}

const Net = struct {
    id: usize,
    from: WorldCoord,
    original_from: WorldCoord,
    to: WorldCoord,
    route: ?Route,
    failures: u32,
    is_violating: bool = false,
};

// Heuristic for REORDER(): Route nets with the most failures first.
// Tie-breaker: Route longer nets first.
fn sortNetPtrsDescending(config: Router, lhs: *Net, rhs: *Net) bool {
    if (lhs.failures == rhs.failures) {
        const dist_lhs = heuristic(lhs.from, lhs.to, config.delay_cost_multiplier);
        const dist_rhs = heuristic(rhs.from, rhs.to, config.delay_cost_multiplier);
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
                    if (existing.ftype == .wire or existing.ftype == .wire_padding) {
                        existing.ref_count -= 1;

                        if (!coordEq(existing.source_coord, net.from)) {
                            existing.foreign_ref_count -= 1;
                        }

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

const CellInfo = struct {
    nets: [4]*Net,
    is_center: [4]bool,
    count: usize,
};

fn isHost(branch_net: *const Net, potential_host: *const Net) bool {
    if (potential_host.route) |*r| {
        for (r.footprints.items) |fp| {
            if (coordEq(fp, branch_net.from)) return true;
        }
    }
    return false;
}

fn updateViolations(a: std.mem.Allocator, nets: []Net) !void {
    var owners = std.AutoHashMap(WorldCoord, CellInfo).init(a);
    defer owners.deinit();

    // Pass 1: Build the complete ownership map
    for (nets) |*net| {
        net.is_violating = if (net.route) |*r| r.violating else false;

        if (net.route) |*r| {
            for (r.footprints.items) |coord| {
                for (SURROUNDING_OFFSETS) |offset| {
                    const target = coord + offset;
                    const is_center = offset[0] == 0 and offset[1] == 0 and offset[2] == 0;

                    if (owners.getPtr(target)) |existing| {
                        var found = false;
                        for (existing.nets[0..existing.count], 0..) |n, i| {
                            if (n == net) {
                                found = true;
                                if (is_center) existing.is_center[i] = true;
                                break;
                            }
                        }
                        if (!found and existing.count < 4) {
                            existing.nets[existing.count] = net;
                            existing.is_center[existing.count] = is_center;
                            existing.count += 1;
                        }
                    } else {
                        var info = CellInfo{ .nets = undefined, .is_center = undefined, .count = 1 };
                        info.nets[0] = net;
                        info.is_center[0] = is_center;
                        try owners.put(target, info);
                    }
                }
            }
        }
    }
    // Pass 2: Evaluate intersections against the complete map
    for (nets) |*net| {
        if (net.route) |*r| {
            for (r.footprints.items) |coord| {
                if (owners.get(coord)) |info| {
                    for (info.nets[0..info.count], 0..) |existing_net, i| {
                        if (existing_net != net) {
                            var is_violation = true;

                            const net_is_branch = isHost(net, existing_net);
                            const existing_is_branch = isHost(existing_net, net);

                            if (net_is_branch or existing_is_branch) {
                                // Find net's center status in the cell
                                var net_is_center = false;
                                for (info.nets[0..info.count], 0..) |n, j| {
                                    if (n == net) {
                                        net_is_center = info.is_center[j];
                                        break;
                                    }
                                }
                                const existing_is_center = info.is_center[i];

                                if (!(net_is_center and existing_is_center)) {
                                    // Exemption: core-to-padding or padding-to-padding overlaps allowed anywhere
                                    is_violation = false;
                                } else {
                                    // Exemption: core-to-core overlaps allowed ONLY at the exact branch origin
                                    const bp = if (net_is_branch) net.from else existing_net.from;
                                    const support_coord = bp + WorldCoord{ 0, -1, 0 };

                                    if (coordEq(coord, bp) or coordEq(coord, support_coord)) {
                                        is_violation = false;
                                    }
                                }
                            }

                            if (is_violation) {
                                existing_net.is_violating = true;
                                net.is_violating = true;
                            }
                        }
                    }
                }
            }
        }
    }

    for (nets) |*net| {
        if (net.route) |*r| r.violating = net.is_violating;
    }
}

fn optimizeBranchPoint(current_net: *Net, routed_nets: []Net, config: Router) void {
    var best_fp: ?WorldCoord = null;
    var best_dist = heuristic(current_net.original_from, current_net.to, config.delay_cost_multiplier);

    for (routed_nets) |*other| {
        if (other.route == null or other.id == current_net.id) continue;

        // Only evaluate footprints of nets that share the same logical origin
        if (coordEq(current_net.original_from, other.original_from)) {
            for (other.route.?.footprints.items) |fp| {
                const dist = heuristic(fp, current_net.to, config.delay_cost_multiplier);
                if (dist < best_dist) {
                    best_dist = dist;
                    best_fp = fp;
                }
            }
        }
    }

    current_net.from = best_fp orelse current_net.original_from;
}

pub fn routeAll(a: std.mem.Allocator, pairs: []RoutePair, forbidden_zone: *ms.ForbiddenZone, config: Router) !Route {
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
            .id = i,
            .from = pair.from,
            .original_from = pair.from,
            .to = pair.to,
            .route = null,
            .failures = 0,
            .is_violating = false,
        };
        optimizeBranchPoint(&nets[i], nets[0..i], config);
        std.log.info("Routing net {} from {any} to {any}", .{ i, nets[i].from, nets[i].to });
        nets[i].route = try routeToUpdateForbiddenZone(a, nets[i].from, nets[i].to, forbidden_zone, config, nets[i].id);
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
        std.sort.block(*Net, v_nets.items, config, sortNetPtrsDescending);
        const num_v_nets_this_pass = v_nets.items.len;

        std.log.info("Iteration {}: Routing {} violating nets", .{ iters, num_v_nets_this_pass });

        for (0..num_v_nets_this_pass) |_| {
            var net = v_nets.orderedRemove(0);
            ripUp(net, forbidden_zone, a);
            optimizeBranchPoint(net, nets, config);
            std.log.info("Re-routing net from {any} to {any} with {} failures", .{ net.from, net.to, net.failures });
            net.route = try routeToUpdateForbiddenZone(a, net.from, net.to, forbidden_zone, config, net.id);
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

const QueueItem = struct {
    state: NodeState,
    g: f32,
    f: f32,
};

// 2d manhattan
// admissible because you cant move 15 blocks without
// increasing delay by 1
// does not consider Y
fn heuristic(curr: WorldCoord, target: WorldCoord, delay_weight: f32) f32 {
    const dx = @abs(curr[0] - target[0]);
    // const dy = @abs(curr[0] - target[0]);
    const dz = @abs(curr[2] - target[2]);
    const manhattan: u32 = dx + dz;

    const min_unavoidable_delay_cost = (manhattan / 15) * @as(u32, @intFromFloat(@round(delay_weight)));

    return @floatFromInt(manhattan + min_unavoidable_delay_cost);
}

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

pub fn routeToUpdateForbiddenZone(a: std.mem.Allocator, from: WorldCoord, to: WorldCoord, forbidden_zone: *ms.ForbiddenZone, config: Router, route_id: usize) !Route {
    const route = try routeTo(a, from, to, forbidden_zone.*, config);

    for (route.footprints.items) |coord| {
        for (SURROUNDING_OFFSETS) |offset| {
            const target = coord + offset;
            const is_center = offset[0] == 0 and offset[1] == 0 and offset[2] == 0;
            const target_ftype: ms.ForbiddenZoneType = if (is_center) .wire else .wire_padding;

            if (forbidden_zone.getPtr(target)) |existing| {
                if (existing.ftype == .wire or existing.ftype == .wire_padding) {
                    existing.ref_count += 1;

                    if (!coordEq(existing.source_coord, from)) {
                        existing.foreign_ref_count += 1;
                    }

                    // Upgrade padding to a hard wire if requested
                    if (target_ftype == .wire and existing.ftype == .wire_padding) {
                        existing.ftype = .wire;

                        // Transfer ownership to the route that placed the hard wire
                        if (existing.route_id != route_id) {
                            // The old owner (and any other nets) are now foreign to the new owner
                            existing.foreign_ref_count = existing.ref_count - 1;

                            existing.route_id = route_id;
                            existing.source_coord = from;
                        }
                    }
                }
            } else {
                try forbidden_zone.put(target, .{
                    .ftype = target_ftype,
                    .ref_count = 1,
                    .foreign_ref_count = 0,
                    .route_id = route_id,
                    .source_coord = from,
                });
            }
        }
    }

    return route;
}

pub fn routeTo(a: std.mem.Allocator, from: WorldCoord, to: WorldCoord, forbidden_zone: ms.ForbiddenZone, config: Router) !Route {
    if (from[1] < phys.MIN_Y_LEVEL or from[1] > phys.MAX_Y_LEVEL or
        to[1] < phys.MIN_Y_LEVEL or to[1] > phys.MAX_Y_LEVEL)
    {
        return error.OutOfBounds;
    }

    const host_entry = forbidden_zone.get(from);
    const host_route_id = if (host_entry) |e| e.route_id else null;

    var queue = std.PriorityQueue(QueueItem, void, queueOrder).init(a, {});
    defer queue.deinit();

    // Dictionaries now key on NodeState (Coord + Signal Strength)
    var parents = std.AutoHashMap(NodeState, Parent).init(a);
    defer parents.deinit();

    var distances = std.AutoHashMap(NodeState, f32).init(a);
    defer distances.deinit();

    const start_state = NodeState{ .coord = from, .signal = 15 };
    try distances.put(start_state, 0);
    try queue.add(.{ .state = start_state, .g = 0, .f = heuristic(from, to, config.delay_cost_multiplier) });

    // Edge weights must be > 0. Scaled to reflect relative pathing delays/material costs.
    const moves = comptime blk: {
        var m: [comp.components.len * 4]Move = undefined;
        var idx = 0;
        for (&comp.components) |*def| {
            for ([_]WorldCoord{ .{ 1, 0, 0 }, .{ 0, 0, 1 }, .{ -1, 0, 0 }, .{ 0, 0, -1 } }) |cdir| {
                m[idx] = .{
                    .dir = rotateCoord(def.base_dir, cdir),
                    .heading = cdir,
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
            //prevent immediate 180-degree turnarounds
            if (parents.get(u_state)) |p| {
                if (move.heading[0] == -p.heading[0] and move.heading[2] == -p.heading[2]) {
                    continue;
                }
            }
            const coord = u + move.dir;
            if (moveIntersectsPath(u, move, u_state, &parents)) continue;

            // Check if this is the very first move from the start coordinate
            const is_first_move = (item.g == 0);
            if (is_first_move and move.def.cat != .dust) continue;

            // Pass the host_route_id down
            const validity = isMoveValid(u, move, forbidden_zone, from, is_first_move, host_route_id);
            if (validity == .invalid) continue;

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

            var move_cost = @as(f32, @floatFromInt(move.def.delay)) * config.delay_cost_multiplier + @as(f32, @floatFromInt(move.def.length));
            var is_violating = false;

            switch (validity) {
                .violation => |refs| {
                    // multiply by how bad the violation is
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
                    .heading = move.heading,
                }) catch @panic("oom");

                const f_cost = g_cost + heuristic(coord, to, config.delay_cost_multiplier) * config.heuristic_weight;
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
        const move_dir = p.heading;

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
