const std = @import("std");
const gl = @import("gl");
const zm = @import("zmath");
const znoise = @import("znoise");
const Chunk = @import("chunk.zig").Chunk;
const Shader = @import("shader.zig").Shader;

pub const World = struct {
    pub const SIZE = Chunk.SIZE * CHUNKS;
    pub const CHUNKS = 16;
    const DENSITY_DIST = @as(f32, SIZE) / 2;
    const VERTICES_DIST = DENSITY_DIST - Chunk.SIZE * 2; // TODO sqrt(2) + .1 instead of 2

    alloc: std.mem.Allocator,
    chunk_alloc: std.mem.Allocator,
    shader: ?Shader,

    // Chunks are just 128 bytes ignoring memory allocated for density & verts
    // With a render distance of 128 chunks we would use 268 MB RAM, 32 = 4 MB
    // This is quite a lot but the chunks themselves will surely use lots more
    // Storing chunks simplifies creation, reduces allocations and indirection
    // Therefore it makes sense to have a large []chunk rather than a []*chunk
    // We are likely to use 70% or so of the chunks anyway, so are wasting 30%
    chunks: []Chunk,
    splits: zm.Vec,
    old_pos: zm.Vec,

    pub fn init(alloc: std.mem.Allocator, chunk_alloc: std.mem.Allocator, shader: ?Shader, cam_pos: ?zm.Vec) !World {
        const pos = cam_pos orelse zm.f32x4s(0);
        var world = World{
            .alloc = alloc,
            .chunk_alloc = chunk_alloc,
            .shader = shader,
            .chunks = try alloc.alloc(Chunk, CHUNKS * CHUNKS * CHUNKS),
            .splits = splitsFromPos(pos),
            .old_pos = pos,
        };

        var count: usize = 0;
        errdefer {
            for (world.chunks) |*chunk| {
                chunk.kill(chunk_alloc);
            }
            alloc.free(world.chunks);
            world.chunks = &.{};
        }

        // Assign uninitialised chunks
        for (world.chunks) |*chunk| {
            chunk.* = Chunk{
                .density = &.{},
                .verts = null,
                .mesh = try @TypeOf(chunk.mesh).init(shader),
            };
            count += 1;
        }

        try world.focus(null);

        return world;
    }

    pub fn kill(world: *World) void {
        for (world.chunks) |*chunk| {
            chunk.kill(world.chunk_alloc);
        }
        world.alloc.free(world.chunks);
        world.chunks = &.{};
    }

    pub fn draw(world: World, shader: Shader) void {
        for (0.., world.chunks) |i, chunk| {
            if (chunk.density.len == 0) continue; // The chunk has no densities
            if (chunk.verts == null) continue; // The chunk has no verts
            shader.set("model", f32, &zm.matToArr(zm.translationV(world.offsetFromIndex(i))));
            chunk.mesh.draw(gl.TRIANGLES);
        }
    }

    pub fn focus(world: *World, position: ?zm.Vec) !void {
        const pos = position orelse world.old_pos;
        const same_pos = if (position) |p| p == world.old_pos else pos != pos;
        if (position) |_| if (zm.all(same_pos, 3)) return;

        const new_splits = splitsFromPos(pos);
        const print = position == null;
        var timer = try std.time.Timer.start();
        var ns: f32 = undefined;
        var free_ns: f32 = 0;

        // TODO use components of same_pos to reduce complexity by CHUNKS
        // TODO use early exit to reduce complexity even further
        // - e.g. some version of 'if the next closest is too far then quit looping'
        for (0.., world.chunks) |i, *chunk| {
            const old_offset = world.offsetFromIndex(i);
            const offset = offsetFromIndexAndSplits(i, new_splits);
            if (zm.any(old_offset != offset, 3)) {
                const old_splits = world.splits;
                // Update splits TODO make this update minimal
                world.splits = new_splits;
                if (print) std.debug.print("{any}\n", .{world.splits});
                // Free invalidated chunks
                var free_timer = try std.time.Timer.start();
                for (0.., world.chunks) |j, *c| {
                    // TODO avoid this check by only looping over invalidated chunks
                    if (zm.all(world.offsetFromIndex(j) == offsetFromIndexAndSplits(j, old_splits), 3)) continue;
                    if (c.verts) |verts| {
                        verts.deinit();
                        c.verts = null;
                        try c.mesh.upload(.{});
                    }
                    world.chunk_alloc.free(c.density);
                    c.density = &.{};
                }
                free_ns = @floatFromInt(free_timer.read());
                if (print) std.debug.print("Frees took {d:.3} ms\n", .{free_ns / 1_000_000});
            }
            if (chunk.density.len > 0) continue;
            if (zm.length3(offset - pos)[0] > DENSITY_DIST) continue;
            chunk.density = try world.chunk_alloc.alloc(f32, Chunk.SIZE * Chunk.SIZE * Chunk.SIZE);
            try chunk.genDensity(offset);
        }
        ns = @floatFromInt(timer.read());
        ns -= free_ns;
        if (print) std.debug.print("Density took {d:.3} ms\n", .{ns / 1_000_000});
        timer.reset();

        for (0.., world.chunks) |i, *chunk| {
            if (chunk.verts) |_| continue;
            const offset = world.offsetFromIndex(i);
            if (zm.lengthSq3(offset - pos)[0] > VERTICES_DIST * VERTICES_DIST) continue;
            chunk.verts = std.ArrayList(f32).init(world.chunk_alloc);
            try chunk.genVerts(world.*, offset);
            if (chunk.verts) |*verts| {
                verts.shrinkAndFree(verts.items.len);
                try chunk.mesh.upload(.{verts.items});
            }
        }

        ns = @floatFromInt(timer.read());
        if (print) std.debug.print("Vertices took {d:.3} ms\n", .{ns / 1_000_000});
    }

    pub fn indexFromOffset(world: World, pos: zm.Vec) !usize {
        const floor = zm.floor(pos / zm.f32x4s(Chunk.SIZE));
        var index: usize = 0;
        for (0..3) |d| {
            const i = 2 - d;
            var f = floor[i] - @floor(world.splits[i] / CHUNKS) * CHUNKS;
            if (@mod(f, CHUNKS) >=
                @mod(world.splits[i], CHUNKS)) f += CHUNKS;
            if (f < 0 or f >= CHUNKS) return error.PositionOutsideWorld;
            index *= CHUNKS;
            index += @intFromFloat(f);
        }
        return index;
    }

    pub fn offsetFromIndex(world: World, index: usize) zm.Vec {
        return offsetFromIndexAndSplits(index, world.splits);
    }

    fn offsetFromIndexAndSplits(index: usize, splits: zm.Vec) zm.Vec {
        var offset = (zm.f32x4(
            @floatFromInt(index % CHUNKS),
            @floatFromInt(index / CHUNKS % CHUNKS),
            @floatFromInt(index / CHUNKS / CHUNKS),
            0,
        ) + zm.f32x4(0.5, 0.5, 0.5, 0));
        for (0..3) |i| {
            offset[i] += @floor(splits[i] / CHUNKS) * CHUNKS;
            if (@mod(offset[i], CHUNKS) >=
                @mod(splits[i], CHUNKS)) offset[i] -= CHUNKS;
        }
        return offset * zm.f32x4s(Chunk.SIZE);
    }

    fn splitsFromPos(pos: zm.Vec) zm.Vec {
        var splits = zm.floor(pos / zm.f32x4s(Chunk.SIZE)) + zm.f32x4s(CHUNKS / 2);
        splits[3] = 0;
        return splits;
    }
};
