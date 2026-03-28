const std = @import("std");
const phys = @import("physical.zig");
const nbt = @import("nbt.zig");
const comp = @import("components/components.zig");
const ms = @import("abstract/structures.zig");

const Router = @This();

max_iterations: u32 = 20,
violation_cost_multiplier: u32 = 15.0,
heuristic_weight: f32 = 1.0,
delay_cost_multiplier: u32 = 1.0,
max_length: u32 = 1000,
max_astar_iterations: u32 = 999999999,

const WorldCoord = ms.WorldCoord;

const NodeState = struct {
    coord: WorldCoord,
    signal: u5,
    heading: WorldCoord,
};

const Parent = struct {
    prev: NodeState,
    def: *const comp.ComponentDef,
    violating: bool,
    heading: WorldCoord,
};

const Route = struct {
    route: std.ArrayList(ms.AbsBlock) = .empty,
    footprints: std.ArrayList(NodeState) = .empty,
    delay: u32 = 0,
    length: u32 = 0,
    violating: bool,
    pub fn deinit(self: *Route, allocator: std.mem.Allocator) void {
        self.route.deinit(allocator);
        self.footprints.deinit(allocator);
    }
};

pub const RoutePair = struct {
    from: WorldCoord,
    to: WorldCoord,
};

const MergePoint = struct {
    cost_to_root: u32,
    signal_at_node: u5,
};

fn coordEq(a: WorldCoord, b: WorldCoord) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2];
}

const SURROUNDING_OFFSETS = blk: {
    var arr: [27]WorldCoord = undefined;
    var i: usize = 0;
    for ([_]i32{ -1, 0, 1 }) |x| {
        for ([_]i32{ -1, 0, 1 }) |y| {
            for ([_]i32{ -1, 0, 1 }) |z| {
                arr[i] = .{ x, y, z };
                i += 1;
            }
        }
    }
    break :blk arr;
};

const MaxMoveBlocks = 12;
const MAX_COMPONENT_RADIUS = 2;
const MoveFootprint = struct {
    blocks: [MaxMoveBlocks]WorldCoord,
    count: usize,
};

fn getMoveFootprint(u: WorldCoord, move: Move) MoveFootprint {
    var fp: MoveFootprint = .{ .blocks = undefined, .count = 0 };
    for (move.def.build_blocks) |bb| {
        fp.blocks[fp.count] = u + rotateCoord(bb.offset, move.heading);
        fp.count += 1;
    }
    return fp;
}

fn moveIntersectsPath(new_u: WorldCoord, new_move: Move, start_state: NodeState, parents: *const std.AutoHashMap(NodeState, Parent)) bool {
    const new_fp = getMoveFootprint(new_u, new_move);
    const new_coord = new_u + new_move.dir;

    var curr = start_state;

    while (true) {
        if (coordEq(curr.coord, new_coord)) return true;

        if (parents.get(curr)) |p| {
            const prev_u = p.prev.coord;
            const past_move = Move{
                .dir = curr.coord - prev_u,
                .heading = p.heading,
                .def = p.def,
            };
            const dx = @abs(prev_u[0] - new_u[0]);
            const dy = @abs(prev_u[1] - new_u[1]);
            const dz = @abs(prev_u[2] - new_u[2]);
            const manhattan = dx + dy + dz;

            if (manhattan > MAX_COMPONENT_RADIUS * 2) {
                curr = p.prev;
                continue;
            }
            const past_fp = getMoveFootprint(prev_u, past_move);

            for (new_fp.blocks[0..new_fp.count]) |b1| {
                for (past_fp.blocks[0..past_fp.count]) |b2| {
                    if (coordEq(b1, b2)) {
                        return true;
                    }
                }
            }
            curr = p.prev;
        } else {
            break;
        }
    }
    return false;
}

const Move = struct {
    dir: WorldCoord,
    heading: WorldCoord,
    def: *const comp.ComponentDef,
};

const MoveValidity = union(enum) {
    valid,
    invalid,
    violation: u32,
};

