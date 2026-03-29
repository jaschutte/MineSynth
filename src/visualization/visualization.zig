const std = @import("std");
const library = @import("../library.zig");
const model = @import("../model.zig");

pub fn blockListFromSchematic(gpa: std.mem.Allocator, schematic: *const model.Schematic) ![]library.SchemBlock {
    var blocks = std.ArrayList(library.SchemBlock).empty;
    for (0..schematic.size[0]) |x| {
        for (0..schematic.size[1]) |y| {
            for (0..schematic.size[2]) |z| {
                const block = schematic.get(x, y, z);
                const pos = @as(library.SchemPos, .{ @intCast(x), @intCast(y), @intCast(z) });
                switch (block) {
                    .undef => continue,
                    .predef => continue,
                    .block => try blocks.append(gpa, .{ .block = .block3, .loc = pos, .rot = .center }),
                    .air => continue,
                    .wire => try blocks.append(gpa, .{ .block = .dust, .loc = pos, .rot = .center }),
                    .repeater_north => try blocks.append(gpa, .{ .block = .repeater, .loc = pos, .rot = .north }),
                    .repeater_east => try blocks.append(gpa, .{ .block = .repeater, .loc = pos, .rot = .east }),
                    .repeater_south => try blocks.append(gpa, .{ .block = .repeater, .loc = pos, .rot = .south }),
                    .repeater_west => try blocks.append(gpa, .{ .block = .repeater, .loc = pos, .rot = .west }),
                }
            }
        }
    }
    return blocks.toOwnedSlice(gpa);
}

pub fn blockListFromPlacement(gpa: std.mem.Allocator, placement: *const model.Placement) ![]library.SchemBlock {
    var blocks = std.ArrayList(library.SchemBlock).empty;
    for (placement.placement) |instance| {
        const pos = @as(library.WorldPos, @intCast(instance.pos));
        const offset = instance.variant.offset;
        const schem = instance.variant.minecraft;
        for (schem.blocks) |block| {
            try blocks.append(gpa, .{
                .block = block.block,
                .rot = block.rot,
                .loc = .{
                    @intCast(pos[0] + block.loc[0] - offset[0]),
                    @intCast(pos[1] + block.loc[1] - offset[1]),
                    @intCast(pos[2] + block.loc[2] - offset[2]),
                },
            });
        }
    }
    return blocks.toOwnedSlice(gpa);
}
