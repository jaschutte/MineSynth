const std = @import("std");
pub const c = @cImport({
    @cInclude("nbt.h");
});
pub const ms = @import("abstract/structures.zig");

pub fn blockcat_to_id(cat: ms.BlockCat) i8 {
    return switch (cat) {
        .dust => 55,
        .repeater => 94,
        .torch => 76,
        .block => 42,
        .block2 => 41,
    };
}

pub fn torch_orientation_to_data(ori: ms.Orientation) i8 {
    return switch (ori) {
        .north => 4,
        .east => 1,
        .south => 3,
        .west => 2,
        .center => 5,
    };
}

pub fn repeater_orientation_to_data(ori: ms.Orientation) i8 {
    const delay = 1;
    var orientation_value: i8 = 0;
    switch (ori) {
        .north => orientation_value = 0,
        .east => orientation_value = 1,
        .south => orientation_value = 2,
        .west => orientation_value = 3,
        .center => @panic("Center orientation specified for repeater, invalid"),
    }
    return (delay - 1) * 4 + orientation_value;
}

// const and_gate = [_]ms.SchemBlock{
//     .{
//         .block = .dust,
//         .loc = .{ 0, 0, 0 },
//         .rot = .center,
//     },
//     .{
//         .block = .dust,
//         .loc = .{ 2, 0, 0 },
//         .rot = .center,
//     },
//     .{
//         .block = .repeater,
//         .loc = .{ 0, 0, 1 },
//         .rot = .south,
//     },
//     .{
//         .block = .repeater,
//         .loc = .{ 2, 0, 1 },
//         .rot = .south,
//     },
//     .{
//         .block = .block,
//         .loc = .{ 0, 0, 2 },
//         .rot = .center,
//     },
//     .{
//         .block = .block,
//         .loc = .{ 1, 0, 2 },
//         .rot = .center,
//     },
//     .{
//         .block = .block,
//         .loc = .{ 2, 0, 2 },
//         .rot = .center,
//     },
//     .{
//         .block = .torch,
//         .loc = .{ 1, 0, 3 },
//         .rot = .south,
//     },
//     .{
//         .block = .dust,
//         .loc = .{ 1, 0, 4 },
//         .rot = .center,
//     },
//     .{
//         .block = .dust,
//         .loc = .{ 1, 1, 2 },
//         .rot = .center,
//     },
//     .{
//         .block = .torch,
//         .loc = .{ 0, 1, 2 },
//         .rot = .center,
//     },
//     .{
//         .block = .torch,
//         .loc = .{ 2, 1, 2 },
//         .rot = .center,
//     },
// };

pub fn abs_block_arr_to_schem(a: std.mem.Allocator, blocks: []ms.AbsBlock) void {
    var min_coord = @as(ms.WorldCoord, @splat(std.math.maxInt(i32)));
    for (blocks) |b| {
        min_coord[0] = @min(min_coord[0], b.loc[0]);
        min_coord[1] = @min(min_coord[1], b.loc[1]);
        min_coord[2] = @min(min_coord[2], b.loc[2]);
    }
    var schem_blocks = a.alloc(ms.SchemBlock, blocks.len) catch @panic("oom");
    errdefer a.free(schem_blocks);
    defer a.free(schem_blocks);

    for (blocks, 0..) |b, i| {
        schem_blocks[i] = .{
            .block = b.block,
            .loc = @intCast(b.loc - min_coord),
            .rot = b.rot,
        };
    }
    block_arr_to_schem(a, schem_blocks);
}

