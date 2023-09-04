const std = @import("std");
const gl = @import("gl");
const zm = @import("zmath");
const znoise = @import("znoise");
const Mesh = @import("mesh.zig").Mesh;

pub const Chunk = struct {
    pub const SIZE = 128;

    alloc: std.mem.Allocator,
    offset: zm.Vec,
    density: []f32,
    verts: std.ArrayList(f32),
    mesh: Mesh(.{.{
        .{ .name = "position", .size = 3, .type = gl.FLOAT },
        .{ .name = "colour", .size = 3, .type = gl.FLOAT },
    }}),

    pub fn init(alloc: std.mem.Allocator) !Chunk {
        var chunk = Chunk{
            .alloc = alloc,
            .offset = zm.f32x4(
                0.5 - 0.5 * @as(comptime_float, SIZE),
                0.5 - 0.5 * @as(comptime_float, SIZE),
                0.5 - 1.5 * @as(comptime_float, SIZE),
                0,
            ),
            .density = &.{},
            .verts = undefined,
            .mesh = undefined,
        };

        chunk.density = try alloc.alloc(f32, SIZE * SIZE * SIZE);
        errdefer chunk.density = &.{};
        errdefer alloc.free(chunk.density);

        chunk.verts = std.ArrayList(f32).init(alloc);
        errdefer chunk.verts.deinit();

        try chunk.genDensity();
        try chunk.genVerts();

        chunk.mesh = try @TypeOf(chunk.mesh).init(null);
        errdefer chunk.mesh.kill();
        try chunk.mesh.upload(.{chunk.verts.items});

        return chunk;
    }

    pub fn kill(chunk: *Chunk) void {
        chunk.mesh.kill();
        chunk.verts.deinit();
        chunk.alloc.free(chunk.density);
        chunk.density = &.{};
    }

    pub fn draw(chunk: Chunk) void {
        chunk.mesh.draw(gl.TRIANGLES);
    }

    fn genDensity(chunk: *Chunk) !void {
        const variant = 5;
        var timer = try std.time.Timer.start();
        switch (variant) {
            0, 1 => { // Empty, Full
                for (0..chunk.density.len) |i| {
                    chunk.density[i] = variant;
                }
            },
            2 => { // Medium vertex density
                for (0..chunk.density.len) |i| {
                    chunk.density[i] = if (i % 9 == 0) 1 else 0;
                }
            },
            3 => { // Max vertex density
                var index: usize = 0;
                for (0..SIZE) |z| {
                    for (0..SIZE) |y| {
                        for (0..SIZE) |x| {
                            chunk.density[index] = @floatFromInt((x + y + z) % 2);
                            index += 1;
                        }
                    }
                }
            },
            4 => { // Gradient noise (perlin)
                const gen = znoise.FnlGenerator{
                    .frequency = 2.7 / @as(f32, SIZE),
                    .noise_type = znoise.FnlGenerator.NoiseType.perlin,
                };
                for (0..chunk.density.len) |i| {
                    const pos = posFromIndex(i);
                    chunk.density[i] = gen.noise3(pos[0], pos[1], pos[2]);
                }
            },
            5 => { // Gradient noise (opensimplex2)
                const gen = znoise.FnlGenerator{
                    .frequency = 2 / @as(f32, SIZE),
                };
                for (0..chunk.density.len) |i| {
                    const pos = posFromIndex(i);
                    chunk.density[i] = gen.noise3(pos[0], pos[1], pos[2]);
                }
            },
            else => unreachable,
        }
        const ns: f32 = @floatFromInt(timer.read());
        std.debug.print("Density variant {} took {d:.3} ms\n", .{ variant, ns / 1_000_000 });
    }

    fn genVerts(chunk: *Chunk) !void {
        var timer = try std.time.Timer.start();
        for (0..chunk.density.len) |i| {
            try chunk.cubeVerts(posFromIndex(i));
        }
        const ns: f32 = @floatFromInt(timer.read());
        std.debug.print("Vertex generation took {d:.3} ms\n", .{ns / 1_000_000});
    }

    // Cubes are centered around their position, which is assumed to be integer
    fn cubeVerts(chunk: *Chunk, pos: zm.Vec) !void {
        if (chunk.empty(pos) orelse return logBadPos(pos)) return;
        // Faces
        for (0..6) |f| {
            var neighbour = pos;
            neighbour[f / 2] += if (f % 2 == 0) -1 else 1;
            if (chunk.full(neighbour) orelse false) continue;
            // Triangles
            for (0..2) |t| {
                // Vertices
                for (0..3) |v| {
                    var vert = (pos + neighbour) / zm.f32x4s(2);
                    vert[(f / 2 + 1) % 3] += if ((t + v + f) % 2 == 0) -0.5 else 0.5;
                    vert[(f / 2 + 2) % 3] += if (v / 2 != t) -0.5 else 0.5;
                    // Vertex positions
                    try chunk.verts.appendSlice(&zm.vecToArr3(vert));
                    // Vertex colours
                    try chunk.verts.appendSlice(&zm.vecToArr3(vert - pos + zm.f32x4s(0.5)));
                }
            }
        }
    }

    fn full(chunk: *Chunk, pos: zm.Vec) ?bool {
        return if (chunk.densityFromPos(pos)) |p| p > 0 else null;
    }

    fn empty(chunk: *Chunk, pos: zm.Vec) ?bool {
        return if (chunk.full(pos)) |e| !e else null;
    }

    fn densityFromPos(chunk: *Chunk, pos: zm.Vec) ?f32 {
        return chunk.density[indexFromPos(pos) catch return null];
    }

    fn indexFromPos(pos: zm.Vec) !usize {
        const floor = zm.floor(pos + zm.f32x4s(0.5));
        var index: usize = 0;
        for (0..3) |d| {
            const i = 2 - d;
            if (pos[i] < 0 or pos[i] >= SIZE) return error.PositionOutsideChunk;
            index *= SIZE;
            index += @intFromFloat(floor[i]);
        }
        return index;
    }

    fn logBadPos(pos: zm.Vec) !void {
        for (0..3) |d| {
            if (pos[d] < 0 or pos[d] >= SIZE) {
                std.log.err("Arg component {} of indexFromPos({}) is outside range 0..{}", .{ d, pos, SIZE });
                return error.PositionOutsideChunk;
            }
        }
    }

    fn posFromIndex(index: usize) zm.Vec {
        return zm.f32x4(
            @floatFromInt(index % SIZE),
            @floatFromInt(index / SIZE % SIZE),
            @floatFromInt(index / SIZE / SIZE),
            0,
        );
    }
};
