const std = @import("std");
const ms = @import("abstract/structures.zig");
const phys = @import("physical.zig");
const nbt = @import("nbt.zig");

// return value
route: std.ArrayList(ms.AbsBlock) = .empty,
delay: u32 = 0,
length: u32 = 0,
violating: bool, // whether the route violates another route

pub fn deinit(self: *Route, allocator: std.mem.Allocator) void {
    self.route.deinit(allocator);
}

const Route = @This();

// the vias are designed to be 3 blocks tall so
// please dont make me change this >:(
pub const LAYER_HEIGHT: u2 = 3;

const WorldCoord = ms.WorldCoord;

const RouteComponent = enum {
    dust,
    repeater,
    via_up,
    via_down,
};

const NodeState = struct {
    coord: WorldCoord,
    signal: u4,
};

const Parent = struct {
    prev: NodeState,
    conn_type: RouteComponent,
    violating: bool,
};

// 3D Manhattan distance towards the target acts as an admissible heuristic.
fn heuristic(curr: WorldCoord, target: WorldCoord) u32 {
    const dx = @as(u32, @intCast(@abs(curr[0] - target[0])));
    const dy = @as(u32, @intCast(@abs(curr[1] - target[1])));
    const dz = @as(u32, @intCast(@abs(curr[2] - target[2])));
    return dx + dy + dz;
}

// any formless volume
const Volume = ms.OrderedSet(WorldCoord);

fn coordEq(a: WorldCoord, b: WorldCoord) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2];
}

const QueueItem = struct {
    state: NodeState,
    g: u32,
    f: u32,
};

fn queueOrder(context: void, a: QueueItem, b: QueueItem) std.math.Order {
    _ = context;
    const f_order = std.math.order(a.f, b.f);
    if (f_order == .eq) {
        // Tie-breaker: If f is equal, prioritize the node with the higher g-cost
        // because it has a smaller h-cost and is deeper in the search tree (closer to goal).
        return std.math.order(b.g, a.g);
    }
    return f_order;
}

const DistanceMetric = struct {
    distance: u32,
    signal_strength: u4,
};

const Move = struct {
    dir: WorldCoord,
    weight: u32,
    conn_type: RouteComponent,
};

fn check_validity(coord: WorldCoord, forbidden_zone: ms.ForbiddenZone) MoveValidity {
    const zone_conflict = forbidden_zone.get(coord);
    // return zone_conflict != null and zone_conflict.?.ftype == .gate;
    if (zone_conflict != null and zone_conflict.?.ftype == .gate) {
        return .invalid;
    }
    if (zone_conflict != null and zone_conflict.?.ftype == .wire) {
        return .violation;
    }
    return .valid;
}

const MoveValidity = enum {
    valid,
    invalid,
    violation,
};

fn isMoveValid(u: WorldCoord, move: Move, forbidden_zone: ms.ForbiddenZone) MoveValidity {
    const coord = u + move.dir;
    // check bounds
    if (coord[1] > phys.MAX_Y_LEVEL or coord[1] < phys.MIN_Y_LEVEL) return .invalid;

    // if (forbidden_zone.contains(coord)) return false;
    var verdict = check_validity(coord, forbidden_zone);
    if (verdict == .invalid) return .invalid;

    switch (move.conn_type) {
        .dust => return verdict,
        .repeater => {
            const mid = (u + coord) / @as(WorldCoord, @splat(2));
            const validity = check_validity(mid, forbidden_zone);
            if (validity == .invalid) return .invalid;
            if (validity == .violation) verdict = .violation;
        },
        .via_up => {
            const base_blocks = [_]WorldCoord{
                .{ 0, 0, 0 },
                .{ 1, 0, 0 },
                .{ 1, -1, 0 },
                .{ 2, 0, 0 },
                .{ 3, 1, 0 },
                .{ 2, 1, 0 },
                .{ 3, 0, 0 },
            };
            for (base_blocks) |base| {
                const rotated = rotateCoord(base, move.dir);
                if (check_validity(u + rotated, forbidden_zone) == .invalid) return .invalid;
                if (check_validity(u + rotated, forbidden_zone) == .violation) verdict = .violation;
            }
        },
        .via_down => {
            const base_blocks = [_]WorldCoord{
                .{ 0, 0, 0 },
                .{ 0, -1, 0 },
                .{ 2, -2, 0 },
                .{ 2, -1, 0 },
                .{ 2, 0, 0 },
                .{ 1, 0, 0 },
                .{ 1, -2, 0 },
                .{ 1, -3, 0 },
                .{ 1, -4, 0 },
            };
            for (base_blocks) |base| {
                const rotated = rotateCoord(base, move.dir);
                if (check_validity(u + rotated, forbidden_zone) == .invalid) return .invalid;
                if (check_validity(u + rotated, forbidden_zone) == .violation) verdict = .violation;
            }
        },
    }
    return verdict;
}

