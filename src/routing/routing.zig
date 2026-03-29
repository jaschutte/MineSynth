const std = @import("std");
const model = @import("../model.zig");
const Wire = model.Wire;
const Schematic = model.Schematic;
const Pos = model.Pos;
const PowerLevel = model.PowerLevel;
const BasicBlock = model.BasicBlock;

const MoveType = enum {
    up,
    flat,
    down,
    repeater,
};
const MoveDir = enum {
    north, // -Z
    east, // +X
    south, // +Z
    west, // -X

    inline fn posDir(self: MoveDir, pos: Pos) Pos {
        return switch (self) {
            .north => .{ pos[0], pos[1], pos[2] - 1 },
            .east => .{ pos[0] + 1, pos[1], pos[2] },
            .south => .{ pos[0], pos[1], pos[2] + 1 },
            .west => .{ pos[0] - 1, pos[1], pos[2] },
        };
    }
};
const Move = struct {
    type: MoveType,
    dir: MoveDir,

    inline fn nextPos(self: Move, pos: Pos) Pos {
        return switch (self.type) {
            .up => posAbove(self.dir.posDir(pos)),
            .flat => self.dir.posDir(pos),
            .down => posBelow(self.dir.posDir(pos)),
            .repeater => self.dir.posDir(pos),
        };
    }

    inline fn block(self: Move) BasicBlock {
        return switch (self.type) {
            .repeater => switch (self.dir) {
                .north => .repeater_north,
                .east => .repeater_east,
                .south => .repeater_south,
                .west => .repeater_west,
            },
            else => .wire,
        };
    }
};
const MoveNode = struct {
    from: usize, // Previous path node
    pos: Pos, // End position of path
    pow: PowerLevel, // Power level at position
    move: Move, // Type of move performed
    cost: f32, // Cost of path so far in ticks
};

const first_from = std.math.maxInt(usize);

const QueueNode = struct {
    cost: f32, // Actual cost + heuristic cost
    move: usize, // Index of the move referenced
};

const unowned = std.math.maxInt(usize);
const BlockOwner = []usize;

const dangerous_blocks = [_]@Vector(3, isize){
    .{ 0, -1, 0 },
    // .{ 0, 0, 0 },
    .{ 0, 1, 0 },
    .{ 1, -1, 0 },
    .{ 1, 0, 0 },
    .{ 1, 1, 0 },
    .{ -1, -1, 0 },
    .{ -1, 0, 0 },
    .{ -1, 1, 0 },
    .{ 0, -1, 1 },
    .{ 0, 0, 1 },
    .{ 0, 1, 1 },
    .{ 0, -1, -1 },
    .{ 0, 0, -1 },
    .{ 0, 1, -1 },
};

fn compareQueueNode(_: void, a: QueueNode, b: QueueNode) std.math.Order {
    return std.math.order(a.cost, b.cost);
}

// TODO: Check that we do not form loops
fn checkPath(start: usize, moves: []MoveNode) bool {
    const spos = moves[start].pos;
    var curr = start;
    while (moves[curr].from != first_from) {
        const cpos = moves[curr].pos;
        if (cpos == spos or cpos == .{ spos[0], spos[1] - 1, spos[2] } or cpos == .{ spos[0], spos[1] - 2, spos[2] })
            return false;
        curr = moves[curr].from;
    }
}

inline fn canGoDir(move: Move, dir: MoveDir) bool {
    return switch (move.type) {
        .repeater => move.dir == dir,
        else => true,
    };
}

inline fn canGoVert(move: Move) bool {
    return switch (move.type) {
        .repeater => false,
        else => true,
    };
}

const search_nodes: usize = 8 * 100000;
const distance_cost: f32 = 0.65;
const vertical_cost: f32 = 0.005;
const repeater_cost: f32 = 0.01;

const default_violation_cost: f32 = 1.1;
const violation_cost_decrement: f32 = 0.22;

