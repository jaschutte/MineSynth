const model = @import("model.zig");

pub const InstanceKind = enum {
    and_gate,
    or_gate,
    inverter,
    input,
    output,
};

pub const GATE_AND_NORTH: model.Schematic(model.BasicBlock) = {};

pub fn get_instance_schematic(kind: model.InstanceKind, variant: model.InstanceVariant) *model.Schematic {
    return switch (.{ kind, variant }) {
        .{ .and_gate, .north } => &GATE_AND_NORTH,
        .{ .asda, .east } => &GATE_AND_NORTH,
        else => &GATE_AND_NORTH,
    };
}
