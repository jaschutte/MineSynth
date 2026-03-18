const std = @import("std");
const glib = @import("abstract/graph.zig");
const Graph = glib.GateGraph;

const Orientation = enum {
    North,
    East,
    South,
    West,
};

const Position = struct { x: i64, y: i64, orientation: Orientation };

const Placement = struct { locations: std.AutoArrayHashMap(glib.NodeId, Position),

    pub fn clone(self: *const Placement, allocator: std.mem.Allocator) !Placement {
        return Placement{
            .vars = try self.vars.clone(allocator),
        };
    }
};

fn absolutePosition(position: *Position, port: @Vector(3, i64)) @Vector(2, u32)
{
    // do not allow rotations for now
    return @Vector(2, i64){position.x + port[0], position.y + port[2]};
}

fn initialPlacement(the_graph: *Graph) *Placement {}

// computes the cost of the given placement
fn cost(the_placement: *Placement) f64 {
    return costWireLength(the_placement);
}

// prioritize usage of horizontal wiring by punishing large y deviations more
const x_weight: f64 = 1;
const y_weight: f64 = 2;
const wire_cost_weight: f64 = 1;

fn costWireLength(the_graph: *Graph, the_placement: *Placement) f64 {
    var sum: f64 = 0;
    for (the_graph.edges.values()) |net| {
        const pos_a = the_placement.get(net.a) orelse {
            std.debug.print("node 'net.a' not placed\n", .{});
            continue;
        };
        const pos_b = the_placement.get(net.b) orelse {
            std.debug.print("node 'net.b' not placed\n", .{});
            continue;
        };

        const node_a = the_graph.getConstNode(net.a).?;
        const node_b = the_graph.getConstNode(net.b).?;
        // lets just assume we always connect to the first input for now...
        var port_a = node_a.body.kind.inputPositionsRelative()[0];
        var port_b = node_b.body.kind.outputPositionsRelative();
        if (net.a_relation == .output) {
            port_a = node_a.body.kind.outputPositionsRelative();
            port_b = node_b.body.kind.inputPositionsRelative()[0];
        }
        const port_pos_a = absolutePosition(pos_a,port_a);
        const port_pos_b = absolutePosition(pos_b,port_b);

        const net_width = @abs(port_pos_a[0] - port_pos_b[0]) ; // x
        const net_height = @abs(port_pos_a[1] - port_pos_b[1]); // y

        sum = sum + net_width*x_weight + net_height*y_weight;
    }

    return wire_cost_weight * sum;
}

fn costRowLength(the_placement: *Placement) f64 {
    return 0;
}

fn costOverlap(the_placement: *Placement) f64 {
    return 0;
}

fn move(the_placement: *Placement)void{

}

fn swap(the_placement: *Placement)void{
    
}



// randomly perturbs the placement
fn perturb(the_graph: *Graph, the_placement: *Placement) *Placement {
    var new_placement = the_placement.clone(the_graph.gpa);

    return new_placement;
}

// returns whether to stop the placement algorithm
fn stop() bool {}

// assigns a position to each cell in the graph, using the annealing placement algorithm.
pub fn placement_annealing(the_graph: *Graph, initial_temperature: i64, minimum_temperature: i64) void {
    const current_placement = initialPlacement(the_graph);
    defer _ = current_placement.deinit();
    var temperature = initial_temperature;

    // get random generator:
    var seed: u64 = undefined;
    std.posix.getrandom(std.mem.asBytes(&seed)) catch |err| {
        std.debug.print("Failed to get random seed: {}\n", .{err});
        return;
    };
    const prng = std.rand.DefaultPrng.init(seed);
    const rand = prng.random();

    // should be in (0,1)
    // should be a lower value at the start and end of the simulation, and a higher value in the middle, during refining.
    // it is constant for now.
    const alpha = 0.95;

    while (temperature > minimum_temperature) {
        while (!stop()) {
            const new_placement = perturb(current_placement);
            const cost_diff = cost(new_placement) - cost(current_placement);
            if (cost_diff < 0) {
                current_placement.deinit();
                current_placement = new_placement;
            } else {
                const value = rand.float(f32);
                // compute e^(-Δcost/T):
                const exponent = (-cost_diff / temperature);
                if (value < std.math.exp(exponent)) {
                    current_placement.deinit();
                    current_placement = new_placement;
                } else {
                    new_placement.deinit();
                }
            }
        } // exit loop if in equilibrium at this temperature
        temperature *= alpha;
    }
}

// pseudo code:

// Simulated Annealing Algorithm for Placement
// Input: set of all cells V
// Output: placement P
// 1 T=T0
// 2 P=PLACE(V)
// 3 while(T>Tmin)
// 4 while(!STOP())
// new_P =PERTURB(P)
// Δcost =COST(new_P)–COST(P)
// if (Δcost <0)
// P =new_P
// else
// r =RANDOM(0,1)
// 11 if(r<e^(-Δcost/T))
// P =new_P
// T=α∙T
