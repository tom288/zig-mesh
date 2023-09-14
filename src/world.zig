const std = @import("std");
const gl = @import("gl");
const zm = @import("zmath");
const znoise = @import("znoise");
const Chunk = @import("chunk.zig").Chunk;
const Shader = @import("shader.zig").Shader;

pub const World = struct {
    pub const SIZE = Chunk.SIZE * CHUNKS;
    const CHUNKS = 1;

    alloc: std.mem.Allocator,

    // Chunks are just 128 bytes ignoring memory allocated for density & verts
    // With a render distance of 128 chunks we would use 268 MB RAM, 32 = 4 MB
    // This is quite a lot but the chunks themselves will surely use lots more
    // Storing chunks simplifies creation, reduces allocations and indirection
    // Therefore it makes sense to have a large []chunk rather than a []*chunk
    // We are likely to use 70% or so of the chunks anyway, so are wasting 30%
    chunks: []Chunk,

    pub fn init(alloc: std.mem.Allocator) !World {
        var world = World{
            .alloc = alloc,
            .chunks = undefined,
        };

        world.chunks = try alloc.alloc(Chunk, CHUNKS * CHUNKS * CHUNKS);
        errdefer world.chunks = &.{};
        errdefer alloc.free(world.chunks);

        for (0.., world.chunks) |i, *chunk| {
            chunk.* = try Chunk.init(alloc, offsetFromIndex(i));
        }

        return world;
    }

    pub fn kill(world: *World) void {
        for (world.chunks) |*chunk| {
            chunk.*.kill(world.alloc);
        }
        world.alloc.free(world.chunks);
        world.chunks = &.{};
    }

    pub fn draw(world: World, shader: Shader) void {
        for (0.., world.chunks) |i, chunk| {
            if (chunk.density.len == 0) return;
            shader.set("model", f32, &zm.matToArr(zm.translationV(offsetFromIndex(i))));
            chunk.mesh.draw(gl.TRIANGLES);
        }
    }

    fn offsetFromIndex(index: usize) zm.Vec {
        _ = index;
        return @splat(0);
    }
};
