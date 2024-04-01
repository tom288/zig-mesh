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
const Density = @import("density.zig");

pub const Chunk = struct {
    pub const SIZE = 16;
    pub const DENSITY = Density.Perlin;
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
        DENSITY.gen(chunk, offset);
    }

    pub fn genSurface(chunk: *Chunk, world: World, offset: zm.Vec) !void {
        // Noise generator used for colour
        const gen = znoise.FnlGenerator{
            .frequency = 0.4 / @as(f32, SIZE),
        };
        for (0..chunk.density.len) |i| {
            try SURFACE.gen(chunk, world, gen, chunk.posFromIndex(i), offset);
        }
        chunk.surface.?.shrinkAndFree(chunk.surface.?.items.len);
    }

    pub fn posFromIndex(chunk: Chunk, index: usize) zm.Vec {
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
