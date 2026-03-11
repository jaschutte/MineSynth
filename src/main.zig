const std = @import("std");
const pretty = @import("pretty");
const aiger = @import("aiger.zig");
const nl = @import("netlist.zig");
// const partitioning = @import("partitioning.zig");
const glib = @import("abstract/graph.zig");
const glibopt = @import("abstract/preprocessor.zig");
const graphviz = @import("abstract/graphviz.zig");
const rt = @import("routing.zig");

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
    defer _ = graph.deinit();

    graphviz.GraphVisualizer(glib.GateBody).printDFS(gpa, graph);
    glibopt.PreProcessor(glib.GateBody).preprocess(graph);
    graphviz.GraphVisualizer(glib.GateBody).print(gpa, graph);
    graph.deinit();

    // each layer is a height of 3, so any target y coordinate must be a multiple of 3
    var forbidden_zone = ms.ForbiddenZone.init(gpa);
    var route = try rt.routeToUpdateForbiddenZone(gpa, .{ -20, 0, 0 }, .{ 40, 0, 0 }, &forbidden_zone);
    var route2 = try rt.routeToUpdateForbiddenZone(gpa, .{ 10, 0, -20 }, .{ 10, 0, 20 }, &forbidden_zone);
    try route.appendSlice(gpa, route2.items);
    nbt.abs_block_arr_to_schem(gpa, route.items);
    route.deinit(gpa);
    route2.deinit(gpa);
    forbidden_zone.deinit();
}
