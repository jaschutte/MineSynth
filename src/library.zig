const std = @import("std");
const model = @import("model.zig");

pub const Size = struct { w: usize, h: usize };

pub const InstanceKind = enum {
    inverter,
    and_gate,
    or_gate,
    input,
    output,

    // If we want to implement variants, this function should
    // return a slice of references to possible implementation
    // schematics
    // TODO: For the love of god, make this return a reference to
    // the schematic that was built once and then stored in one variable
    // or another
    pub fn modelSchematic(self: InstanceKind) model.Schematic {
        return switch (self) {
            .input => getSchematic(&Input),
            .output => getSchematic(&Output),
            .inverter => getSchematic(&Inverter),
            .and_gate => getSchematic(&AndGate),
            .or_gate => getSchematic(&OrGate),
        };
    }

    pub fn mcSchematic(self: InstanceKind) *const MinecraftSchematic {
        return switch (self) {
            .input => &Input,
            .output => &Output,
            .inverter => &Inverter,
            .and_gate => &AndGate,
            .or_gate => &OrGate,
        };
    }
};

pub const WorldPos = @Vector(3, isize);

pub const BlockType = enum {
    air,
    dust,
    repeater,
    torch,
    block,
    block2,
    block3,
};

pub const Orientation = enum {
    north,
    east,
    south,
    west,
    center,
};

pub const MinecraftBlock = struct {
    loc: WorldPos, // Location of the block
    block: BlockType, // Type of the block
    rot: Orientation, // Orientation of the block
};

pub const WorldPortPos = struct { WorldPos, model.PowerLevel };

pub const MinecraftSchematic = struct {
    delay: usize,
    inputs: []const WorldPortPos,
    outputs: []const WorldPortPos,
    blocks: []const MinecraftBlock,
};

// I am fighting with comptime and comptime won
// getSchematic should be precalculated either at startup or at comptime
// for all schematics.
pub fn getSchematic(self: *MinecraftSchematic) model.Schematic {
    if (self.blocks.len == 0) @panic("cry");
    const first = self.blocks[0];
    var xmin, var xmax, var ymin, var ymax, var zmin, var zmax = .{ first.loc[0], first.loc[0], first.loc[1], first.loc[1], first.loc[2], first.loc[2] };
    for (self.blocks) |*block| {
        xmin = @min(xmin, block.loc[0]);
        ymin = @min(ymin, block.loc[1]);
        zmin = @min(zmin, block.loc[2]);
        xmax = @max(xmax, block.loc[0]);
        ymax = @max(ymax, block.loc[1]);
        zmax = @max(zmax, block.loc[2]);
    }

    const xlen = xmax - xmin + 1;
    const ylen = ymax - ymin + 1;
    const zlen = zmax - zmin + 1;

    var grid = .{.{.{model.BasicBlock.undef} ** zlen} ** ylen} ** xlen;

    for (self.blocks) |*block| {
        grid[@as(usize, @intCast(block.loc[0] - xmin))][block.loc[1] - ymin][block.loc[2] - zmin] = .predef;
    }

    var inputs: [self.inputs.len]model.PortPos = .{};
    for (self.inputs, 0..) |port, i| {
        const pos, const pow = port;
        // TODO: Ensure that there is wire at the locations of the
        // inputs and outputs, shifted with the same vector as the
        // normal blocks.
        const shifted: model.Pos = .{ pos[0] - xmin, pos[1] - ymin, pos[2] - zmin };
        inputs[i] = .{
            .pos = shifted,
            .pow = pow,
        };
    }

    var outputs: [self.outputs.len]model.PortPos = .{};
    for (self.outputs, 0..) |port, i| {
        const pos, const pow = port;
        const shifted: model.Pos = .{ pos[0] - xmin, pos[1] - ymin, pos[2] - zmin };
        outputs[i] = .{
            .pos = shifted,
            .pow = pow,
        };
    }

    return .{
        .delay = self.delay,
        .inputs = &inputs,
        .outputs = &outputs,
        .size = .{ xlen, ylen, zlen },
        .grid = grid,
    };
}

