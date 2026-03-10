pub const Graph = @import("graph.zig");

pub const SchemCoord = @Vector(3, u15);

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

pub const Block = struct {
    block: BlockCat,
    rot: Orientation,
    loc: SchemCoord,
};
