const std = @import("std");

pub const Area = u64;

pub const Size = struct {
    const Self = @This();

    w: u64,
    h: u64,

    pub inline fn new(w: u64, h: u64) Self {
        return Self {
            .w = w,
            .h = h,
        };
    }

    pub inline fn zero() Self {
        return Self {
            .w = 0,
            .h = 0,
        };
    }

    pub inline fn area(self: *const Self) Area {
        return self.w * self.h;
    }
};
