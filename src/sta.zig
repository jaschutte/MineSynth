const std = @import("std");
const Graph = @import("abstract/graph.zig").Graph;
const physical = @import("physical.zig");
const glib = @import("abstract/graph.zig");

// set metadata to timing
pub fn InitializeTimingMetadata(the_graph: *const glib.GateGraph) void {
    for (the_graph.nodes.values()) |*node| {
        node.metadata = .{ .timing = .{ .actual_arrival = 0, .required_arrival = 0, .slack = 0 } };
    }
}

// Compute AAT from graph: Actual Arrival Time.
// results are written in graph.node.metadata.timing.actual_arrival for each node
pub fn AAT(the_graph: *glib.GateGraph) void {
    errdefer @panic("Skill issue");

    InitializeTimingMetadata(the_graph);

    const to_visit = DepthFirstSearch(the_graph);
    defer the_graph.gpa.free(to_visit);

    // reverse for loop:
    var i: usize = to_visit.len;
    while (i > 0) {
        i -= 1;
        const node_id = to_visit[i];
        const this_node = the_graph.getNode(node_id).?;
        var this_aa: f32 = 0;
        if (this_node.metadata == .timing) {
            // if this node has not yet been set to a higher value, this is an input node.
            // so, we set its actual_arrival to the gate's delay.
            if (this_node.metadata.timing.actual_arrival == 0) {
                this_node.metadata.timing.actual_arrival = @floatFromInt(this_node.getGate().kind.delay());
            }
            this_aa = this_node.metadata.timing.actual_arrival;
        } else {
            std.debug.print("hey, this isnt the timing metadata :(", .{});
            return;
        }

        const current_edges = the_graph.getNodeEdges(node_id, .output);
        defer the_graph.gpa.free(current_edges);
        for (current_edges) |edge_id| {
            const edge = the_graph.getConstEdge(edge_id).?;
            var next_node = the_graph.getNode(edge.b).?;
            if (edge.b == node_id) {
                next_node = the_graph.getNode(edge.a).?;
            }
            const new_arrival = @as(f32, @floatFromInt(next_node.getGate().kind.delay())) + edge.weight + this_aa;
            if (next_node.metadata == .timing) {
                if (new_arrival > next_node.metadata.timing.actual_arrival) {
                    next_node.metadata.timing.actual_arrival = new_arrival;
                }
            } else {
                std.debug.print("hey, this isnt the timing metadata :(", .{});
                return;
            }
        }
    }
}

const MarkState = enum {
    Unmarked,
    TempMark,
    PermMark,
};

// returns allocated array of node id's on topological order.
// output nodes are at the beginning of the array, input nodes are last.
// so by iterating from the end of the array to the beginning we go from input to output.
pub fn DepthFirstSearch(the_graph: *const glib.GateGraph) []glib.NodeId {
    errdefer @panic("Ran out of memory when allocating");
    var sorted = std.ArrayList(glib.NodeId).empty;

    var marks = std.AutoHashMap(glib.NodeId, MarkState).init(the_graph.gpa);
    defer marks.deinit();
    var unMarked = std.ArrayList(glib.NodeId).empty;
    defer unMarked.deinit(the_graph.gpa);

    // add all to unmarked
    for (the_graph.nodes.values()) |*node| {
        try marks.put(node.id, MarkState.Unmarked);
        try unMarked.append(the_graph.gpa, node.id);
    }

    // permanently mark all nodes
    while (unMarked.items.len > 0) {
        if (!visit(the_graph, unMarked.items[0], &unMarked, &sorted, &marks)) return try sorted.toOwnedSlice(the_graph.gpa);
        _ = unMarked.orderedRemove(0);
    }

    return try sorted.toOwnedSlice(the_graph.gpa);
}

// returns whether to continue search
// returns false when a cycle is found
// marks the node according to the depth first search algorithm
fn visit(the_graph: *const glib.GateGraph, nodeId: glib.NodeId, toMark: *std.ArrayList(glib.NodeId), sorted: *std.ArrayList(glib.NodeId), marks: *std.AutoHashMap(glib.NodeId, MarkState)) bool {
    errdefer @panic("Ran out of memory when allocating");

    const m = marks.get(nodeId) orelse {
        std.debug.print("ID not found\n", .{});
        return false;
    };

    switch (m) {
        .PermMark => return true,
        .TempMark => {
            std.debug.print("cycle detected\n", .{});
            return false;
        },
        .Unmarked => {},
    }

    // assign temp mark
    try marks.put(nodeId, MarkState.TempMark);
    // visit adjacent nodes
    const current_edges = the_graph.getNodeEdges(nodeId, .output);
    defer the_graph.gpa.free(current_edges);
    for (current_edges) |edgeID| {
        var adjacent_node = the_graph.getConstEdge(edgeID).?.b;
        if (adjacent_node == nodeId) {
            adjacent_node = the_graph.getConstEdge(edgeID).?.a;
        }
        if (!visit(the_graph, adjacent_node, toMark, sorted, marks)) return false;
    }
    // add this node to sorted list, and permanently mark.
    try marks.put(nodeId, MarkState.PermMark);
    try sorted.append(the_graph.gpa, nodeId);
    return true;
}
