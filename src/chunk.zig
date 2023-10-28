//! A Chunk holds information about a cubic region of the visible world.
//! Chunk densities indicate the fullness at internal grid positions.
//! Chunks also hold vertex data which is derived from the densities
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

    // The triangle vertex data of this chunk
    verts: std.ArrayList(f32),

    mesh: Mesh(.{.{
        .{ .name = "position", .size = 3, .type = gl.FLOAT },
        .{ .name = "colour", .size = 3, .type = gl.FLOAT },
    }}),

    // Whether this chunk is no longer part of the visible world
    must_free: bool,

    // Mip levels
    density_mip: ?usize,
    vertices_mip: ?usize,

    // The mip level currently being calculated
    wip_mip: ?usize,

    // The world splits used in the ongoing calculations for this chunk
    splits_copy: ?zm.Vec,

    // The number of other chunk threads which are using this chunk
    density_refs: usize,

    pub fn free(chunk: *Chunk, alloc: std.mem.Allocator, gpu: bool) void {
        if (chunk.wip_mip) |_| unreachable;
        if (chunk.density_refs > 0) unreachable;
        if (gpu) chunk.mesh.upload(.{}) catch {};
        if (chunk.vertices_mip) |_| chunk.verts.deinit();
        chunk.vertices_mip = null;
        alloc.free(chunk.density);
        chunk.density = &.{};
        chunk.density_mip = null;
        chunk.must_free = false;
        chunk.splits_copy = null;
    }

    pub fn kill(chunk: *Chunk, alloc: std.mem.Allocator) void {
        chunk.mesh.kill();
        chunk.free(alloc, false);
    }

    pub fn genDensity(chunk: *Chunk, offset: zm.Vec) !void {
        const variant = 5;
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
                    .frequency = 0.8 / @as(f32, SIZE),
                    .noise_type = znoise.FnlGenerator.NoiseType.perlin,
                };
                for (0..chunk.density.len) |i| {
                    const pos = chunk.posFromIndex(i) + offset;
                    chunk.density[i] = gen.noise3(pos[0], pos[1], pos[2]);
                }
            },
            5 => { // Gradient noise (opensimplex2)
                const gen = znoise.FnlGenerator{
                    .frequency = 0.6 / @as(f32, SIZE),
                };
                for (0..chunk.density.len) |i| {
                    const pos = chunk.posFromIndex(i) + offset;
                    chunk.density[i] = gen.noise3(pos[0], pos[1], pos[2]);
                }
            },
            6 => { // Smooth sphere
                const rad = @as(f32, SIZE) * 2.5;
                for (0..chunk.density.len) |i| {
                    const pos = chunk.posFromIndex(i) + offset + zm.f32x4(0, 0, rad + SIZE, 0);
                    chunk.density[i] = rad - zm.length3(pos)[0];
                }
            },
            7 => { // Splattered sphere
                const rad = @as(f32, SIZE) * 2.5;
                const gen = znoise.FnlGenerator{ .frequency = 4 / rad };
                for (0..chunk.density.len) |i| {
                    const pos = chunk.posFromIndex(i) + offset + zm.f32x4(0, 0, rad + SIZE, 0);
                    chunk.density[i] = rad * 0.92 - zm.length3(pos)[0];
                    chunk.density[i] += gen.noise3(pos[0], pos[1], pos[2]) * rad * 0.1;
                }
            },
            8 => { // Chunk corner visualisation
                for (0..chunk.density.len) |i| {
                    const pos = @fabs(chunk.posFromIndex(i));
                    const bools = zm.abs(pos - zm.f32x4s(@as(f32, SIZE - 1) / 2)) > zm.f32x4s(0.5);
                    chunk.density[i] = if (zm.any(bools, 3)) 0 else 1;
                }
            },
            // 9 => { // Alan
            //     const offset2 = zm.floor(offset / zm.f32x4s(Chunk.SIZE));
            //     var feature_biome: u4 = @intFromFloat(@mod(offset2[0] / 4, 7));
            //     if (@mod(offset2[0], 4) == 0) feature_biome = 7; // 7 --> "empty space" biome
            //     const gen: znoise.FnlGenerator =
            //         znoise.FnlGenerator{ .frequency = 0.4 / @as(f32, SIZE) };
            //     // feature_biome = 6; // temp
            //     for (0..chunk.density.len) |i| {
            //         genAlanBlock(i, chunk, offset, feature_biome, gen);
            //     }
            // },
            9 => { // Alan
                const gen: znoise.FnlGenerator =
                    znoise.FnlGenerator{ .frequency = 0.4 / @as(f32, SIZE) };
                for (0..chunk.density.len) |i| {
                    genAlanBlockSimple(i, chunk, offset, gen);
                }
            },
            else => unreachable,
        }
    }

    fn genAlanBlockSimple(block_id: usize, chunk: *Chunk, offset: zm.Vec, gen: znoise.FnlGenerator) void {
        const feature_magnitudes = [_]f32{ 0, 0, 0, 0.05, 0, 0, 0, 1, 0, 0, 0 };
        const feature_thin_counts = [_]u4{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
        const ground_gradient = 0.03;
        // ---
        // const feature_magnitudes = [_]f32{ 0, 0, 0, 0, 0, 0.3, 0, 0, 1, 0, 0 };
        // const feature_thin_counts = [_]u4{ 0, 0, 0, 0, 0, 2, 0, 0, 2, 0, 0 };
        // const ground_gradient = 0.02; // this may supposed to be larger
        // ---
        var feature_wavelength: f32 = 0.02; // smallest feature
        const pos = chunk.posFromIndex(block_id) + offset;
        chunk.density[block_id] = 0;
        for (0..feature_magnitudes.len) |pass| { // "octave" count
            feature_wavelength *= 2;
            const feature_magnitude = feature_magnitudes[pass];
            var feature = gen.noise3(
                pos[0] / feature_wavelength,
                pos[1] / feature_wavelength,
                pos[2] / feature_wavelength,
            );
            for (0..feature_thin_counts[pass]) |_| {
                feature *= if (feature > 0) feature else -feature;
            }
            chunk.density[block_id] += feature * feature_magnitude;
            // todo: offset the perlin noise with a 3-vec (xyz) perlin noise
        }
        chunk.density[block_id] -= pos[1] * ground_gradient;
    }

    fn genAlanBlock(block_id: usize, chunk: *Chunk, offset: zm.Vec, feature_biome: u4, gen: znoise.FnlGenerator) void {
        chunk.density[block_id] = 0;
        const pos = chunk.posFromIndex(block_id) + offset;
        var feature_params = switch (feature_biome) {
            // feature (wavelength, magnitude)
            0 => [2]i8{ 0, 0 }, // exp, exp --> normal, perlin
            1 => [2]i8{ 1, 0 }, // sqr, exp --> small
            2 => [2]i8{ 2, 0 }, // linier, exp --> smooth
            3 => [2]i8{ -1, 1 }, // exp2, linier --> gnarly
            4 => [2]i8{ 1, 1 }, // sqr, sqr --> small gnarly
            5 => [2]i8{ 2, 1 }, // linier, sqr --> smooth
            6 => [2]i8{ -2, 2 }, // exp3, linier --> noisy mess (work on me)
            7 => [2]i8{ 3, 0 }, // empty space
            8 => [2]i8{ 4, 0 }, // sqr2, exp --> normal
            9 => [2]i8{ 5, 0 }, // sqr3, exp --> large
            10 => [2]i8{ 0, -1 }, // exp, exp_y --> normal, perlin
            else => unreachable,
        };
        var feature_wavelength_func: i8 = feature_params[0];
        var feature_magnitude_func: i8 = feature_params[1];
        if (feature_wavelength_func != 3) { // 3 is for the "empty space" biome
            var feature_wavelength: f16 = 0.01; // smallest feature
            var feature_magnitude: f16 = 1;
            var pass: f16 = 0;
            for (0..7) |_| { // "octave" count
                pass += 1;
                if (feature_wavelength_func <= 0) {
                    feature_wavelength *= switch (feature_wavelength_func) {
                        0 => 2, // exp
                        -1 => 2.2, // exp2
                        -2 => 3.7, // exp3
                        else => unreachable,
                    };
                } else {
                    feature_wavelength = switch (feature_wavelength_func) {
                        1 => 0.01 * pass * pass, // sqr
                        2 => 0.1 * pass, // linier
                        3 => 0, // empty space
                        4 => 0.02 * pass * pass, // sqr2
                        5 => 0.04 * pass * pass, // sqr3
                        else => unreachable,
                    };
                }
                if (feature_magnitude_func <= 0) {
                    feature_magnitude *= switch (feature_magnitude_func) {
                        0 => 2, // exp
                        -1 => @floatCast(pos[1] * 0.1), // exp_y
                        else => unreachable,
                    };
                } else {
                    feature_magnitude = switch (feature_magnitude_func) {
                        1 => pass * pass, // sqr
                        2 => pass, // linier
                        else => unreachable,
                    };
                }
                chunk.density[block_id] += gen.noise3(
                    pos[0] / feature_wavelength,
                    pos[1] / feature_wavelength,
                    pos[2] / feature_wavelength,
                ) * feature_magnitude * SIZE; // todo: offset the perlin noise with a 3-vec (xyz) perlin noise
            }
        }
    }

    pub fn genVerts(chunk: *Chunk, world: World, offset: zm.Vec) !void {
        // Noise generator used for colour
        const gen = znoise.FnlGenerator{
            .frequency = 0.4 / @as(f32, SIZE),
        };
        for (0..chunk.density.len) |i| {
            try SURFACE.from(chunk, world, gen, chunk.posFromIndex(i), offset);
        }
        chunk.verts.shrinkAndFree(chunk.verts.items.len);
    }

    pub fn full(chunk: *Chunk, world: World, pos: zm.Vec, offset: zm.Vec, occ: bool, splits: ?zm.Vec) ?bool {
        if (chunk.densityFromPos(world, pos, offset, occ, splits)) |d| {
            return d > 0;
        } else {
            return null;
        }
    }

    pub fn empty(chunk: *Chunk, world: World, pos: zm.Vec, offset: zm.Vec, occ: bool, splits: ?zm.Vec) ?bool {
        return if (chunk.full(world, pos, offset, occ, splits)) |e| !e else null;
    }

    pub fn densityFromPos(chunk: *Chunk, world: World, pos: zm.Vec, offset: zm.Vec, occ: ?bool, splits: ?zm.Vec) ?f32 {
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

    fn indexFromPos(chunk: Chunk, pos: zm.Vec) !usize {
        const mip_level = chunk.wip_mip orelse chunk.density_mip.?;
        const mip_scale = std.math.pow(f32, 2, @floatFromInt(mip_level));
        const size = SIZE / @as(usize, @intFromFloat(mip_scale));

        const floor = zm.floor((pos + zm.f32x4s(@as(f32, SIZE) / 2)) / zm.f32x4s(mip_scale));
        var index: usize = 0;
        for (0..3) |d| {
            const i = 2 - d;
            if (floor[i] < 0 or floor[i] >= @as(f32, @floatFromInt(size))) return error.PositionOutsideChunk;
            index *= size;
            index += @intFromFloat(floor[i]);
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