inline fn heuristic(from: Pos, to: Pos) f32 {
    const dx = @max(from[0], to[0]) - @min(from[0], to[0]);
    // const dy = @max(from[1], to[1]) - @min(from[1], to[1]);
    const dz = @max(from[2], to[2]) - @min(from[2], to[2]);
    const h = @as(f32, @floatFromInt(dx + dz));
    return h;
}

var moveStore = std.ArrayList(MoveNode).empty;
var Q: std.PriorityQueue(QueueNode, void, compareQueueNode) = undefined;

inline fn posIdx(pos: Pos, size: Pos) usize {
    return pos[0] * size[1] * size[2] + pos[1] * size[2] + pos[2];
}

fn routeSingleRoute(wire: *const Wire, S: *const Schematic, O: *const BlockOwner, comptime violate: bool, violation_cost: f32, gpa: std.mem.Allocator) !?struct { []Move } {
    const from = wire.from;
    const to = wire.to;
    const net = wire.net;

    const size = S.size;

    var move_counter: usize = 1;
    moveStore.clearRetainingCapacity();
    try moveStore.append(gpa, .{
        .cost = 0,
        .from = std.math.maxInt(usize),
        .pos = from,
        .pow = 15,
        .move = .{ .dir = .north, .type = .flat }, // Default initial move, does not actually get used
    });

    // Initialize queue
    // var Q = std.PriorityQueue(QueueNode, void, compareQueueNode).init(gpa, undefined);
    Q.clearRetainingCapacity();
    try Q.add(.{
        .cost = heuristic(from, to),
        .move = 0,
    });

    // var visited = std.ArrayList(bool).empty;
    // try visited.appendNTimes(gpa, false, S.size[0] * S.size[1] * S.size[2]);

    var counter: usize = 0;

    outer: while (Q.removeOrNull()) |next| {
        counter += 1;
        if (counter > search_nodes) {
            std.debug.print("Routing took too long\n", .{});
            break;
        }

        const move = moveStore.items[next.move];
        const pos = move.pos;
        const pow = move.pow;
        var cost = move.cost;

        const above = posAbove(pos);
        const below = posBelow(pos);

        const pos_idx = posIdx(pos, size);
        const above_idx = posIdx(above, size);
        const below_idx = posIdx(below, size);

        // Check that we do not intersect anything
        // if (S.getPos(above) == .predef) continue;
        // if (S.getPos(pos) == .predef) continue;
        // if (S.getPos(below) == .predef) continue;
        if (O.*[above_idx] != net and S.getPos(above) != .undef) continue;
        if (O.*[pos_idx] != net and S.getPos(pos) != .undef) continue;
        if (O.*[below_idx] != net and S.getPos(below) != .undef) continue;

        // Check that the path will not override a previous path on the same net
        // if (O.*[posIdx(above, size)] == net and S.getPos(above) != .air) continue;
        if (move.from != first_from and O.*[pos_idx] == net and S.getPos(pos) != moveStore.items[move.from].move.block()) continue;
        if (O.*[below_idx] == net and S.getPos(below) != .block) continue;

        // A bit overly strict, but we disallow being next to the border, to prevent edge cases
        if (pos[0] <= 0 or
            pos[1] <= 0 or
            pos[2] <= 0 or
            pos[0] >= S.size[0] - 1 or
            pos[1] >= S.size[1] - 1 or
            pos[2] >= S.size[2] - 1) continue;

        // No backtracking
        if (move.from != first_from) {
            const prev_move = moveStore.items[move.from];
            if (prev_move.move.dir == .north and move.move.dir == .south) continue;
            if (prev_move.move.dir == .east and move.move.dir == .west) continue;
            if (prev_move.move.dir == .south and move.move.dir == .north) continue;
            if (prev_move.move.dir == .west and move.move.dir == .east) continue;
        }

        // Check that there will not be any shorts with committed routes
        for (dangerous_blocks) |offset| {
            const i_pos = @as(@Vector(3, isize), @intCast(pos));
            const n_pos = @as(Pos, @intCast(i_pos + offset));
            const owner = O.*[n_pos[0] * S.size[1] * S.size[2] + n_pos[1] * S.size[2] + n_pos[2]];
            if (S.getPos(n_pos) != .wire) continue;
            if (owner == unowned) continue;
            if (!violate) {
                if (owner != net) continue :outer;
                // if (owner == net and !std.meta.eql(n_pos, moveStore.items[move.from].pos)) continue :outer;
            } else {
                // TODO: Do not allow violations of ports, as they are fixed
                if (owner != net) {
                    cost += violation_cost;
                    break; // To ensure violation_cost is only applied once
                }
            }
        }

        // Check if we have arrived
        if (std.meta.eql(to, pos)) {
            // Check that we did not end with a repeater
            if (move.move.type == .repeater) continue;

            var moves = std.ArrayList(Move).empty;
            var curr = next.move;
            while (curr != first_from) {
                try moves.append(gpa, moveStore.items[curr].move);
                curr = moveStore.items[curr].from;
            }
            return .{try moves.toOwnedSlice(gpa)};
        }

        // North (-Z)
        if (pos[2] > 0 and canGoDir(move.move, .north)) {
            // Horizontal dust
            if (pow > 1) {
                const next_move = Move{ .dir = .north, .type = .flat };
                const next_pos = next_move.nextPos(pos);
                const next_cost = cost + distance_cost;
                try moveStore.append(gpa, .{
                    .from = next.move,
                    .cost = next_cost,
                    .move = next_move,
                    .pos = next_pos,
                    .pow = pow - 1,
                });
                try Q.add(.{ .cost = next_cost + heuristic(next_pos, to), .move = move_counter });
                move_counter += 1;
            }

            // Go up
            if (pow > 1 and pos[1] < S.size[1] - 1 and canGoVert(move.move)) {
                const next_move = Move{ .dir = .north, .type = .up };
                const next_pos = next_move.nextPos(pos);
                const next_cost = cost + distance_cost + vertical_cost;
                try moveStore.append(gpa, .{
                    .from = next.move,
                    .cost = next_cost,
                    .move = next_move,
                    .pos = next_pos,
                    .pow = pow - 1,
                });
                try Q.add(.{ .cost = next_cost + heuristic(next_pos, to), .move = move_counter });
                move_counter += 1;
            }

            // Go down
            if (pow > 1 and pos[1] > 1 and canGoVert(move.move)) {
                const next_move = Move{ .dir = .north, .type = .down };
                const next_pos = next_move.nextPos(pos);
                const next_cost = cost + distance_cost + vertical_cost;
                try moveStore.append(gpa, .{
                    .from = next.move,
                    .cost = next_cost,
                    .move = next_move,
                    .pos = next_pos,
                    .pow = pow - 1,
                });
                try Q.add(.{ .cost = next_cost + heuristic(next_pos, to), .move = move_counter });
                move_counter += 1;
            }

            // Repeater
            if (pow >= 1) {
                const next_move = Move{ .dir = .north, .type = .repeater };
                const next_pos = next_move.nextPos(pos);
                const next_cost = cost + repeater_cost + distance_cost;
                try moveStore.append(gpa, .{
                    .from = next.move,
                    .cost = next_cost,
                    .move = next_move,
                    .pos = next_pos,
                    .pow = 16,
                });
                try Q.add(.{ .cost = next_cost + heuristic(next_pos, to), .move = move_counter });
                move_counter += 1;
            }
        }

        // East (+X)
        if (pos[0] < S.size[0] - 1 and canGoDir(move.move, .east)) {
            // Horizontal dust
            if (pow > 1) {
                const next_move = Move{ .dir = .east, .type = .flat };
                const next_pos = next_move.nextPos(pos);
                const next_cost = cost + distance_cost;
                try moveStore.append(gpa, .{
                    .from = next.move,
                    .cost = next_cost,
                    .move = next_move,
                    .pos = next_pos,
                    .pow = pow - 1,
                });
                try Q.add(.{ .cost = next_cost + heuristic(next_pos, to), .move = move_counter });
                move_counter += 1;
            }

            // Go up
            if (pow > 1 and pos[1] < S.size[1] - 1 and canGoVert(move.move)) {
                const next_move = Move{ .dir = .east, .type = .up };
                const next_pos = next_move.nextPos(pos);
                const next_cost = cost + distance_cost + vertical_cost;
                try moveStore.append(gpa, .{
                    .from = next.move,
                    .cost = next_cost,
                    .move = next_move,
                    .pos = next_pos,
                    .pow = pow - 1,
                });
                try Q.add(.{ .cost = next_cost + heuristic(next_pos, to), .move = move_counter });
                move_counter += 1;
            }

            // Go down
            if (pow > 1 and pos[1] > 1 and canGoVert(move.move)) {
                const next_move = Move{ .dir = .east, .type = .down };
                const next_pos = next_move.nextPos(pos);
                const next_cost = cost + distance_cost + vertical_cost;
                try moveStore.append(gpa, .{
                    .from = next.move,
                    .cost = next_cost,
                    .move = next_move,
                    .pos = next_pos,
                    .pow = pow - 1,
                });
                try Q.add(.{ .cost = next_cost + heuristic(next_pos, to), .move = move_counter });
                move_counter += 1;
            }

            // Repeater
            if (pow >= 1) {
                const next_move = Move{ .dir = .east, .type = .repeater };
                const next_pos = next_move.nextPos(pos);
                const next_cost = cost + repeater_cost + distance_cost;
                try moveStore.append(gpa, .{
                    .from = next.move,
                    .cost = next_cost,
                    .move = next_move,
                    .pos = next_pos,
                    .pow = 16,
                });
                try Q.add(.{ .cost = next_cost + heuristic(next_pos, to), .move = move_counter });
                move_counter += 1;
            }
        }

        // South (+Z)
        if (pos[2] < S.size[2] - 1 and canGoDir(move.move, .south)) {
            // Horizontal dust
            if (pow > 1) {
                const next_move = Move{ .dir = .south, .type = .flat };
                const next_pos = next_move.nextPos(pos);
                const next_cost = cost + distance_cost;
                try moveStore.append(gpa, .{
                    .from = next.move,
                    .cost = next_cost,
                    .move = next_move,
                    .pos = next_pos,
                    .pow = pow - 1,
                });
                try Q.add(.{ .cost = next_cost + heuristic(next_pos, to), .move = move_counter });
                move_counter += 1;
            }

            // Go up
            if (pow > 1 and pos[1] < S.size[1] - 1 and canGoVert(move.move)) {
                const next_move = Move{ .dir = .south, .type = .up };
                const next_pos = next_move.nextPos(pos);
                const next_cost = cost + distance_cost + vertical_cost;
                try moveStore.append(gpa, .{
                    .from = next.move,
                    .cost = next_cost,
                    .move = next_move,
                    .pos = next_pos,
                    .pow = pow - 1,
                });
                try Q.add(.{ .cost = next_cost + heuristic(next_pos, to), .move = move_counter });
                move_counter += 1;
            }

            // Go down
            if (pow > 1 and pos[1] > 1 and canGoVert(move.move)) {
                const next_move = Move{ .dir = .south, .type = .down };
                const next_pos = next_move.nextPos(pos);
                const next_cost = cost + distance_cost + vertical_cost;
                try moveStore.append(gpa, .{
                    .from = next.move,
                    .cost = next_cost,
                    .move = next_move,
                    .pos = next_pos,
                    .pow = pow - 1,
                });
                try Q.add(.{ .cost = next_cost + heuristic(next_pos, to), .move = move_counter });
                move_counter += 1;
            }

            // Repeater
            if (pow >= 1) {
                const next_move = Move{ .dir = .south, .type = .repeater };
                const next_pos = next_move.nextPos(pos);
                const next_cost = cost + repeater_cost + distance_cost;
                try moveStore.append(gpa, .{
                    .from = next.move,
                    .cost = next_cost,
                    .move = next_move,
                    .pos = next_pos,
                    .pow = 16,
                });
                try Q.add(.{ .cost = next_cost + heuristic(next_pos, to), .move = move_counter });
                move_counter += 1;
            }
        }

        // West (-X)
        if (pos[0] > 0 and canGoDir(move.move, .west)) {
            // Horizontal dust
            if (pow > 1) {
                const next_move = Move{ .dir = .west, .type = .flat };
                const next_pos = next_move.nextPos(pos);
                const next_cost = cost + distance_cost;
                try moveStore.append(gpa, .{
                    .from = next.move,
                    .cost = next_cost,
                    .move = next_move,
                    .pos = next_pos,
                    .pow = pow - 1,
                });
                try Q.add(.{ .cost = next_cost + heuristic(next_pos, to), .move = move_counter });
                move_counter += 1;
            }

            // Go up
            if (pow > 1 and pos[1] < S.size[1] - 1 and canGoVert(move.move)) {
                const next_move = Move{ .dir = .west, .type = .up };
                const next_pos = next_move.nextPos(pos);
                const next_cost = cost + distance_cost + vertical_cost;
                try moveStore.append(gpa, .{
                    .from = next.move,
                    .cost = next_cost,
                    .move = next_move,
                    .pos = next_pos,
                    .pow = pow - 1,
                });
                try Q.add(.{ .cost = next_cost + heuristic(next_pos, to), .move = move_counter });
                move_counter += 1;
            }

            // Go down
            if (pow > 1 and pos[1] > 1 and canGoVert(move.move)) {
                const next_move = Move{ .dir = .west, .type = .down };
                const next_pos = next_move.nextPos(pos);
                const next_cost = cost + distance_cost + vertical_cost;
                try moveStore.append(gpa, .{
                    .from = next.move,
                    .cost = next_cost,
                    .move = next_move,
                    .pos = next_pos,
                    .pow = pow - 1,
                });
                try Q.add(.{ .cost = next_cost + heuristic(next_pos, to), .move = move_counter });
                move_counter += 1;
            }

            // Repeater
            if (pow >= 1) {
                const next_move = Move{ .dir = .west, .type = .repeater };
                const next_pos = next_move.nextPos(pos);
                const next_cost = cost + repeater_cost + distance_cost;
                try moveStore.append(gpa, .{
                    .from = next.move,
                    .cost = next_cost,
                    .move = next_move,
                    .pos = next_pos,
                    .pow = 16,
                });
                try Q.add(.{ .cost = next_cost + heuristic(next_pos, to), .move = move_counter });
                move_counter += 1;
            }
        }
    }

    std.debug.print("Routing failed\n", .{});
    return null;
}

