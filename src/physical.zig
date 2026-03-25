const std = @import("std");

pub const PosType = u32;
pub const Area = u64;
pub const Coordinate = @Vector(3, PosType);
pub const CoordinateRelative = @Vector(3, i32);
pub const Delay = u32;
pub const InputPositionsRelative = [2]?CoordinateRelative;
pub const OutputPositionsRelative = CoordinateRelative;
pub const PowerLevel = u8;

pub const MIN_Y_LEVEL = 0;
pub const MAX_Y_LEVEL = 3 * 10; // 10 layers

pub const Size = struct {
    const Self = @This();

    w: u64,
    h: u64,

    pub inline fn new(w: u64, h: u64) Self {
        return Self{
            .w = w,
            .h = h,
        };
    }

    pub inline fn zero() Self {
        return Self{
            .w = 0,
            .h = 0,
        };
    }

    pub inline fn area(self: *const Self) Area {
        return self.w * self.h;
    }
};
