const std = @import("std");
const nl = @import("../netlist.zig");
const glib = @import("graph.zig");

// https://magjac.com/graphviz-visual-editor/

pub fn print_gate(gpa: std.mem.Allocator, graph: *const glib.Graph(nl.GatePtr)) !void {
    var string = std.io.Writer.Allocating.init(gpa);
    try string.writer.writeAll("digraph {\n");
    // try string.writer.writeAll("    layout = fdp;\n");
    try string.writer.writeAll("    node [style=filled];\n");

    for (graph.edges.items) |edge| {
        const net = graph.source.netlist.get_net(edge.body.net_id);
        const color = switch (net.literal.is_negated()) {
            true => "\"#601400\"",
            false => "\"#006004\"",
        };
        const non_const_graph: *glib.Graph(nl.GatePtr) = @constCast(graph);
        const relation = non_const_graph.get_node(edge.a).?.edge_relation(edge.id);
        const order: struct { arrow: *const [2]u8, from: u64, to: u64 } = switch (relation) {
            .input => .{ .arrow = "->", .from = edge.b, .to = edge.a },
            .output => .{ .arrow = "->", .from = edge.a, .to = edge.b },
            .inout => .{ .arrow = "--", .from = edge.a, .to = edge.b },
            .none => .{ .arrow = "--", .from = edge.a, .to = edge.b },
        };

        try string.writer.print("    {} {s} {} [label=\"", .{ order.from, order.arrow, order.to });
        try net.literal.write_symbol(&string.writer);
        try string.writer.print("\", color={s}, tooltip=\"{}\"]\n", .{color, edge.id});
    }

    for (graph.nodes.items) |node| {
        const gate = graph.source.netlist.get_gate(node.body);
        const symbol = gate.symbol;
        const color = switch (gate.kind) {
            .and_gate => "\"#e0a143\"",
            .inverter => "\"#8fb2c9\"",
            .input => "\"#33f747\"",
            .output => "\"#33f7f0\"",
        };
        try string.writer.print("    {} [label=\"{s}\", fillcolor={s}, tooltip=\"{}\"];\n", .{ node.id, symbol, color, node.id });

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
