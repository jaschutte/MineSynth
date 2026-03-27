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
    const sta = @import("sta.zig");
    const graph = glib.GraphConstructors.fromNetlist(gpa, &netlist);
    defer graph.deinit();
    glibopt.PreProcessor(glib.GateBody).preprocess(graph);
    sta.AAT(graph); // Perform static timing analysis

    // Print graph
    const graphviz = @import("graph/graphviz.zig");
    graphviz.GraphVisualizer(glib.GateBody).print(gpa, graph);

    // Convert graph into model type
    const conversion = @import("normalization/conversion.zig");
    return try conversion.convertGraphToModel(gpa, graph);
}

// fn placement_stage(netlist: model.Netlist) model.Placement {}

// fn routing_stage(schem: model.Schematic(model.BasicBlock), wires: []model.Wire) model.Schematic(model.BasicBlock) {}

// fn visualization_stage(schem: model.Schematic(model.BasicBlock)) nbt.NbtTag {}

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
    _ = netlist; // autofix

    // var placement = plc.placement_annealing(graph, .{ .initial_temperature = 2, .moves_per_temperature = 15000 }).?;
    // plc.print(graph, placement, graph.gpa);
    // // graphviz.printPlacement(graph.gpa, graph, placement);
    // // const tuples = plc.getThoseTuples(graph, placement, 0);
    // // plc.printThoseTuples(graph.gpa, tuples);
    // // graph.gpa.free(tuples);
    // const allblocks = plc.toBlocklist(graph, placement, 0);
    // nbt.block_arr_to_schem(gpa, allblocks);
    // graph.gpa.free(allblocks);
    // placement.deinit(graph.gpa);

    // var forbidden_zone = ms.ForbiddenZone.init(gpa);
    // defer forbidden_zone.deinit();

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
    // var route = try rt.routeAll(gpa, pairs.items, &forbidden_zone, .{});

    // defer route.deinit(gpa);

    // // nbt.abs_block_arr_to_schem(gpa, master_route.route.items);
}