fn check_validity(coord: WorldCoord, forbidden_zone: ms.ForbiddenZone, current_from: WorldCoord, is_first_move: bool, host_route_id: ?usize, targets: *const std.AutoHashMap(WorldCoord, MergePoint)) MoveValidity {
    _ = current_from;

    if (targets.contains(coord)) return .valid;

    if (forbidden_zone.get(coord)) |conflict| {
        if (conflict.ftype == .gate) return .invalid;
        if (is_first_move) return .valid;

        // Exempt the padding of target routes by checking adjacency to known target centers
        for (SURROUNDING_OFFSETS) |offset| {
            if (targets.contains(coord + offset)) return .valid;
        }

        if (conflict.ftype == .wire_padding) {
            if (host_route_id != null and conflict.route_id == host_route_id.? and conflict.foreign_ref_count == 0) {
                return .valid;
            }
            return .{ .violation = conflict.ref_count };
        }

        if (conflict.ftype == .wire) return .{ .violation = conflict.ref_count };
    }
    return .valid;
}

fn isMoveValid(
    u: WorldCoord,
    move: Move,
    forbidden_zone: ms.ForbiddenZone,
    current_from: WorldCoord,
    is_first_move: bool,
    host_route_id: ?usize,
    targets: *const std.AutoHashMap(WorldCoord, MergePoint), // Added
) MoveValidity {
    const target_coord = u + move.dir;
    if (target_coord[1] > phys.MAX_Y_LEVEL or target_coord[1] < phys.MIN_Y_LEVEL) return .invalid;

    var total_refs: u32 = 0;
    for (move.def.build_blocks) |bb| {
        const rotated = rotateCoord(bb.offset, move.heading);
        switch (check_validity(u + rotated, forbidden_zone, current_from, is_first_move, host_route_id, targets)) {
            .invalid => return .invalid,
            .valid => {},
            .violation => |refs| total_refs += refs,
        }
    }

    if (total_refs > 0) return .{ .violation = total_refs };
    return .valid;
}

const Net = struct {
    id: usize,
    from: WorldCoord,
    from_signal: u5,
    to: WorldCoord,
    route: ?Route,
    failures: u32,
    is_violating: bool = false,
    sort_weight: u32 = 0,
};

fn sortNetPtrsDescending(config: Router, lhs: *Net, rhs: *Net) bool {
    _ = config;
    return lhs.sort_weight > rhs.sort_weight;
}

fn ripUp(net: *Net, forbidden_zone: *ms.ForbiddenZone, a: std.mem.Allocator) void {
    if (net.route) |*r| {
        for (r.footprints.items) |fp| {
            for (SURROUNDING_OFFSETS) |offset| {
                const target = fp.coord + offset;

                if (forbidden_zone.getPtr(target)) |existing| {
                    if (existing.ftype == .wire or existing.ftype == .wire_padding) {
                        existing.ref_count -= 1;

                        if (existing.route_id != net.id) {
                            existing.foreign_ref_count -= 1;
                        }

                        if (existing.ref_count == 0) {
                            _ = forbidden_zone.remove(target);
                        }
                    }
                }
            }
        }
        r.deinit(a);
        net.route = null;
    }
}

const CellInfo = struct {
    nets: [16]*Net,
    is_center: [16]bool,
    count: usize,
};

fn isHost(branch_net: *const Net, potential_host: *const Net) bool {
    if (potential_host.route) |*r| {
        for (r.footprints.items) |fp| {
            if (coordEq(fp.coord, branch_net.from) or coordEq(fp.coord, branch_net.to)) return true;
        }
    }
    return false;
}

