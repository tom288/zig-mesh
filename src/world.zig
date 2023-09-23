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
                .verts = undefined,
                .mesh = try @TypeOf(chunk.mesh).init(shader),
                .must_free = false,
                .density_mip = null,
                .vertices_mip = null,
                .wip_mip = null,
            };
            count += 1;
        }

        try world.gen(null);

        return world;
    }

    pub fn kill(world: *World) !void {
        // Wait for the other threads
        var checked: usize = 0;
        outer: while (true) {
            for (checked..world.pool.busy_bools.len) |i| {
                if (world.pool.busy_bools[i]) {
                    try world.sync();
                    std.time.sleep(100_000); // 0.1 ms
                    continue :outer;
                } else {
                    checked += 1;
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
            if (chunk.vertices_mip == null) continue; // The chunk has no verts
            shader.set("model", f32, &zm.matToArr(zm.translationV(world.offsetFromIndex(i))));
            chunk.mesh.draw(gl.TRIANGLES);
        }
    }

    pub fn gen(world: *World, position: ?zm.Vec) !void {
        const bench = false;
        var timer = try std.time.Timer.start();
        var ns: f32 = undefined;

        try world.sync();
        ns = @floatFromInt(timer.read());
        // if (bench) std.debug.print("Pool took {d:.3} ms\n", .{ns / 1_000_000});
        timer.reset();

        const pos = position orelse world.old_pos;
        // const same_pos = if (position) |p| p == world.old_pos else pos != pos;

        const new_splits = splitsFromPos(pos);
        const thread = true;
        var free_ns: f32 = 0;

        if (!world.pool.busy(.vertices)) {
            // TODO use components of same_pos to reduce complexity by CHUNKS
            // TODO use early exit to reduce complexity even further
            // - e.g. some version of 'if the next closest is too far then quit looping'
            for (0.., world.chunks) |i, *chunk| {
                if (chunk.wip_mip != null or chunk.density_mip != null) continue;
                const old_offset = world.offsetFromIndex(i);
                const offset = offsetFromIndexAndSplits(i, new_splits);
                if (zm.length3(offset - pos)[0] > DENSITY_DIST) continue;
                if (zm.any(old_offset != offset, 3)) {
                    const old_splits = world.splits;
                    // Update splits TODO make this update minimal
                    world.splits = new_splits;
                    // Free invalidated chunks
                    var free_timer = try std.time.Timer.start();
                    for (0.., world.chunks) |j, *c| {
                        // TODO avoid this check by only looping over invalidated chunks
                        if (zm.all(world.offsetFromIndex(j) == offsetFromIndexAndSplits(j, old_splits), 3)) continue;
                        if (c.wip_mip) |_| {
                            c.must_free = true;
                        } else {
                            c.free(world.chunk_alloc);
                            try c.mesh.upload(.{});
                        }
                    }
                    free_ns = @floatFromInt(free_timer.read());
                    if (bench) std.debug.print("Frees took {d:.3} ms\n", .{free_ns / 1_000_000});
                }
                const mip_level = 0;
                const mip_scale = std.math.pow(f32, 2, @floatFromInt(mip_level));
                const size = Chunk.SIZE / @as(usize, @intFromFloat(mip_scale));
                chunk.density = try world.chunk_alloc.alloc(f32, size * size * size);
                if (thread) {
                    const old_mip = chunk.density_mip;
                    chunk.density_mip = null;
                    chunk.wip_mip = mip_level;
                    if (!try world.pool.work(world.*, i, .density)) {
                        world.chunk_alloc.free(chunk.density);
                        chunk.density = &.{};
                        chunk.density_mip = old_mip;
                        chunk.wip_mip = null;
                        break;
                    }
                } else {
                    chunk.density_mip = null;
                    chunk.wip_mip = mip_level;
                    try chunk.genDensity(offset);
                    chunk.density_mip = chunk.wip_mip;
                    chunk.wip_mip = null;
                }
            }
            ns = @floatFromInt(timer.read());
            ns -= free_ns;
            if (bench) std.debug.print("Density took {d:.3} ms\n", .{ns / 1_000_000});
            timer.reset();
        }

        if (!world.pool.busy(.density)) {
            chunk_loop: for (0.., world.chunks) |i, *chunk| {
                if (chunk.wip_mip != null or chunk.density_mip == null or chunk.vertices_mip != null) continue;
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
                            if (neighbour.wip_mip != null or neighbour.density_mip == null) continue :chunk_loop;
                        }
                    }
                }
                chunk.verts = std.ArrayList(f32).init(world.chunk_alloc);
                if (thread) {
                    const old_mip = chunk.vertices_mip;
                    chunk.vertices_mip = null;
                    chunk.wip_mip = chunk.density_mip;
                    if (!try world.pool.work(world.*, i, .vertices)) {
                        if (chunk.vertices_mip) |_| chunk.verts.deinit();
                        chunk.vertices_mip = old_mip;
                        chunk.wip_mip = null;
                        break;
                    }
                } else {
                    chunk.vertices_mip = null;
                    chunk.wip_mip = chunk.density_mip;
                    try chunk.genVerts(world.*, offset);
                    chunk.verts.shrinkAndFree(chunk.verts.items.len);
                    try chunk.mesh.upload(.{chunk.verts.items});
                    chunk.vertices_mip = chunk.wip_mip;
                    chunk.wip_mip = null;
                }
            }
            ns = @floatFromInt(timer.read());
            if (bench) std.debug.print("Vertices took {d:.3} ms\n", .{ns / 1_000_000});
        }
    }

    fn sync(world: *World) !void {
        // Iterate over pool workers
        for (0.., world.pool.wait_bools) |i, *wait_bool| {
            // Look for workers who are finished and waiting for a sync
            if (!wait_bool.load(.Unordered)) continue;
            // Reset worker state
            wait_bool.store(false, .Unordered);
            world.pool.busy_bools[i] = false;
            var chunk = &world.chunks[world.pool.chunks[i]];
            if (chunk.must_free) {
                chunk.free(world.chunk_alloc);
                try chunk.mesh.upload(.{});
            }
            // If the task was to generate vertices
            if (world.pool.vert_bools[i]) {
                // Upload the vertices
                chunk.verts.shrinkAndFree(chunk.verts.items.len);
                try chunk.mesh.upload(.{chunk.verts.items});
                chunk.vertices_mip = chunk.wip_mip;
            } else {
                chunk.density_mip = chunk.wip_mip;
            }
            chunk.wip_mip = null;
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
