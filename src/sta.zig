const std = @import("std");
const Graph = @import("abstract/graph.zig").Graph;
const physical = @import("physical.zig");
const glib = @import("abstract/graph.zig");

// Compute AAT from netlist: Actual Arrival Time.
// The time at which the signal gets to the final gate
pub fn AAT(the_graph: *glib.GateGraph, start_node: glib.NodeId) u32 {
    errdefer @panic("Skill issue");
    var tovisit = std.ArrayList(glib.NodeId).empty;
    try tovisit.append(the_graph.gpa, start_node);
    while (tovisit.items.len > 0) {
        const current_edges = the_graph.getNodeEdges(tovisit.items[0], .output);
        for (current_edges) |edgeID| {
            const edge = the_graph.getConstEdge(edgeID).?;
            const weight_current = edge.b; //.metadata.actual_arrival;
            const weight_new = edge.a; //.metadata.actual_arrival + edge.metadata.weight;
            if (weight_new > weight_current) {
                //edge.b.metadata.actual_arrival = weight_new;
            }
            //tovisit.append(the_graph.gpa, edge.b);
        }
    }

    return 0; // the_graph.sum();
}
