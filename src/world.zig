const std = @import("std");
const gl = @import("gl");
const zm = @import("zmath");
const znoise = @import("znoise");
const Chunk = @import("chunk.zig").Chunk;
const Shader = @import("shader.zig").Shader;

pub const World = struct {
    pub const SIZE = Chunk.SIZE * CHUNKS;
    pub const CHUNKS = 4;

    alloc: std.mem.Allocator,
    shader: ?Shader,

    // Chunks are just 128 bytes ignoring memory allocated for density & verts
    // With a render distance of 128 chunks we would use 268 MB RAM, 32 = 4 MB
    // This is quite a lot but the chunks themselves will surely use lots more
    // Storing chunks simplifies creation, reduces allocations and indirection
    // Therefore it makes sense to have a large []chunk rather than a []*chunk
    // We are likely to use 70% or so of the chunks anyway, so are wasting 30%
    chunks: []Chunk,
    splits: zm.Vec,

    pub fn init(alloc: std.mem.Allocator, shader: ?Shader) !World {
        var world = World{
            .alloc = alloc,
            .shader = shader,
            .chunks = undefined,
            .splits = @splat(CHUNKS / 2),
        };

        world.chunks = try alloc.alloc(Chunk, CHUNKS * CHUNKS * CHUNKS);

        var count: usize = 0;
        errdefer {
            for (0..count) |i| {
                world.chunks[i].kill(world.alloc);
            }
            alloc.free(world.chunks);
            world.chunks = &.{};
        }

        // Assign uninitialised chunks
        for (world.chunks) |*chunk| {
            chunk.* = Chunk{
                .density = &.{},
                .verts = std.ArrayList(f32).init(alloc),
                .mesh = undefined,
            };
            errdefer chunk.verts.deinit();
            chunk.mesh = try @TypeOf(chunk.mesh).init(shader);
            count += 1;
        }

        var timer = try std.time.Timer.start();
        var ns: f32 = undefined;

        // Generate density for all chunks TODO only do this for closest chunks
        for (0.., world.chunks) |i, *chunk| {
            chunk.density = try alloc.alloc(f32, Chunk.SIZE * Chunk.SIZE * Chunk.SIZE);
            try chunk.genDensity(world.offsetFromIndex(i));
        }

        ns = @floatFromInt(timer.lap());
        std.debug.print("Density took {d:.3} ms\n", .{ns / 1_000_000});

        // Generate vertices for all chunks TODO only do this for closest chunks
        for (0.., world.chunks) |i, *chunk| {
            try chunk.genVerts(world, world.offsetFromIndex(i));
            chunk.verts.shrinkAndFree(chunk.verts.items.len);
            try chunk.mesh.upload(.{chunk.verts.items});
        }

        ns = @floatFromInt(timer.lap());
        std.debug.print("Vertices took {d:.3} ms\n", .{ns / 1_000_000});

        return world;
    }

    pub fn kill(world: *World) void {
        for (world.chunks) |*chunk| {
            chunk.kill(world.alloc);
        }
        world.alloc.free(world.chunks);
        world.chunks = &.{};
    }

    pub fn draw(world: World, shader: Shader) void {
        for (0.., world.chunks) |i, chunk| {
            if (chunk.density.len == 0) continue; // The chunk has no densities
            if (chunk.verts.items.len == 0) continue; // The chunk has no verts
            shader.set("model", f32, &zm.matToArr(zm.translationV(world.offsetFromIndex(i))));
            chunk.mesh.draw(gl.TRIANGLES);
        }
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
        var offset = (zm.f32x4(
            @floatFromInt(index % CHUNKS),
            @floatFromInt(index / CHUNKS % CHUNKS),
            @floatFromInt(index / CHUNKS / CHUNKS),
            0,
        ) + zm.f32x4(0.5, 0.5, 0.5, 0));
        for (0..3) |i| {
            offset[i] += @floor(world.splits[i] / CHUNKS) * CHUNKS;
            if (@mod(offset[i], CHUNKS) >= @mod(world.splits[i], CHUNKS)) offset[i] -= CHUNKS;
        }
        return offset * zm.f32x4s(Chunk.SIZE);
    }
};
