const std = @import("std");
const nl = @import("../netlist.zig");
const glib = @import("graph.zig");

// https://magjac.com/graphviz-visual-editor/

pub fn printNode(string: *std.io.Writer.Allocating, node: *glib.GateGraph.Node) void {
    errdefer @panic("Skill issue");

    const symbol = node.body.symbol;
    const color = switch (node.body.kind) {
        .and_gate => "\"#e0a143\"",
        .or_gate => "\"#ead04f\"",
        .inverter => "\"#8fb2c9\"",
        .input => "\"#33f747\"",
        .output => "\"#33f7f0\"",
    };
    try string.writer.print("    {} [label=\"{s}\", fillcolor={s}, tooltip=\"{}\"];\n", .{ node.id, symbol, color, node.id });
}

pub fn printEdge(graph: *const glib.GateGraph, string: *std.io.Writer.Allocating, edge: *glib.GateGraph.Edge) void {
    errdefer @panic("Skill issue");

    const net = graph.source.getNet(edge.body);
    const color = switch (net.literal.isNegated()) {
        true => "\"#601400\"",
        false => "\"#006004\"",
    };
    const relation = graph.getConstNode(edge.a).?.edgeRelation(edge.id) orelse @panic("Invalid edge?");
    const order: struct { arrow: *const [2]u8, from: u64, to: u64 } = switch (relation) {
        .input => .{ .arrow = "->", .from = edge.b, .to = edge.a },
        .output => .{ .arrow = "->", .from = edge.a, .to = edge.b },
    };

    try string.writer.print("    {} {s} {} [label=\"", .{ order.from, order.arrow, order.to });
    try net.literal.writeSymbol(&string.writer);
    try string.writer.print("\", color={s}, tooltip=\"{}\"]\n", .{ color, edge.id });
}

pub fn printGate(gpa: std.mem.Allocator, graph: *const glib.GateGraph) void {
    errdefer @panic("Skill issue");

    var string = std.io.Writer.Allocating.init(gpa);
    try string.writer.writeAll("digraph {\n");
    // try string.writer.writeAll("    layout = fdp;\n");
    try string.writer.writeAll("    node [style=filled];\n");

    for (graph.edges.values()) |*edge| {
        printEdge(graph, &string, edge);
    }

    for (graph.nodes.values()) |*node| {
        printNode(&string, node);
    }

    try string.writer.writeAll("}\n");

    std.debug.print("{s}", .{string.written()});
    string.deinit();
}

pub fn printGateDFS(gpa: std.mem.Allocator, graph: *const glib.GateGraph) void {
    errdefer @panic("Skill issue");

    var non_const_graph: *glib.GateGraph = @constCast(graph);

    var string = std.io.Writer.Allocating.init(gpa);
    defer _ = string.deinit();

    try string.writer.writeAll("digraph {\n");
    try string.writer.writeAll("    node [style=filled];\n");

    var node_queue = std.ArrayList(glib.NodeId).empty;
    defer _ = node_queue.deinit(gpa);
    for (graph.nodes.values()) |*node| {
        if (node.body.kind == .input) {
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

                const edge = non_const_graph.getEdge(edge_id).?;
                const other_id = switch (edge.a == node_id) {
                    true => edge.b,
                    false => edge.a,
                };

                try node_queue.append(gpa, other_id);
            }
        }
    }

    for (edges_visited.keys()) |edge_id| {
        const edge = non_const_graph.getEdge(edge_id).?;
        printEdge(graph, &string, edge);
    }
    for (visited.keys()) |node_id| {
        const node = non_const_graph.getNode(node_id).?;
        printNode(&string, node);
    }

    try string.writer.writeAll("}\n");

    std.debug.print("{s}", .{string.written()});
}

pub fn GraphVisualizer(comptime NodeBody: type) type {
    return struct {
        pub const print = switch (NodeBody) {
            glib.GateBody => printGate,
            else => @compileError("Unsupported graph type"),
        };

        pub const printDFS = switch (NodeBody) {
            glib.GateBody => printGateDFS,
            else => @compileError("Unsupported graph type"),
        };
    };
}
