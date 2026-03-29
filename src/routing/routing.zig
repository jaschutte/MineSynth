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
    // .{ 0, -1, 0 },
    // .{ 0, 0, 0 },
    // .{ 0, 1, 0 },
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

const search_nodes: usize = 200000;
const distance_cost: f32 = 0.25;
const vertical_cost: f32 = 0.01;
const repeater_cost: f32 = 0.01;

inline fn heuristic(from: Pos, to: Pos) f32 {
    const dx = @max(from[0], to[0]) - @min(from[0], to[0]);
    // const dy = @max(from[1], to[1]) - @min(from[1], to[1]);
    const dz = @max(from[2], to[2]) - @min(from[2], to[2]);
    const h = @as(f32, @floatFromInt(dx + dz));
    return h;
}

var moveStore = std.ArrayList(MoveNode).empty;
var Q: std.PriorityQueue(QueueNode, void, compareQueueNode) = undefined;

fn routeSingleRoute(wire: *const Wire, S: *const Schematic, O: *const BlockOwner, comptime violate: bool, gpa: std.mem.Allocator) !?struct { []Move, []usize } {
    const from = wire.from;
    const to = wire.to;
    const net = wire.net;

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

        // Check that we do not go through instances
        // if (S.getPos(posAbove(posAbove(pos))) != .undef and S.getPos(posAbove(posAbove(pos))) != .block) continue;
        // if (S.getPos(posBelow(pos)) != .undef and S.getPos(posBelow(pos)) != .block) continue;
        if (S.getPos(pos) != .undef and S.getPos(pos) != .wire) continue;
        if (S.getPos(posBelow(pos)) != .undef and S.getPos(posBelow(pos)) != .block) continue;
        // if (S.getPos(posBelow(posBelow(pos))) != .undef and S.getPos(posBelow(posBelow(pos))) != .block) continue;

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
            if (owner != net) continue :outer;
            // if (owner == net and !std.meta.eql(n_pos, moveStore.items[move.from].pos)) continue :outer;
        }

        // Check if we have arrived
        if (std.meta.eql(to, pos)) {
            var moves = std.ArrayList(Move).empty;
            var curr = next.move;
            while (curr != first_from) {
                try moves.append(gpa, moveStore.items[curr].move);
                curr = moveStore.items[curr].from;
            }
            return try moves.toOwnedSlice(gpa);
        }

        // North (-Z)
        if (pos[2] > 0 and canGoDir(move.move, .north)) {
            // Horizontal dust
            if (pow > 1) {
                const next_move = Move{ .dir = .north, .type = .flat };
                const next_pos = next_move.nextPos(pos);
                const next_cost = move.cost + distance_cost;
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
                const next_cost = move.cost + distance_cost + vertical_cost;
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
                const next_cost = move.cost + distance_cost + vertical_cost;
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
                const next_cost = move.cost + repeater_cost + distance_cost;
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
                const next_cost = move.cost + distance_cost;
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
                const next_cost = move.cost + distance_cost + vertical_cost;
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
                const next_cost = move.cost + distance_cost + vertical_cost;
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
                const next_cost = move.cost + repeater_cost + distance_cost;
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
                const next_cost = move.cost + distance_cost;
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
                const next_cost = move.cost + distance_cost + vertical_cost;
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
                const next_cost = move.cost + distance_cost + vertical_cost;
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
                const next_cost = move.cost + repeater_cost + distance_cost;
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
                const next_cost = move.cost + distance_cost;
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
                const next_cost = move.cost + distance_cost + vertical_cost;
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
                const next_cost = move.cost + distance_cost + vertical_cost;
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
                const next_cost = move.cost + repeater_cost + distance_cost;
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
    return &.{};
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

fn applyRoute(wire: *const Wire, S: *Schematic, O: *std.ArrayList(usize), moves_rev: []Move) void {
    var curr = wire.from;
    O.items[curr[0] * S.size[1] * S.size[2] + curr[1] * S.size[2] + curr[2]] = wire.net;
    O.items[curr[0] * S.size[1] * S.size[2] + (curr[1] - 1) * S.size[2] + curr[2]] = wire.net;
    S.getPosPtr(curr).* = .wire;
    S.getPosPtr(posBelow(curr)).* = .block;
    // std.debug.print("Applying route for {}\n", .{wire});
    for (0..moves_rev.len) |i| {
        if (i == 0) continue; // Skip initial (undefined) move
        const move = moves_rev[moves_rev.len - 1 - i];
        // std.debug.print("Move {}: {}\n", .{ i, move });
        curr = move.nextPos(curr);
        O.items[curr[0] * S.size[1] * S.size[2] + curr[1] * S.size[2] + curr[2]] = wire.net;
        O.items[curr[0] * S.size[1] * S.size[2] + (curr[1] - 1) * S.size[2] + curr[2]] = wire.net;
        S.getPosPtr(curr).* = switch (move.type) {
            .repeater => switch (move.dir) {
                .north => .repeater_north,
                .east => .repeater_east,
                .south => .repeater_south,
                .west => .repeater_west,
            },
            else => .wire,
        };
        S.getPosPtr(posBelow(curr)).* = .block;
    }
}

fn compareWire(_: usize, a: Wire, b: Wire) bool {
    return heuristic(a.from, a.to) < heuristic(b.from, b.to);
}

fn setPortOwnership(O: *std.ArrayList(usize), wires: *const []Wire, size: Pos) void {
    for (wires.*) |wire| {
        const fp1 = wire.from;
        const fp2 = posBelow(fp1);
        O.items[fp1[0] * size[1] * size[2] + fp1[1] * size[2] + fp1[2]] = wire.net;
        O.items[fp2[0] * size[1] * size[2] + fp2[1] * size[2] + fp2[2]] = wire.net;
        const tp1 = wire.to;
        const tp2 = posBelow(tp1);
        O.items[tp1[0] * size[1] * size[2] + tp1[1] * size[2] + tp1[2]] = wire.net;
        O.items[tp2[0] * size[1] * size[2] + tp2[1] * size[2] + tp2[2]] = wire.net;
    }
}

pub fn route(wires: []Wire, schem: *const Schematic, gpa: std.mem.Allocator) !Schematic {
    var S = try cloneSchematic(schem, gpa);

    var O = std.ArrayList(usize).empty;
    try O.appendNTimes(gpa, unowned, S.size[0] * S.size[1] * S.size[2]);

    // Assign ownership for all ports
    setPortOwnership(&O, &wires, S.size);

    // Initialize the queue for the routing process
    Q = .init(gpa, undefined);

    // Sort wires from short to long
    std.mem.sort(Wire, wires, @as(usize, 0), compareWire);

    for (wires, 0..) |*wire, i| {
        std.debug.print("Routing wire {}/{}: {}\n", .{ i + 1, wires.len, wire });
        const path_rev = try routeSingleRoute(wire, &S, &O.items, false, gpa);
        applyRoute(wire, &S, &O, path_rev);
    }
    return S;
}
