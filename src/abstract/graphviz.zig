const std = @import("std");
const nl = @import("../netlist.zig");
const glib = @import("graph.zig");

// https://magjac.com/graphviz-visual-editor/


pub fn print_gate(gpa: std.mem.Allocator, graph: *const glib.Graph(nl.GatePtr)) !void {
    var string = std.io.Writer.Allocating.init(gpa);
    try string.writer.writeAll("graph {\n");
    // try string.writer.writeAll("    layout = fdp;\n");
    try string.writer.writeAll("    node [style=filled];\n");

    for (graph.edges.items) |edge| {
        const symbol = graph.source.netlist.get_net(edge.body.net_id).symbol;
        try string.writer.print("    {} -- {} [label=\"{s}\"];\n", .{ edge.a, edge.b, symbol });
    }

    for (graph.nodes.items) |node| {
        const gate = graph.source.netlist.get_gate(node.body);
        const symbol = gate.symbol;
        const color = switch (gate.kind) {
            .and_gate => "\"#dd9908\"",
            .inverter => "\"#adadad\"",
        };
        try string.writer.print("    {} [label=\"{s}\", fillcolor={s}];\n", .{ node.id, symbol, color });
    }

    try string.writer.writeAll("}\n");

    std.debug.print("{s}", .{string.written()});
    string.deinit();
}

pub fn GraphVisualizer(comptime NodeBody: type) type {
    return struct {
        pub const print = switch (NodeBody) {
            nl.GatePtr => print_gate,
            else => @compileError("Unsupported graph type"),
        };
    };
}

// pub fn node_visualizer(gpa: std.mem.Allocator, module: *const partitioning.Module, part: *const partitioning.Partition) !void {
//     var string = std.io.Writer.Allocating.init(gpa);
//     try string.writer.writeAll("graph {\n");
//     try string.writer.writeAll("    layout = fdp;\n");
//     try string.writer.writeAll("    node [style=filled];\n");
//
//     var node_check = std.AutoHashMap(struct { f: *partitioning.Node, t: *partitioning.Node }, void).init(gpa);
//
//     const netlist = module.netlist.?;
//
//     for (0.., module.raw_edges.items) |edge_idx, edge| {
//         for (edge) |a| {
//             for (edge) |b| {
//                 if (a == b) continue;
//                 if (node_check.contains(.{ .f = a, .t = b })) continue;
//                 if (node_check.contains(.{ .f = b, .t = a })) continue;
//
//                 const net_ptr = module.edge_to_net_mapping.get(edge_idx).?;
//                 const net = netlist.get_net(net_ptr);
//
//                 try string.writer.print("    {} -- {} [label=\"{s}\"];\n", .{ a.content.gate, b.content.gate, net.symbol });
//                 try node_check.put(.{ .f = a, .t = b }, undefined);
//             }
//         }
//     }
//
//     const lc: f32 = @floatFromInt(part.data.left.count());
//     const rc: f32 = @floatFromInt(part.data.left.count());
//     const lcsr: f32 = @sqrt(lc);
//     const rcsr: f32 = @sqrt(rc);
//
//     var key_iter = part.data.left.keyIterator();
//     var x_offset: f32 = 0.0;
//     var x: f32 = 0.0;
//     var y: f32 = 0.0;
//     while (key_iter.next()) |node| {
//         const gate_ptr = node.*.content.gate;
//         const gate = netlist.get_gate(gate_ptr);
//         var w: f32 = @floatFromInt(gate.kind.size().w);
//         var h: f32 = @floatFromInt(gate.kind.size().h);
//         w /= 4.0;
//         h /= 4.0;
//
//         try string.writer.print("    {} [pos=\"{},{}\", label=\"{any}.{}\", width={}, height={}, shape=rectangle, fixedsize=true, fillcolor=lightyellow];\n", .{ gate_ptr, x + x_offset, y, gate.kind, gate_ptr, w, h });
//
//         if (x >= lcsr) {
//             x = 0.0;
//             y += 1.0;
//         } else {
//             x += 1.0;
//         }
//     }
//     key_iter = part.data.right.keyIterator();
//     x_offset = lcsr + 5;
//     x = 0.0;
//     y = 0.0;
//     while (key_iter.next()) |node| {
//         const gate_ptr = node.*.content.gate;
//         const gate = netlist.get_gate(gate_ptr);
//         var w: f32 = @floatFromInt(gate.kind.size().w);
//         var h: f32 = @floatFromInt(gate.kind.size().h);
//         w /= 4.0;
//         h /= 4.0;
//
//         try string.writer.print("    {} [pos=\"{},{}\", label=\"{any}.{}\", width={}, height={}, shape=rectangle, fixedsize=true, fillcolor=lightblue];\n", .{ gate_ptr, x + x_offset, y, gate.kind, gate_ptr, w, h });
//
//         if (x >= rcsr) {
//             x = 0.0;
//             y += 1.0;
//         } else {
//             x += 1.0;
//         }
//     }
//
//     try string.writer.writeAll("}\n");
//
//     std.debug.print("{s}", .{string.written()});
//     string.deinit();
//     node_check.deinit();
// }
