const std = @import("std");
const model = @import("../model.zig");
const library = @import("../library.zig");
const WorldCoord = model.Pos;

pub const SignalBehavior = enum { decay, reset, via };

pub const BuildBlock = struct {
    offset: WorldCoord,
    cat: library.BlockType,
    rot: library.Orientation = .center,
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
            .{ .offset = .{ 1, 0, 0 }, .cat = .repeater, .rot = .east },
            .{ .offset = .{ 1, -1, 0 }, .cat = .block },
            .{ .offset = .{ 2, 0, 0 }, .cat = .dust },
            .{ .offset = .{ 2, -1, 0 }, .cat = .block },
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
    },
};
