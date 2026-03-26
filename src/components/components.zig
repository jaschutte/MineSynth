const std = @import("std");
const ms = @import("../abstract/structures.zig");
const WorldCoord = ms.WorldCoord;

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
    min_signal: u4,
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
    // .{
    //     .name = "via_up",
    //     .base_dir = .{ 2, 3, 0 },
    //     .weight = 45,
    //     .delay = 2,
    //     .length = 5,
    //     .min_signal = 2,
    //     .signal_behavior = .via,
    //     .build_blocks = &[_]BuildBlock{
    //         .{ .offset = .{ 0, 0, 0 }, .cat = .dust },
    //         .{ .offset = .{ 0, 0, 1 }, .cat = .air },
    //         .{ .offset = .{ 0, 0, -1 }, .cat = .air },
    //         .{ .offset = .{ 0, -1, 0 }, .cat = .block },
    //         .{ .offset = .{ 1, 0, 0 }, .cat = .dust },
    //         .{ .offset = .{ 1, -1, 0 }, .cat = .block },
    //         .{ .offset = .{ 2, 0, 0 }, .cat = .block },
    //         .{ .offset = .{ 3, 1, 0 }, .cat = .block },
    //         .{ .offset = .{ 2, 1, 0 }, .cat = .torch, .rot = .west },
    //         .{ .offset = .{ 3, 0, 0 }, .cat = .torch, .rot = .east },
    //     },
    // },
    // .{
    //     .name = "via_down",
    //     .base_dir = .{ 2, -3, 0 },
    //     .weight = 45,
    //     .delay = 2,
    //     .length = 5,
    //     .min_signal = 2,
    //     .signal_behavior = .via,
    //     .build_blocks = &[_]BuildBlock{
    //         .{ .offset = .{ 0, 0, 0 }, .cat = .dust },
    //         .{ .offset = .{ 0, 0, 1 }, .cat = .air },
    //         .{ .offset = .{ 0, 0, -1 }, .cat = .air },
    //         .{ .offset = .{ 0, -1, 0 }, .cat = .block },
    //         .{ .offset = .{ 2, -2, 0 }, .cat = .block },
    //         .{ .offset = .{ 2, -1, 0 }, .cat = .dust },
    //         .{ .offset = .{ 2, 0, 0 }, .cat = .torch, .rot = .east },
    //         .{ .offset = .{ 1, 0, 0 }, .cat = .block },
    //         .{ .offset = .{ 1, -2, 0 }, .cat = .torch, .rot = .west },
    //         .{ .offset = .{ 1, -3, 0 }, .cat = .dust, .rot = .west },
    //         .{ .offset = .{ 1, -4, 0 }, .cat = .block },
    //     },
    // },
};
