const std = @import("std");
const gl = @import("gl");
const zm = @import("zmath");
const Chunk = @import("chunk.zig").Chunk;
const Shader = @import("shader.zig").Shader;
const Pool = @import("pool.zig").Pool;

pub const World = struct {
    const SIZE = Chunk.SIZE * CHUNKS;
    const CHUNKS = 16;
    const DENSITY_DIST = @as(f32, SIZE) / 2;
    // Vertex occluslusion depends on density of neighbours
    // These neighbours may be connected by 3D diagonals hence sqrt(3)
    const VERTICES_DIST = DENSITY_DIST - Chunk.SIZE * @sqrt(3.0);

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
    pool: Pool,

    pub fn init(alloc: std.mem.Allocator, chunk_alloc: std.mem.Allocator, shader: ?Shader, cam_pos: ?zm.Vec) !World {
        const pos = cam_pos orelse zm.f32x4s(0);
        var world = World{
            .alloc = alloc,
            .chunk_alloc = chunk_alloc,
            .shader = shader,
            .chunks = try alloc.alloc(Chunk, CHUNKS * CHUNKS * CHUNKS),
            .splits = splitsFromPos(pos),
            .old_pos = pos,
            .pool = undefined,
        };

        var count: usize = 0;
        errdefer {
            for (world.chunks) |*chunk| {
                chunk.kill(chunk_alloc);
            }
            alloc.free(world.chunks);
            world.chunks = &.{};
        }

        world.pool = try Pool.init(alloc);
        errdefer world.pool.kill(alloc);

        // Assign uninitialised chunks
        for (world.chunks) |*chunk| {
            chunk.* = .{
                .density = &.{},
                .verts = null,
                .mesh = try @TypeOf(chunk.mesh).init(shader),
                .density_wip = false,
                .vertices_wip = false,
            };
            count += 1;
        }

        try world.focus(null);

        return world;
    }

    pub fn kill(world: *World) void {
        // Wait for the other threads
        outer: while (true) {
            for (world.pool.busy_bools, world.pool.wait_bools) |busy_bool, wait_bool| {
                if (busy_bool and !wait_bool.load(.Unordered)) {
                    std.time.sleep(100_000); // 0.1 ms
                    continue :outer;
                }
            }
            break;
        }
        // Free everything
        for (world.chunks) |*chunk| {
            chunk.kill(world.chunk_alloc);
        }
        world.pool.kill(world.alloc);
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
        // Iterate over pool workers
        for (0.., world.pool.wait_bools) |i, *wait_bool| {
            // If a worker has finished
            if (wait_bool.load(.Unordered)) {
                // Reset worker state
                wait_bool.store(false, .Unordered);
                world.pool.busy_bools[i] = false;
                // If the task was to generate vertices
                var chunk = &world.chunks[world.pool.chunks[i]];
                if (world.pool.vert_bools[i]) {
                    // Upload the vertices
                    if (chunk.verts) |*verts| {
                        verts.shrinkAndFree(verts.items.len);
                        try chunk.mesh.upload(.{verts.items});
                        chunk.vertices_wip = false;
                    } else unreachable;
                } else {
                    chunk.density_wip = false;
                }
            }
        }

        const pos = position orelse world.old_pos;
        // const same_pos = if (position) |p| p == world.old_pos else pos != pos;
        // if (position) |_| if (zm.all(same_pos, 3)) return;

        const new_splits = splitsFromPos(pos);
        const print = true; // TODO revert
        const thread = true;
        var timer = try std.time.Timer.start();
        var ns: f32 = undefined;
        var free_ns: f32 = 0;

        if (!world.pool.busy(.vertices)) {
            // TODO use components of same_pos to reduce complexity by CHUNKS
            // TODO use early exit to reduce complexity even further
            // - e.g. some version of 'if the next closest is too far then quit looping'
            for (0.., world.chunks) |i, *chunk| {
                if (chunk.density_wip or chunk.density.len > 0) continue;
                const old_offset = world.offsetFromIndex(i);
                const offset = offsetFromIndexAndSplits(i, new_splits);
                if (zm.length3(offset - pos)[0] > DENSITY_DIST) continue;
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
                chunk.density = try world.chunk_alloc.alloc(f32, Chunk.SIZE * Chunk.SIZE * Chunk.SIZE);
                if (thread) {
                    var free = true;
                    defer if (free) {
                        world.chunk_alloc.free(chunk.density);
                        chunk.density = &.{};
                    };
                    if (!try world.pool.work(world.*, i, .density)) break;
                    free = false;
                    chunk.density_wip = true;
                } else {
                    try chunk.genDensity(offset);
                }
            }
            ns = @floatFromInt(timer.read());
            ns -= free_ns;
            if (print) std.debug.print("Density took {d:.3} ms\n", .{ns / 1_000_000});
            timer.reset();
        }

        std.debug.print("2: {} {}\n", .{ world.pool.busy(.density), world.pool.busy(.vertices) }); // TODO remove

        if (!world.pool.busy(.density)) {
            chunk_loop: for (0.., world.chunks) |i, *chunk| {
                if (chunk.vertices_wip or chunk.verts != null) continue;
                const offset = world.offsetFromIndex(i);
                if (zm.lengthSq3(offset - pos)[0] > VERTICES_DIST * VERTICES_DIST) continue;
                for (0..3) |z| {
                    for (0..3) |y| {
                        for (0..3) |x| {
                            var v = zm.f32x4(
                                @floatFromInt(x),
                                @floatFromInt(y),
                                @floatFromInt(z),
                                0,
                            );
                            if (zm.lengthSq3(v)[0] == 1) continue;
                            v -= zm.f32x4(1, 1, 1, 0);
                            v *= zm.f32x4s(Chunk.SIZE);
                            const neighbour = world.chunks[world.indexFromOffset(v + offset) catch continue :chunk_loop];
                            if (neighbour.density_wip or neighbour.density.len == 0) continue :chunk_loop;
                        }
                    }
                }
                chunk.verts = std.ArrayList(f32).init(world.chunk_alloc);
                if (thread) {
                    var free = true;
                    defer if (free) {
                        if (chunk.verts) |verts| verts.deinit();
                        chunk.verts = null;
                    };
                    if (!try world.pool.work(world.*, i, .vertices)) break;
                    free = false;
                    chunk.vertices_wip = true;
                } else {
                    try chunk.genVerts(world, offset);
                    if (chunk.verts) |*verts| {
                        verts.shrinkAndFree(verts.items.len);
                        try chunk.mesh.upload(.{verts.items});
                    }
                }
            }
            ns = @floatFromInt(timer.read());
            if (print) std.debug.print("Vertices took {d:.3} ms\n", .{ns / 1_000_000});
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
