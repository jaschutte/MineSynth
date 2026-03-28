const std = @import("std");
const glib = @import("graph.zig");
const library = @import("../library.zig");
const Graph = glib.Graph;

// set metadata to timing
pub fn initializeTimingMetadata(the_graph: *const glib.GateGraph) void {
    for (the_graph.nodes.values()) |*node| {
        node.metadata = .{ .timing = .{ .actual_arrival = 0, .required_arrival = 0, .slack = 0 } };
    }
}

// Compute AAT from graph: Actual Arrival Time.
// results are written in graph.node.metadata.timing.actual_arrival for each node
pub fn AAT(the_graph: *glib.GateGraph, lib: *const library.Library) void {
    errdefer @panic("Skill issue");

    initializeTimingMetadata(the_graph);

    const to_visit = the_graph.topologicalSort();
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
                this_node.metadata.timing.actual_arrival = @floatFromInt(lib.variants.get(this_node.body.kind).?.items[0].minecraft.delay);
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
            const new_arrival = @as(f32, @floatFromInt(lib.variants.get(next_node.body.kind).?.items[0].minecraft.delay)) + edge.weight + this_aa;
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
