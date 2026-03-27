const std = @import("std");
const glib = @import("../graph/graph.zig");
const model = @import("../model.zig");

pub fn convertGraphToModel(gpa: std.mem.Allocator, graph: *const glib.Graph(glib.GateBody)) !model.Netlist {
    _ = graph;

    var instances: std.ArrayList(model.Instance) = .empty;

    var nets: std.ArrayList(model.Net) = .empty;

    return .{
        .instances = try instances.toOwnedSlice(gpa),
        .nets = try nets.toOwnedSlice(gpa),
    };
}
