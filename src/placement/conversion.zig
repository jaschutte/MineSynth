const std = @import("std");
const model = @import("../model.zig");
const plc = @import("placement.zig");

const layerHeight: usize = 0;

pub fn convertPlacement(gpa: std.mem.Allocator, plc_orig: *const plc.Placement) !model.Placement {
    var instances = std.ArrayList(model.InstancePlacement).empty;
    try instances.appendNTimes(gpa, undefined, plc_orig.locations.keys().len);

    for (plc_orig.locations.keys()) |id| {
        const loc = plc_orig.locations.get(id).?;
        const variant = plc_orig.variants.get(id).?;
        const yoffset = if (variant.model.inputs.len == 0 or variant.model.outputs.len == 0) model.padding[1] + layerHeight else model.padding[1];
        const pos = .{ loc.x + model.padding[0], yoffset, loc.y + model.padding[2] };
        instances.items[id] = .{
            .pos = pos,
            .variant = variant,
        };
    }

    return .{ .placement = try instances.toOwnedSlice(gpa) };
}
