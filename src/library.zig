const std = @import("std");
const model = @import("model.zig");

pub const InstanceVariant = struct {
    model: *const model.Schematic, // The schematic of the instance as in the report
    offset: WorldPos, // The offset applied to the mc to get the model (minimum coordinate)
    minecraft: *const MinecraftSchematic, // The blocks that make up the schematic
};

pub const Library = struct {
    variants: std.AutoHashMap(InstanceKind, std.ArrayList(InstanceVariant)),

    pub fn init(gpa: std.mem.Allocator) !Library {
        var library = Library{
            .variants = .init(gpa),
        };

        const kinds = [_]InstanceKind{ .inverter, .and_gate, .or_gate, .input, .output, .pin };
        const bases = [_]*const MinecraftSchematic{ &Inverter, &AndGate, &OrGate, &Input, &Output, &Pin };
        for (kinds, bases) |kind, base| {
            var v = std.ArrayList(InstanceVariant).empty;

            // TODO: Add rotations to the library
            // TODO: Add flipped versions to the library
            const schem, const offset = try getSchematic(base.*, gpa);
            try v.append(gpa, .{ .minecraft = base, .offset = offset, .model = schem });

            try library.variants.put(kind, v);
        }

        return library;
    }
};

pub const InstanceKind = enum {
    inverter,
    and_gate,
    or_gate,
    input,
    output,
    pin, // Does nothing
};

pub const SchemPosNum = u16;
pub const SchemPos = @Vector(3, SchemPosNum);
pub const WorldPosNum = isize;
pub const WorldPos = @Vector(3, WorldPosNum);

pub const BlockType = enum {
    air,
    dust,
    repeater,
    torch,
    block,
    block2,
    block3,
    input_block,
    output_block,
    sign,
    floor,
};

pub const Orientation = enum {
    north,
    east,
    south,
    west,
    center,
};

fn MCBlockType(comptime B: type) type {
    return struct {
        loc: B, // Location of the block
        block: BlockType, // Type of the block
        rot: Orientation, // Orientation of the block
    };
}

pub const MinecraftBlock = MCBlockType(WorldPos);
pub const SchemBlock = MCBlockType(SchemPos);

pub const WorldPortPos = struct { WorldPos, model.PowerLevel };

pub const MinecraftSchematic = struct {
    delay: usize,
    inputs: []const WorldPortPos,
    outputs: []const WorldPortPos,
    blocks: []const MinecraftBlock,
};

fn getSchematic(self: MinecraftSchematic, gpa: std.mem.Allocator) !struct { *const model.Schematic, WorldPos } {
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
    for (self.inputs) |port| {
        const pos = port.@"0";
        xmin = @min(xmin, pos[0]);
        ymin = @min(ymin, pos[1]);
        zmin = @min(zmin, pos[2]);
        xmax = @max(xmax, pos[0]);
        ymax = @max(ymax, pos[1]);
        zmax = @max(zmax, pos[2]);
    }
    for (self.outputs) |port| {
        const pos = port.@"0";
        xmin = @min(xmin, pos[0]);
        ymin = @min(ymin, pos[1]);
        zmin = @min(zmin, pos[2]);
        xmax = @max(xmax, pos[0]);
        ymax = @max(ymax, pos[1]);
        zmax = @max(zmax, pos[2]);
    }

    const xlen: usize = @intCast(xmax - xmin + 1);
    const ylen: usize = @intCast(ymax - ymin + 1);
    const zlen: usize = @intCast(zmax - zmin + 1);

    var grid = std.ArrayList(model.BasicBlock).empty;
    try grid.appendNTimes(gpa, .undef, xlen * ylen * zlen);

    for (self.blocks) |*block| {
        const xpos: usize = @intCast(block.loc[0] - xmin);
        const ypos: usize = @intCast(block.loc[1] - ymin);
        const zpos: usize = @intCast(block.loc[2] - zmin);
        grid.items[xpos * ylen * zlen + ypos * zlen + zpos] = .predef;
    }

    var inputs = std.ArrayList(model.PortPos).empty;
    for (self.inputs) |port| {
        const pos, const pow = port;
        const xpos: usize = @intCast(pos[0] - xmin);
        const ypos: usize = @intCast(pos[1] - ymin);
        const zpos: usize = @intCast(pos[2] - zmin);

        grid.items[xpos * ylen * zlen + ypos * zlen + zpos] = .wire;
        grid.items[xpos * ylen * zlen + (ypos - 1) * zlen + zpos] = .block;
        try inputs.append(gpa, .{
            .pos = .{ xpos, ypos, zpos },
            .pow = pow,
        });
    }

    var outputs = std.ArrayList(model.PortPos).empty;
    for (self.outputs) |port| {
        const pos, const pow = port;
        const xpos: usize = @intCast(pos[0] - xmin);
        const ypos: usize = @intCast(pos[1] - ymin);
        const zpos: usize = @intCast(pos[2] - zmin);

        grid.items[xpos * ylen * zlen + ypos * zlen + zpos] = .wire;
        grid.items[xpos * ylen * zlen + (ypos - 1) * zlen + zpos] = .block;
        try outputs.append(gpa, .{
            .pos = .{ xpos, ypos, zpos },
            .pow = pow,
        });
    }

    var ret = try gpa.create(model.Schematic);
    ret.delay = self.delay;
    ret.inputs = try inputs.toOwnedSlice(gpa);
    ret.outputs = try outputs.toOwnedSlice(gpa);
    ret.size = .{ xlen, ylen, zlen };
    ret.grid = try grid.toOwnedSlice(gpa);
    return .{ ret, .{ xmin, ymin, zmin } };
}

