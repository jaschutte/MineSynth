const std = @import("std");
const glib = @import("abstract/graph.zig");
const nl = @import("netlist.zig");
const ms = @import("abstract/structures.zig");
const nbt = @import("nbt.zig");
const rt = @import("routing.zig");

const GateStructure = struct {
    blocks: std.ArrayList(ms.AbsBlock),
};

const CoordPair = struct {
    input: ms.WorldCoord,
    output: ms.WorldCoord,
};

pub fn createGates(a: std.mem.Allocator, graph: *const glib.GateGraph) !void {
    var blocks: std.ArrayList(ms.AbsBlock) = .empty;
    errdefer blocks.deinit(a);

    const num_nodes = graph.nodes.count();

    const spacing = 8;

    const side_length: u32 = @intFromFloat(std.math.ceil(@as(f32, @floatFromInt(std.math.sqrt(num_nodes)))) * spacing);
    var pos: ms.WorldCoord = .{ 0, 0, 0 };

    var forbidden_zone = ms.ForbiddenZone.init(a);
    defer forbidden_zone.deinit();
    //
    var node_input_map = std.AutoHashMap(glib.NodeId, ms.WorldCoord).init(a);
    defer node_input_map.deinit();
    var node_output_map = std.AutoHashMap(glib.NodeId, ms.WorldCoord).init(a);
    defer node_output_map.deinit();

    for (graph.nodes.values()) |*node| {
        const gate: *nl.Gate = graph.source.getGate(node.body);

        std.log.debug("Placing gate {d} of kind {any} at position {any}", .{ node.id, gate.kind, pos });
        switch (gate.kind) {
            .and_gate => {
                // create and gate
                const and_gate_blocks = [_]ms.AbsBlock{
                    .{ .block = .block, .rot = .center, .loc = pos },
                };
                blocks.appendSlice(a, &and_gate_blocks) catch @panic("oom");
                // append all coords to forbidden zone to prevent routing through the gate
                for (and_gate_blocks) |block| {
                    forbidden_zone.put(block.loc, void{}) catch @panic("oom");
                }
                node_input_map.put(node.id, pos + ms.WorldCoord{ -2, 0, 0 }) catch @panic("oom");
                node_output_map.put(node.id, pos + ms.WorldCoord{ 2, 0, 0 }) catch @panic("oom");
            },
            .or_gate => {
                // create or gate
                const or_gate_blocks = [_]ms.AbsBlock{
                    .{ .block = .block2, .rot = .center, .loc = pos },
                };
                blocks.appendSlice(a, &or_gate_blocks) catch @panic("oom");
                for (or_gate_blocks) |block| {
                    forbidden_zone.put(block.loc, void{}) catch @panic("oom");
                }
                node_input_map.put(node.id, pos + ms.WorldCoord{ -2, 0, 0 }) catch @panic("oom");
                node_output_map.put(node.id, pos + ms.WorldCoord{ 2, 0, 0 }) catch @panic("oom");
            },
            .inverter => {
                // create inverter
                const or_gate_blocks = [_]ms.AbsBlock{
                    .{ .block = .block2, .rot = .center, .loc = pos },
                    .{ .block = .torch, .rot = .east, .loc = pos + ms.WorldCoord{ 1, 0, 0 } },
                };
                blocks.appendSlice(a, &or_gate_blocks) catch @panic("oom");
                for (or_gate_blocks) |block| {
                    forbidden_zone.put(block.loc, void{}) catch @panic("oom");
                }
                node_input_map.put(node.id, pos + ms.WorldCoord{ -2, 0, 0 }) catch @panic("oom");
                node_output_map.put(node.id, pos + ms.WorldCoord{ 2, 0, 0 }) catch @panic("oom");
            },

            .input => {
                // create input
                const input_blocks = [_]ms.AbsBlock{
                    .{
                        .block = .block,
                        .rot = .center,
                        .loc = pos,
                    },
                    .{
                        .block = .torch,
                        .rot = .center,
                        .loc = pos + ms.WorldCoord{ 0, 1, 0 },
                    },
                };
                blocks.appendSlice(a, &input_blocks) catch @panic("oom");
                for (input_blocks) |block| {
                    forbidden_zone.put(block.loc, void{}) catch @panic("oom");
                }
                node_output_map.put(node.id, pos + ms.WorldCoord{ 2, 0, 0 }) catch @panic("oom");
            },
            .output => {
                // create output
                const output_blocks = [_]ms.AbsBlock{ .{
                    .block = .block2,
                    .rot = .center,
                    .loc = pos,
                }, .{
                    .block = .torch,
                    .rot = .center,
                    .loc = pos + ms.WorldCoord{ 0, 1, 0 },
                } };
                blocks.appendSlice(a, &output_blocks) catch @panic("oom");
                for (output_blocks) |block| {
                    forbidden_zone.put(block.loc, void{}) catch @panic("oom");
                }
                node_input_map.put(node.id, pos + ms.WorldCoord{ -2, 0, 0 }) catch @panic("oom");
            },
        }
        pos += .{ spacing, 0, 0 };
        if (pos[0] >= side_length) {
            pos[0] = 0;
            pos[2] += spacing;
        }
    }

    for (graph.edges.values()) |*edge| {
        const a_output = node_output_map.get(edge.a);
        const b_input = node_input_map.get(edge.b);
        if (a_output == null or b_input == null) {
            std.log.err("Missing input or output for edge {d} between nodes {d} and {d}", .{ edge.id, edge.a, edge.b });
            continue;
        }
        const new_a_output = a_output.?;
        const new_b_input = b_input.?;
        // check if a_output in forbidden zone, if so, move it up by one and add to forbidden zone until we find a free spot
        // var new_a_output = a_output.?;
        // if (forbidden_zone.contains(a_output.?)) {
        //     while (forbidden_zone.contains(new_a_output)) {
        //         new_a_output += ms.WorldCoord{ 1, 0, 1 };
        //     }
        //     node_output_map.put(edge.a, new_a_output) catch @panic("oom");
        // }
        // var new_b_input = b_input.?;
        // if (forbidden_zone.contains(b_input.?)) {
        //     while (forbidden_zone.contains(new_b_input)) {
        //         new_b_input += ms.WorldCoord{ 1, 0, 1 };
        //     }
        //     node_input_map.put(edge.b, new_b_input) catch @panic("oom");
        // }

        std.log.info("Routing between {any} and {any}", .{ new_a_output, new_b_input });
        var route = rt.routeToUpdateForbiddenZone(a, new_a_output, new_b_input, &forbidden_zone) catch |err| {
            std.log.err("Failed to route between {any} and {any}: {any}", .{ new_a_output, b_input.?, err });
            std.log.err("Gate info: {d} of kind {any} at position {any}", .{ edge.a, graph.source.getGate(edge.a).kind, a_output.? });
            if (err == error.PathNotFound) {
                std.log.err("No path found between {any} and {any}", .{ new_a_output, new_b_input });
                continue;
            }
            return err;
        };
        blocks.appendSlice(a, route.route.items) catch @panic("oom");
        route.deinit(a);
    }

    const result = GateStructure{
        .blocks = blocks,
    };

    nbt.abs_block_arr_to_schem(a, blocks.items);
    blocks.deinit(a);

    _ = result; // autofix
}