fn cloneSchematic(S: *const Schematic, gpa: std.mem.Allocator) !Schematic {
    var grid = try std.ArrayList(BasicBlock).fromOwnedSlice(S.grid).clone(gpa);
    return .{
        .delay = S.delay,
        .inputs = &.{},
        .outputs = &.{},
        .size = S.size,
        .grid = try grid.toOwnedSlice(gpa),
    };
}

inline fn posBelow(pos: Pos) Pos {
    return .{ pos[0], pos[1] - 1, pos[2] };
}
inline fn posAbove(pos: Pos) Pos {
    return .{ pos[0], pos[1] + 1, pos[2] };
}

// Applies the route in the ownership grid and schematic grid
// If any violations are encountered, they are overwritten and the violating nets are returned
fn applyRoute(wire: *const Wire, S: *Schematic, O: *std.ArrayList(usize), moves_rev: []Move, gpa: std.mem.Allocator) ![]usize {
    var curr = wire.from;
    O.items[curr[0] * S.size[1] * S.size[2] + curr[1] * S.size[2] + curr[2]] = wire.net;
    O.items[curr[0] * S.size[1] * S.size[2] + (curr[1] - 1) * S.size[2] + curr[2]] = wire.net;
    O.items[curr[0] * S.size[1] * S.size[2] + (curr[1] + 1) * S.size[2] + curr[2]] = wire.net;
    S.getPosPtr(curr).* = .wire;
    S.getPosPtr(posBelow(curr)).* = .block;
    S.getPosPtr(posAbove(curr)).* = .air;
    // std.debug.print("Applying route for {}\n", .{wire});

    var violations = std.AutoArrayHashMap(usize, void).init(gpa);
    for (0..moves_rev.len) |i| {
        if (i == 0) continue; // Skip initial (undefined) move
        const move = moves_rev[moves_rev.len - 1 - i];
        // std.debug.print("Move {}: {}\n", .{ i, move });
        curr = move.nextPos(curr);

        const pos_idx = curr[0] * S.size[1] * S.size[2] + curr[1] * S.size[2] + curr[2];
        const below_pos_idx = pos_idx - S.size[2];
        const above_pos_idx = pos_idx + S.size[2];

        // Test for violations
        if (O.items[pos_idx] != unowned and O.items[pos_idx] != wire.net)
            try violations.put(O.items[pos_idx], undefined);
        if (O.items[below_pos_idx] != unowned and O.items[below_pos_idx] != wire.net)
            try violations.put(O.items[below_pos_idx], undefined);
        if (O.items[above_pos_idx] != unowned and O.items[above_pos_idx] != wire.net)
            try violations.put(O.items[above_pos_idx], undefined);
        for (dangerous_blocks) |offset| {
            const i_pos = @as(@Vector(3, isize), @intCast(curr));
            const n_pos = @as(Pos, @intCast(i_pos + offset));
            const owner = O.items[n_pos[0] * S.size[1] * S.size[2] + n_pos[1] * S.size[2] + n_pos[2]];
            if (owner != unowned and owner != wire.net and S.getPos(n_pos) == .wire)
                try violations.put(owner, undefined);
        }

        // Apply move to grids
        O.items[pos_idx] = wire.net;
        O.items[below_pos_idx] = wire.net;
        S.getPosPtr(curr).* = move.block();
        S.getPosPtr(posBelow(curr)).* = .block;
        if ((i + 2 <= moves_rev.len and moves_rev[moves_rev.len - i - 2].type == .up) or moves_rev[moves_rev.len - i - 1].type == .down) {
            S.getPosPtr(posAbove(curr)).* = .air;
            O.items[above_pos_idx] = wire.net;
        }
    }
    return violations.keys();
}