const Pin: MinecraftSchematic = .{
    .delay = 0,
    .inputs = &.{.{ .{ 0, 1, 0 }, 1 }},
    .outputs = &.{.{ .{ 0, 1, 2 }, 15 }},
    .blocks = &.{
        .{
            .block = .dust,
            .loc = .{ 0, 1, 0 },
            .rot = .center,
        },
        .{
            .block = .repeater,
            .loc = .{ 0, 1, 1 },
            .rot = .south,
        },
        .{
            .block = .dust,
            .loc = .{ 0, 1, 2 },
            .rot = .center,
        },
        .{
            .block = .block,
            .loc = .{ 0, 0, 0 },
            .rot = .center,
        },
        .{
            .block = .block,
            .loc = .{ 0, 0, 1 },
            .rot = .center,
        },
        .{
            .block = .block,
            .loc = .{ 0, 0, 2 },
            .rot = .center,
        },
    },
};

const Input: MinecraftSchematic = .{
    .delay = 0,
    .inputs = &.{},
    .outputs = &.{.{ .{ 0, 1, 0 }, 15 }},
    .blocks = &.{
        .{
            .block = .dust,
            .loc = .{ 0, 1, 0 },
            .rot = .center,
        },
        .{
            .block = .input_block,
            .loc = .{ 0, 0, 0 },
            .rot = .center,
        },
        .{
            .block = .input_block,
            .loc = .{ 0, 3, 0 },
            .rot = .center,
        },
        .{
            .block = .sign,
            .loc = .{ 0, 4, 0 },
            .rot = .center,
        },
    },
};

const Output: MinecraftSchematic = .{
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
            .block = .output_block,
            .loc = .{ 0, 0, 0 },
            .rot = .center,
        },
        .{
            .block = .output_block,
            .loc = .{ 0, 3, 0 },
            .rot = .center,
        },
        .{
            .block = .sign,
            .loc = .{ 0, 4, 0 },
            .rot = .center,
        },
    },
};

const Inverter: MinecraftSchematic = .{
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
            .block = .block,
            .loc = .{ 0, 1, 1 },
            .rot = .center,
        },
        .{
            .block = .torch,
            .loc = .{ 0, 1, 2 },
            .rot = .south,
        },
        .{
            .block = .air,
            .loc = .{ 0, 0, 1 },
            .rot = .center,
        },
        .{
            .block = .air,
            .loc = .{ 1, 1, 1 },
            .rot = .center,
        },
        .{
            .block = .air,
            .loc = .{ -1, 1, 1 },
            .rot = .center,
        },
        .{
            .block = .air,
            .loc = .{ 0, 2, 1 },
            .rot = .center,
        },
        .{
            .block = .air,
            .loc = .{ 0, 0, 2 },
            .rot = .center,
        },
        .{
            .block = .air,
            .loc = .{ 1, 1, 2 },
            .rot = .center,
        },
        .{
            .block = .air,
            .loc = .{ -1, 1, 2 },
            .rot = .center,
        },
        .{
            .block = .air,
            .loc = .{ 0, 2, 2 },
            .rot = .center,
        },
    },
};

const AndGate: MinecraftSchematic = .{
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
        .{
            .block = .air,
            .loc = .{ 0, 3, 1 },
            .rot = .center,
        },
        .{
            .block = .air,
            .loc = .{ 2, 3, 1 },
            .rot = .center,
        },
        .{
            .block = .air,
            .loc = .{ 0, 1, 2 },
            .rot = .center,
        },
        .{
            .block = .air,
            .loc = .{ 1, 0, 2 },
            .rot = .center,
        },
        .{
            .block = .air,
            .loc = .{ 2, 1, 2 },
            .rot = .center,
        },
        .{
            .block = .air,
            .loc = .{ 0, 2, 2 },
            .rot = .center,
        },
        .{
            .block = .air,
            .loc = .{ 2, 2, 2 },
            .rot = .center,
        },
        .{
            .block = .air,
            .loc = .{ 1, 2, 2 },
            .rot = .center,
        },
        .{
            .block = .air,
            .loc = .{ -1, 1, 1 },
            .rot = .center,
        },
        .{
            .block = .air,
            .loc = .{ 3, 1, 1 },
            .rot = .center,
        },
        .{
            .block = .air,
            .loc = .{ -1, 2, 1 },
            .rot = .center,
        },
        .{
            .block = .air,
            .loc = .{ 3, 2, 1 },
            .rot = .center,
        },
        .{
            .block = .air,
            .loc = .{ 0, 2, 0 },
            .rot = .center,
        },
        .{
            .block = .air,
            .loc = .{ 2, 2, 0 },
            .rot = .center,
        },
        .{
            .block = .air,
            .loc = .{ 0, 0, 1 },
            .rot = .center,
        },
        .{
            .block = .air,
            .loc = .{ 2, 0, 1 },
            .rot = .center,
        },
        .{
            .block = .air,
            .loc = .{ 1, 1, 0 },
            .rot = .center,
        },
        .{
            .block = .air,
            .loc = .{ 1, 2, 0 },
            .rot = .center,
        },
    },
};

const OrGate: MinecraftSchematic = .{
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
