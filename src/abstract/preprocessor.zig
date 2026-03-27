const std = @import("std");
const nl = @import("../netlist.zig");
const glib = @import("graph.zig");

// Enforce that all INPUTS have are registered as OUTPUT on the other end and vice versa
pub fn removeLooseConnections(graph: *glib.GateGraph) void {
    errdefer @panic("Ran out of memory when optimising loose connections away");

    var faulty_edges = std.ArrayList(glib.EdgeId).empty;
    defer _ = faulty_edges.deinit(graph.gpa);

    for (graph.edges.values()) |*edge| {
        const a_connected = edge.a_relation;
        const b_connected = edge.b_relation;

        if (!((a_connected == .input and b_connected == .output) or (a_connected == .output and b_connected == .input))) {
            try faulty_edges.append(graph.gpa, edge.id);
        }
    }

    for (faulty_edges.items) |faulty_id| {
        graph.removeEdge(faulty_id);
    }
}

pub fn substituteInOrs(graph: *glib.GateGraph) void {
    errdefer @panic("Ran out of memory while substituting ORs. How? L bozo?");

    while (true) {
        var has_changed = false;
        or_finder: for (graph.nodes.values()) |*node| {
            if (node.body.kind != .inverter) continue :or_finder;

            const root_input_ids = node.relatedNodes(glib.GateGraph.Edge.Relation.input);
            defer graph.gpa.free(root_input_ids);
            if (root_input_ids.len != 1) continue :or_finder;
            const and_gate = graph.getConstNode(root_input_ids[0]).?;
            if (and_gate.body.kind != .and_gate) continue :or_finder;
            const and_outputs = and_gate.relatedNodes(glib.GateGraph.Edge.Relation.output);
            defer graph.gpa.free(and_outputs);
            if (and_outputs.len != 1) continue :or_finder;

            const outputs = node.relatedNodes(glib.GateGraph.Edge.Relation.output);
            defer graph.gpa.free(outputs);

            const and_gate_input_ids = and_gate.relatedNodes(glib.GateGraph.Edge.Relation.input);
            defer graph.gpa.free(and_gate_input_ids);
            if (and_gate_input_ids.len != 2) continue :or_finder;
            for (and_gate_input_ids) |and_gate_input_id| {
                const and_gate_input = graph.getConstNode(and_gate_input_id).?;
                if (and_gate_input.body.kind != .inverter) continue :or_finder;
                const inverter_outputs = and_gate_input.relatedNodes(glib.GateGraph.Edge.Relation.output);
                defer graph.gpa.free(inverter_outputs);
                if (inverter_outputs.len != 1) continue :or_finder;
            }

            var inputs = std.ArrayList(glib.NodeId).empty;
            defer inputs.deinit(graph.gpa);
            for (and_gate_input_ids) |and_gate_input_id| {
                const and_gate_input = graph.getConstNode(and_gate_input_id).?;
                const inverter_inputs = and_gate_input.relatedNodes(glib.GateGraph.Edge.Relation.input);
                defer graph.gpa.free(inverter_inputs);
                try inputs.appendSlice(graph.gpa, inverter_inputs);
            }
            const owned_inputs = try inputs.toOwnedSlice(graph.gpa);
            defer graph.gpa.free(owned_inputs);

            // Important! These references become invalid the moment we invoke `removeNode`, therefore storing the ID before any graph manipulation is IMPORTANT!
            const and_gate_id = and_gate.id;
            const root_id = node.id;

            // Remove all of the old gates no longer needed
            for (and_gate_input_ids) |and_gate_input_id| {
                graph.removeNode(and_gate_input_id);
            }
            graph.removeNode(and_gate_id);
            graph.removeNode(root_id);

            // Insert the replacement OR gate
            var label_creator = std.io.Writer.Allocating.init(graph.gpa);
            defer label_creator.deinit();

            const or_gate_id = graph.addNode(.{
                .symbol = undefined,
                .kind = .or_gate,
            }, .none);
            try label_creator.writer.print("sub.or-gate.{}", .{or_gate_id});
            graph.getNode(or_gate_id).?.body.symbol = try graph.gpa.dupe(u8, label_creator.written());

            for (owned_inputs) |input_id| {
                const edge_id = graph.addEdge(or_gate_id, .input, input_id, .output, .{
                    .symbol = undefined,
                    .negated = .undefined,
                }, 0.0);
                label_creator.clearRetainingCapacity();
                try label_creator.writer.print("sub.or-edge.{}", .{edge_id});
                graph.getEdge(edge_id).?.body.symbol = try graph.gpa.dupe(u8, label_creator.written());
            }
            for (outputs) |output_id| {
                const edge_id = graph.addEdge(or_gate_id, .output, output_id, .input, .{
                    .symbol = undefined,
                    .negated = .undefined,
                }, 0.0);
                label_creator.clearRetainingCapacity();
                try label_creator.writer.print("sub.or-edge.{}", .{edge_id});
                graph.getEdge(edge_id).?.body.symbol = try graph.gpa.dupe(u8, label_creator.written());
            }

            // We have to break the loop, since we inserted/deleted nodes, it is no longer save to
            // iterate the graph as we did before (we do not use smart iterators)
            has_changed = true;
            break :or_finder;
        }

        // If the operation didn't lower the amount of nodes, then we should stop substituting
        // ORs should *always* lower the amount of nodes available
        if (!has_changed) break;
    }
}

pub fn PreProcessor(comptime NodeBody: type) type {
    return struct {
        pub fn preprocess(graph: *glib.Graph(NodeBody)) void {
            switch (NodeBody) {
                glib.GateBody => {
                    removeLooseConnections(graph);
                    substituteInOrs(graph);
                },
                else => {},
            }
        }
    };
}
