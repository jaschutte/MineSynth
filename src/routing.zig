const std = @import("std");
const ms = @import("abstract/structures.zig");
const phys = @import("physical.zig");
const nbt = @import("nbt.zig");

// return value
route: std.ArrayList(ms.AbsBlock) = .empty,
delay: u32 = 0,
length: u32 = 0,

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

const Parent = struct {
    prev: WorldCoord,
    conn_type: RouteComponent,
};

// any formless volume
const Volume = ms.OrderedSet(WorldCoord);

fn coordEq(a: WorldCoord, b: WorldCoord) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2];
}

const QueueItem = struct {
    coord: WorldCoord,
    dist: u32,
    manhattan: u32,
};

fn queueOrder(context: void, a: QueueItem, b: QueueItem) std.math.Order {
    _ = context;
    const dist_order = std.math.order(a.dist, b.dist);
    if (dist_order == .eq) {
        return std.math.order(a.manhattan, b.manhattan);
    }
    return dist_order;
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

fn isMoveValid(u: WorldCoord, move: Move, forbidden_zone: ms.ForbiddenZone) bool {
    const coord = u + move.dir;
    // check bounds
    if (coord[1] > phys.MAX_Y_LEVEL or coord[1] < phys.MIN_Y_LEVEL) return false;

    if (forbidden_zone.contains(coord)) return false;

    switch (move.conn_type) {
        .dust => return true,
        .repeater => {
            const mid = (u + coord) / @as(WorldCoord, @splat(2));
            return !forbidden_zone.contains(mid);
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
                if (forbidden_zone.contains(u + rotated)) return false;
            }
            return true;
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
                if (forbidden_zone.contains(u + rotated)) return false;
            }
            return true;
        },
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
            // WorldCoord acts as a vector here, permitting direct addition
            const coord = b.loc + offset;
            try forbidden_zone.put(coord, void{});
        }
    }
    // remove blocks around to and from
    for (offsets) |offset| {
        const from_coord = from + offset;
        _ = forbidden_zone.remove(from_coord);

        const to_coord = to + offset;
        _ = forbidden_zone.remove(to_coord);
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

    // extra debug checks
    // if (forbidden_zone.contains(from)) {
    //     std.log.err("From coordinate .{any} is in the forbidden zone", .{from});
    //     return error.InvalidToOrFromInForbiddenZone;
    // }
    // if (forbidden_zone.contains(to)) {
    //     std.log.err("To coordinate .{any} is in the forbidden zone", .{to});
    //     return error.InvalidToOrFromInForbiddenZone;
    // }

    const SEARCH_RADIUS = 200; // in Manhattan distance

    var queue = std.PriorityQueue(QueueItem, void, queueOrder).init(a, {});
    defer queue.deinit();

    var parents = std.AutoHashMap(WorldCoord, Parent).init(a);
    defer parents.deinit();

    var explored = std.AutoHashMap(WorldCoord, void).init(a);
    defer explored.deinit();

    var distances = std.AutoHashMap(WorldCoord, DistanceMetric).init(a);
    defer distances.deinit();

    try distances.put(from, .{ .distance = 0, .signal_strength = 15 });
    try queue.add(.{ .coord = from, .dist = 0, .manhattan = 0 });

    const moves = [_]Move{
        // consider regular redstone
        .{ .dir = .{ 1, 0, 0 }, .weight = 0, .conn_type = .dust },
        .{ .dir = .{ 0, 0, 1 }, .weight = 0, .conn_type = .dust },
        .{ .dir = .{ -1, 0, 0 }, .weight = 0, .conn_type = .dust },
        .{ .dir = .{ 0, 0, -1 }, .weight = 0, .conn_type = .dust },
        // consider repeaters
        .{ .dir = .{ 2, 0, 0 }, .weight = 1, .conn_type = .repeater },
        .{ .dir = .{ 0, 0, 2 }, .weight = 1, .conn_type = .repeater },
        .{ .dir = .{ -2, 0, 0 }, .weight = 1, .conn_type = .repeater },
        .{ .dir = .{ 0, 0, -2 }, .weight = 1, .conn_type = .repeater },
        // via up
        .{ .dir = .{ 2, 3, 0 }, .weight = 2, .conn_type = .via_up },
        .{ .dir = .{ -2, 3, 0 }, .weight = 2, .conn_type = .via_up },
        .{ .dir = .{ 0, 3, 2 }, .weight = 2, .conn_type = .via_up },
        .{ .dir = .{ 0, 3, -2 }, .weight = 2, .conn_type = .via_up },
        // via down
        .{ .dir = .{ 2, -3, 0 }, .weight = 2, .conn_type = .via_down },
        .{ .dir = .{ -2, -3, 0 }, .weight = 2, .conn_type = .via_down },
        .{ .dir = .{ 0, -3, 2 }, .weight = 2, .conn_type = .via_down },
        .{ .dir = .{ 0, -3, -2 }, .weight = 2, .conn_type = .via_down },
    };

    while (queue.count() > 0) {
        const item = queue.removeOrNull().?;
        const u = item.coord;

        // Lazy Dijkstra: discard popped items that are stale
        const best_dist = distances.get(u) orelse continue;
        if (item.dist > best_dist.distance) continue;

        // done once arrived at the destination for the first time
        // could consider more options but this is still a good heuristic
        // or maybe optimal considering our specific case...
        // could add a search depth option and search limit
        if (coordEq(u, to)) break;

        for (moves) |move| {
            const coord = u + move.dir;

            if (!isMoveValid(u, move, forbidden_zone)) continue;
            // check if within search radius
            const manhattan = @abs(coord[0] - from[0]) + @abs(coord[2] - from[2]);
            if (manhattan > SEARCH_RADIUS) continue;

            const prev_metric = distances.get(u).?;
            var signal_strength = prev_metric.signal_strength;

            if (move.conn_type == .dust) {
                if (signal_strength == 0) continue;
                // need at least signal strength 1 at input
                if (signal_strength == 1 and coordEq(coord, to)) continue;
                signal_strength -= 1;
            } else if (move.conn_type == .repeater) {
                if (signal_strength == 0) continue;
                signal_strength = 15;
            } else if (move.conn_type == .via_up or move.conn_type == .via_down) {
                if (signal_strength < 2) continue;
                signal_strength = 14;
            }

            const dist = prev_metric.distance + move.weight;
            const distv = distances.get(coord);

            // If we found a strictly better path to `coord`
            if (distv == null or dist < distv.?.distance) {
                distances.put(coord, .{ .signal_strength = signal_strength, .distance = dist }) catch @panic("oom");
                parents.put(coord, .{ .conn_type = move.conn_type, .prev = u }) catch @panic("oom");

                // Push duplicate entry. The heap sorts by this static item.dist.
                queue.add(.{ .coord = coord, .dist = dist, .manhattan = @as(u32, @intCast(manhattan)) }) catch @panic("oom");
            }
        }

        explored.put(u, void{}) catch @panic("oom");
    }

    // check if exhausted search space without finding destination
    if (parents.get(to) == null) {
        std.log.err("Could not find a path to .{any}", .{to});
        return error.PathNotFound;
    }

    // construct block array
    return try buildRouteBlocks(a, from, to, parents);
}

fn buildRouteBlocks(a: std.mem.Allocator, from: WorldCoord, to: WorldCoord, parents: std.AutoHashMap(WorldCoord, Parent)) !Route {
    var abs_blocks: std.ArrayList(ms.AbsBlock) = .empty;

    var vec = to;
    var prev_vec = to;

    var length: u32 = 0;
    var delay: u32 = 0;

    while (!coordEq(vec, from)) {
        const p = parents.get(vec) orelse return error.MissingParent;
        vec = p.prev;

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
                length += 1;
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
    try abs_blocks.append(a, .{ .block = .dust, .loc = to, .rot = .center });
    try abs_blocks.append(a, .{ .block = .block, .loc = to + WorldCoord{ 0, -1, 0 }, .rot = .center });

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
