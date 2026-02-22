const std = @import("std");
const partitioning = @import("partitioning.zig");

// https://www.graphvisualizer.com/editor

const Vertex = struct {
    id: usize,
    x: usize,
    y: usize,
    label: []const u8,
    size: usize,
    color: []const u8,
    borderColor: []const u8,
    borderThickness: usize,
    fontSize: usize,
    labelSize: usize,
    fontFamily: []const u8,
    fontColor: []const u8,
    shape: []const u8,

    fn new_left(gpa: std.mem.Allocator, id: usize, gate_id: usize) Vertex {
        return Vertex {
            .id = id,
            .x = 100,
            .y = 30 + id * 80,
            .label = std.fmt.allocPrint(gpa, "gate.{}", .{gate_id}) catch "OOM",
            .size = 25,
            .color = "#0088dd",
            .borderColor = "#000000",
            .borderThickness = 0,
            .fontSize = 14,
            .labelSize = 14,
            .fontFamily = "Inter, sans-serif",
            .fontColor = "#ffffff",
            .shape = "circle",
        };
    }

    fn new_right(gpa: std.mem.Allocator, id: usize, gate_id: usize) Vertex {
        return Vertex {
            .id = id,
            .x = 500,
            .y = 30 + id * 80,
            .label = std.fmt.allocPrint(gpa, "gate.{}", .{gate_id}) catch "OOM",
            .size = 25,
            .color = "#00ee66",
            .borderColor = "#000000",
            .borderThickness = 0,
            .fontSize = 14,
            .labelSize = 14,
            .fontFamily = "Inter, sans-serif",
            .fontColor = "#ffffff",
            .shape = "circle",
        };
    }
};

const Edge = struct {
    from: usize,
    to: usize,
    weight: usize,
    @"type": []const u8,
    direction: []const u8,
    style: []const u8,
    lineStyle: []const u8,

    fn new_edge(from: usize, to: usize) Edge {
        return Edge {
            .from = from,
            .to = to,
            .type = "straight",
            .weight = 1,
            .direction = "undirected",
            .style = "straight",
            .lineStyle = "solid",
        };
    }
};

const FinalJson = struct {
    vertices: []Vertex,
    edges: []Edge,
    nextVertexId: usize,
    vertexSize: usize,
    edgeType: []const u8,
    edgeDirection: []const u8,
    theme: []const u8,
    vertexColor: []const u8,
    vertexBorderColor: []const u8,
    vertexFontSize: usize,
    vertexLabelSize: usize,
    vertexFontFamily: []const u8,
    vertexFontColor: []const u8,
    edgeColor: []const u8,
    edgeWidth: usize,
    edgeFontSize: usize,
    edgeFontFamily: []const u8,
    edgeFontColor: []const u8,
};

pub fn node_visualizer(gpa: std.mem.Allocator, module: *const partitioning.Module, part: *const partitioning.Partition) !void {
    var vertices = std.ArrayList(Vertex).empty;
    var edges = std.ArrayList(Edge).empty;

    var mapper = std.AutoArrayHashMap(*partitioning.Node, usize).init(gpa);

    var key_iter = part.data.left.keyIterator();
    while (key_iter.next()) |node| {
        try vertices.append(gpa, Vertex.new_left(gpa, vertices.items.len, node.*.content.gate));
        try mapper.put(node.*, vertices.items.len - 1);
    }
    key_iter = part.data.right.keyIterator();
    while (key_iter.next()) |node| {
        try vertices.append(gpa, Vertex.new_right(gpa, vertices.items.len, node.*.content.gate));
        try mapper.put(node.*, vertices.items.len - 1);
    }

    for (module.raw_edges.items) |edge| {
        for (edge) |a| {
            for (edge) |b| {
                if (a != b) {
                    try edges.append(gpa, Edge.new_edge(
                        mapper.get(a).?,
                        mapper.get(b).?,
                    ));
                }
            }
        }
    }

    const json_obj = FinalJson {
        .vertices = try vertices.toOwnedSlice(gpa),
        .edges = try edges.toOwnedSlice(gpa),
        .nextVertexId = std.math.maxInt(usize) - 10,
        .vertexSize = 25,
        .edgeType = "straight",
        .edgeDirection = "undirected",
        .theme = "dark",
        .vertexColor = "#1f2937",
        .vertexBorderColor = "#111827",
        .vertexFontSize = 14,
        .vertexLabelSize = 14,
        .vertexFontFamily = "Inter, sans-serif",
        .vertexFontColor = "#ffffff",
        .edgeColor = "#6b7280",
        .edgeWidth = 0,
        .edgeFontSize = 12,
        .edgeFontFamily = "Inter, sans-serif",
        .edgeFontColor = "#374151"
    };

    std.debug.print("\nJSON: {f}\n", .{
        std.json.fmt(json_obj, .{})
    });

    gpa.free(json_obj.edges);
    gpa.free(json_obj.vertices);
}
