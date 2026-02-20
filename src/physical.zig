pub const Size = struct {
    const Self = @This();

    w: u64,
    h: u64,

    pub inline fn area(self: *Self) u64 {
        return self.w * self.h;
    }
};
