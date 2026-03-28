const std = @import("std");
const model = @import("model.zig");

// Validate that the grid is valid.
pub fn validate_grid(S: model.Schematic(model.BasicBlock)) bool {
    const xlen = S.grid.len;
    const ylen = S.grid[0].len;
    const zlen = S.grid[0][0].len;
    for (0..xlen) |x| {
        for (0..ylen) |y| {
            for (0..zlen) |z| {
                // Check that there is a block beneath redstone and repeaters
                switch (S.grid[x][y][z]) {
                    .wire, .repeater_north, .repeater_east, .repeater_south, .repeater_west => {
                        if (y == 0 or S.grid[x][y - 1][z] != .block)
                            return false;
                    },
                    else => {},
                }
                // Check that there is redstone in front of and behind repeaters
                switch (S.grid[x][y][z]) {
                    .repeater_north, .repeater_south => {
                        if (z == 0 or z == zlen - 1 or S.grid[x][y][z - 1] != .wire or S.grid[x][y][z + 1] != .wire)
                            return false;
                    },
                    .repeater_east, .repeater_west => {
                        if (x == 0 or x == xlen - 1 or S.grid[x - 1][y][z] != .wire or S.grid[x + 1][y][z] != .wire)
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
pub fn validate_logical_equivalence(D: model.Netlist, S: model.Schematic(model.BasicBlock), c: model.Placement, gpa: std.mem.Allocator) bool {
    // Check that the chosen instances exist in the schematic
    if (D.instances.len != c.len) return false;
    for (0..c.len) |i| {
        const pos = c[i].pos;
        const schem = c[i].variant;
        const xlen = schem.grid.len;
        const ylen = schem.grid[0].len;
        const zlen = schem.grid[0][0].len;
        for (0..xlen) |x| {
            for (0..ylen) |y| {
                for (0..zlen) |z| {
                    if (schem[x][y][z] != .undef and S.grid[pos[0] + x][pos[1] + y][pos[2] + z] != schem[x][y][z])
                        return false;
                }
            }
        }
    }

    // Obtain positions of all ports
    var connectivity = std.AutoHashMap(model.Port, std.AutoHashMap(model.Port, void));
    var ports = std.AutoHashMap(model.Pos, model.Port).init(gpa);
    for (0..c.len) |i| {
        const pos = c[i].pos;
        for (c[i].variant.inputs, 0..) |ipos, j| {
            const port_pos = .{ pos[0] + ipos[0], pos[1] + ipos[1], pos[2] + ipos[2] };
            try ports.put(port_pos, model.Port{
                .instance = i,
                .direction = .input,
                .port = j,
            });
        }
        for (c[i].variant.outputs, 0..) |ipos, j| {
            const port_pos = .{ pos[0] + ipos[0], pos[1] + ipos[1], pos[2] + ipos[2] };
            const port = model.Port{
                .instance = i,
                .direction = .output,
                .port = j,
            };
            try ports.put(port_pos, port);
            try connectivity.put(port, std.AutoHashMap(model.Port, void).init(gpa));
        }
    }

    // Extract connectivity from D
    for (D.nets) |net| {
        var output_ports = std.ArrayList(model.Port).empty;
        var input_ports = std.ArrayList(model.Port).empty;
        for (net) |port| {
            switch (port.direction) {
                .input => {
                    try input_ports.append(gpa, port);
                },
                .output => {
                    try output_ports.append(gpa, port);
                },
            }
        }
        for (output_ports) |output| {
            const port_conn = connectivity.getPtr(output).?;
            for (input_ports) |input| {
                try port_conn.put(input);
            }
        }
    }

    // Check if every output port is connected as it should be
    var ports_iterator = ports.iterator();
    while (ports_iterator.next()) |entry| {
        const pos = entry.key_ptr;
        const port = entry.value_ptr;
        if (port.direction != .output) continue;
    }

    return true;
}

fn find_connected_ports(start: model.PortPos, S: model.Schematic(model.BasicBlock), ports: std.AutoHashMap(model.Pos, model.Port), gpa: std.mem.Allocator) std.AutoHashMap(model.Port, void) {
    const xlen = S.grid.len;
    const ylen = S.grid[0].len;
    const zlen = S.grid[0][0].len;
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
                if (x > 0 and S.grid[x - 1][y][z] == .wire)
                    Q.append(gpa, .{ .{ x - 1, y, z }, pow - 1 }) catch @panic("cry");
                if (x < xlen - 1 and S.grid[x + 1][y][z] == .wire)
                    Q.append(gpa, .{ .{ x + 1, y, z }, pow - 1 }) catch @panic("cry");
                if (z > 0 and S.grid[x][y][z - 1] == .wire)
                    Q.append(gpa, .{ .{ x, y, z - 1 }, pow - 1 }) catch @panic("cry");
                if (z < zlen - 1 and S.grid[x][y][z + 1] == .wire)
                    Q.append(gpa, .{ .{ x, y, z + 1 }, pow - 1 }) catch @panic("cry");

                // Condition 2 for connectivity
                if (y < ylen - 1 and x > 0 and S.grid[x - 1][y + 1][z] == .wire and S.grid[x][y + 1][z] == .air)
                    Q.append(gpa, .{ .{ x - 1, y + 1, z }, pow - 1 }) catch @panic("cry");
                if (y < ylen - 1 and x < xlen - 1 and S.grid[x + 1][y + 1][z] == .wire and S.grid[x][y + 1][z] == .air)
                    Q.append(gpa, .{ .{ x + 1, y + 1, z }, pow - 1 }) catch @panic("cry");
                if (y < ylen - 1 and z > 0 and S.grid[x][y + 1][z - 1] == .wire and S.grid[x][y + 1][z] == .air)
                    Q.append(gpa, .{ .{ x, y + 1, z - 1 }, pow - 1 }) catch @panic("cry");
                if (y < ylen - 1 and z < zlen - 1 and S.grid[x][y + 1][z + 1] == .wire and S.grid[x][y + 1][z] == .air)
                    Q.append(gpa, .{ .{ x, y + 1, z + 1 }, pow - 1 }) catch @panic("cry");

                // Condition 3 for connectivity
                if (y > 0 and x > 0 and S.grid[x - 1][y - 1][z] == .wire and S.grid[x - 1][y][z] == .air)
                    Q.append(gpa, .{ .{ x - 1, y - 1, z }, pow - 1 }) catch @panic("cry");
                if (y > 0 and x < xlen - 1 and S.grid[x + 1][y - 1][z] == .wire and S.grid[x + 1][y][z] == .air)
                    Q.append(gpa, .{ .{ x + 1, y - 1, z }, pow - 1 }) catch @panic("cry");
                if (y > 0 and z > 0 and S.grid[x][y - 1][z - 1] == .wire and S.grid[x][y][z - 1] == .air)
                    Q.append(gpa, .{ .{ x, y - 1, z - 1 }, pow - 1 }) catch @panic("cry");
                if (y > 0 and z < zlen - 1 and S.grid[x][y - 1][z + 1] == .wire and S.grid[x][y][z + 1] == .air)
                    Q.append(gpa, .{ .{ x, y - 1, z + 1 }, pow - 1 }) catch @panic("cry");

                // Condition 4 for connectivity
                if (x > 0 and S.grid[x - 1][y][z] == .repeater_west)
                    Q.append(gpa, .{ .{ x - 1, y, z }, 16 }) catch @panic("cry");
                if (x < xlen - 1 and S.grid[x + 1][y][z] == .repeater_east)
                    Q.append(gpa, .{ .{ x + 1, y, z }, 16 }) catch @panic("cry");
                if (z > 0 and S.grid[x][y][z - 1] == .repeater_north)
                    Q.append(gpa, .{ .{ x, y, z - 1 }, 16 }) catch @panic("cry");
                if (z < zlen - 1 and S.grid[x][y][z + 1] == .repeater_south)
                    Q.append(gpa, .{ .{ x, y, z + 1 }, 16 }) catch @panic("cry");
            },
            .repeater_north => {
                // Condition 5 for connectivity
                if (z > 0 and S.grid[x][y][z - 1] == .wire)
                    Q.append(gpa, .{ .{ x, y, z - 1 }, 15 }) catch @panic("cry");
            },
            .repeater_east => {
                // Condition 5 for connectivity
                if (x < xlen - 1 and S.grid[x + 1][y][z] == .wire)
                    Q.append(gpa, .{ .{ x + 1, y, z }, 15 }) catch @panic("cry");
            },
            .repeater_south => {
                // Condition 5 for connectivity
                if (z < zlen - 1 and S.grid[x][y][z + 1] == .wire)
                    Q.append(gpa, .{ .{ x, y, z + 1 }, 15 }) catch @panic("cry");
            },
            .repeater_west => {
                // Condition 5 for connectivity
                if (x > 0 and S.grid[x - 1][y][z] == .wire)
                    Q.append(gpa, .{ .{ x - 1, y, z }, 15 }) catch @panic("cry");
            },
            else => {},
        }
    }
}
