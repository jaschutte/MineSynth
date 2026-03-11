const std = @import("std");
pub const Graph = @import("graph.zig");

pub const SchemCoord = @Vector(3, u15);
pub const WorldCoord = @Vector(3, i32);

pub const BlockCat = enum {
    dust,
    repeater,
    torch,
    block,
};

pub const Orientation = enum {
    north,
    east,
    south,
    west,
    center,
};

pub const SchemBlock = struct {
    block: BlockCat,
    rot: Orientation,
    loc: SchemCoord,
};

pub const AbsBlock = struct {
    block: BlockCat,
    rot: Orientation,
    loc: WorldCoord,
};

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
