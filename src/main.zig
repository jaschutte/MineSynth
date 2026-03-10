const std = @import("std");
const pretty = @import("pretty");
const aiger = @import("aiger.zig");
const nl = @import("netlist.zig");
// const partitioning = @import("partitioning.zig");
const glib = @import("abstract/graph.zig");
const graphviz = @import("abstract/graphviz.zig");

const nbt = @import("nbt.zig");

pub fn main() !void {
    var real_gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = real_gpa.deinit();

    const gpa = real_gpa.allocator();

    // const content = try std.fs.cwd().readFileAlloc(gpa, "aiger-examples/half-adder.aag", std.math.maxInt(usize));
    const content = try std.fs.cwd().readFileAlloc(gpa, "aiger-examples/serial-adder.aag", std.math.maxInt(usize));
    defer _ = gpa.free(content);

    const aig = try aiger.Aiger.parse_aag(gpa, content);
    defer _ = aig.deinit();

    var netlist = try nl.Netlist.from_aiger(gpa, aig);
    defer _ = netlist.deinit();

    // try netlist.print_nets();
    // try netlist.print_gates();

    var graph = try glib.GraphConstructors.from_netlist(gpa, &netlist);
    try graphviz.GraphVisualizer(nl.GatePtr).print(gpa, graph);
    graph.deinit();

    nbt.nbt_test();

    nbt.block_arr_to_schem(gpa);

    // // nl.print_nets();
    // // netlist.print_gates();
    //
    // var module = try partitioning.Module.from_netlist(allocator, &netlist);
    // defer _ = module.deinit();
    //
    // var partition = try module.initial_partition();
    // defer _ = partition.deinit(allocator);
    // // partition.pretty_print();
    //
    // try graphviz.node_visualizer(allocator, &module, &partition);
    // try partition.fm_algorithm(allocator);
    // // partition.pretty_print();
    // try graphviz.node_visualizer(allocator, &module, &partition);
    //
    // // try pretty.print(allocator, nl, .{});
    // // try pretty.print(allocator, aig, .{});
    //
}
