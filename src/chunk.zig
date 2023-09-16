const std = @import("std");
const gl = @import("gl");
const zm = @import("zmath");
const znoise = @import("znoise");
const Mesh = @import("mesh.zig").Mesh;
const World = @import("world.zig").World;

pub const Chunk = struct {
    pub const SIZE = 32;

    density: []f32,
    verts: std.ArrayList(f32),
    mesh: Mesh(.{.{
        .{ .name = "position", .size = 3, .type = gl.FLOAT },
        .{ .name = "colour", .size = 3, .type = gl.FLOAT },
    }}),

    pub fn kill(chunk: *Chunk, alloc: std.mem.Allocator) void {
        chunk.mesh.kill();
        chunk.verts.deinit();
        alloc.free(chunk.density);
        chunk.density = &.{};
    }

    pub fn genDensity(chunk: *Chunk, offset: zm.Vec) !void {
        const variant = 7;
        // var timer = try std.time.Timer.start();
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
                for (0..chunk.density.len) |i| {
                    const pos = posFromIndex(i);
                    chunk.density[i] = @mod(pos[0] + pos[1] + pos[2] - 0.5, 2);
                }
            },
            4 => { // Gradient noise (perlin)
                const gen = znoise.FnlGenerator{
                    .frequency = 2.7 / @as(f32, World.SIZE),
                    .noise_type = znoise.FnlGenerator.NoiseType.perlin,
                };
                for (0..chunk.density.len) |i| {
                    const pos = posFromIndex(i) + offset;
                    chunk.density[i] = gen.noise3(pos[0], pos[1], pos[2]);
                }
            },
            5 => { // Gradient noise (opensimplex2)
                const gen = znoise.FnlGenerator{
                    .frequency = 2 / @as(f32, World.SIZE),
                };
                for (0..chunk.density.len) |i| {
                    const pos = posFromIndex(i) + offset;
                    chunk.density[i] = gen.noise3(pos[0], pos[1], pos[2]);
                }
            },
            6 => { // Smooth sphere
                const rad = @as(f32, World.SIZE) / 2;
                for (0..chunk.density.len) |i| {
                    const pos = posFromIndex(i) + offset;
                    chunk.density[i] = rad - zm.length3(pos)[0];
                }
            },
            7 => { // Splattered sphere
                const gen = znoise.FnlGenerator{
                    .frequency = 8 / @as(f32, World.SIZE),
                };
                const rad = @as(f32, World.SIZE) / 2;
                for (0..chunk.density.len) |i| {
                    const pos = posFromIndex(i) + offset;
                    chunk.density[i] = rad * 0.92 - zm.length3(pos)[0];
                    chunk.density[i] += gen.noise3(pos[0], pos[1], pos[2]) * rad * 0.1;
                }
            },
            8 => { // Chunk visualisation
                for (0..chunk.density.len) |i| {
                    chunk.density[i] = if (zm.any(@fabs(posFromIndex(i)) >
                        zm.f32x4s(@as(f32, SIZE) / 2 - 1), 3)) 0 else 1;
                }
            },
            else => unreachable,
        }
        // const ns: f32 = @floatFromInt(timer.read());
        // std.debug.print("Density variant {} took {d:.3} ms\n", .{ variant, ns / 1_000_000 });
    }

    pub fn genVerts(chunk: *Chunk, world: World, offset: zm.Vec) !void {
        const gen = znoise.FnlGenerator{
            .frequency = 1 / @as(f32, World.SIZE),
        };
        // var timer = try std.time.Timer.start();
        for (0..chunk.density.len) |i| {
            try chunk.cubeVerts(world, gen, posFromIndex(i), offset);
        }
        // const ns: f32 = @floatFromInt(timer.read());
        // std.debug.print("Vertex generation took {d:.3} ms\n", .{ns / 1_000_000});
    }

    // Cubes are centered around their position, which is assumed to be integer
    fn cubeVerts(chunk: *Chunk, world: World, gen: znoise.FnlGenerator, pos: zm.Vec, offset: zm.Vec) !void {
        if (chunk.empty(world, pos, offset) orelse return logBadPos(pos)) return;
        // Faces
        for (0..6) |f| {
            var neighbour = pos;
            neighbour[f / 2] += if (f % 2 == 0) -1 else 1;
            if (chunk.full(world, neighbour, offset) orelse false) continue;
            // Sample voxel occlusion
            var occlusion: [8]bool = undefined;
            for (0..4) |e| {
                // Voxels that share edges
                var occluder = neighbour;
                occluder[(e / 2 + f / 2 + 1) % 3] += if (e % 2 > 0) 1.0 else -1.0;
                occlusion[e] = chunk.full(world, occluder, offset) orelse false;
                // Voxels that share corners
                var corner = neighbour;
                corner[(f / 2 + 1) % 3] += if (e % 2 > 0) 1.0 else -1.0;
                corner[(f / 2 + 2) % 3] += if (e / 2 > 0) 1.0 else -1.0;
                occlusion[e + 4] = chunk.full(world, corner, offset) orelse false;
            }
            // Triangles
            for (0..2) |t| {
                // Vertices
                for (0..3) |v| {
                    var vert = (pos + neighbour) / zm.f32x4s(2);
                    const x = (t + v + f) % 2 > 0;
                    const y = v / 2 == t;
                    vert[(f / 2 + 1) % 3] += if (x) 0.5 else -0.5;
                    vert[(f / 2 + 2) % 3] += if (y) 0.5 else -0.5;
                    // Vertex positions
                    try chunk.verts.appendSlice(&zm.vecToArr3(vert));
                    // Vertex colours
                    var colour = zm.f32x4s(0);
                    for (0..3) |c| {
                        var c_pos = vert + offset;
                        c_pos[c] += World.SIZE * 9;
                        colour[c] += (gen.noise3(c_pos[0], c_pos[1], c_pos[2]) + 1) / 2;
                    }
                    // Accumulate occlusion
                    var occ: usize = 0;
                    if (occlusion[if (x) 1 else 0]) occ += 1;
                    if (occlusion[if (y) 3 else 2]) occ += 1;
                    if (occlusion[
                        4 + @as(usize, if (x) 1 else 0) +
                            @as(usize, if (y) 2 else 0)
                    ]) occ += 1;
                    // Darken occluded vertices
                    for (0..occ) |_| colour /= @splat(1.1);
                    try chunk.verts.appendSlice(&zm.vecToArr3(colour));
                }
            }
        }
    }

    fn full(chunk: *Chunk, world: World, pos: zm.Vec, offset: zm.Vec) ?bool {
        if (chunk.densityFromPos(pos)) |p| return p > 0;
        const i = world.indexFromOffset(pos + offset) catch return null;
        const off = world.offsetFromIndex(i);
        return world.chunks[i].full(world, pos + offset - off, off);
    }

    fn empty(chunk: *Chunk, world: World, pos: zm.Vec, offset: zm.Vec) ?bool {
        return if (chunk.full(world, pos, offset)) |e| !e else null;
    }

    fn densityFromPos(chunk: *Chunk, pos: zm.Vec) ?f32 {
        return chunk.density[indexFromPos(pos) catch return null];
    }

    fn indexFromPos(pos: zm.Vec) !usize {
        const floor = zm.floor(pos + zm.f32x4s(@as(f32, SIZE) / 2));
        var index: usize = 0;
        for (0..3) |d| {
            const i = 2 - d;
            if (floor[i] < 0 or floor[i] >= SIZE) return error.PositionOutsideChunk;
            index *= SIZE;
            index += @intFromFloat(floor[i]);
        }
        return index;
    }

    fn logBadPos(pos: zm.Vec) void {
        const half = @as(f32, SIZE) / 2;
        for (0..3) |d| {
            if (pos[d] < -half or pos[d] >= half) {
                std.log.err("Arg component {} of indexFromPos({}) is outside range -{}..{}", .{ d, pos, half, half });
                unreachable;
            }
        }
    }

    fn posFromIndex(index: usize) zm.Vec {
        const half = @as(f32, SIZE) / 2;
        return zm.f32x4(
            @floatFromInt(index % SIZE),
            @floatFromInt(index / SIZE % SIZE),
            @floatFromInt(index / SIZE / SIZE),
            0,
        ) - zm.f32x4(
            half - 0.5,
            half - 0.5,
            half - 0.5,
            0,
        );
    }
};
