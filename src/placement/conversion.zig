const std = @import("std");
const model = @import("../model.zig");
const plc = @import("../placement.zig");

pub fn convertPlacement(gpa: std.mem.Allocator, plc_orig: *const plc.Placement) !model.Placement {
    var instances = std.ArrayList(model.InstancePlacement).empty;

    for (plc_orig.locations.keys()) |id| {
        const loc = plc_orig.locations.get(id).?;
        const pos = .{ loc.x, 0, loc.y };
        const variant = plc_orig.variants.get(id).?;
        try instances.append(gpa, .{
            .pos = pos,
            .variant = variant,
        });
    }

    return .{ .placement = try instances.toOwnedSlice(gpa) };
}
