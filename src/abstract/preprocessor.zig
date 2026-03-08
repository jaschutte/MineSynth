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
    var faulty_edges = std.ArrayList(glib.EdgeId).empty;
    defer _ = faulty_edges.deinit(graph.gpa);

    for (graph.edges.items) |*edge| {
        const a_connected = graph.get_node(edge.a).?.edge_relation(edge.id);
        const b_connected = graph.get_node(edge.b).?.edge_relation(edge.id);

        if (!((a_connected == .input and b_connected == .output) or (a_connected == .output and b_connected == .input))) {
            try faulty_edges.append(graph.gpa, edge.id);
        }
    }

    for (faulty_edges.items) |faulty_id| {
        try graph.remove_edge(faulty_id);
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
