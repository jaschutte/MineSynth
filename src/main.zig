const std = @import("std");
const pretty = @import("pretty");
const aiger = @import("aiger.zig");
const nl = @import("netlist.zig");
// const partitioning = @import("partitioning.zig");
const glib = @import("abstract/graph.zig");
const glibopt = @import("abstract/preprocessor.zig");
const graphviz = @import("abstract/graphviz.zig");
const route = @import("routing.zig");

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

    var graph = try glib.GraphConstructors.from_netlist(gpa, &netlist);

    try glibopt.PreProcessor(glib.GateBody).preprocess(graph);
    try graphviz.GraphVisualizer(glib.GateBody).print(gpa, graph);

    graph.deinit();
}
