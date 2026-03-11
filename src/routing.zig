const std = @import("std");
const ms = @import("abstract/structures.zig");
const nbt = @import("nbt.zig");

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
    euclid: u32,
};

fn queueOrder(context: void, a: QueueItem, b: QueueItem) std.math.Order {
    _ = context;
    const dist_order = std.math.order(a.dist, b.dist);
    if (dist_order == .eq) {
        return std.math.order(a.euclid, b.euclid);
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

fn isMoveValid(u: WorldCoord, move: Move, forbidden_zones: Volume) bool {
    const coord = u + move.dir;
    if (forbidden_zones.contains(coord)) return false;

    switch (move.conn_type) {
        .dust => return true,
        .repeater => {
            const mid = (u + coord) / @as(WorldCoord, @splat(2));
            return !forbidden_zones.contains(mid);
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
                if (forbidden_zones.contains(u + rotated)) return false;
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
                if (forbidden_zones.contains(u + rotated)) return false;
            }
            return true;
        },
    }
}

pub fn routeTo(a: std.mem.Allocator, from: WorldCoord, to: WorldCoord, forbidden_zones: Volume) !void {
    var explored = std.AutoHashMap(WorldCoord, void).init(a);
    defer explored.deinit();

    var distances = std.AutoHashMap(WorldCoord, DistanceMetric).init(a);
    defer distances.deinit();

    var queue = std.PriorityQueue(QueueItem, void, queueOrder).init(a, {});
    defer queue.deinit();

    var parents = std.AutoHashMap(WorldCoord, Parent).init(a);
    defer parents.deinit();

    try distances.put(from, .{ .distance = 0, .signal_strength = 15 });
    try queue.add(.{ .coord = from, .dist = 0, .euclid = 0 });

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
        const item = queue.remove();
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

            if (!isMoveValid(u, move, forbidden_zones)) continue;

            const prev_metric = distances.get(u).?;
            var signal_strength = prev_metric.signal_strength;

            if (move.conn_type == .dust) {
                if (signal_strength == 0) continue;
                // need at least signal strength 1 at output
                if (signal_strength == 1 and coordEq(coord, to)) continue;
                signal_strength -= 1;
            } else if (move.conn_type == .repeater) {
                signal_strength = 14;
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

                const euclid = @abs(coord[0] - from[0]) + @abs(coord[2] - from[2]);

                // Push duplicate entry. The heap sorts by this static item.dist.
                queue.add(.{ .coord = coord, .dist = dist, .euclid = @as(u32, @intCast(euclid)) }) catch @panic("oom");
            }
        }

        explored.put(u, void{}) catch @panic("oom");
    }

    // construct block array
    var blocks = try buildRouteBlocks(a, from, to, parents);
    defer blocks.deinit(a);
    var min_coord = @as(WorldCoord, @splat(std.math.maxInt(i32)));
    for (blocks.items) |b| {
        min_coord[0] = @min(min_coord[0], b.loc[0]);
        min_coord[1] = @min(min_coord[1], b.loc[1]);
        min_coord[2] = @min(min_coord[2], b.loc[2]);
    }
    nbt.block_arr_to_schem(a, blocks.items);
}

fn buildRouteBlocks(a: std.mem.Allocator, from: WorldCoord, to: WorldCoord, parents: std.AutoHashMap(WorldCoord, Parent)) !std.ArrayList(ms.Block) {
    const AbsBlock = struct {
        block: ms.BlockCat,
        loc: WorldCoord,
        rot: ms.Orientation,
    };

    var abs_blocks: std.ArrayList(AbsBlock) = .empty;
    defer abs_blocks.deinit(a);

    var vec = to;
    var prev_vec = to;

    while (!coordEq(vec, from)) {
        const p = parents.get(vec) orelse return error.MissingParent;
        vec = p.prev;

        const move_dir = prev_vec - vec;

        switch (p.conn_type) {
            .dust => {
                try abs_blocks.append(a, .{ .block = .dust, .loc = vec, .rot = .center });
                try abs_blocks.append(a, .{ .block = .block, .loc = vec + WorldCoord{ 0, -1, 0 }, .rot = .center });
            },
            .repeater => {
                const rot: ms.Orientation = if (vec[0] > prev_vec[0]) .west else if (vec[0] < prev_vec[0]) .east else if (vec[2] > prev_vec[2]) .north else .south;

                try abs_blocks.append(a, .{ .block = .repeater, .loc = vec, .rot = rot });

                const mid = (prev_vec + vec) / @as(WorldCoord, @splat(2));
                try abs_blocks.append(a, .{ .block = .dust, .loc = mid, .rot = .center });
                try abs_blocks.append(a, .{ .block = .block, .loc = mid + WorldCoord{ 0, -1, 0 }, .rot = .center });
                try abs_blocks.append(a, .{ .block = .block, .loc = vec + WorldCoord{ 0, -1, 0 }, .rot = .center });
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
            },
        }

        // Substrate block
        // try abs_blocks.append(a, .{ .block = .block, .loc = vec + WorldCoord{ 0, -1, 0 }, .rot = .center });

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

    var blocks: std.ArrayList(ms.Block) = .empty;
    errdefer blocks.deinit(a);
    try blocks.ensureTotalCapacity(a, abs_blocks.items.len);

    for (abs_blocks.items) |b| {
        blocks.appendAssumeCapacity(.{
            .block = b.block,
            .loc = @intCast(b.loc - min_coord),
            .rot = b.rot,
        });
    }

    return blocks;
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