pub fn block_arr_to_schem(a: std.mem.Allocator, blocks: []ms.SchemBlock) void {
    const out = c.nbt_new_tag_compound();
    c.nbt_set_tag_name(out, "Schematic", c.strlen("Schematic"));

    // get length and width
    var length: ms.SchemCoordNum = 1;
    var width: ms.SchemCoordNum = 1;
    var height: ms.SchemCoordNum = 1;
    for (blocks) |block| {
        if (block.loc[0] + 1 > width) width = block.loc[0] + 1;
        if (block.loc[1] + 1 > height) height = block.loc[1] + 1;
        if (block.loc[2] + 1 > length) length = block.loc[2] + 1;
    }
    const tag_length = c.nbt_new_tag_short(length);
    c.nbt_set_tag_name(tag_length, "Length", c.strlen("Length"));
    const tag_height = c.nbt_new_tag_short(height);
    c.nbt_set_tag_name(tag_height, "Height", c.strlen("Height"));
    const tag_width = c.nbt_new_tag_short(width);
    c.nbt_set_tag_name(tag_width, "Width", c.strlen("Width"));
    c.nbt_tag_compound_append(out, tag_length);
    c.nbt_tag_compound_append(out, tag_width);
    c.nbt_tag_compound_append(out, tag_height);

    // necessary but useless things
    const tag_materials = c.nbt_new_tag_string("Alpha", c.strlen("Alpha"));
    c.nbt_set_tag_name(tag_materials, "Materials", c.strlen("Materials"));
    c.nbt_tag_compound_append(out, tag_materials);

    const tag_entities = c.nbt_new_tag_list(c.NBT_TYPE_COMPOUND);
    c.nbt_set_tag_name(tag_entities, "Entities", c.strlen("Entities"));
    c.nbt_tag_compound_append(out, tag_entities);
    const tag_tile_entities = c.nbt_new_tag_list(c.NBT_TYPE_COMPOUND);
    c.nbt_set_tag_name(tag_tile_entities, "TileEntities", c.strlen("TileEntities"));
    c.nbt_tag_compound_append(out, tag_tile_entities);

    // optional: WorldEdit offset and origin. not needed for now
    //
    //
    // const tag_WEOffsetX = c.nbt_new_tag_int(offset[0]);
    // const tag_WEOffsetY = c.nbt_new_tag_int(offset[1] - 10);
    // const tag_WEOffsetZ = c.nbt_new_tag_int(offset[2]);
    // c.nbt_set_tag_name(tag_WEOffsetX, "WEOriginX", c.strlen("WEOffsetX"));
    // c.nbt_set_tag_name(tag_WEOffsetY, "WEOriginY", c.strlen("WEOffsetY"));
    // c.nbt_set_tag_name(tag_WEOffsetZ, "WEOriginZ", c.strlen("WEOffsetZ"));
    // c.nbt_tag_compound_append(out, tag_WEOffsetX);
    // c.nbt_tag_compound_append(out, tag_WEOffsetY);
    // c.nbt_tag_compound_append(out, tag_WEOffsetZ);

    // blocks and block data

    const volume: u64 = length * height * width;
    std.log.debug("nbt conversion dims: {d}x{d}x{d}, volume: {d}", .{ length, width, height, volume });
    var blocks_byte_arr = a.alloc(i8, volume) catch @panic("oom");
    @memset(blocks_byte_arr, 0);
    defer a.free(blocks_byte_arr);
    var data_byte_arr = a.alloc(i8, volume) catch @panic("oom");
    @memset(data_byte_arr, 0);
    defer a.free(data_byte_arr);
    for (blocks) |block| {
        const idx = (block.loc[1] * length + block.loc[2]) * width + block.loc[0];
        blocks_byte_arr[idx] = blockcat_to_id(block.block);
        data_byte_arr[idx] = switch (block.block) {
            .dust => 0,
            .repeater => repeater_orientation_to_data(block.rot),
            .torch => torch_orientation_to_data(block.rot),
            .block => 0,
            .block2 => 0,
        };

        // _ = block;
        // blocks.items
    }

    const tag_blocks = c.nbt_new_tag_byte_array(blocks_byte_arr.ptr, volume);
    c.nbt_set_tag_name(tag_blocks, "Blocks", c.strlen("Blocks"));
    const tag_data = c.nbt_new_tag_byte_array(data_byte_arr.ptr, volume);
    c.nbt_set_tag_name(tag_data, "Data", c.strlen("Data"));

    c.nbt_tag_compound_append(out, tag_blocks);
    c.nbt_tag_compound_append(out, tag_data);
    // print_nbt_tree(out, 0);
    write_nbt_file("out.schematic", out, c.NBT_WRITE_FLAG_USE_GZIP);

    c.nbt_free_tag(out);
    // write_nbt_file("out.schematic", out, c.NBT_WRITE_FLAG_USE_RAW);
}

fn writer_write(userdata: ?*anyopaque, data: [*c]const u8, size: usize) callconv(.c) usize {
    return c.fwrite(data, 1, size, @ptrCast(@alignCast(userdata)));
}

