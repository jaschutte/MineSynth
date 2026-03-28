const std = @import("std");
const model = @import("../model.zig");

// Validate that the grid is valid.
pub fn validate_grid(S: *const model.Schematic) bool {
    const xlen = S.size[0];
    const ylen = S.size[1];
    const zlen = S.size[2];
    for (0..xlen) |x| {
        for (0..ylen) |y| {
            for (0..zlen) |z| {
                // Check that there is a block beneath redstone and repeaters
                switch (S.get(x, y, z)) {
                    .wire, .repeater_north, .repeater_east, .repeater_south, .repeater_west => {
                        if (y == 0 or S.get(x, y - 1, z) != .block)
                            return false;
                    },
                    else => {},
                }
                // Check that there is redstone in front of and behind repeaters
                switch (S.get(x, y, z)) {
                    .repeater_north, .repeater_south => {
                        if (z == 0 or z == zlen - 1 or S.get(x, y, z - 1) != .wire or S.get(x, y, z + 1) != .wire)
                            return false;
                    },
                    .repeater_east, .repeater_west => {
                        if (x == 0 or x == xlen - 1 or S.get(x - 1, y, z) != .wire or S.get(x + 1, y, z) != .wire)
                            return false;
                    },
                    else => {},
                }
            }
        }
    }
    return true;
}

// Validate logical equivalence between a netlist and a schematic with a placement
pub fn validate_logical_equivalence(D: *const model.Netlist, S: *const model.Schematic, c: *const model.Placement, gpa: std.mem.Allocator) !bool {
    // Check that the chosen instances exist in the schematic
    if (D.instances.len != c.placement.len) return false;
    for (c.placement) |instance| {
        const pos = instance.pos;
        const schem = instance.variant.model;
        const xlen = schem.size[0];
        const ylen = schem.size[1];
        const zlen = schem.size[2];
        for (0..xlen) |x| {
            for (0..ylen) |y| {
                for (0..zlen) |z| {
                    if (schem.get(x, y, z) != .undef and S.get(pos[0] + x, pos[1] + y, pos[2] + z) != schem.get(x, y, z))
                        return false;
                }
            }
        }
    }

    // Obtain positions of all ports
    // TODO: Keep track of the powerlevel, for now we assume 15 at output, 1 at input
    var connectivity = std.AutoHashMap(model.Port, std.AutoHashMap(model.Port, void)).init(gpa);
    var ports = std.AutoHashMap(model.Pos, model.Port).init(gpa);
    for (c.placement, 0..) |instance, i| {
        const pos = instance.pos;
        for (instance.variant.model.inputs, 0..) |ipos, j| {
            const port_pos = .{ pos[0] + ipos.pos[0], pos[1] + ipos.pos[1], pos[2] + ipos.pos[2] };
            try ports.put(port_pos, model.Port{
                .instance = i,
                .direction = .input,
                .port = j,
            });
        }
        for (instance.variant.model.outputs, 0..) |ipos, j| {
            const port_pos = .{ pos[0] + ipos.pos[0], pos[1] + ipos.pos[1], pos[2] + ipos.pos[2] };
            const port = model.Port{
                .instance = i,
                .direction = .output,
                .port = j,
            };
            try ports.put(port_pos, port);
            try connectivity.put(port, std.AutoHashMap(model.Port, void).init(gpa));
        }
    }

    // // Extract connectivity from D
    // for (D.nets) |net| {
    //     var output_ports = std.ArrayList(model.Port).empty;
    //     var input_ports = std.ArrayList(model.Port).empty;
    //     for (net) |port| {
    //         switch (port.direction) {
    //             .input => {
    //                 try input_ports.append(gpa, port);
    //             },
    //             .output => {
    //                 try output_ports.append(gpa, port);
    //             },
    //         }
    //     }
    //     for (output_ports) |output| {
    //         const port_conn = connectivity.getPtr(output).?;
    //         for (input_ports) |input| {
    //             try port_conn.put(input);
    //         }
    //     }
    // }

    // // Check if every output port is connected as it should be
    // var ports_iterator = ports.iterator();
    // while (ports_iterator.next()) |entry| {
    //     const pos = entry.key_ptr;
    //     _ = pos; // autofix
    //     const port = entry.value_ptr;
    //     if (port.direction != .output) continue;
    //     // TODO: Finish
    // }

    return true;
}