pub fn routeAll(a: std.mem.Allocator, pairs: []struct { from: WorldCoord, to: WorldCoord }, forbidden_zone: *ms.ForbiddenZone) !Route {
    for (pairs) |pair| {
        const route = routeTo(a, pair.from, pair.to, forbidden_zone);
        for (route.route.items) |b| {
            _ = b; // autofix
            // for (offsets) |offset| {
            // const coord = b.loc + offset;
            // try forbidden_zone.put(coord, .{ .ftype = .wire });
            // }
        }
    }
}

pub fn routeToUpdateForbiddenZone(a: std.mem.Allocator, from: WorldCoord, to: WorldCoord, forbidden_zone: *ms.ForbiddenZone) !Route {
    const route = try routeTo(a, from, to, forbidden_zone.*);

    const offsets = [_]WorldCoord{
        .{ 0, 0, 0 }, // Target block
        .{ 1, 0, 0 }, // +X
        .{ -1, 0, 0 }, // -X
        .{ 0, 1, 0 }, // +Y
        .{ 0, -1, 0 }, // -Y
        .{ 0, 0, 1 }, // +Z
        .{ 0, 0, -1 }, // -Z
    };

    for (route.route.items) |b| {
        for (offsets) |offset| {
            const coord = b.loc + offset;
            try forbidden_zone.put(coord, .{ .ftype = .wire });
        }
    }

    return route;
}