pub fn write_nbt_file(filename: [*:0]const u8, tag: *c.nbt_tag_t, flags: c_int) void {
    const file = c.fopen(filename, "wb");
    if (file == null) {
        std.debug.print("Failed to open file: {s}\n", .{filename});
        return;
    }
    const writer: c.nbt_writer_t = .{
        .write = writer_write,
        .userdata = file,
    };
    c.nbt_write(writer, tag, flags);
}

pub fn print_nbt_tree(tag: *c.nbt_tag_t, indentation: usize) void {
    for (0..indentation) |_| {
        std.debug.print(" ", .{});
    }

    if (tag.name != null) {
        std.debug.print("{s}: ", .{tag.name});
    }

    switch (tag.type) {
        c.NBT_TYPE_END => {
            std.debug.print("[end]", .{});
        },
        c.NBT_TYPE_BYTE => {
            std.debug.print("{d}", .{tag.unnamed_0.tag_byte.value});
        },
        c.NBT_TYPE_SHORT => {
            std.debug.print("{d}", .{tag.unnamed_0.tag_short.value});
        },
        c.NBT_TYPE_INT => {
            std.debug.print("{d}", .{tag.unnamed_0.tag_int.value});
        },
        c.NBT_TYPE_LONG => {
            std.debug.print("{d}", .{tag.unnamed_0.tag_long.value});
        },
        c.NBT_TYPE_FLOAT => {
            std.debug.print("{d}", .{tag.unnamed_0.tag_float.value});
        },
        c.NBT_TYPE_DOUBLE => {
            std.debug.print("{d}", .{tag.unnamed_0.tag_double.value});
        },
        c.NBT_TYPE_BYTE_ARRAY => {
            std.debug.print("[byte array] ", .{});
            for (0..tag.unnamed_0.tag_byte_array.size) |i| {
                std.debug.print("{d} ", .{tag.unnamed_0.tag_byte_array.value[i]});
            }
        },
        c.NBT_TYPE_STRING => {
            std.debug.print("{s}", .{tag.unnamed_0.tag_string.value});
        },
        c.NBT_TYPE_LIST => {
            std.debug.print("\n", .{});
            for (0..tag.unnamed_0.tag_list.size) |i| {
                print_nbt_tree(tag.unnamed_0.tag_list.value[i], indentation + tag.name_size + 2);
            }
        },
        c.NBT_TYPE_COMPOUND => {
            std.debug.print("\n", .{});
            for (0..tag.unnamed_0.tag_compound.size) |i| {
                print_nbt_tree(tag.unnamed_0.tag_compound.value[i], indentation + tag.name_size + 2);
            }
        },
        c.NBT_TYPE_INT_ARRAY => {
            std.debug.print("[int array] ", .{});
            for (0..tag.unnamed_0.tag_int_array.size) |i| {
                std.debug.print("{d} ", .{tag.unnamed_0.tag_int_array.value[i]});
            }
        },
        c.NBT_TYPE_LONG_ARRAY => {
            std.debug.print("[long array] ", .{});
            for (0..tag.unnamed_0.tag_long_array.size) |i| {
                std.debug.print("{d} ", .{tag.unnamed_0.tag_long_array.value[i]});
            }
        },
        else => {
            std.debug.print("[error]", .{});
        },
    }

    std.debug.print("\n", .{});
}

pub fn nbt_test() void {
    const tag_level = c.nbt_new_tag_compound();

    c.nbt_set_tag_name(tag_level, "Level", c.strlen("Level"));

    const tag_longtest = c.nbt_new_tag_long(9223372036854775807);
    c.nbt_set_tag_name(tag_longtest, "longTest", c.strlen("longTest"));

    const tag_shorttest = c.nbt_new_tag_short(32767);
    c.nbt_set_tag_name(tag_shorttest, "shortTest", c.strlen("shortTest"));

    const tag_stringtest = c.nbt_new_tag_string("HELLO WORLD THIS IS A TEST STRING ÅÄÖ!", c.strlen("HELLO WORLD THIS IS A TEST STRING ÅÄÖ!"));
    c.nbt_set_tag_name(tag_stringtest, "stringTest", c.strlen("stringTest"));

    c.nbt_tag_compound_append(tag_level, tag_longtest);
    c.nbt_tag_compound_append(tag_level, tag_shorttest);
    c.nbt_tag_compound_append(tag_level, tag_stringtest);

    print_nbt_tree(tag_level, 2);
}
