const std = @import("std");
const nl = @import("../netlist.zig");
const glib = @import("graph.zig");

// https://magjac.com/graphviz-visual-editor/

pub fn print_node(graph: *const glib.GateGraph, string: *std.io.Writer.Allocating, node: *glib.GateGraph.Node) !void {
    const gate = graph.source.get_gate(node.body);
    const symbol = gate.symbol;
    const color = switch (gate.kind) {
        .and_gate => "\"#e0a143\"",
        .or_gate => "\"#ead04f\"",
        .inverter => "\"#8fb2c9\"",
        .input => "\"#33f747\"",
        .output => "\"#33f7f0\"",
    };
    try string.writer.print("    {} [label=\"{s}\", fillcolor={s}, tooltip=\"{}\"];\n", .{ node.id, symbol, color, node.id });
}

pub fn print_edge(graph: *const glib.GateGraph, string: *std.io.Writer.Allocating, edge: *glib.GateGraph.Edge) !void {
    const net = graph.source.get_net(edge.body);
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
    try string.writer.print("\", color={s}, tooltip=\"{}\"]\n", .{ color, edge.id });
}

pub fn print_gate(gpa: std.mem.Allocator, graph: *const glib.Graph(nl.GatePtr)) !void {
    var string = std.io.Writer.Allocating.init(gpa);
    try string.writer.writeAll("digraph {\n");
    // try string.writer.writeAll("    layout = fdp;\n");
    try string.writer.writeAll("    node [style=filled];\n");

    for (graph.edges.items) |*edge| {
        try print_edge(graph, &string, edge);
    }

    for (graph.nodes.items) |*node| {
        try print_node(graph, &string, node);
    }

    try string.writer.writeAll("}\n");

    std.debug.print("{s}", .{string.written()});
    string.deinit();
}

pub fn print_gate_dfs(gpa: std.mem.Allocator, graph: *const glib.GateGraph) !void {
    var non_const_graph: *glib.GateGraph = @constCast(graph);

    var string = std.io.Writer.Allocating.init(gpa);
    defer _ = string.deinit();

    try string.writer.writeAll("digraph {\n");
    try string.writer.writeAll("    node [style=filled];\n");

    var node_queue = std.ArrayList(glib.NodeId).empty;
    defer _ = node_queue.deinit(gpa);
    for (graph.nodes.items) |*node| {
        if (graph.source.get_gate(node.body).kind == .input) {
            try node_queue.append(gpa, node.id);
        }
    }

    var visited = std.AutoArrayHashMap(glib.NodeId, void).init(gpa);
    defer _ = visited.deinit();
    var edges_visited = std.AutoArrayHashMap(glib.EdgeId, void).init(gpa);
    defer _ = edges_visited.deinit();

    while (node_queue.pop()) |node_id| {
        if (visited.contains(node_id)) continue;
        try visited.put(node_id, undefined);

        if (graph.node2edges.getPtr(node_id)) |edges| {
            for (edges.items) |edge_id| {
                if (edges_visited.contains(edge_id)) continue;
                try edges_visited.put(edge_id, undefined);

                const edge = non_const_graph.get_edge(edge_id).?;
                const other_id = switch (edge.a == node_id) {
                    true => edge.b,
                    false => edge.a,
                };

                try node_queue.append(gpa, other_id);
            }
        }
    }

    for (edges_visited.keys()) |edge_id| {
        const edge = non_const_graph.get_edge(edge_id).?;
        try print_edge(graph, &string, edge);
    }
    for (visited.keys()) |node_id| {
        const node = non_const_graph.get_node(node_id).?;
        try print_node(graph, &string, node);
    }

    try string.writer.writeAll("}\n");

    std.debug.print("{s}", .{string.written()});
}

pub fn GraphVisualizer(comptime NodeBody: type) type {
    return struct {
        pub const print = switch (NodeBody) {
            nl.GatePtr => print_gate,
            else => @compileError("Unsupported graph type"),
        };

        pub const print_dfs = switch (NodeBody) {
            nl.GatePtr => print_gate_dfs,
            else => @compileError("Unsupported graph type"),
        };
    };
}