fn updateViolations(a: std.mem.Allocator, nets: []Net) !void {
    var owners = std.AutoHashMap(WorldCoord, CellInfo).init(a);
    defer owners.deinit();

    var one_violation = false;
    for (nets) |*net| {
        net.is_violating = false;

        if (net.route) |*r| {
            if (net.route.?.violating) one_violation = true;
            r.violating = false;
            // net.is_violating = r.violating;
            for (r.footprints.items) |fp| {
                for (SURROUNDING_OFFSETS) |offset| {
                    const target = fp.coord + offset;
                    const is_center = offset[0] == 0 and offset[1] == 0 and offset[2] == 0;

                    if (owners.getPtr(target)) |existing| {
                        var found = false;
                        for (existing.nets[0..existing.count], 0..) |n, i| {
                            if (n == net) {
                                found = true;
                                if (is_center) existing.is_center[i] = true;
                                break;
                            }
                        }
                        if (!found and existing.count < 4) {
                            existing.nets[existing.count] = net;
                            existing.is_center[existing.count] = is_center;
                            existing.count += 1;
                        }
                    } else {
                        var info = CellInfo{ .nets = undefined, .is_center = undefined, .count = 1 };
                        info.nets[0] = net;
                        info.is_center[0] = is_center;
                        try owners.put(target, info);
                    }
                }
            }
        }
    }
    if (!one_violation) return;

    for (nets) |*net| {
        if (net.route) |*r| {
            for (r.footprints.items) |fp| {
                if (owners.get(fp.coord)) |info| {
                    for (info.nets[0..info.count], 0..) |existing_net, i| {
                        if (existing_net != net) {
                            var is_violation = true;

                            const net_is_branch = isHost(net, existing_net);
                            const existing_is_branch = isHost(existing_net, net);
                            const shares_destination = coordEq(net.to, existing_net.to); // Added

                            // Nets targeting the same destination can merge absolutely anywhere along their length.
                            if (shares_destination) {
                                is_violation = false;
                            }
                            // Standard branching logic remains strictly limited to valid endpoints.
                            else if (net_is_branch or existing_is_branch) {
                                var net_is_center = false;
                                for (info.nets[0..info.count], 0..) |n, j| {
                                    if (n == net) {
                                        net_is_center = info.is_center[j];
                                        break;
                                    }
                                }
                                const existing_is_center = info.is_center[i];

                                if (!(net_is_center and existing_is_center)) {
                                    is_violation = false;
                                } else {
                                    const bp1 = net.from;
                                    const dest = net.to;

                                    const is_valid_overlap =
                                        coordEq(fp.coord, bp1) or coordEq(fp.coord, bp1 + WorldCoord{ 0, -1, 0 }) or
                                        coordEq(fp.coord, dest) or coordEq(fp.coord, dest + WorldCoord{ 0, -1, 0 });

                                    if (is_valid_overlap) {
                                        is_violation = false;
                                    }
                                }
                            }
                            if (is_violation) {
                                net.is_violating = true;
                                break;
                            }
                        }
                    }
                }
                if (net.is_violating) break;
            }
        }
    }

    for (nets) |*net| {
        if (net.route) |*r| r.violating = net.is_violating;
    }
}

fn sortNetsSortWeight(context: Router, lhs: Net, rhs: Net) bool {
    _ = context;
    return lhs.sort_weight > rhs.sort_weight;
}

