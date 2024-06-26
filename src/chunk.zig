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
const CFG = @import("cfg.zig");

pub const Chunk = struct {
    // The fullness at internal grid positions
    density: []f32,

    // The triangle surface data of this chunk
    surface: ?std.ArrayList(f32),

    mesh: Mesh(.{.{
        .{ .name = "position", .size = 3, .type = gl.FLOAT },
        .{ .name = "padding", .size = 4, .type = gl.UNSIGNED_BYTE },
        .{ .name = "normal", .size = 3, .type = gl.FLOAT },
        .{ .name = "colour", .size = 4, .type = gl.UNSIGNED_BYTE },
    }}),

    // Whether this chunk is no longer part of the visible world
    must_free: bool,

    // Mip levels
    density_mip: ?usize,
    surface_mip: ?usize,
    gpu_mip: ?usize,

    // The mip level currently being calculated
    wip_mip: ?usize,

    // The world splits used in the ongoing calculations for this chunk
    splits_copy: ?zm.Vec,

    // The number of other chunk threads which are using this chunk
    density_refs: usize,

    density_buffer: ?gl.GLuint,
    atomics_buffer: ?gl.GLuint,

    pub fn free(chunk: *@This(), alloc: std.mem.Allocator, gpu: bool) void {
        if (chunk.wip_mip) |_| unreachable;
        if (chunk.density_refs > 0) unreachable;
        if (gpu) {
            chunk.mesh.vert_count = 0;
            chunk.gpu_mip = null;
        }
        if (chunk.surface) |_| {
            chunk.surface.?.clearAndFree();
            chunk.surface = null;
        }
        chunk.surface_mip = null;
        alloc.free(chunk.density);
        chunk.density = &.{};
        chunk.density_mip = null;
        chunk.must_free = false;
        chunk.splits_copy = null;
    }

    pub fn kill(chunk: *@This(), alloc: std.mem.Allocator) void {
        if (chunk.density_buffer) |density_buffer| {
            gl.deleteBuffers(1, &density_buffer);
            chunk.density_buffer = null;
        }
        if (chunk.atomics_buffer) |atomics_buffer| {
            gl.deleteBuffers(1, &atomics_buffer);
            chunk.atomics_buffer = null;
        }
        chunk.mesh.kill();
        chunk.mesh = undefined;
        chunk.free(alloc, false);
        chunk.gpu_mip = null;
    }

    pub fn genDensity(chunk: *@This(), offset: zm.Vec) !void {
        CFG.density.gen(chunk, offset);
    }

    pub fn genSurface(chunk: *@This(), world: World, offset: zm.Vec) !void {
        chunk.surface.?.clearRetainingCapacity();
        for (0..chunk.density.len) |i| {
            try CFG.surface.gen(chunk, world, chunk.posFromIndex(i), offset);
        }
        chunk.surface.?.shrinkAndFree(chunk.surface.?.items.len);
    }

    pub fn posFromIndex(chunk: @This(), index: usize) zm.Vec {
        const mip_level = chunk.wip_mip orelse chunk.density_mip.?;
        const mip_scale = std.math.pow(f32, 2, @floatFromInt(mip_level));
        const size = CFG.chunk_blocks / @as(usize, @intFromFloat(mip_scale));
        const half = @as(f32, @floatFromInt(size)) / 2;
        return (zm.f32x4(
            @floatFromInt(index % size),
            @floatFromInt(index / size % size),
            @floatFromInt(index / size / size),
            half - CFG.surface.CELL_OFFSET,
        ) + zm.f32x4s(CFG.surface.CELL_OFFSET - half)) * zm.f32x4s(mip_scale);
    }

    pub fn indexFromPos(chunk: *@This(), _pos: zm.Vec) !usize {
        const mip_level = chunk.wip_mip orelse chunk.density_mip.?;
        const mip_scale = std.math.pow(f32, 2, @floatFromInt(mip_level));
        const size = CFG.chunk_blocks / @as(usize, @intFromFloat(mip_scale));

        const pos = zm.floor((_pos + zm.f32x4s(@as(f32, CFG.chunk_blocks) / 2)) / zm.f32x4s(mip_scale));
        var index: usize = 0;
        for (0..3) |d| {
            const i = 2 - d;
            if (pos[i] < 0 or pos[i] >= @as(f32, @floatFromInt(size))) return error.PositionOutsideChunk;
            index *= size;
            index += @intFromFloat(pos[i]);
        }
        return index;
    }

    pub fn dig(chunk: *@This(), pos: zm.Vec, rad: f32) !void {
        std.debug.assert(rad >= 0);
        var corner = pos - zm.f32x4s(rad);
        corner[3] = 0;
        const iters: usize = @intFromFloat(@ceil(rad * 2) + 1);

        for (0..iters) |k| {
            const z = @as(f32, @floatFromInt(k));
            for (0..iters) |j| {
                const y = @as(f32, @floatFromInt(j));
                for (0..iters) |i| {
                    const x = @as(f32, @floatFromInt(i));
                    const block_pos = corner + zm.f32x4(x, y, z, 0);
                    const block_index = chunk.indexFromPos(block_pos) catch continue;
                    chunk.density[block_index] -= @max(rad - zm.length3(block_pos - pos)[0], 0);
                }
            }
        }
    }
};
