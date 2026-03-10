const std = @import("std");
pub const c = @cImport({
    @cInclude("nbt.h");
});

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