pub fn routeAll(a: std.mem.Allocator, seed: u32, pairs: []RoutePair, forbidden_zone: *ms.ForbiddenZone, config: Router) !Route {
    var nets = try a.alloc(Net, pairs.len);

    defer {
        for (nets) |*net| {
            if (net.route) |*r| r.deinit(a);
        }
        a.free(nets);
    }

    var v_nets: std.ArrayList(*Net) = .empty;
    defer v_nets.deinit(a);

    var targets = std.AutoHashMap(WorldCoord, MergePoint).init(a);
    defer targets.deinit();

    for (pairs, 0..) |pair, i| {
        nets[i] = .{
            .id = i,
            .from = pair.from,
            .to = pair.to,
            .route = null,
            .failures = 0,
            .is_violating = false,
            .from_signal = 15,
            .sort_weight = heuristic(pair.from, pair.to, config.delay_cost_multiplier),
        };
    }

    // sort beforehand
    std.sort.block(Net, nets, config, sortNetsSortWeight);

    for (nets, 0..) |*net, i| {
        targets.clearRetainingCapacity();
        try targets.put(net.to, .{ .cost_to_root = 0, .signal_at_node = 1 });

        for (nets[0..i]) |*other| {
            if (other.route) |*r| {
                if (coordEq(other.to, net.to)) {
                    var accumulated_cost: u32 = 0;
                    var rev_idx: usize = r.footprints.items.len;
                    while (rev_idx > 0) {
                        rev_idx -= 1;
                        const fp = r.footprints.items[rev_idx];
                        accumulated_cost += 1;

                        // 1. Register the center
                        if (!targets.contains(fp.coord)) {
                            try targets.put(fp.coord, .{ .cost_to_root = accumulated_cost * config.delay_cost_multiplier, .signal_at_node = fp.signal });
                        }

                        // 2. Register the padding as immediate merge points
                        for (SURROUNDING_OFFSETS) |offset| {
                            const pad_coord = fp.coord + offset;
                            if (!targets.contains(pad_coord)) {
                                // Signal degrades by 1 across the adjacency gap
                                const pad_signal = if (fp.signal > 0) fp.signal - 1 else 0;
                                try targets.put(pad_coord, .{ .cost_to_root = (accumulated_cost + 1) * config.delay_cost_multiplier, .signal_at_node = pad_signal });
                            }
                        }
                    }
                }
            }
        }

        std.log.info("Routing net {} from {any} to {any}", .{ net.id, net.from, net.to });
        net.route = routeToUpdateForbiddenZone(a, net.from, net.from_signal, targets, forbidden_zone, config, net.id) catch null;
    }

    try updateViolations(a, nets);
    for (nets) |*net| {
        if (net.route) |r| {
            std.log.info("Initial route for net from {any} to {any} has delay {d} and violating={any}", .{ net.from, net.to, r.delay, net.is_violating });
        }
        if (net.is_violating or net.route == null) {
            try v_nets.append(a, net);
        }
    }

    var iters: u32 = 0;
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    while (v_nets.items.len > 0 and iters < config.max_iterations) : (iters += 1) {
        for (v_nets.items) |net| {
            const base_weight = net.failures * 1000;
            const dist = heuristic(net.from, net.to, config.delay_cost_multiplier) * 100;
            const random_jitter = random.intRangeLessThan(u32, 0, 200);
            net.sort_weight = base_weight + dist + random_jitter;
        }

        std.sort.block(*Net, v_nets.items, config, sortNetPtrsDescending);
        const num_v_nets_this_pass = v_nets.items.len;

        std.log.info("Iteration {}: Routing {} violating nets", .{ iters, num_v_nets_this_pass });

        for (0..num_v_nets_this_pass) |_| {
            var net = v_nets.orderedRemove(0);
            ripUp(net, forbidden_zone, a);

            targets.clearRetainingCapacity();
            try targets.put(net.to, .{ .cost_to_root = 0, .signal_at_node = 1 });

            for (nets) |*other| {
                if (other.id == net.id) continue;
                if (other.route) |*r| {
                    if (coordEq(other.to, net.to)) {
                        var accumulated_cost: u32 = 0;
                        var rev_idx: usize = r.footprints.items.len;
                        while (rev_idx > 0) {
                            rev_idx -= 1;
                            const fp = r.footprints.items[rev_idx];
                            accumulated_cost += 1;

                            // 1. Register the center
                            if (!targets.contains(fp.coord)) {
                                try targets.put(fp.coord, .{ .cost_to_root = accumulated_cost * config.delay_cost_multiplier, .signal_at_node = fp.signal });
                            }

                            // 2. Register the padding as immediate merge points
                            for (SURROUNDING_OFFSETS) |offset| {
                                const pad_coord = fp.coord + offset;
                                if (!targets.contains(pad_coord)) {
                                    // Signal degrades by 1 across the adjacency gap
                                    const pad_signal = if (fp.signal > 0) fp.signal - 1 else 0;
                                    try targets.put(pad_coord, .{ .cost_to_root = (accumulated_cost + 1) * config.delay_cost_multiplier, .signal_at_node = pad_signal });
                                }
                            }
                        }
                    }
                }
            }

            std.log.info("Re-routing net from {any} to {any} with {} failures", .{ net.from, net.to, net.failures });
            net.route = routeToUpdateForbiddenZone(a, net.from, net.from_signal, targets, forbidden_zone, config, net.id) catch null;
        }

        try updateViolations(a, nets);

        v_nets.clearRetainingCapacity();
        for (nets) |*net| {
            if (net.is_violating or net.route == null) {
                net.failures += 1;
                try v_nets.append(a, net);
            }
        }
    }

    if (v_nets.items.len > 0) {
        std.log.warn("routeAll finished with {} unresolved violations after {} iterations.", .{ v_nets.items.len, config.max_iterations });
    }

    var final_route = Route{
        .route = .empty,
        .footprints = .empty,
        .delay = 0,
        .length = 0,
        .violating = v_nets.items.len > 0,
    };
    errdefer final_route.deinit(a);

    std.log.info("Assembling final route with total {} nets, {} violating.", .{ nets.len, v_nets.items.len });
    for (nets) |*net| {
        if (net.route) |*r| {
            if (net.is_violating) {
                for (0..r.route.items.len) |i| {
                    if (r.route.items[i].block == .block) {
                        r.route.items[i].block = .block3;
                    }
                }
            }
            try final_route.route.appendSlice(a, r.route.items);
            try final_route.footprints.appendSlice(a, r.footprints.items);
            final_route.delay += r.delay;
            final_route.length += r.length;
        } else {
            try final_route.route.append(a, .{ .block = .block3, .rot = .center, .loc = net.to });
            try final_route.route.append(a, .{ .block = .block3, .rot = .center, .loc = net.from });
        }
    }

    return final_route;
}

