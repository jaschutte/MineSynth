const std = @import("std");
const netlist = @import("netlist.zig");
const physical = @import("physical.zig");

// Compute AAT from netlist: Actual Arrival Time.
// The time at which the signal gets to the final gate
pub fn AAT(theNet: netlist.Net) u32 {
    return theNet.tag;
}
