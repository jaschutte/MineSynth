const std = @import("std");
const glib = @import("abstract/graph.zig");
const Graph = glib.GateGraph;

const Position = struct { x: f64, y: f64 };

const Placement = struct { locations: std.AutoArrayHashMap(glib.NodeId, Position) };

fn initialPlacement(the_graph: *Graph) *Placement {}

// computes the cost of the given placement
fn cost(the_Placement: *Placement) f64 {
    return costWireLength(the_Placement) + costRowLength(the_Placement) + costOverlap(the_Placement);
}

fn costWireLength(the_Placement: *Placement) f64 {}

fn costRowLength(the_Placement: *Placement) f64 {}

fn costOverlap(the_Placement: *Placement) f64 {}

// randomly perturbs the placement
fn perturb(the_Placement: *Placement) *Placement {}

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
                const exponent = (-cost_diff/temperature);
                if (value < std.math.exp(exponent)) {
                    current_placement.deinit();
                    current_placement = new_placement;
                }
                else {
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
