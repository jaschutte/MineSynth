const std = @import("std");
const ms = @import("abstract/structures.zig");
const nbt = @import("nbt.zig");

pub const WorldCoord = @Vector(3, i32);

pub fn OrderedSet(T: type) type {
    return struct {
        const This = @This();

        const AllocErr = std.mem.Allocator.Error;

        set: std.AutoArrayHashMap(T, void),

        pub fn init(a: std.mem.Allocator) This {
            return This{
                .set = std.AutoArrayHashMap(T, void).init(a),
            };
        }

        pub fn add(self: *This, item: T) AllocErr!void {
            try self.set.put(item, void{});
        }

        pub fn contains(self: This, item: T) bool {
            return self.set.get(item) != null;
        }

        pub fn remove(self: *This, item: T) void {
            self.set.orderedRemove(item);
        }

        pub fn popFirst(self: *This) T {
            const item = self.set.unmanaged.entries.get(0).key;

            self.set.orderedRemoveAt(0);

            return item;
        }

        pub fn getPtr(self: This, item: T) ?*T {
            return self.set.getKeyPtr(item);
        }

        pub fn deinit(self: *This) void {
            self.set.deinit();
        }
    };
}

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
const Volume = OrderedSet(WorldCoord);

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

const Self = @This();

const DistanceMetric = struct {
    distance: u32,
    signal_strength: u4,
};

explored: std.AutoHashMap(WorldCoord, void),
distances: std.AutoHashMap(WorldCoord, DistanceMetric),
queue: std.PriorityQueue(QueueItem, void, queueOrder),
forbidden_zones: Volume,
parents: std.AutoHashMap(WorldCoord, Parent),

pub fn process(self: *Self, start: WorldCoord, prev: WorldCoord, coord: WorldCoord, weight: u32, conn_type: RouteComponent) void {
    if (self.forbidden_zones.contains(coord)) return;

    if (conn_type == .repeater) {
        const mid = (prev + coord) / @as(WorldCoord, @splat(2));
        if (self.forbidden_zones.contains(mid)) return;
    }
    var signal_strength = self.distances.get(prev).?.signal_strength;
    if (conn_type == .dust) {
        if (signal_strength == 0) return;
        signal_strength -= 1;
    } else if (conn_type == .repeater) {
        signal_strength = 14;
    }

    const dist = self.distances.get(prev).?.distance + weight;
    const distv = self.distances.get(coord);

    // If we found a strictly better path to `coord`
    if (distv == null or dist < distv.?.distance) {
        self.distances.put(coord, .{ .signal_strength = signal_strength, .distance = dist }) catch @panic("oom");
        self.parents.put(coord, .{ .conn_type = conn_type, .prev = prev }) catch @panic("oom");

        const euclid = @abs(coord[0] - start[0]) + @abs(coord[2] - start[2]);

        // Push duplicate entry. The heap sorts by this static item.dist.
        self.queue.add(.{ .coord = coord, .dist = dist, .euclid = @as(u32, @intCast(euclid)) }) catch @panic("oom");
    }
}

pub fn routeTo(a: std.mem.Allocator, from: WorldCoord, to: WorldCoord, forbidden_zones: Volume) !void {
    var self = Self{
        .explored = std.AutoHashMap(WorldCoord, void).init(a),
        .distances = std.AutoHashMap(WorldCoord, DistanceMetric).init(a),
        .queue = std.PriorityQueue(QueueItem, void, queueOrder).init(a, {}),
        .forbidden_zones = forbidden_zones,
        .parents = std.AutoHashMap(WorldCoord, Parent).init(a),
    };
    defer self.explored.deinit();
    defer self.distances.deinit();
    defer self.queue.deinit();
    defer self.parents.deinit();

    try self.distances.put(from, .{ .distance = 0, .signal_strength = 15 });
    try self.queue.add(.{ .coord = from, .dist = 0, .euclid = 0 });

    while (self.queue.count() > 0) {
        const item = self.queue.remove();
        const u = item.coord;

        // Lazy Dijkstra: discard popped items that are stale
        const best_dist = self.distances.get(u) orelse continue;
        if (item.dist > best_dist.distance) continue;

        std.log.info("Exploring {any} with dist {d}\n", .{ u, item.dist });

        if (coordEq(u, to)) break;

        var x_vec = WorldCoord{ 1, 0, 0 };
        var z_vec = WorldCoord{ 0, 0, 1 };

        // consider regular redstone
        var vec = u + x_vec;
        self.process(from, u, vec, 0, .dust);
        vec = u + z_vec;
        self.process(from, u, vec, 0, .dust);
        vec = u - x_vec;
        self.process(from, u, vec, 0, .dust);
        vec = u - z_vec;
        self.process(from, u, vec, 0, .dust);

        // consider repeaters
        x_vec = WorldCoord{ 2, 0, 0 };
        z_vec = WorldCoord{ 0, 0, 2 };

        vec = u + x_vec;
        self.process(from, u, vec, 1, .repeater);
        vec = u + z_vec;
        self.process(from, u, vec, 1, .repeater);
        vec = u - x_vec;
        self.process(from, u, vec, 1, .repeater);
        vec = u - z_vec;
        self.process(from, u, vec, 1, .repeater);

        self.explored.put(u, void{}) catch @panic("oom");
    }

    var vec = to;
    while (!coordEq(vec, from)) {
        const p = self.parents.get(vec).?;
        vec = p.prev;
        std.log.info("{any}\n", .{p});
    }
    // construct block array
    var blocks: std.ArrayList(ms.Block) = .empty;
    vec = to;
    var prev_vec = to;
    while (!coordEq(vec, from)) {
        const p = self.parents.get(vec).?;
        vec = p.prev;

        // let start block be 0,0,0

        const zero_point = from + WorldCoord{ 0, -1, 0 }; // substrate
        const loc: ms.SchemCoord = @intCast(vec - zero_point);
        if (p.conn_type == .dust) {
            blocks.append(a, .{
                .block = .dust,
                .loc = loc, // translate to start at 0,0,0
                .rot = .center,
            }) catch @panic("oom");
        }
        if (p.conn_type == .repeater) {
            var rot = ms.Orientation.center;
            if (vec[0] > prev_vec[0]) {
                rot = .west;
            } else if (vec[0] < prev_vec[0]) {
                rot = .east;
            } else if (vec[2] > prev_vec[2]) {
                rot = .north;
            } else if (vec[2] < prev_vec[2]) {
                rot = .south;
            }
            blocks.append(a, .{
                .block = .repeater,
                .loc = loc,
                .rot = rot,
            }) catch @panic("oom");
            // add dust after repeater
            // midpoint
            const mid = (prev_vec + vec) / @as(WorldCoord, @splat(2));
            blocks.append(a, .{
                .block = .dust,
                .loc = @intCast(mid - zero_point),
                .rot = .center,
            }) catch @panic("oom");
            // and block
            blocks.append(a, .{
                .block = .block,
                .loc = @intCast(mid - zero_point + WorldCoord{ 0, -1, 0 }),
                .rot = .center,
            }) catch @panic("oom");
        }
        // also append blocks under
        blocks.append(a, .{
            .block = .block,
            .loc = @intCast(loc + WorldCoord{ 0, -1, 0 }),
            .rot = .center,
        }) catch @panic("oom");
        prev_vec = vec;
    }
    nbt.block_arr_to_schem(a, blocks.items);
    blocks.deinit(a);
}
