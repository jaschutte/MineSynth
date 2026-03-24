const std = @import("std");
const phys = @import("physical.zig");
const nbt = @import("nbt.zig");
const comp = @import("components/components.zig");
const ms = @import("abstract/structures.zig");

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
fn heuristic(curr: WorldCoord, target: WorldCoord) u32 {
    const dx = @as(u32, @intCast(@abs(curr[0] - target[0])));
    const dy = @as(u32, @intCast(@abs(curr[1] - target[1])));
    const dz = @as(u32, @intCast(@abs(curr[2] - target[2])));
    return dx + dy + dz;
}

const MaxMoveBlocks = 10;
const MoveFootprint = struct {
    blocks: [MaxMoveBlocks]WorldCoord,
    count: usize,
};

fn getMoveFootprint(u: WorldCoord, move: Move) MoveFootprint {
    var fp: MoveFootprint = .{ .blocks = undefined, .count = 0 };
    for (move.def.footprint) |base| {
        fp.blocks[fp.count] = u + rotateCoord(base, move.dir);
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
        // 1. Check for node overlap
        if (coordEq(curr.coord, new_coord)) return true;

        // 2. Check for physical edge volume overlap
        if (parents.get(curr)) |p| {
            const prev_u = p.prev.coord;
            const past_move = Move{
                .dir = curr.coord - prev_u,
                .def = p.def,
            };
            const past_fp = getMoveFootprint(prev_u, past_move);

            for (new_fp.blocks[0..new_fp.count]) |b1| {
                for (past_fp.blocks[0..past_fp.count]) |b2| {
                    if (coordEq(b1, b2)) {
                        // Allow the new move to share a node with its immediate parent edge
                        if (is_immediate_parent and coordEq(b1, new_u)) {
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
    def: *const comp.ComponentDef,
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
    const target_coord = u + move.dir;
    if (target_coord[1] > phys.MAX_Y_LEVEL or target_coord[1] < phys.MIN_Y_LEVEL) return .invalid;

    var verdict: MoveValidity = .valid;
    for (move.def.footprint) |base| {
        const rotated = rotateCoord(base, move.dir);
        const check = check_validity(u + rotated, forbidden_zone);
        if (check == .invalid) return .invalid;
        if (check == .violation) verdict = .violation;
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
            if (moveIntersectsPath(u, move, u_state, &parents)) continue;
            const validity = isMoveValid(u, move, forbidden_zone);
            if (validity == .invalid) continue;

            // Data-driven signal calculation
            var next_signal = u_state.signal;
            if (next_signal < move.def.min_signal) continue;

            switch (move.def.signal_behavior) {
                .decay => {
                    if (next_signal == 1 and coordEq(coord, to)) continue;
                    next_signal -= 1;
                },
                .reset => next_signal = 15,
                .via => next_signal = 14,
            }

            const next_state = NodeState{ .coord = coord, .signal = next_signal };

            var move_cost = move.def.weight;
            if (validity == .violation) move_cost += 100;
            const g_cost = item.g + move_cost;

            const existing_g = distances.get(next_state);
            if (existing_g == null or g_cost < existing_g.?) {
                distances.put(next_state, g_cost) catch @panic("oom");
                parents.put(next_state, .{
                    .prev = u_state,
                    .def = move.def,
                    .violating = validity == .violation,
                }) catch @panic("oom");

                queue.add(.{
                    .state = next_state,
                    .g = g_cost,
                    .f = g_cost + heuristic(coord, to),
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

        // Data-driven block placement utilizing the pre-defined offsets
        for (p.def.build_blocks) |block_def| {
            const rotated_coord = rotateCoord(block_def.offset, move_dir);
            const rotated_rot = rotateOrientation(block_def.rot, move_dir);

            try abs_blocks.append(a, .{
                .block = block_def.cat,
                .loc = vec + rotated_coord,
                .rot = rotated_rot,
            });
        }

        length += p.def.length;
        delay += p.def.delay;
        prev_vec = vec;
    }

    try abs_blocks.append(a, .{ .block = .dust, .loc = final_state.coord, .rot = .center });
    try abs_blocks.append(a, .{ .block = .block, .loc = final_state.coord + WorldCoord{ 0, -1, 0 }, .rot = .center });

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
