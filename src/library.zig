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
    pub inline fn modelSchematic(self: InstanceKind) *const model.Schematic {
        return switch (self) {
            .and_gate => &AndGateSchem,
            else => @panic("cry"),
        };
    }

    pub inline fn mcSchematic(self: InstanceKind) *const MinecraftSchematic {
        return switch (self) {
            .and_gate => &AndGate,
            else => @panic("cry"),
        };
    }
};

pub const MinecraftBlock = struct {
    pos: model.Pos,
};

pub const MinecraftSchematic = struct {
    delay: usize,
    inputs: []model.PortPos,
    outputs: []model.PortPos,
    blocks: []MinecraftBlock,

    pub fn getSchematic(self: *const MinecraftSchematic) model.Schematic {
        return .{
            .delay = self.delay,
            .inputs = &.{},
            .outputs = &.{},
            .size = .{ 0, 0, 0 },
            .grid = &.{},
        };
    }
};

pub const AndGate: MinecraftSchematic = .{
    .delay = 1,
    .inputs = &.{},
    .outputs = &.{},
    .blocks = &.{},
};
pub const AndGateSchem: model.Schematic = AndGate.getSchematic();
