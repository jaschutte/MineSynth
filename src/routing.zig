const std = @import("std");
const pretty = @import("pretty");
const aiger = @import("aiger.zig");
const nl = @import("netlist.zig");
// const partitioning = @import("partitioning.zig");
const glib = @import("abstract/graph.zig");
const graphviz = @import("abstract/graphviz.zig");
const phys = @import("physical.zig");
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

const Route = OrderedSet(nbt.Block);

// any formless volume
const Volume = OrderedSet(WorldCoord);

fn BFSNode(T: type) type {
    return struct {
        const Node = std.DoublyLinkedList.Node;
        data: T,
        node: Node,
    };
}

fn coordEq(a: WorldCoord, b: WorldCoord) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2];
}

explored: std.AutoHashMap(WorldCoord, void),
queue: OrderedSet(WorldCoord),
forbidden_zones: Volume,
parents: std.AutoHashMap(WorldCoord, WorldCoord),
pub fn process(self: *@This(), prev: WorldCoord, coord: WorldCoord) void {
    if (!self.forbidden_zones.contains(coord) and !self.explored.contains(coord)) {
        self.explored.put(coord, void{}) catch @panic("oom");
        self.queue.add(coord) catch @panic("oom");
        self.parents.put(coord, prev) catch @panic("oom");
    }
}
pub fn routeTo(a: std.mem.Allocator, from: WorldCoord, to: WorldCoord, forbidden_zones: Volume) !Route {
    const route = Route.init(a);

    var self = @This(){
        .explored = std.AutoHashMap(WorldCoord, void).init(a),
        .queue = OrderedSet(WorldCoord).init(a),
        .forbidden_zones = forbidden_zones,
        .parents = std.AutoHashMap(WorldCoord, WorldCoord).init(a),
    };
    defer self.explored.deinit();
    defer self.queue.deinit();
    defer self.parents.deinit();
    // shitty draft algorithm outline
    // run dijkstra's using a graph representing 3d space with edges to forbidden zones removed
    // add edges up/down which inserts a via structure IF it fits
    // add/remove edges dynamically based on repeaters fitting
    // probably do some backtracking if repeaters dont fit idk
    // im sleepy

    // self.explored = std.AutoHashMap(Coord, void).init(a);
    // self.queue = OrderedSet(Coord).init(a);

    // vertices.add(root);
    // queue.append(&vertices.set.getPtr(root).?.node);
    try self.queue.add(from);

    while (true) {
        const v = self.queue.popFirst();
        if (coordEq(v, to)) {
            break;
        }
        // for all edges
        const x_vec = WorldCoord{ 1, 0, 0 };
        const y_vec = WorldCoord{ 0, 1, 0 };
        const z_vec = WorldCoord{ 0, 0, 1 };

        var vec = v + x_vec;
        self.process(v, vec);
        vec = v + y_vec;
        self.process(v, vec);
        vec = v + z_vec;
        self.process(v, vec);
        vec = v - x_vec;
        self.process(v, vec);
        vec = v - y_vec;
        self.process(v, vec);
        vec = v - z_vec;
        self.process(v, vec);
    }

    var vec = to;
    while (!coordEq(vec, from)) {
        std.log.info("{any}\n", .{vec});
        vec = self.parents.get(vec).?;
    }

    return route;
}