pub var Input: MinecraftSchematic = .{
    .delay = 0,
    .inputs = &.{.{ .{ 0, 1, 0 }, 15 }},
    .outputs = &.{},
    .blocks = &.{
        .{
            .block = .dust,
            .loc = .{ 0, 1, 0 },
            .rot = .center,
        },
        .{
            .block = .block2,
            .loc = .{ 0, 0, 0 },
            .rot = .center,
        },
        .{
            .block = .block2,
            .loc = .{ 0, -1, 0 },
            .rot = .center,
        },
    },
};
// pub const InputSchem: model.Schematic = Input.getSchematic();

pub var Output: MinecraftSchematic = .{
    .delay = 0,
    .inputs = &.{.{ .{ 0, 1, 0 }, 1 }},
    .outputs = &.{},
    .blocks = &.{
        .{
            .block = .dust,
            .loc = .{ 0, 1, 0 },
            .rot = .center,
        },
        .{
            .block = .block2,
            .loc = .{ 0, 0, 0 },
            .rot = .center,
        },
    },
};
// pub const OutputSchem: model.Schematic = Output.getSchematic();

pub var Inverter: MinecraftSchematic = .{
    .delay = 2,
    .inputs = &.{.{ .{ 0, 1, -1 }, 1 }},
    .outputs = &.{.{ .{ 0, 1, 3 }, 15 }},
    .blocks = &.{
        .{
            .block = .repeater,
            .loc = .{ 0, 1, 0 },
            .rot = .south,
        },
        .{
            .block = .block,
            .loc = .{ 0, 0, 0 },
            .rot = .east,
        },
        .{
            .block = .block2,
            .loc = .{ 0, 1, 1 },
            .rot = .center,
        },
        .{
            .block = .torch,
            .loc = .{ 0, 1, 2 },
            .rot = .south,
        },
    },
};
// pub const InverterSchem: model.Schematic = Inverter.getSchematic();

pub var AndGate: MinecraftSchematic = .{
    .delay = 3,
    .inputs = &.{ .{ .{ 0, 1, -1 }, 1 }, .{ .{ 2, 1, -1 }, 1 } },
    .outputs = &.{.{ .{ 1, 1, 3 }, 15 }},
    .blocks = &.{
        .{
            .block = .repeater,
            .loc = .{ 0, 1, 0 },
            .rot = .south,
        },
        .{
            .block = .block,
            .loc = .{ 0, 0, 0 },
            .rot = .east,
        },
        .{
            .block = .repeater,
            .loc = .{ 2, 1, 0 },
            .rot = .south,
        },
        .{
            .block = .block,
            .loc = .{ 2, 0, 0 },
            .rot = .east,
        },
        .{
            .block = .block,
            .loc = .{ 0, 1, 1 },
            .rot = .center,
        },
        .{
            .block = .block,
            .loc = .{ 1, 1, 1 },
            .rot = .center,
        },
        .{
            .block = .block,
            .loc = .{ 2, 1, 1 },
            .rot = .center,
        },
        .{
            .block = .torch,
            .loc = .{ 1, 1, 2 },
            .rot = .south,
        },
        .{
            .block = .dust,
            .loc = .{ 1, 2, 1 },
            .rot = .center,
        },
        .{
            .block = .torch,
            .loc = .{ 0, 2, 1 },
            .rot = .center,
        },
        .{
            .block = .torch,
            .loc = .{ 2, 2, 1 },
            .rot = .center,
        },
    },
};
// pub const AndGateSchem: model.Schematic = AndGate.getSchematic();

pub var OrGate: MinecraftSchematic = .{
    .delay = 1,
    .inputs = &.{ .{ .{ -1, 1, 0 }, 1 }, .{ .{ 3, 1, 0 }, 1 } },
    .outputs = &.{.{ .{ 1, 1, 0 }, 15 }},
    .blocks = &.{
        .{
            .block = .repeater,
            .loc = .{ 0, 1, 0 },
            .rot = .east,
        },
        .{
            .block = .block,
            .loc = .{ 0, 0, 0 },
            .rot = .center,
        },
        .{
            .block = .repeater,
            .loc = .{ 2, 1, 0 },
            .rot = .west,
        },
        .{
            .block = .block,
            .loc = .{ 2, 0, 0 },
            .rot = .center,
        },
    },
};
// pub const OrGateSchem: model.Schematic = OrGate.getSchematic();
