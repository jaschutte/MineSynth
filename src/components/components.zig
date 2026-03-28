const std = @import("std");
const ms = @import("../abstract/structures.zig");
const WorldCoord = ms.WorldCoord;

pub fn rotateCoord(coord: WorldCoord, dir: WorldCoord) WorldCoord {
    if (dir[0] > 0) return coord;
    if (dir[0] < 0) return .{ -coord[0], coord[1], -coord[2] };
    if (dir[2] > 0) return .{ -coord[2], coord[1], coord[0] };
    if (dir[2] < 0) return .{ coord[2], coord[1], -coord[0] };
    return coord; // Fallback for zero or strictly vertical vectors
}

pub fn rotateOrientation(rot: ms.Orientation, dir: WorldCoord) ms.Orientation {
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

pub const SignalBehavior = enum { decay, reset, via };

pub const BuildBlock = struct {
    offset: WorldCoord,
    cat: ms.BlockCat,
    rot: ms.Orientation = .center,
};

pub const ComponentType = enum {
    dust,
    repeater,
    staircase_up,
    staircase_down,
};

pub const ComponentDef = struct {
    cat: ComponentType,
    base_dir: WorldCoord,
    delay: u32,
    length: u32,
    min_signal: u5,
    signal_behavior: SignalBehavior,
    build_blocks: []const BuildBlock,
    padding: []const WorldCoord,
};
pub const components = [_]ComponentDef{
    .{
        .cat = .dust,
        .base_dir = .{ 1, 0, 0 },
        .delay = 0,
        .length = 1,
        .min_signal = 1,
        .signal_behavior = .decay,
        .build_blocks = &[_]BuildBlock{
            .{ .offset = .{ 0, 0, 0 }, .cat = .dust },
            .{ .offset = .{ 0, -1, 0 }, .cat = .block },
        },
        .padding = &[_]WorldCoord{
            // four cardinal directions
            .{ 1, 0, 0 },
            .{ -1, 0, 0 },
            .{ 0, 0, 1 },
            .{ 0, 0, -1 },
            // also cant have dust diagonally but corners are ok
            .{ 1, 1, 0 },
            .{ 1, -1, 0 },
            .{ -1, 1, 0 },
            .{ -1, -1, 0 },
            .{ 0, 1, -1 },
            .{ 0, 1, 1 },
            .{ 0, -1, -1 },
            .{ 0, -1, 1 },
        },
    },
    .{
        .cat = .repeater,
        .base_dir = .{ 3, 0, 0 },
        .delay = 1,
        .length = 3,
        .min_signal = 1,
        .signal_behavior = .via,
        .build_blocks = &[_]BuildBlock{
            .{ .offset = .{ 0, 0, 0 }, .cat = .dust },
            .{ .offset = .{ 0, -1, 0 }, .cat = .block },
            .{ .offset = .{ 1, 0, 0 }, .cat = .repeater, .rot = .west },
            .{ .offset = .{ 1, -1, 0 }, .cat = .block },
            .{ .offset = .{ 2, 0, 0 }, .cat = .dust },
            .{ .offset = .{ 2, -1, 0 }, .cat = .block },
        },
        .padding = &[_]WorldCoord{
            // four cardinal directions
            .{ 1, 0, 0 },
            .{ -1, 0, 0 },
            .{ 0, 0, 1 },
            .{ 0, 0, -1 },
            // also cant have dust diagonally but corners are ok
            .{ 1, 1, 0 },
            .{ 1, -1, 0 },
            .{ -1, 1, 0 },
            .{ -1, -1, 0 },
            .{ 0, 1, -1 },
            .{ 0, 1, 1 },
            .{ 0, -1, -1 },
            .{ 0, -1, 1 },
            // and for the other dust
            .{ 3, 0, 0 },
            .{ 1, 0, 0 },
            .{ 2, 0, 1 },
            .{ 2, 0, -1 },
            // diagonally
            .{ 3, 1, 0 },
            .{ 3, -1, 0 },
            .{ 1, 1, 0 },
            .{ 1, -1, 0 },
            .{ 2, 1, 1 },
            .{ 2, 1, -1 },
            .{ 2, -1, 1 },
            .{ 2, -1, -1 },
        },
    },
    .{
        .cat = .staircase_up,
        .base_dir = .{ 1, 1, 0 },
        .delay = 0,
        .length = 2,
        .min_signal = 1,
        .signal_behavior = .decay,
        .build_blocks = &[_]BuildBlock{
            .{ .offset = .{ 0, 1, 0 }, .cat = .dust },
            .{ .offset = .{ 0, 0, 0 }, .cat = .block },
            .{ .offset = .{ -1, 1, 0 }, .cat = .air },
        },
        .padding = &[_]WorldCoord{
            // four cardinal directions from dust
            .{ 1, 1, 0 },
            .{ -1, 1, 0 },
            .{ 0, 1, 1 },
            .{ 0, 1, -1 },
            // also cant have dust diagonally but corners are ok
            .{ 1, 2, 0 },
            .{ 1, 0, 0 },
            .{ -1, 2, 0 },
            .{ -1, 0, 0 },
            .{ 0, 2, 1 },
            .{ 0, 2, -1 },
            .{ 0, 0, 1 },
            .{ 0, 0, -1 },
        },
    },
    .{
        .cat = .staircase_down,
        .base_dir = .{ 1, -1, 0 },
        .delay = 0,
        .length = 2,
        .min_signal = 1,
        .signal_behavior = .decay,
        .build_blocks = &[_]BuildBlock{
            .{ .offset = .{ 0, 0, 0 }, .cat = .air },
            .{ .offset = .{ 0, -1, 0 }, .cat = .dust },
            .{ .offset = .{ 0, -2, 0 }, .cat = .block },
        },
        .padding = &[_]WorldCoord{
            // four cardinal directions
            .{ 1, -1, 0 },
            .{ -1, -1, 0 },
            .{ 0, -1, 1 },
            .{ 0, -1, -1 },
            // also cant have dust diagonally but corners are ok
            .{ 1, -2, 0 },
            .{ 1, 0, 0 },
            .{ -1, -2, 0 },
            .{ -1, 0, 0 },
            .{ 0, -2, 1 },
            .{ 0, -2, -1 },
            .{ 0, 0, 1 },
            .{ 0, 0, -1 },
        },
    },
};
