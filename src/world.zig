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
    cam_pos: zm.Vec,
    splits: zm.Vec,
    pool: Pool,

    pub fn init(alloc: std.mem.Allocator, chunk_alloc: std.mem.Allocator, shader: ?Shader, cam_pos: ?zm.Vec) !World {
        const pos = cam_pos orelse zm.f32x4s(0);
        var world = World{
            .alloc = alloc,
            .chunk_alloc = chunk_alloc,
            .shader = shader,
            .chunks = try alloc.alloc(Chunk, CHUNKS * CHUNKS * CHUNKS),
            .cam_pos = pos,
            .splits = splitsFromPos(pos),
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
                .density_refs = 0,
                .splits_copy = null,
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
        world.chunks = &.{};
    }

    pub fn draw(world: World, shader: Shader) void {
        for (0.., world.chunks) |i, chunk| {
            if (chunk.vertices_mip == null) continue; // The chunk has no verts
            shader.set("model", f32, &zm.matToArr(zm.translationV(world.offsetFromIndex(i, null))));
            chunk.mesh.draw(gl.TRIANGLES);
        }
    }

    // Chunk boundaries occur at multiples of Chunk.SIZE
    // The group of closest chunks changes halfway between these boundaries
    pub fn gen(world: *World, cam_pos: ?zm.Vec) !void {
        const bench = false;
        if (cam_pos) |pos| {
            world.cam_pos = (pos / zm.f32x4s(Chunk.SIZE)) - zm.f32x4s(0.5);
            world.cam_pos = zm.ceil(world.cam_pos) * zm.f32x4s(Chunk.SIZE);
            world.cam_pos[3] = 0;
        }
        const new_splits = splitsFromPos(world.cam_pos);
        const bound = CHUNKS / 2;
        var timer = try std.time.Timer.start();
        var ns: f32 = undefined;

        try world.sync();

        outer: for (0..bound) |dist| {
            const edge = dist + 1 == bound;
            for (0..2) |s| {
                var other: isize = @intCast(dist);
                if (s == 0) other = -other - 1;

                // YZ plane
                const usmall = dist;
                const small: isize = @intCast(usmall);
                const ubig = usmall + 1;
                const big: isize = small + 1;
                for (0..ubig * 2) |z| {
                    for (0..ubig * 2) |y| {
                        if (!try world.genChunk(
                            world.cam_pos + zm.f32x4(
                                @floatFromInt(other),
                                @floatFromInt(@as(isize, @intCast(y)) - big),
                                @floatFromInt(@as(isize, @intCast(z)) - big),
                                0,
                            ) * zm.f32x4s(Chunk.SIZE),
                            dist,
                            edge,
                            new_splits,
                        )) break :outer;
                    }
                }

                // XZ plane
                for (0..usmall * 2) |x| {
                    for (0..ubig * 2) |z| {
                        if (!try world.genChunk(
                            world.cam_pos + zm.f32x4(
                                @floatFromInt(@as(isize, @intCast(x)) - small),
                                @floatFromInt(other),
                                @floatFromInt(@as(isize, @intCast(z)) - big),
                                0,
                            ) * zm.f32x4s(Chunk.SIZE),
                            dist,
                            edge,
                            new_splits,
                        )) break :outer;
                    }
                }

                // XY plane
                for (0..usmall * 2) |y| {
                    for (0..usmall * 2) |x| {
                        if (!try world.genChunk(
                            world.cam_pos + zm.f32x4(
                                @floatFromInt(@as(isize, @intCast(x)) - small),
                                @floatFromInt(@as(isize, @intCast(y)) - small),
                                @floatFromInt(other),
                                0,
                            ) * zm.f32x4s(Chunk.SIZE),
                            dist,
                            edge,
                            new_splits,
                        )) break :outer;
                    }
                }
            }
        }
        ns = @floatFromInt(timer.read());
        if (bench) std.debug.print("Gen took {d:.3} ms\n", .{ns / 1_000_000});
    }

    // Return false if we have ran out of threads so that the caller can break
    // Otherwise return true
    pub fn genChunk(world: *World, pos: zm.Vec, dist: usize, edge: bool, new_splits: zm.Vec) !bool {
        _ = dist; // TODO use this for LOD?

        const thread = true;
        const mip_level = 0;
        const chunk_index = try world.indexFromOffsetWithNewSplits(
            pos,
            new_splits,
        );
        var chunk = &world.chunks[chunk_index];

        // Skip chunks which are already being processed
        if (chunk.wip_mip) |_| return true;
        // Skip chunks on the edge
        if (edge) return true;
        // Skip chunks which are already generated
        if (chunk.vertices_mip) |mip| if (mip <= mip_level) return true;

        // Whether all chunks ine surrounding 3x3 region have sufficity densities
        var all_ready = true;

        // Iterate over 3x3 region and generate any missing densities
        for (0..3) |k| {
            for (0..3) |j| {
                for (0..3) |i| {
                    // Find the chunk in the 3x3 neighbourhood
                    var neighbour_pos = (zm.f32x4(
                        @floatFromInt(i),
                        @floatFromInt(j),
                        @floatFromInt(k),
                        1,
                    ) - zm.f32x4s(1)) * zm.f32x4s(Chunk.SIZE) + pos;
                    const neighbour_index = try world.indexFromOffsetWithNewSplits(
                        neighbour_pos,
                        new_splits,
                    );
                    var neighbour = &world.chunks[neighbour_index];

                    // Skip neighbours which are already being processed
                    if (neighbour.wip_mip) |_| {
                        all_ready = false;
                        continue;
                    }

                    // If the neighbour is already finished then move on
                    if (neighbour.density_mip) |mip| if (mip <= mip_level) continue;

                    if (thread) all_ready = false;

                    // Skip chunks currently being used for their densities
                    if (neighbour.density_refs > 0) continue;

                    neighbour.free(world.chunk_alloc);
                    const mip_scale = std.math.pow(f32, 2, @floatFromInt(mip_level));
                    const size = Chunk.SIZE / @as(usize, @intFromFloat(mip_scale));
                    neighbour.density = try world.chunk_alloc.alloc(f32, size * size * size);

                    const old_mip = neighbour.density_mip;
                    neighbour.density_mip = null;
                    neighbour.wip_mip = mip_level;
                    neighbour.splits_copy = world.splits;
                    if (thread) {
                        if (!try world.pool.work(world.*, neighbour_index, .density)) {
                            world.chunk_alloc.free(neighbour.density);
                            neighbour.density = &.{};
                            neighbour.density_mip = old_mip;
                            neighbour.wip_mip = null;
                            neighbour.splits_copy = null;
                            return false;
                        }
                    } else {
                        try neighbour.genDensity(world.offsetFromIndex(neighbour_index, null));
                        neighbour.density_mip = neighbour.wip_mip;
                        neighbour.wip_mip = null;
                        neighbour.splits_copy = null;
                    }
                }
            }
        }
        if (!all_ready) return true;
        // If all densities are already present then generate the vertices
        chunk.verts = std.ArrayList(f32).init(world.chunk_alloc);
        const old_mip = chunk.vertices_mip;
        chunk.vertices_mip = null;
        chunk.wip_mip = chunk.density_mip;
        chunk.splits_copy = world.splits;
        if (thread) {
            if (!try world.pool.work(world.*, chunk_index, .vertices)) {
                if (chunk.vertices_mip) |_| chunk.verts.deinit();
                chunk.vertices_mip = old_mip;
                chunk.wip_mip = null;
                chunk.splits_copy = null;
                return false;
            }
            for (0..3) |k| {
                for (0..3) |j| {
                    for (0..3) |i| {
                        var neighbour_pos = (zm.f32x4(
                            @floatFromInt(i),
                            @floatFromInt(j),
                            @floatFromInt(k),
                            1,
                        ) - zm.f32x4s(1)) * zm.f32x4s(Chunk.SIZE);
                        neighbour_pos += world.offsetFromIndex(chunk_index, chunk.splits_copy);
                        const neighbour = &world.chunks[try world.indexFromOffset(neighbour_pos, chunk.splits_copy)];
                        neighbour.density_refs += 1;
                    }
                }
            }
        } else {
            try chunk.genVerts(world.*, world.offsetFromIndex(chunk_index, null));
            chunk.verts.shrinkAndFree(chunk.verts.items.len);
            try chunk.mesh.upload(.{chunk.verts.items});
            chunk.vertices_mip = chunk.wip_mip;
            chunk.wip_mip = null;
            chunk.splits_copy = null;
        }
        return true;
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
            if (world.pool.vert_bools[i]) {
                const splits = chunk.splits_copy orelse unreachable;
                for (0..3) |z| {
                    for (0..3) |y| {
                        for (0..3) |x| {
                            var neighbour_pos = (zm.f32x4(
                                @floatFromInt(x),
                                @floatFromInt(y),
                                @floatFromInt(z),
                                1,
                            ) - zm.f32x4s(1)) * zm.f32x4s(Chunk.SIZE);
                            neighbour_pos += world.offsetFromIndex(world.pool.chunks[i], splits);
                            const neighbour = &world.chunks[try world.indexFromOffset(neighbour_pos, splits)];
                            neighbour.density_refs -= 1;
                            if (neighbour.must_free and neighbour.density_refs == 0) {
                                neighbour.free(world.chunk_alloc);
                                try neighbour.mesh.upload(.{});
                            }
                        }
                    }
                }
            }
            if (chunk.wip_mip == null) continue; // Already freed

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
            chunk.splits_copy = null;
        }
    }

    pub fn indexFromOffset(world: World, pos: zm.Vec, splits: ?zm.Vec) !usize {
        const spl = splits orelse world.splits;
        const floor = zm.floor(pos / zm.f32x4s(Chunk.SIZE));
        var index: usize = 0;
        for (0..3) |d| {
            const i = 2 - d;
            var f = floor[i] - @floor(spl[i] / CHUNKS) * CHUNKS;
            if (@mod(f, CHUNKS) >=
                @mod(spl[i], CHUNKS)) f += CHUNKS;
            if (f < 0 or f >= CHUNKS) return error.PositionOutsideWorld;
            index *= CHUNKS;
            index += @intFromFloat(f);
        }
        return index;
    }

    pub fn offsetFromIndex(world: World, index: usize, splits: ?zm.Vec) zm.Vec {
        const spl = splits orelse world.splits;
        var offset = (zm.f32x4(
            @floatFromInt(index % CHUNKS),
            @floatFromInt(index / CHUNKS % CHUNKS),
            @floatFromInt(index / CHUNKS / CHUNKS),
            0,
        ) + zm.f32x4(0.5, 0.5, 0.5, 0));
        for (0..3) |i| {
            offset[i] += @floor(spl[i] / CHUNKS) * CHUNKS;
            if (@mod(offset[i], CHUNKS) >=
                @mod(spl[i], CHUNKS)) offset[i] -= CHUNKS;
        }
        return offset * zm.f32x4s(Chunk.SIZE);
    }

    fn splitsFromPos(pos: zm.Vec) zm.Vec {
        var splits = zm.floor(pos / zm.f32x4s(Chunk.SIZE) + zm.f32x4s(0.5)) + zm.f32x4s(CHUNKS / 2);
        splits[3] = 0;
        return splits;
    }

    fn indexFromOffsetWithNewSplits(world: *World, pos: zm.Vec, new_splits: zm.Vec) !usize {
        return world.indexFromOffset(pos, null) catch {
            // TODO consider calculating and using the minimal splits
            // adjustment which still satisfies the new requirements
            if (zm.all(world.splits == new_splits, 3)) unreachable;
            // TODO only iterate over the necessary chunks
            for (0.., world.chunks) |i, *chunk| {
                if (zm.all(world.offsetFromIndex(i, null) ==
                    world.offsetFromIndex(i, new_splits), 3)) continue;
                if (chunk.wip_mip != null or chunk.density_refs > 0) {
                    chunk.must_free = true;
                } else {
                    chunk.free(world.chunk_alloc);
                    try chunk.mesh.upload(.{});
                }
            }

            world.splits = new_splits;
            return world.indexFromOffset(pos, null);
        };
    }
};
