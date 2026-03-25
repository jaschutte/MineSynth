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
pub const Pos = [3]usize;

// A port can be an input or output port
pub const PortDirection = enum { input, output };
pub const Port = struct {
    instance: usize, // The index of the instance to which this port belongs
    direction: PortDirection, // Whether this port is an input or output port
    port: usize, // The number of the port on the instance (i.e. 1st or 2nd input)
};

// A net consists of a list of ports
pub const Net = []Port;

// Type of gate
pub const InstanceKind = enum { and_gate, or_gate, inverter, input, output };
// Possible variants of the gate
// pub const InstanceVariant = enum { north, east, south, west };
// Placement of a gate in a grid
pub const InstancePlacement = struct {
    pos: Pos,
    variant: *Schematic(BasicBlock),
};
pub const Instance = struct {
    kind: InstanceKind,
};

// Describes a netlist as in the report
// In the report, a netlist also has inputs and outputs. We ignore these,
// as we replace the inputs and outputs with cells that represent those
// inputs and outputs.
pub const Netlist = struct {
    nets: []Net,
    instances: []Instance,
};

// Describes a schematic as in the report
// The size is implicit from the grid value.
// All our cells have a port-independent end-to-end delay, so the
// delay is just a single value.
pub fn Schematic(comptime Block: type) type {
    return struct {
        inputs: []Pos, // Positions of the inputs
        outputs: []Pos, // Positions of the outputs
        grid: [][][]Block, // Grid of blocks, indexed with grid[x][y][z]
        delay: usize, // End-to-end delay of the schematic
    };
}

// Describes a placement of the instances of a netlist.
// Together with a netlist D, Placement[i] indicates the chosen
// variant and position for instance i in netlist D.
pub const Placement = []InstancePlacement;
