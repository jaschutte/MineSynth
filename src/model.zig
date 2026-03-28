const std = @import("std");
const library = @import("library.zig");

// The block types as in the report
pub const BasicBlock = enum {
    undef,
    predef,
    block,
    air,
    wire,
    repeater_north,
    repeater_east,
    repeater_south,
    repeater_west,
};

// A position in the grid is just three usizes
pub const Pos = @Vector(3, usize);
pub const Size = @Vector(3, usize);
pub const PowerLevel = u8;
pub const Id = usize;
pub const NodeId = Id;
pub const Rect = struct {
    w: usize,
    h: usize,
};

// A port can be an input or output port
pub const PortDirection = enum { input, output };
pub const Port = struct {
    instance: usize, // The index of the instance to which this port belongs
    direction: PortDirection, // Whether this port is an input or output port
    port: usize, // The number of the port on the instance (i.e. 1st or 2nd input)
};

// A net consists of a list of ports
// For simpler implementation in some places, the hyperedges in the netlist as
// described in the report are collapsed to individual edges from output ports
// to input ports. All Net structs with the same `net` value belong to the same net.
pub const Net = struct {
    net: Id, // The id of the net that this edge belongs to
    input: Port, // The input port on this net
    output: Port, // The output port on this net
};

// Placement of a gate in a grid
pub const InstancePlacement = struct {
    pos: Pos,
    variant: library.InstanceVariant,
};
pub const Instance = struct {
    kind: library.InstanceKind,
    symbol: []const u8,
};

// Describes a netlist as in the report
// In the report, a netlist also has inputs and outputs. We ignore these,
// as we replace the inputs and outputs with cells that represent those
// inputs and outputs.
pub const Netlist = struct {
    nets: []Net,
    instances: []Instance,
    lib: library.Library,

    pub fn numInputPorts(self: *const Netlist, node: NodeId) usize {
        var count: usize = 0;
        for (self.nets) |*net| {
            if (net.input.instance == node and net.input.port >= count) {
                count = net.input.port + 1;
            }
        }
        return count;
    }

    pub fn numOutputPorts(self: *const Netlist, node: NodeId) usize {
        var count: usize = 0;
        for (self.nets) |*net| {
            if (net.output.instance == node and net.output.port >= count) {
                count = net.output.port + 1;
            }
        }
        return count;
    }
};

pub const Wire = struct {
    net: Id,
    from: Pos,
    from_power: PowerLevel,
    to: Pos,
    to_power: PowerLevel,
};

pub const PortPos = struct { pos: Pos, pow: u8 };

// Describes a schematic as in the report
// The size is implicit from the grid value.
// All our cells have a port-independent end-to-end delay, so the
// delay is just a single value.
pub const Schematic = struct {
    inputs: []PortPos, // Positions of the inputs
    outputs: []PortPos, // Positions of the outputs
    size: Size, // Size of the grid
    grid: []BasicBlock, // Grid of blocks, indexed with grid[x*size[1]*size[2] + y*size[2] + z]
    delay: usize, // End-to-end delay of the Schematic

    pub fn brect(self: *const Schematic) Rect {
        return Rect{
            .h = self.size[2], // Height is north/south so Z coordinate
            .w = self.size[0], // Width is east/west so X coordinate
        };
    }

    pub inline fn get(self: *const Schematic, x: usize, y: usize, z: usize) BasicBlock {
        return self.grid[x * self.size[1] * self.size[2] + y * self.size[2] + z];
    }

    pub inline fn getPtr(self: *const Schematic, x: usize, y: usize, z: usize) *BasicBlock {
        return &self.grid[x * self.size[1] * self.size[2] + y * self.size[2] + z];
    }
};

// Describes a placement of the instances of a netlist.
// Together with a netlist D, Placement[i] indicates the chosen
// variant and position for instance i in netlist D.
pub const padding: Pos = .{ 5, 10, 5 };

pub const Placement = struct {
    placement: []InstancePlacement,

    pub fn toSchematic(self: *const Placement, gpa: std.mem.Allocator) !Schematic {
        if (self.placement.len == 0) @panic("Must have at least one instance");
        const first = self.placement[0];
        var xmin, var xmax, var ymin, var ymax, var zmin, var zmax = .{
            first.pos[0],
            first.pos[0] + first.variant.model.size[0],
            first.pos[1],
            first.pos[1] + first.variant.model.size[1],
            first.pos[2],
            first.pos[2] + first.variant.model.size[2],
        };

        for (self.placement) |*placement| {
            const pos, const variant = .{ placement.pos, placement.variant.model };
            xmin = @min(xmin, pos[0]);
            xmax = @max(xmax, pos[0] + variant.size[0]);
            ymin = @min(ymin, pos[1]);
            ymax = @max(ymax, pos[1] + variant.size[1]);
            zmin = @min(zmin, pos[2]);
            zmax = @max(zmax, pos[2] + variant.size[2]);
        }

        const xlen = xmax - xmin + 1 + padding[0] * 2;
        const ylen = ymax - ymin + 1 + padding[1] * 2;
        const zlen = zmax - zmin + 1 + padding[2] * 2;

        var grid = std.ArrayList(BasicBlock).empty;
        try grid.appendNTimes(gpa, .undef, xlen * ylen * zlen);

        var ret = Schematic{
            .delay = 0,
            .inputs = &.{},
            .outputs = &.{},
            .size = .{ xlen, ylen, zlen },
            .grid = try grid.toOwnedSlice(gpa),
        };

        for (self.placement) |*placement| {
            const pos, const variant = .{ placement.pos, placement.variant.model };
            for (0..variant.size[0]) |x| {
                for (0..variant.size[1]) |y| {
                    for (0..variant.size[2]) |z| {
                        if (variant.get(x, y, z) != .undef)
                            ret.getPtr(pos[0] + x, pos[1] + y, pos[2] + z).* = variant.get(x, y, z);
                    }
                }
            }
        }

        return ret;
    }

    pub fn getWires(self: *const Placement, gpa: std.mem.Allocator) ![]Wire {
        _ = self; // autofix
        _ = gpa; // autofix
        // TODO: Implement
        return &.{};
    }
};
