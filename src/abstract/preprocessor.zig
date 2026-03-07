const std = @import("std");
const nl = @import("../netlist.zig");
const glib = @import("graph.zig");

// const edge = graph.get_edge(edge_id).?;
// const net_id = graph.get_edge(edge_id).?.body.net_id;
// const net = graph.source.netlist.get_net(net_id);
// var string = std.io.Writer.Allocating.init(graph.gpa);
// defer _ = string.deinit();
// try net.literal.write_symbol(&string.writer);
// std.debug.print("Removing {s} for nodes ({}, {}) (node: {})\n", .{ string.written(), edge.a, edge.b, node.id });

// Enforce that all INPUTS have are registered as OUTPUT on the other end and vice versa
pub fn remove_loose_connections(graph: *glib.GateGraph) !void {
    for (graph.nodes.items) |*node| {
        const edges = graph.node2edges.getPtr(node.id) orelse continue;
        var faulty_edges = std.ArrayList(glib.EdgeId).empty;
        defer _ = faulty_edges.deinit(graph.gpa);

        for (edges.items) |edge_id| {
            const edge = graph.get_edge(edge_id).?;
            if (node.edge_relation(edge_id) == .input) {
                const opposite = switch (edge.a == node.id) {
                    true => graph.get_node(edge.b),
                    false => graph.get_node(edge.a),
                }.?;
                if (opposite.edge_relation(edge_id) != .output) {
                    try faulty_edges.append(graph.gpa, edge_id);
                    continue;
                }
            }

            if (node.edge_relation(edge_id) == .output) {
                const opposite = switch (edge.a == node.id) {
                    true => graph.get_node(edge.b),
                    false => graph.get_node(edge.a),
                }.?;
                if (opposite.edge_relation(edge_id) != .input) {
                    try faulty_edges.append(graph.gpa, edge_id);
                    continue;
                }
            }
        }

        for (faulty_edges.items) |faulty_id| {
            try graph.remove_edge(faulty_id);
        }
    }
}

pub fn PreProcessor(comptime NodeBody: type) type {
    return struct {
        pub fn preprocess(graph: *glib.Graph(NodeBody)) !void {
            switch (NodeBody) {
                glib.GateBody => {
                    try remove_loose_connections(graph);
                },
                else => {},
            }
        }
    };
}
