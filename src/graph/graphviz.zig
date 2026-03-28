const std = @import("std");
const nl = @import("../netlist.zig");
const glib = @import("graph.zig");
const placement = @import("../placement.zig");

// https://magjac.com/graphviz-visual-editor/

pub fn printNode(string: *std.io.Writer.Allocating, node: *glib.GateGraph.Node, position: ?@Vector(2, placement.postype)) void {
    errdefer @panic("Skill issue");

    const symbol = node.body.symbol;
    const color = switch (node.body.kind) {
        .and_gate => "\"#e0a143\"",
        .or_gate => "\"#ead04f\"",
        .inverter => "\"#8fb2c9\"",
        .input => "\"#33f747\"",
        .output => "\"#33f7f0\"",
    };
    try string.writer.print("    {} [label=\"{s}", .{ node.id, symbol });
    var timing: f32 = 0;
    if (node.metadata == .timing) {
        timing = node.metadata.timing.actual_arrival;
        try string.writer.print("--{d}", .{timing});
    }
    try string.writer.print("\", fillcolor={s}, tooltip=\"{}\"", .{ color, node.id });
    if (position != null) {
        try string.writer.print(", pos=\"{d},{d}!, pin=true\"", .{ position.?[0], position.?[1] });
    }
    try string.writer.print("];\n", .{});
}

pub fn printEdge(graph: *const glib.GateGraph, string: *std.io.Writer.Allocating, edge: *glib.GateGraph.Edge) void {
    errdefer @panic("Skill issue");

    const color = switch (edge.body.negated) {
        .negated => "\"#601400\"",
        .unnegated => "\"#006004\"",
        .undefined => "\"#000000\"",
    };
    const relation = graph.getConstNode(edge.a).?.edgeRelation(edge.id) orelse @panic("Invalid edge?");
    const order: struct { arrow: *const [2]u8, from: u64, to: u64 } = switch (relation) {
        .input => .{ .arrow = "->", .from = edge.b, .to = edge.a },
        .output => .{ .arrow = "->", .from = edge.a, .to = edge.b },
    };

    try string.writer.print("    {} {s} {} [label=\"", .{ order.from, order.arrow, order.to });
    try string.writer.print("{s}", .{edge.body.symbol});
    try string.writer.print("\", color={s}, tooltip=\"{}\"]\n", .{ color, edge.id });
}

pub fn printPlacement(gpa: std.mem.Allocator, graph: *const glib.GateGraph, the_placement: *const placement.Placement) void {
    errdefer @panic("Skill issue");

    var string = std.io.Writer.Allocating.init(gpa);
    try string.writer.writeAll("digraph {\n");
    try string.writer.writeAll("    layout = fdp;\n");
    try string.writer.writeAll("    node [style=filled];\n");

    for (graph.edges.values()) |*edge| {
        printEdge(graph, &string, edge);
    }

    for (graph.nodes.values()) |*node| {
        const pos = the_placement.locations.get(node.id) orelse {
            std.debug.print("node {d} not placed\n", .{node.id});
            continue;
        };
        printNode(&string, node, @Vector(2, placement.postype){ pos.x, pos.y });
    }

    try string.writer.writeAll("}\n");

    std.debug.print("{s}", .{string.written()});
    string.deinit();
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
        printNode(&string, node, null);
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
        printNode(&string, node, null);
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