const QueueItem = struct {
    state: NodeState,
    g: u32,
    f: u32,
    length: u32,
    delay: u32,
};

fn heuristic(curr: WorldCoord, target: WorldCoord, delay_weight: u32) u32 {
    const dx = @abs(curr[0] - target[0]);
    const dy = @abs(curr[1] - target[1]);
    const dz = @abs(curr[2] - target[2]);
    const manhattan_f: u32 = (dx + dy + dz);
    const min_unavoidable_delay_cost = (manhattan_f / 30) * delay_weight;
    return manhattan_f + min_unavoidable_delay_cost;
}

fn minimumHeuristic(curr: WorldCoord, targets: std.AutoHashMap(WorldCoord, MergePoint), delay_weight: u32) u32 {
    var min_h: u32 = std.math.maxInt(u32);
    var it = targets.iterator();
    while (it.next()) |entry| {
        const h = heuristic(curr, entry.key_ptr.*, delay_weight) + entry.value_ptr.cost_to_root;
        if (h < min_h) min_h = h;
    }
    return min_h;
}

fn queueOrder(context: void, a: QueueItem, b: QueueItem) std.math.Order {
    _ = context;
    const f_order = std.math.order(a.f, b.f);
    if (f_order == .eq) {
        return std.math.order(a.g, b.g).invert();
    }
    return f_order;
}

pub fn routeToUpdateForbiddenZone(a: std.mem.Allocator, from: WorldCoord, from_signal: u5, targets: std.AutoHashMap(WorldCoord, MergePoint), forbidden_zone: *ms.ForbiddenZone, config: Router, route_id: usize) !Route {
    const route = try routeTo(a, from, from_signal, targets, forbidden_zone.*, config);

    for (route.footprints.items) |fp| {
        for (SURROUNDING_OFFSETS) |offset| {
            const target = fp.coord + offset;
            const is_center = offset[0] == 0 and offset[1] == 0 and offset[2] == 0;
            const target_ftype: ms.ForbiddenZoneType = if (is_center) .wire else .wire_padding;

            if (forbidden_zone.getPtr(target)) |existing| {
                if (existing.ftype == .wire or existing.ftype == .wire_padding) {
                    existing.ref_count += 1;

                    if (!coordEq(existing.source_coord, from)) {
                        existing.foreign_ref_count += 1;
                    }

                    if (target_ftype == .wire and existing.ftype == .wire_padding) {
                        existing.ftype = .wire;

                        if (existing.route_id != route_id) {
                            existing.foreign_ref_count = existing.ref_count - 1;
                            existing.route_id = route_id;
                            existing.source_coord = from;
                        }
                    }
                }
            } else {
                try forbidden_zone.put(target, .{
                    .ftype = target_ftype,
                    .ref_count = 1,
                    .foreign_ref_count = 0,
                    .route_id = route_id,
                    .source_coord = from,
                });
            }
        }
    }

    return route;
}

