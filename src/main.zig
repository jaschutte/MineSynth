const std = @import("std");
const aiger = @import("aiger.zig");
const nl = @import("netlist.zig");
const glib = @import("abstract/graph.zig");
const glibopt = @import("abstract/preprocessor.zig");
const graphviz = @import("abstract/graphviz.zig");
const rt = @import("routing.zig");
const nbt = @import("nbt.zig");
const ms = @import("abstract/structures.zig");
const sta = @import("sta.zig");
const plc = @import("placement.zig");

pub fn main() !void {
    var real_gpa: std.heap.DebugAllocator(.{}) = .init;
    const gpa = real_gpa.allocator();
    defer _ = real_gpa.deinit();

    const content = try std.fs.cwd().readFileAlloc(gpa, "aiger-examples/serial-adder.aag", std.math.maxInt(usize));
    defer _ = gpa.free(content);

    const aig = try aiger.Aiger.parseAag(gpa, content);
    defer _ = aig.deinit();

    var netlist = try nl.Netlist.fromAiger(gpa, aig);
    defer _ = netlist.deinit();

    var graph = glib.GraphConstructors.fromNetlist(gpa, &netlist);
    defer graph.deinit();
    graphviz.GraphVisualizer(glib.GateBody).print(gpa, graph);
    glibopt.PreProcessor(glib.GateBody).preprocess(graph);
    sta.AAT(graph);
    graphviz.GraphVisualizer(glib.GateBody).printDFS(gpa, graph);

    // get random generator:
    var seed: u32 = undefined;
    try std.posix.getrandom(std.mem.asBytes(&seed));

    var placement = plc.placement_annealing(graph, seed, .{ .initial_temperature = 3, .moves_per_temperature = 8000, .initial_window_size = 80, .alpha = 0.5, .node_padding = 5 }).?;
    defer placement.deinit(gpa);
    plc.print(graph, placement, graph.gpa);
    graphviz.printPlacement(graph.gpa, graph, placement);
    const tuples = plc.getThoseTuples(graph, placement, 0);
    defer gpa.free(tuples);
    // plc.printThoseTuples(gpa, tuples);
    // gpa.free(tuples);
    const placementBlocks = placement.toBlocklist(graph, 0);
    defer gpa.free(placementBlocks);
    // nbt.block_arr_to_schem(gpa, placementBlocks);
    var forbidden_zone = placement.toForbiddenzone(graph, 0);
    defer forbidden_zone.deinit();

    var allBlocks: std.ArrayList(ms.AbsBlock) = .empty;
    defer allBlocks.deinit(gpa);

    // var iter = forbidden_zone.iterator();
    // while (iter.next()) |entry| {
    //     const coord = entry.key_ptr.*;
    //     const info = entry.value_ptr.*;
    //     _ = info; // autofix
    //     try allBlocks.append(gpa, ms.AbsBlock{
    //         .block = .block2,
    //         .rot = .center,
    //         .loc = .{ @as(ms.WorldCoordNum, coord[0]), @as(ms.WorldCoordNum, coord[1]), @as(ms.WorldCoordNum, coord[2]) },
    //     });
    // }

    for (placementBlocks) |block| {
        try allBlocks.append(gpa, ms.AbsBlock{
            .block = block.block,
            .rot = block.rot,
            .loc = block.loc,
        });
    }

    var pairs: std.ArrayList(rt.RoutePair) = .empty;
    defer pairs.deinit(gpa);
    for (tuples) |tuple| {
        try pairs.append(gpa, rt.RoutePair{
            .to = .{ @as(ms.WorldCoordNum, @intCast(tuple.x[0])), @as(ms.WorldCoordNum, @intCast(tuple.x[1])), @as(ms.WorldCoordNum, @intCast(tuple.x[2])) },
            .from = .{ @as(ms.WorldCoordNum, @intCast(tuple.y[0])), @as(ms.WorldCoordNum, @intCast(tuple.y[1])), @as(ms.WorldCoordNum, @intCast(tuple.y[2])) },
        });
    }

    var route = rt.routeAll(gpa, seed, pairs.items, &forbidden_zone, .{}) catch |err| {
        std.debug.print("Routing failed: {}\n", .{err});
        return;
    };
    defer route.deinit(gpa);
    try allBlocks.appendSlice(gpa, route.route.items);

    // visualize forbidden zone

    nbt.abs_block_arr_to_schem(gpa, allBlocks.items);
}