fn ripUp(net: usize, S: *Schematic, O: *std.ArrayList(usize)) void {
    for (0..S.size[0]) |x| {
        for (0..S.size[1]) |y| {
            for (0..S.size[2]) |z| {
                const idx = x * S.size[1] * S.size[2] + y * S.size[2] + z;
                if (O.items[idx] == net) {
                    O.items[idx] = unowned;
                    S.getPtr(x, y, z).* = .undef;
                    // S.getPtr(x, y - 1, z).* = .undef;
                }
            }
        }
    }
}

fn compareWire(_: usize, a: Wire, b: Wire) bool {
    return heuristic(a.from, a.to) > heuristic(b.from, b.to);
}

fn setPortOwnership(S: *Schematic, O: *std.ArrayList(usize), wires: *const []Wire, size: Pos) void {
    for (wires.*) |wire| {
        const fp1 = wire.from;
        const fp2 = posBelow(fp1);
        const fp3 = posAbove(fp1);
        O.items[fp1[0] * size[1] * size[2] + fp1[1] * size[2] + fp1[2]] = wire.net;
        O.items[fp2[0] * size[1] * size[2] + fp2[1] * size[2] + fp2[2]] = wire.net;
        O.items[fp3[0] * size[1] * size[2] + fp3[1] * size[2] + fp3[2]] = wire.net;
        S.getPosPtr(fp1).* = .wire;
        S.getPosPtr(fp2).* = .block;
        S.getPosPtr(fp3).* = .air;
        const tp1 = wire.to;
        const tp2 = posBelow(tp1);
        const tp3 = posAbove(tp1);
        O.items[tp1[0] * size[1] * size[2] + tp1[1] * size[2] + tp1[2]] = wire.net;
        O.items[tp2[0] * size[1] * size[2] + tp2[1] * size[2] + tp2[2]] = wire.net;
        O.items[tp3[0] * size[1] * size[2] + tp3[1] * size[2] + tp3[2]] = wire.net;
        S.getPosPtr(tp1).* = .wire;
        S.getPosPtr(tp2).* = .block;
        S.getPosPtr(tp3).* = .air;
    }
}