pub fn routeTo(a: std.mem.Allocator, from: WorldCoord, from_signal: u5, targets: std.AutoHashMap(WorldCoord, MergePoint), forbidden_zone: ms.ForbiddenZone, config: Router) !Route {
    if (from[1] < phys.MIN_Y_LEVEL or from[1] > phys.MAX_Y_LEVEL) {
        return error.OutOfBounds;
    }

    const host_entry = forbidden_zone.get(from);
    const host_route_id = if (host_entry) |e| e.route_id else null;

    var queue = std.PriorityQueue(QueueItem, void, queueOrder).init(a, {});
    defer queue.deinit();

    var parents = std.AutoHashMap(NodeState, Parent).init(a);
    defer parents.deinit();

    var distances = std.AutoHashMap(NodeState, u32).init(a);
    defer distances.deinit();

    const start_state = NodeState{ .coord = from, .signal = from_signal, .heading = .{ 0, 0, 0 } };
    try distances.put(start_state, 0);
    try queue.add(.{ .state = start_state, .g = 0, .f = minimumHeuristic(from, targets, config.delay_cost_multiplier), .length = 0, .delay = 0 });

    const moves = comptime blk: {
        var m: [comp.components.len * 4]Move = undefined;
        var idx = 0;
        for (&comp.components) |*def| {
            for ([_]WorldCoord{ .{ 1, 0, 0 }, .{ 0, 0, 1 }, .{ -1, 0, 0 }, .{ 0, 0, -1 } }) |cdir| {
                m[idx] = .{
                    .dir = rotateCoord(def.base_dir, cdir),
                    .heading = cdir,
                    .def = def,
                };
                idx += 1;
            }
        }
        break :blk m;
    };

    var final_state: ?NodeState = null;
    var final_merge_cost: u32 = 0;

    var counter: usize = 0;
    var is_violating = false;

    while (queue.count() > 0 and counter < config.max_astar_iterations) {
        counter += 1;
        const item = queue.removeOrNull().?;
        const u_state = item.state;
        const u = u_state.coord;

        const best_g = distances.get(u_state) orelse std.math.maxInt(u32);
        if (item.g > best_g) continue;

        if (targets.get(u)) |merge_pt| {
            if (u_state.signal >= 15 - merge_pt.signal_at_node) {
                final_state = u_state;
                final_merge_cost = merge_pt.cost_to_root;
                break;
            }
        }

        for (moves) |move| {
            if (parents.get(u_state)) |p| {
                if (move.heading[0] == -p.heading[0] and move.heading[2] == -p.heading[2]) {
                    continue;
                }
            }
            const coord = u + move.dir;
            // if (moveIntersectsPath(u, move, u_state, &parents)) continue;

            const is_first_move = (item.g == 0);
            if (is_first_move and move.def.cat != .dust) continue;

            const g_length = item.length + move.def.length;
            if (g_length > config.max_length) continue;

            const validity = isMoveValid(u, move, forbidden_zone, from, is_first_move, host_route_id, &targets);
            if (validity == .invalid) continue;

            var next_signal = u_state.signal;
            if (next_signal < move.def.min_signal) continue;

            switch (move.def.signal_behavior) {
                .decay => {
                    // if (next_signal == 1 and targets.contains(coord)) continue;
                    next_signal -= move.def.min_signal;
                },
                .reset => next_signal = 15,
                .via => next_signal = 14,
            }

            const next_state = NodeState{ .coord = coord, .signal = next_signal, .heading = move.heading };
            var move_cost = move.def.delay * config.delay_cost_multiplier + move.def.length;

            switch (validity) {
                .violation => |refs| {
                    _ = refs;
                    move_cost *= config.violation_cost_multiplier;
                    is_violating = true;
                },
                else => {
                    is_violating = false;
                },
            }

            const g_cost = item.g + move_cost;
            const g_delay = item.delay + move.def.delay;

            var dominated = false;
            var s_check: u5 = next_signal;
            while (s_check <= 15) : (s_check += 1) {
                if (distances.get(.{ .coord = coord, .signal = s_check, .heading = move.heading })) |better_g| {
                    if (better_g <= g_cost) {
                        dominated = true;
                        break;
                    }
                }
            }

            if (!dominated) {
                distances.put(next_state, g_cost) catch @panic("oom");
                parents.put(next_state, .{
                    .prev = u_state,
                    .def = move.def,
                    .violating = is_violating,
                    .heading = move.heading,
                }) catch @panic("oom");

                const f_cost = g_cost + minimumHeuristic(coord, targets, config.delay_cost_multiplier);
                queue.add(.{
                    .state = next_state,
                    .g = g_cost,
                    .f = f_cost,
                    .length = g_length,
                    .delay = g_delay,
                }) catch @panic("oom");
            }
        }
    }

    if (final_state == null) {
        std.log.err("A* completed with {d} iterations. Path not found.", .{counter});
        return error.PathNotFound;
    }

    var final_route = try buildRouteBlocks(a, start_state, final_state.?, parents);
    std.log.info("A* completed with {d} iterations, violating={}", .{ counter, final_route.violating });
    final_route.delay += final_merge_cost;
    return final_route;
}

