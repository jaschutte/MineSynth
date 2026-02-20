const std = @import("std");
const pretty = @import("pretty");
const aiger = @import("aiger.zig");
const netlist = @import("netlist.zig");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const content = try std.fs.cwd().readFileAlloc(allocator, "aiger-examples/half-adder.aag", std.math.maxInt(usize));
    defer _ = allocator.free(content);

    const aig = try aiger.Aiger.parse_aag(allocator, content);
    defer _ = aig.deinit();

    var nl = try netlist.Netlist.from_aiger(allocator, aig);
    defer _ = nl.deinit();

    try pretty.print(allocator, nl, .{});
    try pretty.print(allocator, aig, .{});

}