pub fn route(wires: []Wire, schem: *const Schematic, gpa: std.mem.Allocator) !Schematic {
    var S = try cloneSchematic(schem, gpa);

    var O = std.ArrayList(usize).empty;
    try O.appendNTimes(gpa, unowned, S.size[0] * S.size[1] * S.size[2]);

    // Assign ownership for all ports
    setPortOwnership(&S, &O, &wires, S.size);

    // Initialize the queue for the routing process
    Q = .init(gpa, undefined);

    // Sort wires from short to long
    std.mem.sort(Wire, wires, @as(usize, 0), compareWire);

    var wire_queue = std.ArrayList(Wire).empty;
    try wire_queue.appendSlice(gpa, wires);

    var prng: std.Random.DefaultPrng = .init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const rand = prng.random();

    var i: usize = 0;
    while (i < wire_queue.items.len) {
        const wire = wire_queue.items[i];
        std.debug.print("#{} Routing net {}, {} queued: {}\n", .{ i, wire.net, wire_queue.items.len - i, wire });
        i += 1;
        // const default_violation_cost = 1.50 - @as(f32, @floatFromInt(i)) / 300.0;
        var path_rev = try routeSingleRoute(&wire, &S, &O.items, false, default_violation_cost, gpa);
        if (path_rev) |path| {
            const violations = try applyRoute(&wire, &S, &O, path.@"0", gpa);
            if (violations.len != 0)
                std.debug.print("Route in net {} violates others even though routing successfull\n", .{wire.net});
        } else {
            var violation_cost: f32 = default_violation_cost + violation_cost_decrement;
            while (path_rev == null) {
                violation_cost -= violation_cost_decrement;
                path_rev = try routeSingleRoute(&wire, &S, &O.items, true, violation_cost, gpa);
            }

            const path = path_rev.?;
            const violations = try applyRoute(&wire, &S, &O, path.@"0", gpa);
            std.debug.print("Routed {} in violation with {any}\n", .{ i, violations });
            // Randomize order in which wires get added
            rand.shuffle(Wire, wires);
            for (violations) |net| {
                ripUp(net, &S, &O); // Rip up violating net
                for (wires) |w| {
                    if (w.net == net) {
                        var found = false;
                        for (wire_queue.items[i..]) |enqueued| {
                            if (std.meta.eql(enqueued, w)) {
                                found = true;
                            }
                        }
                        if (!found)
                            try wire_queue.append(gpa, w);
                    }
                }
            }
            // Ensure that ownership is set correctly for ports
            setPortOwnership(&S, &O, &wires, S.size);
        }
    }
    return S;
}