pub fn routeTo(a: std.mem.Allocator, from: WorldCoord, to: WorldCoord, forbidden_zone: ms.ForbiddenZone) !Route {
    if (from[1] < phys.MIN_Y_LEVEL or from[1] > phys.MAX_Y_LEVEL or
        to[1] < phys.MIN_Y_LEVEL or to[1] > phys.MAX_Y_LEVEL)
    {
        return error.OutOfBounds;
    }

    if (@as(u32, @intCast(from[1])) % LAYER_HEIGHT != 0 or @as(u32, @intCast(to[1])) % LAYER_HEIGHT != 0) {
        return error.InvalidToOrFromYLevel;
    }

    var queue = std.PriorityQueue(QueueItem, void, queueOrder).init(a, {});
    defer queue.deinit();

    // Dictionaries now key on NodeState (Coord + Signal Strength)
    var parents = std.AutoHashMap(NodeState, Parent).init(a);
    defer parents.deinit();

    var distances = std.AutoHashMap(NodeState, u32).init(a);
    defer distances.deinit();

    const start_state = NodeState{ .coord = from, .signal = 15 };
    try distances.put(start_state, 0);
    try queue.add(.{ .state = start_state, .g = 0, .f = heuristic(from, to) });

    // Edge weights must be > 0. Scaled to reflect relative pathing delays/material costs.
    const moves = [_]Move{
        .{ .dir = .{ 1, 0, 0 }, .weight = 0, .conn_type = .dust },
        .{ .dir = .{ 0, 0, 1 }, .weight = 0, .conn_type = .dust },
        .{ .dir = .{ -1, 0, 0 }, .weight = 0, .conn_type = .dust },
        .{ .dir = .{ 0, 0, -1 }, .weight = 0, .conn_type = .dust },

        .{ .dir = .{ 2, 0, 0 }, .weight = 2, .conn_type = .repeater },
        .{ .dir = .{ 0, 0, 2 }, .weight = 2, .conn_type = .repeater },
        .{ .dir = .{ -2, 0, 0 }, .weight = 2, .conn_type = .repeater },
        .{ .dir = .{ 0, 0, -2 }, .weight = 2, .conn_type = .repeater },

        .{ .dir = .{ 2, 3, 0 }, .weight = 5, .conn_type = .via_up },
        .{ .dir = .{ -2, 3, 0 }, .weight = 5, .conn_type = .via_up },
        .{ .dir = .{ 0, 3, 2 }, .weight = 5, .conn_type = .via_up },
        .{ .dir = .{ 0, 3, -2 }, .weight = 5, .conn_type = .via_up },

        .{ .dir = .{ 2, -3, 0 }, .weight = 5, .conn_type = .via_down },
        .{ .dir = .{ -2, -3, 0 }, .weight = 5, .conn_type = .via_down },
        .{ .dir = .{ 0, -3, 2 }, .weight = 5, .conn_type = .via_down },
        .{ .dir = .{ 0, -3, -2 }, .weight = 5, .conn_type = .via_down },
    };

    var final_state: ?NodeState = null;

    while (queue.count() > 0) {
        const item = queue.removeOrNull().?;
        const u_state = item.state;
        const u = u_state.coord;

        const best_g = distances.get(u_state) orelse std.math.maxInt(u32);
        if (item.g > best_g) continue;

        if (coordEq(u, to)) {
            final_state = u_state;
            break;
        }

        for (moves) |move| {
            const coord = u + move.dir;
            const validity = isMoveValid(u, move, forbidden_zone);
            if (validity == .invalid) continue;

            var next_signal = u_state.signal;

            if (move.conn_type == .dust) {
                if (next_signal == 0) continue;
                if (next_signal == 1 and coordEq(coord, to)) continue;
                next_signal -= 1;
            } else if (move.conn_type == .repeater) {
                if (next_signal == 0) continue;
                next_signal = 15;
            } else if (move.conn_type == .via_up or move.conn_type == .via_down) {
                if (next_signal < 2) continue;
                next_signal = 14;
            }

            const next_state = NodeState{ .coord = coord, .signal = next_signal };

            var move_cost = move.weight;
            if (validity == .violation) {
                move_cost += 100;
            }

            const g_cost = item.g + move_cost;
            const existing_g = distances.get(next_state);

            if (existing_g == null or g_cost < existing_g.?) {
                distances.put(next_state, g_cost) catch @panic("oom");
                parents.put(next_state, .{
                    .prev = u_state,
                    .conn_type = move.conn_type,
                    .violating = validity == .violation,
                }) catch @panic("oom");

                const h_cost = heuristic(coord, to);
                queue.add(.{
                    .state = next_state,
                    .g = g_cost,
                    .f = g_cost + h_cost,
                }) catch @panic("oom");
            }
        }
    }

    if (final_state == null) {
        std.log.err("Could not find a path to .{any}", .{to});
        return error.PathNotFound;
    }

    return try buildRouteBlocks(a, from, final_state.?, parents);
}

