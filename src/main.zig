const std = @import("std");
const model = @import("model.zig");
const library = @import("library.zig");
const nbt = @import("visualization/nbt.zig");

pub fn main() !void {
    // Initialize allocator
    // var real_gpa: std.heap.DebugAllocator(.{}) = .init;
    var real_gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const gpa = real_gpa.allocator();
    // defer _ = real_gpa.deinit();

    // Read AIGER file
    const content = try std.fs.cwd().readFileAlloc(gpa, "aiger-examples/8-adder.aag", std.math.maxInt(usize));
    defer _ = gpa.free(content);

    // Apply normalization to AIGER file
    // and generate netlist tuple
    const netlist = try normalization_stage(gpa, content);

    // Perform placement
    const placement = try placement_stage(gpa, &netlist);

    // Convert to schematic and wires
    const placed_schematic = try placement.toSchematic(gpa);
    const wires = try placement.getWires(&netlist, gpa);

    // Perform routing
    const schematic = try routing_stage(gpa, &placed_schematic, wires);

    // Perform validation
    const result = try validation_stage(gpa, &schematic, &netlist, &placement);
    if (!result) @panic("Validation failed");

    // Visualize schematic
    const visualization = try visualization_stage(gpa, &schematic, &placement);
    nbt.write_nbt_file("circuit.schematic", visualization);
}

fn normalization_stage(gpa: std.mem.Allocator, aiger_file: []u8) !model.Netlist {
    // Construct library
    const lib = try library.Library.init(gpa);

    // Parse AIGER file
    const aiger = @import("normalization/aiger.zig");
    const aig = try aiger.Aiger.parseAag(gpa, aiger_file);
    defer _ = aig.deinit();

    // Extract netlist form AIGER
    const nl = @import("normalization/netlist.zig");
    var netlist = try nl.Netlist.fromAiger(gpa, aig);
    defer _ = netlist.deinit();

    // Construct Graph from netlit and apply normalization
    const glib = @import("normalization/graph.zig");
    const preprocessor = @import("normalization/preprocessor.zig");
    const sta = @import("normalization/sta.zig");
    const graph = glib.GraphConstructors.fromNetlist(gpa, &netlist);
    defer graph.deinit();
    preprocessor.PreProcessor(glib.GateBody).preprocess(graph);
    sta.AAT(graph, &lib); // Perform static timing analysis

    // Print graph
    const graphviz = @import("normalization/graphviz.zig");
    graphviz.GraphVisualizer(glib.GateBody).print(gpa, graph);

    // Convert graph into model type
    const conversion = @import("normalization/conversion.zig");
    const nets = try conversion.convertGraphToModel(gpa, graph, lib);

    return nets;
}

fn placement_stage(gpa: std.mem.Allocator, netlist: *const model.Netlist) !model.Placement {
    var seed: u32 = undefined;
    try std.posix.getrandom(std.mem.asBytes(&seed));

    std.debug.print("Early netlist {any}\n", .{netlist});

    const plc = @import("placement/placement.zig");
    const annealing_config: plc.AnnealingConfig = .{
        .initial_temperature = 30,
        .moves_per_temperature = 2000,
        // .moves_per_temperature = 5000,
        .initial_window_size = 70,
        .alpha = 0.8,
        .node_padding = 1,
        .congestion_cost_weight = 50,
        // .initial_input_y = 20,
        // .initial_output_y = 130,
        .fix_inoutputs = false,
    };
    const placement = plc.placement_annealing(gpa, netlist, seed, annealing_config).?;

    const conversion = @import("placement/conversion.zig");
    const plac = try conversion.convertPlacement(gpa, placement);

    return plac;
}

fn routing_stage(gpa: std.mem.Allocator, schem: *const model.Schematic, wires: []model.Wire) !model.Schematic {
    const routing = @import("routing/routing.zig");
    const schematic = try routing.route(wires, schem, gpa);
    return schematic;
}

fn validation_stage(gpa: std.mem.Allocator, schematic: *const model.Schematic, netlist: *const model.Netlist, placement: *const model.Placement) !bool {
    const validation = @import("validation/validation.zig");

    // Print list of instances for reference
    for (netlist.instances, 0..) |inst, i| {
        std.debug.print("Instance {} is a {} placed at {}\n", .{ i, inst.kind, placement.placement[i].pos });
    }

    // Validate that the schematic is valid
    const schematic_valid = validation.validate_grid(schematic);
    if (!schematic_valid) @panic("Generated schematic is not valid");

    // Validate that logical equivalence is preserved
    const logical_equivalence = try validation.validate_logical_equivalence(netlist, schematic, placement, gpa);
    if (!logical_equivalence) @panic("Generated schematic is not logically equivalent");

    // TODO: Perform static timing analysis

    return true;
}

fn visualization_stage(gpa: std.mem.Allocator, schematic: *const model.Schematic, placement: *const model.Placement) !nbt.NbtTag {
    const visualization = @import("visualization/visualization.zig");

    // Convert schematic and placement to minecraft blocks
    const schem_blocks = try visualization.blockListFromSchematic(gpa, schematic);
    const place_blocks = try visualization.blockListFromPlacement(gpa, placement);

    // Combine the two block lists
    var blocks = std.ArrayList(library.SchemBlock).fromOwnedSlice(schem_blocks);
    try blocks.appendSlice(gpa, place_blocks);

    // Add a floor
    const floor_blocks = try visualization.addFloor(gpa, &blocks.items);
    try blocks.appendSlice(gpa, floor_blocks);

    return nbt.block_arr_to_schem(gpa, try blocks.toOwnedSlice(gpa));
}