// TODO: Finish
pub fn find_connected_ports(start: model.PortPos, S: model.Schematic, ports: std.AutoHashMap(model.Pos, model.Port), gpa: std.mem.Allocator) std.AutoHashMap(model.Port, void) {
    _ = ports; // autofix
    const xlen = S.size[0];
    const ylen = S.size[1];
    const zlen = S.size[2];
    var strength: [xlen][ylen][zlen]u8 = .{.{.{0} ** zlen} ** ylen} ** xlen;
    var Q = std.ArrayList(struct { model.Pos, u8 }).empty;
    try Q.append(gpa, start);
    strength[start.pos[0]][start.pos[1]][start.pos[2]] = start.pow;

    while (Q.items.len > 0) {
        const pos, const pow = Q.pop().?;
        const x, const y, const z = pos;
        if (pow <= 0) continue;
        if (strength[x][y][z] >= pow) continue;
        strength[x][y][z] = pow;

        switch (S.grid[x][y][z]) {
            .wire => {
                // Condition 1 for connectivity
                if (x > 0 and S.get(x - 1, y, z) == .wire)
                    Q.append(gpa, .{ .{ x - 1, y, z }, pow - 1 }) catch @panic("cry");
                if (x < xlen - 1 and S.get(x + 1, y, z) == .wire)
                    Q.append(gpa, .{ .{ x + 1, y, z }, pow - 1 }) catch @panic("cry");
                if (z > 0 and S.get(x, y, z - 1) == .wire)
                    Q.append(gpa, .{ .{ x, y, z - 1 }, pow - 1 }) catch @panic("cry");
                if (z < zlen - 1 and S.get(x, y, z + 1) == .wire)
                    Q.append(gpa, .{ .{ x, y, z + 1 }, pow - 1 }) catch @panic("cry");

                // Condition 2 for connectivity
                if (y < ylen - 1 and x > 0 and S.get(x - 1, y + 1, z) == .wire and S.get(x, y + 1, z) == .air)
                    Q.append(gpa, .{ .{ x - 1, y + 1, z }, pow - 1 }) catch @panic("cry");
                if (y < ylen - 1 and x < xlen - 1 and S.get(x + 1, y + 1, z) == .wire and S.get(x, y + 1, z) == .air)
                    Q.append(gpa, .{ .{ x + 1, y + 1, z }, pow - 1 }) catch @panic("cry");
                if (y < ylen - 1 and z > 0 and S.get(x, y + 1, z - 1) == .wire and S.get(x, y + 1, z) == .air)
                    Q.append(gpa, .{ .{ x, y + 1, z - 1 }, pow - 1 }) catch @panic("cry");
                if (y < ylen - 1 and z < zlen - 1 and S.get(x, y + 1, z + 1) == .wire and S.get(x, y + 1, z) == .air)
                    Q.append(gpa, .{ .{ x, y + 1, z + 1 }, pow - 1 }) catch @panic("cry");

                // Condition 3 for connectivity
                if (y > 0 and x > 0 and S.get(x - 1, y - 1, z) == .wire and S.get(x - 1, y, z) == .air)
                    Q.append(gpa, .{ .{ x - 1, y - 1, z }, pow - 1 }) catch @panic("cry");
                if (y > 0 and x < xlen - 1 and S.get(x + 1, y - 1, z) == .wire and S.get(x + 1, y, z) == .air)
                    Q.append(gpa, .{ .{ x + 1, y - 1, z }, pow - 1 }) catch @panic("cry");
                if (y > 0 and z > 0 and S.get(x, y - 1, z - 1) == .wire and S.get(x, y, z - 1) == .air)
                    Q.append(gpa, .{ .{ x, y - 1, z - 1 }, pow - 1 }) catch @panic("cry");
                if (y > 0 and z < zlen - 1 and S.get(x, y - 1, z + 1) == .wire and S.get(x, y, z + 1) == .air)
                    Q.append(gpa, .{ .{ x, y - 1, z + 1 }, pow - 1 }) catch @panic("cry");

                // Condition 4 for connectivity
                if (x > 0 and S.get(x - 1, y, z) == .repeater_west)
                    Q.append(gpa, .{ .{ x - 1, y, z }, 16 }) catch @panic("cry");
                if (x < xlen - 1 and S.get(x + 1, y, z) == .repeater_east)
                    Q.append(gpa, .{ .{ x + 1, y, z }, 16 }) catch @panic("cry");
                if (z > 0 and S.get(x, y, z - 1) == .repeater_north)
                    Q.append(gpa, .{ .{ x, y, z - 1 }, 16 }) catch @panic("cry");
                if (z < zlen - 1 and S.get(x, y, z + 1) == .repeater_south)
                    Q.append(gpa, .{ .{ x, y, z + 1 }, 16 }) catch @panic("cry");
            },
            .repeater_north => {
                // Condition 5 for connectivity
                if (z > 0 and S.get(x, y, z - 1) == .wire)
                    Q.append(gpa, .{ .{ x, y, z - 1 }, 15 }) catch @panic("cry");
            },
            .repeater_east => {
                // Condition 5 for connectivity
                if (x < xlen - 1 and S.get(x + 1, y, z) == .wire)
                    Q.append(gpa, .{ .{ x + 1, y, z }, 15 }) catch @panic("cry");
            },
            .repeater_south => {
                // Condition 5 for connectivity
                if (z < zlen - 1 and S.get(x, y, z + 1) == .wire)
                    Q.append(gpa, .{ .{ x, y, z + 1 }, 15 }) catch @panic("cry");
            },
            .repeater_west => {
                // Condition 5 for connectivity
                if (x > 0 and S.get(x - 1, y, z) == .wire)
                    Q.append(gpa, .{ .{ x - 1, y, z }, 15 }) catch @panic("cry");
            },
            else => {},
        }
    }
}
