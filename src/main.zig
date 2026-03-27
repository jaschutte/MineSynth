const std = @import("std");
const model = @import("model.zig");

fn normalization_stage(gpa: std.mem.Allocator, aiger_file: []u8) !model.Netlist {
    // Parse AIGER file
    const aiger = @import("normalization/aiger.zig");
    const aig = try aiger.Aiger.parseAag(gpa, aiger_file);
    defer _ = aig.deinit();

    // Extract netlist form AIGER
    const nl = @import("netlist.zig");
    var netlist = try nl.Netlist.fromAiger(gpa, aig);
    defer _ = netlist.deinit();

    // Construct Graph from netlit and apply normalization
    const glib = @import("graph/graph.zig");
    const glibopt = @import("graph/preprocessor.zig");
    // const sta = @import("sta.zig");
    const graph = glib.GraphConstructors.fromNetlist(gpa, &netlist);
    defer graph.deinit();
    glibopt.PreProcessor(glib.GateBody).preprocess(graph);
    // sta.AAT(graph); // Perform static timing analysis

    // Print graph
    const graphviz = @import("graph/graphviz.zig");
    graphviz.GraphVisualizer(glib.GateBody).print(gpa, graph);

    // Convert graph into model type
    const conversion = @import("normalization/conversion.zig");
    return try conversion.convertGraphToModel(gpa, graph);
}

fn placement_stage(gpa: std.mem.Allocator, netlist: *const model.Netlist) !model.Placement {
    var seed: u32 = undefined;
    try std.posix.getrandom(std.mem.asBytes(&seed));

    const plc = @import("placement.zig");
    const annealing_config: plc.AnnealingConfig = .{
        .initial_temperature = 3,
        .moves_per_temperature = 8000,
        .initial_window_size = 80,
        .alpha = 0.5,
        .node_padding = 5,
    };
    const placement = plc.placement_annealing(gpa, netlist, seed, annealing_config);

    // return placement;
    _ = placement;
    @panic("");
}

// fn routing_stage(schem: model.Schematic, wires: []model.Wire) model.Schematic {}

// fn validation(schem: model.Schematic, netlist: model.Netlist, placement: model.Placement) bool {}

// fn visualization_stage(schem: model.Schematic nbt.NbtTag {}

pub fn main() !void {
    // Initialize allocator
    var real_gpa: std.heap.DebugAllocator(.{}) = .init;
    // var real_gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const gpa = real_gpa.allocator();
    defer _ = real_gpa.deinit();

    // Read AIGER file
    const content = try std.fs.cwd().readFileAlloc(gpa, "aiger-examples/serial-adder.aag", std.math.maxInt(usize));
    defer _ = gpa.free(content);

    // Apply normalization to AIGER file
    // and generate netlist tuple
    const netlist = try normalization_stage(gpa, content);

    // Perform placement
    const placement = try placement_stage(gpa, &netlist);

    _ = placement;

    // // get random generator:
    // var seed: u32 = undefined;
    // try std.posix.getrandom(std.mem.asBytes(&seed));

    // var placement = plc.placement_annealing(graph, seed, .{ .initial_temperature = 3, .moves_per_temperature = 8000, .initial_window_size = 80, .alpha = 0.5, .node_padding = 5 }).?;
    // defer placement.deinit(gpa);
    // plc.print(graph, placement, graph.gpa);
    // graphviz.printPlacement(graph.gpa, graph, placement);
    // const tuples = plc.getThoseTuples(graph, placement, 0);
    // defer gpa.free(tuples);
    // // plc.printThoseTuples(gpa, tuples);
    // // gpa.free(tuples);
    // const placementBlocks = placement.toBlocklist(graph, 0);
    // defer gpa.free(placementBlocks);
    // // nbt.block_arr_to_schem(gpa, placementBlocks);
    // var forbidden_zone = placement.toForbiddenzone(graph, 0);
    // defer forbidden_zone.deinit();

    // var allBlocks: std.ArrayList(ms.AbsBlock) = .empty;
    // defer allBlocks.deinit(gpa);

    // // var iter = forbidden_zone.iterator();
    // // while (iter.next()) |entry| {
    // //     const coord = entry.key_ptr.*;
    // //     const info = entry.value_ptr.*;
    // //     _ = info; // autofix
    // //     try allBlocks.append(gpa, ms.AbsBlock{
    // //         .block = .block2,
    // //         .rot = .center,
    // //         .loc = .{ @as(ms.WorldCoordNum, coord[0]), @as(ms.WorldCoordNum, coord[1]), @as(ms.WorldCoordNum, coord[2]) },
    // //     });
    // // }

    // for (placementBlocks) |block| {
    //     try allBlocks.append(gpa, ms.AbsBlock{
    //         .block = block.block,
    //         .rot = block.rot,
    //         .loc = block.loc,
    //     });
    // }

    // var pairs: std.ArrayList(rt.RoutePair) = .empty;
    // defer pairs.deinit(gpa);
    // for (tuples) |tuple| {
    //     try pairs.append(gpa, rt.RoutePair{
    //         .from = .{ @as(ms.WorldCoordNum, @intCast(tuple.x[0])), @as(ms.WorldCoordNum, @intCast(tuple.x[1])), @as(ms.WorldCoordNum, @intCast(tuple.x[2])) },
    //         .to = .{ @as(ms.WorldCoordNum, @intCast(tuple.y[0])), @as(ms.WorldCoordNum, @intCast(tuple.y[1])), @as(ms.WorldCoordNum, @intCast(tuple.y[2])) },
    //     });
    // }

    // var route = rt.routeAll(gpa, seed, pairs.items, &forbidden_zone, .{}) catch |err| {
    //     std.debug.print("Routing failed: {}\n", .{err});
    //     return;
    // };
    // defer route.deinit(gpa);
    // try allBlocks.appendSlice(gpa, route.route.items);

    // // visualize forbidden zone

    // nbt.abs_block_arr_to_schem(gpa, allBlocks.items);
}
