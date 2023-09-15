const std = @import("std");
const gl = @import("gl");
const zm = @import("zmath");
const znoise = @import("znoise");
const Chunk = @import("chunk.zig").Chunk;
const Shader = @import("shader.zig").Shader;

pub const World = struct {
    pub const SIZE = Chunk.SIZE * CHUNKS;
    const CHUNKS = 4;

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
            chunk.mesh = try @TypeOf(chunk.mesh).init(null); // TODO pass shader
            count += 1;
        }

        var timer = try std.time.Timer.start();
        var ns: f32 = undefined;

        // Generate density for all chunks TODO only do this for closest chunks
        for (0.., world.chunks) |i, *chunk| {
            chunk.density = try alloc.alloc(f32, Chunk.SIZE * Chunk.SIZE * Chunk.SIZE);
            try chunk.genDensity(offsetFromIndex(i));
        }

        ns = @floatFromInt(timer.lap());
        std.debug.print("Density took {d:.3} ms\n", .{ns / 1_000_000});

        // Generate vertices for all chunks TODO only do this for closest chunks
        for (0.., world.chunks) |i, *chunk| {
            try chunk.genVerts(offsetFromIndex(i));
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
            if (chunk.density.len == 0) return; // The chunk is not initialised
            if (chunk.verts.items.len == 0) return; // The chunk has 0 vertices
            shader.set("model", f32, &zm.matToArr(zm.translationV(offsetFromIndex(i))));
            chunk.mesh.draw(gl.TRIANGLES);
        }
    }

    fn indexFromOffset(pos: zm.Vec) !usize {
        const floor = zm.floor(pos / Chunk.SIZE);
        var index: usize = 0;
        for (0..3) |d| {
            const i = 2 - d;
            if (floor[i] < 0 or floor[i] >= CHUNKS) return error.PositionOutsideWorld;
            index *= CHUNKS;
            index += @intFromFloat(floor[i]);
        }
        return index;
    }

    fn logBadOffset(pos: zm.Vec) !void {
        for (0..3) |d| {
            if (pos[d] < 0 or pos[d] >= SIZE) {
                std.log.err("Arg component {} of indexFromOffset({}) is outside range 0..{}", .{ d, pos, SIZE });
                return error.PositionOutsideWorld;
            }
        }
    }

    fn offsetFromIndex(index: usize) zm.Vec {
        return (zm.f32x4(
            @floatFromInt(index % CHUNKS),
            @floatFromInt(index / CHUNKS % CHUNKS),
            @floatFromInt(index / CHUNKS / CHUNKS),
            0,
        ) + zm.f32x4(0.5, 0.5, 0.5, 0)) * zm.f32x4s(Chunk.SIZE);
    }
};
