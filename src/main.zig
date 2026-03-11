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
const ms = @import("abstract/structures.zig");

pub fn main() !void {
    var real_gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = real_gpa.deinit();

    const gpa = real_gpa.allocator();

    // const content = try std.fs.cwd().readFileAlloc(gpa, "aiger-examples/half-adder.aag", std.math.maxInt(usize));
    const content = try std.fs.cwd().readFileAlloc(gpa, "aiger-examples/serial-adder.aag", std.math.maxInt(usize));
    defer _ = gpa.free(content);

    const aig = try aiger.Aiger.parseAag(gpa, content);
    defer _ = aig.deinit();

    var netlist = try nl.Netlist.fromAiger(gpa, aig);
    defer _ = netlist.deinit();

    var graph = glib.GraphConstructors.fromNetlist(gpa, &netlist);

    graphviz.GraphVisualizer(glib.GateBody).printDFS(gpa, graph);
    glibopt.PreProcessor(glib.GateBody).preprocess(graph);
    graphviz.GraphVisualizer(glib.GateBody).print(gpa, graph);

    const set = ms.OrderedSet(route.WorldCoord).init(gpa);
    try route.routeTo(gpa, .{ 0, 0, 0 }, .{ 25, 0, 15 }, set);

    graph.deinit();
}