fn buildRouteBlocks(a: std.mem.Allocator, start_state: NodeState, final_state: NodeState, parents: std.AutoHashMap(NodeState, Parent)) !Route {
    var abs_blocks: std.ArrayList(ms.AbsBlock) = .empty;
    var footprints: std.ArrayList(NodeState) = .empty;
    var length: u32 = 0;
    var delay: u32 = 0;
    var violating = false;

    try footprints.append(a, start_state);

    var curr_state = final_state;
    var vec = curr_state.coord;

    while (!coordEq(vec, start_state.coord)) {
        const p = parents.get(curr_state) orelse return error.MissingParent;
        curr_state = p.prev;
        vec = curr_state.coord;

        if (p.violating) violating = true;
        const move_dir = p.heading;

        for (p.def.build_blocks) |block_def| {
            const rotated_coord = rotateCoord(block_def.offset, move_dir);
            const rotated_rot = rotateOrientation(block_def.rot, move_dir);

            try abs_blocks.append(a, .{
                .block = block_def.cat,
                .loc = vec + rotated_coord,
                .rot = rotated_rot,
            });

            try footprints.append(a, .{
                .coord = vec + rotated_coord,
                .signal = p.prev.signal,
                .heading = move_dir,
            });
        }

        length += p.def.length;
        delay += p.def.delay;
    }

    try abs_blocks.append(a, .{ .block = .dust, .loc = final_state.coord, .rot = .center });
    try abs_blocks.append(a, .{ .block = .block, .loc = final_state.coord + WorldCoord{ 0, -1, 0 }, .rot = .center });

    try footprints.append(a, final_state);
    try footprints.append(a, .{ .coord = final_state.coord + WorldCoord{ 0, -1, 0 }, .signal = final_state.signal, .heading = final_state.heading });

    return .{
        .route = abs_blocks,
        .footprints = footprints,
        .delay = delay,
        .length = length,
        .violating = violating,
    };
}

fn rotateCoord(coord: WorldCoord, dir: WorldCoord) WorldCoord {
    if (dir[0] > 0) return coord;
    if (dir[0] < 0) return .{ -coord[0], coord[1], -coord[2] };
    if (dir[2] > 0) return .{ -coord[2], coord[1], coord[0] };
    return .{ coord[2], coord[1], -coord[0] };
}

fn rotateOrientation(rot: ms.Orientation, dir: WorldCoord) ms.Orientation {
    if (rot == .center) return .center;
    if (dir[0] > 0) return rot;

    if (dir[0] < 0) {
        return switch (rot) {
            .east => .west,
            .west => .east,
            .north => .south,
            .south => .north,
            else => rot,
        };
    }
    if (dir[2] > 0) {
        return switch (rot) {
            .east => .south,
            .west => .north,
            .north => .east,
            .south => .west,
            else => rot,
        };
    }

    return switch (rot) {
        .east => .north,
        .west => .south,
        .north => .west,
        .south => .east,
        else => rot,
    };
}
