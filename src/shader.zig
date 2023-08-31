pub fn init(comptime vert: []const u8) void {
    @embedFile(vert);
}
