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
    graphviz.GraphVisualizer(glib.GateBody).print(gpa, graph);
    glibopt.PreProcessor(glib.GateBody).preprocess(graph);
    sta.AAT(graph);
    graphviz.GraphVisualizer(glib.GateBody).printDFS(gpa, graph);
    var placement = plc.placement_annealing(graph, .{ .initial_temperature = 30, .moves_per_temperature = 8000, .initial_window_size = 80 }).?;
    plc.print(graph, placement, graph.gpa);
    // graphviz.printPlacement(graph.gpa, graph, placement);
    const tuples = plc.getThoseTuples(graph, placement, 0);
    // plc.printThoseTuples(graph.gpa, tuples);
    // graph.gpa.free(tuples);
    const allblocks = placement.toBlocklist(graph, 0);
    nbt.block_arr_to_schem(gpa, allblocks);
    graph.gpa.free(allblocks);
    var forbidden_zone = placement.toForbiddenzone(graph, 0);
    defer forbidden_zone.deinit();
    placement.deinit(graph.gpa);
    defer graph.deinit();

    var pairs: std.ArrayList(rt.RoutePair) = .empty;
    defer pairs.deinit(gpa);
    for (tuples) |tuple| {
        try pairs.append(gpa, rt.RoutePair{
            .from = .{ @as(ms.WorldCoordNum, @intCast(tuple.x[0])), @as(ms.WorldCoordNum, @intCast(tuple.x[1])), @as(ms.WorldCoordNum, @intCast(tuple.x[2])) },
            .to = .{ @as(ms.WorldCoordNum, @intCast(tuple.y[0])), @as(ms.WorldCoordNum, @intCast(tuple.y[1])), @as(ms.WorldCoordNum, @intCast(tuple.y[2])) },
        });
    }

    // const test_endpoints = [_][2][3]i32{
    //     .{ .{ 0, 0, 0 }, .{ 0, 0, 10 } },
    //     .{ .{ 4, 0, 0 }, .{ 4, 0, 10 } },
    //     .{ .{ 0, 0, 12 }, .{ 5, 0, 12 } },
    //     .{ .{ 0, 0, -2 }, .{ 5, 0, -2 } },
    //     .{ .{ -5, 0, 5 }, .{ 4, 0, 5 } }, // the violator
    //     .{ .{ -20, 0, 0 }, .{ 40, 0, 0 } },
    //     .{ .{ 10, 0, -20 }, .{ 10, 0, 20 } },
    //     .{ .{ -20, 0, 10 }, .{ 40, 0, 10 } },
    //     .{ .{ 30, 0, -30 }, .{ -10, 0, 30 } },
    //     .{ .{ -40, 0, -10 }, .{ 20, 0, -10 } },
    //     .{ .{ 0, 0, -40 }, .{ 0, 0, 40 } },
    //     .{ .{ 50, 0, -50 }, .{ -20, 0, 20 } },
    //     .{ .{ -50, 0, 40 }, .{ 30, 0, 50 } },
    // };

    // var pairs: std.ArrayList(rt.RoutePair) = .empty;
    // defer pairs.deinit(gpa);
    // for (test_endpoints) |endpoints| {
    //     try pairs.append(gpa, rt.RoutePair{
    //         .from = endpoints[0],
    //         .to = endpoints[1],
    //     });
    // }
    var route = try rt.routeAll(gpa, pairs.items, &forbidden_zone, .{});

    defer route.deinit(gpa);

    nbt.abs_block_arr_to_schem(gpa, route.route.items);
}
