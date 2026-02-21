const std = @import("std");
const pretty = @import("pretty");
const aiger = @import("aiger.zig");
const nl = @import("netlist.zig");
const partitioning = @import("partitioning.zig");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const content = try std.fs.cwd().readFileAlloc(allocator, "aiger-examples/half-adder.aag", std.math.maxInt(usize));
    // const content = try std.fs.cwd().readFileAlloc(allocator, "aiger-examples/serial-adder.aag", std.math.maxInt(usize));
    defer _ = allocator.free(content);

    const aig = try aiger.Aiger.parse_aag(allocator, content);
    defer _ = aig.deinit();

    var netlist = try nl.Netlist.from_aiger(allocator, aig);
    defer _ = netlist.deinit();

    // nl.print_nets();
    netlist.print_gates();

    var module = try partitioning.Module.from_netlist(allocator, &netlist);
    defer _ = module.deinit();

    var partition = try module.initial_partition();
    defer _ = partition.deinit(allocator);
    partition.pretty_print();

    try partition.fm_algorithm(allocator);
    partition.pretty_print();


    // try pretty.print(allocator, nl, .{});
    // try pretty.print(allocator, aig, .{});

}
