const std = @import("std");
const aiger = @import("aiger");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const content = try std.fs.cwd().readFileAlloc(allocator, "aiger-examples/half-adder.aag", std.math.maxInt(usize));
    defer _ = allocator.free(content);

    const aig = try aiger.Aiger.parse_aag(allocator, content);
    defer _ = aig.deinit();
    std.debug.print("{any}\n", .{aig});
}
