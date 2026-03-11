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
    const gpa = real_gpa.allocator();
    defer _ = real_gpa.deinit();

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
    graph.deinit();

    // each layer is a height of 3, so any target y coordinate must be a multiple of 3
    // forbidden zone should contain all mc blocks inside an AND/NOT block
    // + input/outputs + blocks adjacent to inputs/outputs
    var forbidden_zone = ms.ForbiddenZone.init(gpa);
    defer forbidden_zone.deinit();
    var route = try rt.routeToUpdateForbiddenZone(gpa, .{ -20, 0, 0 }, .{ 40, 0, 0 }, &forbidden_zone);
    std.log.info(
        "path of length {d} and delay {d} found between {any} and {any}\n",
        .{ route.length, route.delay, .{ -20, 0, 0 }, .{ 40, 0, 0 } },
    );
    defer route.deinit(gpa);
    var route2 = try rt.routeToUpdateForbiddenZone(gpa, .{ 10, 0, -20 }, .{ 10, 0, 20 }, &forbidden_zone);
    std.log.info(
        "path of length {d} and delay {d} found between {any} and {any}\n",
        .{ route2.length, route2.delay, .{ 10, 0, -20 }, .{ 10, 0, 20 } },
    );
    defer route2.deinit(gpa);
    try route.route.appendSlice(gpa, route2.route.items);
    nbt.abs_block_arr_to_schem(gpa, route.route.items);
}
