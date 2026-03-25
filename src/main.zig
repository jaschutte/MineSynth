const std = @import("std");
const aiger = @import("aiger.zig");
const nl = @import("netlist.zig");
const glib = @import("abstract/graph.zig");
const glibopt = @import("abstract/preprocessor.zig");
const graphviz = @import("abstract/graphviz.zig");
const rt = @import("routing.zig");
const nbt = @import("nbt.zig");
const ms = @import("abstract/structures.zig");
const place = @import("gates.zig");
const sta = @import("sta.zig");

pub fn main() !void {
    var real_gpa: std.heap.DebugAllocator(.{}) = .init;
    const gpa = real_gpa.allocator();
    defer _ = real_gpa.deinit();

    const content = try std.fs.cwd().readFileAlloc(gpa, "aiger-examples/half-adder.aag", std.math.maxInt(usize));
    defer _ = gpa.free(content);

    const aig = try aiger.Aiger.parseAag(gpa, content);
    defer _ = aig.deinit();

    var netlist = try nl.Netlist.fromAiger(gpa, aig);
    defer _ = netlist.deinit();

    var graph = glib.GraphConstructors.fromNetlist(gpa, &netlist);
    errdefer graph.deinit();
    // graphviz.GraphVisualizer(glib.GateBody).printDFS(gpa, graph);
    glibopt.PreProcessor(glib.GateBody).preprocess(graph);
    sta.AAT(graph);
    graphviz.GraphVisualizer(glib.GateBody).print(gpa, graph);

    try place.createGates(gpa, graph);
    graph.deinit();

    // var forbidden_zone = ms.ForbiddenZone.init(gpa);
    // defer forbidden_zone.deinit();

    // var master_route = try rt.routeToUpdateForbiddenZone(gpa, test_endpoints[0][0], test_endpoints[0][1], &forbidden_zone);
    // defer master_route.deinit(gpa);

    // const master_route = 2;
    // std.log.info(
    //     "path of length {d} and delay {d} with violating {any} found between {any} and {any}\n",
    //     .{ master_route.length, master_route.delay, master_route.violating, test_endpoints[0][0], test_endpoints[0][1] },
    // );

    // for (test_endpoints[1..]) |endpoints| {
    //     const start = endpoints[0];
    //     const end = endpoints[1];

    //     var route = try rt.routeToUpdateForbiddenZone(gpa, start, end, &forbidden_zone);
    //     defer route.deinit(gpa);

    //     std.log.info(
    //         "path of length {d} and delay {d} with violating {any} found between {any} and {any}",
    //         .{ route.length, route.delay, route.violating, start, end },
    //     );

    //     try master_route.route.appendSlice(gpa, route.route.items);
    // }

    // nbt.abs_block_arr_to_schem(gpa, route.route.items);
}
