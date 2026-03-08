const std = @import("std");
const pretty = @import("pretty");
const aiger = @import("aiger.zig");
const nl = @import("netlist.zig");
// const partitioning = @import("partitioning.zig");
const glib = @import("abstract/graph.zig");
const graphviz = @import("abstract/graphviz.zig");
const phys = @import("physical.zig");

const Coord = phys.Coordinate;

const BlockCat = enum {
    dust,
    repeater,
    torch,
    block,
};

const Orientation = enum {
    north,
    east,
    south,
    west,
    center,
};

const Block = struct {
    block: BlockCat,
    rot: Orientation,
    loc: Coord,
};

fn Set(T: type) type {
    return struct {
        const This = @This();
        const AllocErr = std.mem.Allocator.Error;
        set: std.AutoHashMap(T, void),

        pub fn init(a: std.mem.Allocator) void {
            return This{ .set = This{
                .set = std.AutoHashMap(T, void).init(a),
            } };
        }

        pub fn add(self: This, item: T) AllocErr!void {
            try self.set.put(item, void);
        }

        pub fn contains(self: This, item: T) bool {
            return self.set.get(item) == null;
        }

        pub fn deinit(self: This) void {
            self.set.deinit();
        }
    };
}

const Route = Set(Block);

// any formless volume
const Volume = Set(Coord);

pub fn routeTo(a: std.mem.Allocator, from: Coord, to: Coord, forbidden_zones: Volume) !Route {
    const route = Route.init(a);
    _ = from;
    _ = to;
    _ = forbidden_zones;

    // shitty draft algorithm outline
    // run dijkstra's using a graph representing 3d space with edges to forbidden zones removed
    // add edges up/down which inserts a via structure IF it fits
    // add/remove edges dynamically based on repeaters fitting
    // probably do some backtracking if repeaters dont fit idk
    // im sleepy

    return route;
}