fn buildRouteBlocks(a: std.mem.Allocator, from: WorldCoord, final_state: NodeState, parents: std.AutoHashMap(NodeState, Parent)) !Route {
    var abs_blocks: std.ArrayList(ms.AbsBlock) = .empty;

    var length: u32 = 0;
    var delay: u32 = 0;

    var violating = false;
    var curr_state = final_state;
    var vec = curr_state.coord;
    var prev_vec = vec;

    while (!coordEq(vec, from)) {
        const p = parents.get(curr_state) orelse return error.MissingParent;
        curr_state = p.prev;
        vec = curr_state.coord;

        if (p.violating) violating = true;
        const move_dir = prev_vec - vec;

        switch (p.conn_type) {
            .dust => {
                try abs_blocks.append(a, .{ .block = .dust, .loc = vec, .rot = .center });
                try abs_blocks.append(a, .{ .block = .block, .loc = vec + WorldCoord{ 0, -1, 0 }, .rot = .center });
                length += 1;
            },
            .repeater => {
                const mid = (prev_vec + vec) / @as(WorldCoord, @splat(2));
                const rot: ms.Orientation = if (vec[0] > prev_vec[0]) .west else if (vec[0] < prev_vec[0]) .east else if (vec[2] > prev_vec[2]) .north else .south;

                try abs_blocks.append(a, .{ .block = .repeater, .loc = mid, .rot = rot });

                try abs_blocks.append(a, .{ .block = .dust, .loc = vec, .rot = .center });
                try abs_blocks.append(a, .{ .block = .block, .loc = mid + WorldCoord{ 0, -1, 0 }, .rot = .center });
                try abs_blocks.append(a, .{ .block = .block, .loc = vec + WorldCoord{ 0, -1, 0 }, .rot = .center });
                length += 2;
                delay += 1; // repeaters add a delay of 1 tick
            },
            .via_up => {
                const offsets = [_]struct { WorldCoord, ms.BlockCat, ms.Orientation }{
                    .{ .{ 0, 0, 0 }, .dust, .center },
                    .{ .{ 0, -1, 0 }, .block, .center },
                    .{ .{ 1, 0, 0 }, .dust, .center },
                    .{ .{ 1, -1, 0 }, .block, .center },
                    .{ .{ 2, 0, 0 }, .block, .center },
                    .{ .{ 3, 1, 0 }, .block, .center },
                    .{ .{ 2, 1, 0 }, .torch, .west },
                    .{ .{ 3, 0, 0 }, .torch, .east },
                };
                for (offsets) |off| {
                    const rotated_coord = rotateCoord(off[0], move_dir);
                    const rotated_rot = rotateOrientation(off[2], move_dir);
                    try abs_blocks.append(a, .{
                        .block = off[1],
                        .loc = vec + rotated_coord,
                        .rot = rotated_rot,
                    });
                }
                // try abs_blocks.append(a, .{ .block = .block, .loc = vec + WorldCoord{ 0, -1, 0 }, .rot = .center });
                delay += 2; // vias add a delay of 2 ticks
                // well, 3 blocks up and 2 blocks over, kinda
                length += 5;
            },

            .via_down => {
                const offsets = [_]struct { WorldCoord, ms.BlockCat, ms.Orientation }{
                    .{ .{ 0, 0, 0 }, .dust, .center },
                    .{ .{ 0, -1, 0 }, .block, .center },
                    .{ .{ 2, -2, 0 }, .block, .center },
                    .{ .{ 2, -1, 0 }, .dust, .center },
                    .{ .{ 2, 0, 0 }, .torch, .east },
                    .{ .{ 1, 0, 0 }, .block, .center },
                    .{ .{ 1, -2, 0 }, .torch, .west },
                    .{ .{ 1, -3, 0 }, .dust, .west },
                    .{ .{ 1, -4, 0 }, .block, .center },
                };
                for (offsets) |off| {
                    const rotated_coord = rotateCoord(off[0], move_dir);
                    const rotated_rot = rotateOrientation(off[2], move_dir);
                    try abs_blocks.append(a, .{
                        .block = off[1],
                        .loc = vec + rotated_coord,
                        .rot = rotated_rot,
                    });
                }
                delay += 2; // vias add a delay of 2 ticks
                length += 5;
            },
        }

        prev_vec = vec;
    }
    // append output
    try abs_blocks.append(a, .{ .block = .dust, .loc = final_state.coord, .rot = .center });
    try abs_blocks.append(a, .{ .block = .block, .loc = final_state.coord + WorldCoord{ 0, -1, 0 }, .rot = .center });

    var min_coord = @as(WorldCoord, @splat(std.math.maxInt(i32)));
    for (abs_blocks.items) |b| {
        min_coord[0] = @min(min_coord[0], b.loc[0]);
        min_coord[1] = @min(min_coord[1], b.loc[1]);
        min_coord[2] = @min(min_coord[2], b.loc[2]);
    }

    return .{
        .route = abs_blocks,
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
