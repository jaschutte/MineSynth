const std = @import("std");
const glib = @import("../graph/graph.zig");
const id = @import("../graph/id.zig");
const model = @import("../model.zig");
const library = @import("../library.zig");

pub fn convertGraphToModel(gpa: std.mem.Allocator, graph: *const glib.Graph(glib.GateBody)) !model.Netlist {
    var id_mapping: std.AutoArrayHashMap(id.Id, usize) = .init(gpa);
    var ports_used: std.ArrayList(usize) = .empty;
    var instances: std.ArrayList(model.Instance) = .empty;
    var nets: std.ArrayList(model.Net) = .empty;

    // Loop over all gates
    for (graph.nodes.values(), 0..) |*node, i| {
        // Insert instance into instances list
        try id_mapping.put(node.id, i);
        try instances.append(gpa, node.body);
        try ports_used.append(gpa, 0);
    }

    // Loop over all edges
    var net_counter: usize = 0;
    var net_mapping: std.AutoArrayHashMap(usize, usize) = .init(gpa);
    for (graph.edges.values()) |*edge| {
        // Map node to instance id
        const in_node_id, const out_node_id = switch (edge.a_relation) {
            .input => .{ edge.a, edge.b },
            .output => .{ edge.b, edge.a },
        };
        const in_id = id_mapping.get(in_node_id).?;
        const out_id = id_mapping.get(out_node_id).?;

        // Figure out the net number for this edge
        // We assume every net has exactly one output,
        // so we can determine net at looking at the net
        // of the output port.
        // We also assume that each gate has exactly one output
        var net_id = net_counter;
        if (net_mapping.get(out_id)) |net| {
            // If output is already on a net, use that one
            net_id = net;
        } else {
            // Otherwise, increment net_counter and store net
            try net_mapping.put(out_id, net_id);
            net_counter += 1;
        }

        // Create the new edge
        const port = ports_used.items[in_id];
        ports_used.items[in_id] = port + 1;
        const net: model.Net = .{
            .net = net_id,
            .input = .{
                .instance = in_id,
                .direction = .input,
                .port = port,
            },
            .output = .{
                .instance = out_id,
                .direction = .output,
                .port = 0, // We assume every gate has just one output
            },
        };
        try nets.append(gpa, net);
    }

    var nl: model.Netlist = undefined;
    nl.nets = try nets.toOwnedSlice(gpa);
    nl.instances = try instances.toOwnedSlice(gpa);
    nl.lib = try library.Library.init(gpa);
    return nl;
}
