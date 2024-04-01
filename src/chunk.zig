//! A Chunk holds information about a cubic region of the visible world.
//! Chunk densities indicate the fullness at internal grid positions.
//! Chunks also hold surface data which is derived from the density.
//! of the current Chunk and its neighbours.
//! The memory of one distant Chunk may be reused to represent a closer Chunk.

const std = @import("std");
const gl = @import("gl");
const zm = @import("zmath");
const znoise = @import("znoise");
const Mesh = @import("mesh.zig").Mesh;
const World = @import("world.zig").World;
const Surface = @import("surface.zig");

pub const Chunk = struct {
    pub const SIZE = 16;
    pub const SURFACE = Surface.Voxel;

    // The fullness at internal grid positions
    density: []f32,

    // The triangle surface data of this chunk
    surface: ?std.ArrayList(f32),

    mesh: Mesh(.{.{
        .{ .name = "position", .size = 3, .type = gl.FLOAT },
        .{ .name = "normal", .size = 3, .type = gl.FLOAT },
        .{ .name = "colour", .size = 4, .type = gl.UNSIGNED_BYTE },
    }}),

    // Whether this chunk is no longer part of the visible world
    must_free: bool,

    // Mip levels
    density_mip: ?usize,
    surface_mip: ?usize,

    // The mip level currently being calculated
    wip_mip: ?usize,

    // The world splits used in the ongoing calculations for this chunk
    splits_copy: ?zm.Vec,

    // The number of other chunk threads which are using this chunk
    density_refs: usize,

    density_buffer: ?gl.GLuint,
    atomics_buffer: ?gl.GLuint,

    pub fn free(chunk: *Chunk, alloc: std.mem.Allocator, gpu: bool) void {
        if (chunk.wip_mip) |_| unreachable;
        if (chunk.density_refs > 0) unreachable;
        if (gpu) chunk.mesh.vert_count = 0;
        if (chunk.surface) |surface| {
            surface.deinit();
            chunk.surface = null;
        }
        chunk.surface_mip = null;
        alloc.free(chunk.density);
        chunk.density = &.{};
        chunk.density_mip = null;
        chunk.must_free = false;
        chunk.splits_copy = null;
    }

    pub fn kill(chunk: *Chunk, alloc: std.mem.Allocator) void {
        if (chunk.density_buffer) |density_buffer| {
            gl.deleteBuffers(1, &density_buffer);
            chunk.density_buffer = null;
        }
        if (chunk.atomics_buffer) |atomics_buffer| {
            gl.deleteBuffers(1, &atomics_buffer);
            chunk.atomics_buffer = null;
        }
        chunk.mesh.kill();
        chunk.free(alloc, false);
    }

    pub fn genDensity(chunk: *Chunk, offset: zm.Vec) !void {
        const variant = 4;
        switch (variant) {
            0, 1 => { // Empty, Full
                for (0..chunk.density.len) |i| {
                    chunk.density[i] = variant;
                }
            },
            2 => { // Medium vertex density
                for (0..chunk.density.len) |i| {
                    chunk.density[i] = if (i % 9 > 0) 0 else 1;
                }
            },
            3 => { // Max vertex density
                for (0..chunk.density.len) |i| {
                    const pos = chunk.posFromIndex(i);
                    chunk.density[i] = @mod(
                        pos[0] + pos[1] + pos[2] +
                            if (Chunk.SIZE % 4 != 1) 0 else 1 -
                            if (Chunk.SIZE % 2 > 0) 0 else 0.5,
                        2,
                    );
                }
            },
            4 => { // Gradient noise (perlin)
                const gen = znoise.FnlGenerator{
                    .frequency = 0.75 / @as(f32, SIZE),
                    .noise_type = .perlin,
                };
                for (0..chunk.density.len) |i| {
                    const pos = chunk.posFromIndex(i) + offset;
                    chunk.density[i] = gen.noise3(pos[0], pos[1], pos[2]);
                }
            },
            5 => { // Gradient noise (opensimplex2)
                const gen = znoise.FnlGenerator{
                    .frequency = 0.5 / @as(f32, SIZE),
                };
                for (0..chunk.density.len) |i| {
                    const pos = chunk.posFromIndex(i) + offset;
                    chunk.density[i] = gen.noise3(pos[0], pos[1], pos[2]);
                }
            },
            6 => { // Smooth sphere
                const rad = @as(f32, SIZE) * 2.5;
                for (0..chunk.density.len) |i| {
                    const pos = chunk.posFromIndex(i) + offset +
                        zm.f32x4(0, 0, rad + SIZE, 0);
                    chunk.density[i] = rad - zm.length3(pos)[0];
                }
            },
            7 => { // Splattered sphere
                const rad = @as(f32, SIZE) * 2.5;
                const gen = znoise.FnlGenerator{ .frequency = 4 / rad };
                for (0..chunk.density.len) |i| {
                    const pos = chunk.posFromIndex(i) + offset +
                        zm.f32x4(0, 0, rad + SIZE, 0);
                    chunk.density[i] = rad * 0.92 - zm.length3(pos)[0];
                    const noise = gen.noise3(pos[0], pos[1], pos[2]);
                    chunk.density[i] += noise * rad * 0.1;
                }
            },
            8 => { // Chunk corner visualisation
                for (0..chunk.density.len) |i| {
                    const pos = @abs(chunk.posFromIndex(i));
                    const diff = @abs(pos - zm.f32x4s(@as(f32, SIZE - 1) / 2));
                    const corner = zm.all(diff <= zm.f32x4s(0.5), 3);
                    chunk.density[i] = if (corner) 1 else 0;
                }
            },
            9 => { // Alan
                // todo: build a movement system, like a hovercraft
                const biome: u4 = 6;
                if (biome > 6) return error.BadBiome;
                const noThin = [_]u4{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
                const feature_biomes_magnitudes = [_][11]f32{
                    .{ 0, 0.00, 0.00, 0.100, 0.00, 0.30, 0.00, 0.0, 0, 0, 0 }, // hinter hills
                    .{ 0, 0.00, 0.00, 0.000, 0.00, 0.30, 0.00, 0.0, 1, 0, 0 }, // war zone
                    .{ 0, 0.00, 0.00, 0.050, 0.00, 0.00, 0.00, 1.0, 0, 0, 0 }, // wales
                    .{ 0, 0.00, 0.02, 0.020, 0.20, 0.50, 1.20, 0.0, 0, 0, 0 }, // mount optimum
                    .{ 0, 0.02, 0.05, 0.050, 0.20, 0.00, 0.00, 0.0, 0, 0, 0 }, // mount lesser optimum
                    .{ 0, 0.00, 0.00, 0.005, 0.05, 0.10, 0.10, 0.2, 0, 0, 0 }, // smooth
                    .{ 0, 0.00, 0.00, 0.005, 0.02, 0.05, 0.05, 0.2, 0, 0, 0 }, // muddy
                };
                const feature_biomes_thin_counts = [_][11]u4{
                    .{ 0, 0.00, 0.00, 1.000, 0.00, 1.00, 0.00, 0.0, 0, 0, 0 }, // hinter hills
                    .{ 0, 0.00, 0.00, 0.000, 0.00, 1.00, 0.00, 0.0, 2, 0, 0 }, // war zone
                    .{ 0, 0.00, 0.00, 0.000, 0.00, 0.00, 0.00, 0.0, 0, 0, 0 }, // wales
                    noThin, noThin, // mount optimum, mount lesser optimum,
                    noThin, noThin, // smooth, muddy
                };
                const feature_magnitudes = feature_biomes_magnitudes[biome];
                const feature_thin_counts = feature_biomes_thin_counts[biome];
                const gen: znoise.FnlGenerator =
                    znoise.FnlGenerator{ .seed = 0, .frequency = 0.4 / @as(f32, SIZE) };
                for (0..chunk.density.len) |i| {
                    chunk.density[i] = try genAlanBlockSimple(
                        chunk.posFromIndex(i) + offset,
                        feature_magnitudes,
                        feature_thin_counts,
                        gen,
                    );
                }
                //if (genAlanBlockHasTree()) genAlanBlockDrawTree();
            },
            else => unreachable,
        }
    }

    // fn genAlanBlockDrawTree(
    //     world_pos: zm.Vec,
    //     gen: znoise.FnlGenerator) {
    //     ;
    // }

    // fn genAlanBlockHasTree() bool {
    //     return true;
    // }

    fn genAlanBlockSimple(
        world_pos: zm.Vec,
        feature_magnitudes: [11]f32,
        feature_thin_counts: [11]u4,
        gen: znoise.FnlGenerator,
    ) !f32 {
        const ground_gradient = 0.03;
        var feature_wavelength: f32 = 0.02; // smallest feature
        // ---
        var density: f32 = 0;
        for (0..feature_magnitudes.len) |pass| { // "octave" count
            const feature_magnitude = feature_magnitudes[pass];
            feature_wavelength *= 2;
            if (feature_magnitude != 0) {
                var feature = gen.noise3(
                    world_pos[0] / feature_wavelength,
                    world_pos[1] / feature_wavelength,
                    world_pos[2] / feature_wavelength,
                );
                for (0..feature_thin_counts[pass]) |_| {
                    feature *= if (feature > 0) feature else -feature;
                }
                density += feature * feature_magnitude;
            }
        }
        return density - world_pos[1] * ground_gradient;
    }

    pub fn genSurface(chunk: *Chunk, world: World, offset: zm.Vec) !void {
        // Noise generator used for colour
        const gen = znoise.FnlGenerator{
            .frequency = 0.4 / @as(f32, SIZE),
        };
        for (0..chunk.density.len) |i| {
            try SURFACE.from(chunk, world, gen, chunk.posFromIndex(i), offset);
        }
        chunk.surface.?.shrinkAndFree(chunk.surface.?.items.len);
    }

    pub fn full(
        chunk: *Chunk,
        world: World,
        pos: zm.Vec,
        offset: zm.Vec,
        occ: bool,
        splits: ?zm.Vec,
    ) ?bool {
        if (chunk.densityFromPos(world, pos, offset, occ, splits)) |d| {
            return d > 0;
        } else {
            return null;
        }
    }

    pub fn empty(
        chunk: *Chunk,
        world: World,
        pos: zm.Vec,
        offset: zm.Vec,
        occ: bool,
        splits: ?zm.Vec,
    ) ?bool {
        return if (chunk.full(world, pos, offset, occ, splits)) |e| !e else null;
    }

    pub fn densityFromPos(
        chunk: *Chunk,
        world: World,
        pos: zm.Vec,
        offset: zm.Vec,
        occ: ?bool,
        splits: ?zm.Vec,
    ) ?f32 {
        const spl = splits orelse chunk.splits_copy.?;
        if (chunk.densityLocal(pos)) |d| return d;
        if (chunk.wip_mip != 0 and occ == false) return 0;
        const i = world.indexFromOffset(pos + offset, spl) catch unreachable;
        const off = world.offsetFromIndex(i, spl);
        return world.chunks[i].densityFromPos(world, pos + offset - off, off, occ, spl);
    }

    fn densityLocal(chunk: *Chunk, pos: zm.Vec) ?f32 {
        return chunk.density[chunk.indexFromPos(pos) catch return null];
    }

    fn indexFromPos(chunk: Chunk, _pos: zm.Vec) !usize {
        const mip_level = chunk.wip_mip orelse chunk.density_mip.?;
        const mip_scale = std.math.pow(f32, 2, @floatFromInt(mip_level));
        const size = SIZE / @as(usize, @intFromFloat(mip_scale));

        const pos = zm.floor((_pos + zm.f32x4s(@as(f32, SIZE) / 2)) / zm.f32x4s(mip_scale));
        var index: usize = 0;
        for (0..3) |d| {
            const i = 2 - d;
            if (pos[i] < 0 or pos[i] >= @as(f32, @floatFromInt(size))) return error.PositionOutsideChunk;
            index *= size;
            index += @intFromFloat(pos[i]);
        }
        return index;
    }

    fn posFromIndex(chunk: Chunk, index: usize) zm.Vec {
        const mip_level = chunk.wip_mip orelse chunk.density_mip.?;
        const mip_scale = std.math.pow(f32, 2, @floatFromInt(mip_level));
        const size = SIZE / @as(usize, @intFromFloat(mip_scale));
        const half = @as(f32, @floatFromInt(size)) / 2;
        return (zm.f32x4(
            @floatFromInt(index % size),
            @floatFromInt(index / size % size),
            @floatFromInt(index / size / size),
            half - SURFACE.CELL_OFFSET,
        ) + zm.f32x4s(SURFACE.CELL_OFFSET - half)) * zm.f32x4s(mip_scale);
    }
};
