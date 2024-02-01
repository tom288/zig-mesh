//! The World manages the visible environment and by subdividing it into Chunks.
//! These Chunk densities and vertices are generated on separate Pool threads.

const std = @import("std");
const gl = @import("gl");
const zm = @import("zmath");
const Chunk = @import("chunk.zig").Chunk;
const Shader = @import("shader.zig").Shader;
const Pool = @import("pool.zig").Pool;

pub const World = struct {
    const SIZE = Chunk.SIZE * CHUNKS;
    const CHUNKS = 16;
    const MIP0_DIST = CHUNKS / 2; // CHUNKS / 2 = Whole world

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
    pool: Pool(WorkerData),
    dist_done: usize,
    index_done: usize,

    pub fn init(
        alloc: std.mem.Allocator,
        chunk_alloc: std.mem.Allocator,
        shader: ?Shader,
        cam_pos: ?zm.Vec,
    ) !World {
        var world = World{
            .alloc = alloc,
            .chunk_alloc = chunk_alloc,
            .shader = shader,
            .chunks = try alloc.alloc(Chunk, CHUNKS * CHUNKS * CHUNKS),
            .cam_pos = cam_pos orelse zm.f32x4s(0),
            .splits = undefined,
            .pool = undefined,
            .dist_done = 0,
            .index_done = 0,
        };
        world.splits = splitsFromPos(world.cam_pos);

        var count: usize = 0;
        errdefer {
            for (0..count) |i| {
                world.chunks[i].kill(chunk_alloc);
            }
            alloc.free(world.chunks);
            world.chunks = &.{};
        }

        world.pool = try @TypeOf(world.pool).init(alloc);
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
        for (world.pool.workers) |*worker| {
            while (worker.busy) {
                try world.sync();
                std.time.sleep(100_000); // 0.1 ms
            }
        }
        // Free everything
        for (world.chunks) |*chunk| {
            chunk.kill(world.chunk_alloc);
        }
        world.pool.kill(world.alloc);
        world.chunks = &.{};
    }

    pub fn draw(world: World, shader: Shader, pos: zm.Vec, world_to_clip: zm.Mat) !void {
        const cull = true;
        const count = false;
        const bench = false;
        var timer = try std.time.Timer.start();
        var ns: f32 = undefined;
        var attempts: usize = 0;
        var draws: usize = 0;
        for (0.., world.chunks) |i, chunk| {
            if (chunk.vertices_mip == null) continue; // The chunk has no verts
            attempts += 1;
            const offset = world.offsetFromIndex(i, null);
            const model = zm.translationV(offset);
            const model_to_clip = zm.mul(model, world_to_clip);

            // Draw the chunk we are inside of no matter what
            // Chunk.SIZE is assumed to be sufficient - half of it is not...
            if (zm.all(@abs(pos - offset) < zm.f32x4s(Chunk.SIZE), 3) and !bench) {
                shader.set("model_to_clip", f32, &zm.matToArr(model_to_clip));
                chunk.mesh.draw(gl.TRIANGLES);
                draws += 1;
                continue;
            }

            // Iterate over corners to see if any are on-screen
            corners: for (0..8) |c| {
                if (cull) {
                    var corner = zm.f32x4(
                        if (c % 2 > 0) 1 else -1,
                        if (c / 2 % 2 > 0) 1 else -1,
                        if (c / 4 > 0) 1 else -1,
                        0,
                    ) * zm.f32x4s(Chunk.SIZE / 2);
                    corner[3] = 1;
                    corner = zm.mul(corner, model_to_clip);
                    corner /= @splat(corner[3]);
                    for (0..3) |d| {
                        if (@abs(corner[d]) > 1) continue :corners;
                    }
                    if (corner[2] < 0) continue :corners;
                }
                if (!bench) {
                    shader.set("model_to_clip", f32, zm.matToArr(model_to_clip));
                    chunk.mesh.draw(gl.TRIANGLES);
                }
                draws += 1;
                break :corners;
            }
        }
        if (count) std.debug.print("{} / {}\n", .{ draws, attempts });
        ns = @floatFromInt(timer.read());
        if (bench) std.debug.print("Culling took {d:.3} ms\n", .{ns / 1_000_000});
    }

    // Chunk boundaries occur at multiples of Chunk.SIZE
    // The group of closest chunks changes halfway between these boundaries
    pub fn gen(world: *World, cam_pos: ?zm.Vec) !void {
        if (cam_pos) |pos| {
            world.cam_pos = (pos / zm.f32x4s(Chunk.SIZE)) - zm.f32x4s(0.5);
            world.cam_pos = zm.ceil(world.cam_pos) * zm.f32x4s(Chunk.SIZE);
            world.cam_pos[3] = 0;
        }
        const new_splits = splitsFromPos(world.cam_pos);
        const max_dist = CHUNKS / 2;
        const bench = false;
        var timer = try std.time.Timer.start();
        var ns: f32 = undefined;

        try world.sync();
        // ns = @floatFromInt(timer.lap());
        // if (bench) std.debug.print("Sync took {d:.3} ms\n", .{ns / 1_000_000});

        if (zm.any(world.splits != new_splits, 3)) {
            // TODO only iterate over the necessary chunks
            for (0.., world.chunks) |i, *chunk| {
                if (zm.all(world.offsetFromIndex(i, null) ==
                    world.offsetFromIndex(i, new_splits), 3)) continue;
                if (chunk.wip_mip != null or chunk.density_refs > 0) {
                    chunk.must_free = true;
                } else {
                    chunk.free(world.chunk_alloc, true);
                }
            }

            const diff = @abs(world.splits - new_splits);
            const max_diff: usize = @intFromFloat(@max(diff[0], @max(diff[1], diff[2])));
            world.dist_done = @min(MIP0_DIST, world.dist_done) -| max_diff; // Saturating sub on usize
            world.index_done = 0;
            world.splits = new_splits;
            // ns = @floatFromInt(timer.lap());
            // if (bench) std.debug.print("Splits took {d:.3} ms\n", .{ns / 1_000_000});
        }

        var all_done = true;

        outer: for (world.dist_done..max_dist) |dist| {
            const big = dist + 1;
            const edge = big == max_dist;
            const max_index = 8 * (3 * big * dist + 1);
            if (all_done) world.dist_done = dist;
            for (world.index_done..max_index) |index| {
                if (all_done) world.index_done = index;
                var i = index / 2;
                var pos = zm.f32x4s(0);

                // Create a nested function without language support
                const signedDist = struct {
                    fn f(l: usize, r: usize) f32 {
                        const signed_dist = @as(isize, @intCast(l)) -
                            @as(isize, @intCast(r));
                        return @floatFromInt(signed_dist);
                    }
                }.f;

                // Determine the axis in which the plane is fixed
                var plane: usize = 2;
                var thresh = 4 * big * big;
                if (i >= thresh) {
                    i -= thresh;
                    plane -= 1;
                    thresh = 4 * big * dist;
                    if (i >= thresh) {
                        i -= thresh;
                        plane -= 1;
                    }
                }
                pos[plane] = @floatFromInt(dist);
                if (index % 2 > 0) pos[plane] *= -1;
                const base = if (plane < 1) dist else big;
                pos[if (plane < 1) 1 else 0] = signedDist(i % (base * 2), base);
                pos[if (plane > 1) 1 else 2] = signedDist(i / (base * 2), base);

                if (try world.genChunk(
                    world.cam_pos + pos * zm.f32x4s(Chunk.SIZE),
                    dist,
                    edge,
                )) |done| {
                    all_done = all_done and done;
                } else break :outer;
            }
            if (all_done and big < max_dist) world.index_done = 0;
        }
        ns = @floatFromInt(timer.read());
        if (bench) std.debug.print("Gen took {d:.3} ms\n", .{ns / 1_000_000});
    }

    pub fn genChunkDensity(
        world: *World,
        chunk: *Chunk,
        chunk_index: usize,
        thread: bool,
        mip_level: usize,
    ) !bool {
        chunk.free(world.chunk_alloc, false);
        const mip_scale = std.math.pow(f32, 2, @floatFromInt(mip_level));
        const size = Chunk.SIZE / @as(usize, @intFromFloat(mip_scale));
        chunk.density = try world.chunk_alloc.alloc(f32, size * size * size);

        const old_mip = chunk.density_mip;
        chunk.density_mip = null;
        chunk.wip_mip = mip_level;
        chunk.splits_copy = world.splits;
        if (thread) {
            if (!try world.pool.work(
                workerThread,
                .{
                    .task = .density,
                    .world = world,
                    .chunk = chunk,
                    .offset = world.offsetFromIndex(
                        chunk_index,
                        chunk.splits_copy.?,
                    ),
                },
            )) {
                world.chunk_alloc.free(chunk.density);
                chunk.density = &.{};
                chunk.density_mip = old_mip;
                chunk.wip_mip = null;
                chunk.splits_copy = null;
                return false;
            }
        } else {
            try chunk.genDensity(world.offsetFromIndex(chunk_index, null));
            chunk.density_mip = chunk.wip_mip;
            chunk.wip_mip = null;
            chunk.splits_copy = null;
        }
        return true;
    }

    pub fn genChunkVerts(
        world: *World,
        chunk: *Chunk,
        chunk_index: usize,
        thread: bool,
        comptime min: comptime_int,
    ) !bool {
        chunk.verts = std.ArrayList(f32).init(world.chunk_alloc);
        const old_mip = chunk.vertices_mip;
        chunk.vertices_mip = null;
        chunk.wip_mip = chunk.density_mip;
        chunk.splits_copy = world.splits;
        if (thread) {
            if (!try world.pool.work(
                workerThread,
                .{
                    .task = .vertices,
                    .world = world,
                    .chunk = chunk,
                    .offset = world.offsetFromIndex(
                        chunk_index,
                        chunk.splits_copy.?,
                    ),
                },
            )) {
                if (chunk.vertices_mip) |_| chunk.verts.deinit();
                chunk.vertices_mip = old_mip;
                chunk.wip_mip = null;
                chunk.splits_copy = null;
                return false;
            }
            for (min..3) |k| {
                for (min..3) |j| {
                    for (min..3) |i| {
                        const neighbour_pos = (zm.f32x4(
                            @floatFromInt(i),
                            @floatFromInt(j),
                            @floatFromInt(k),
                            1,
                        ) - zm.f32x4s(1)) * zm.f32x4s(Chunk.SIZE) +
                            world.offsetFromIndex(chunk_index, chunk.splits_copy);
                        const neighbour = &world.chunks[try world.indexFromOffset(neighbour_pos, chunk.splits_copy)];
                        neighbour.density_refs += 1;
                    }
                }
            }
        } else {
            try chunk.genVerts(world.*, world.offsetFromIndex(chunk_index, null));
            try chunk.mesh.upload(.{chunk.verts.items});
            chunk.vertices_mip = chunk.wip_mip;
            chunk.wip_mip = null;
            chunk.splits_copy = null;
        }
        return true;
    }

    // Return null if we have ran out of threads so that the caller can break
    // Return true if the chunk is already generated at a sufficient mip level
    // Otherwise return false
    pub fn genChunk(world: *World, pos: zm.Vec, dist: usize, edge: bool) !?bool {
        const THREAD = true;
        const mip_level: usize = if (dist < MIP0_DIST) 0 else 2;
        const chunk_index = try world.indexFromOffset(pos, null);
        const chunk = &world.chunks[chunk_index];

        // Skip chunks which are already being processed
        if (chunk.wip_mip) |_| return false;
        // Only generate densities for edge chunks
        if (edge) {
            // If the neighbour is already finished then move on
            if (chunk.density_mip) |mip| if (mip <= mip_level) return true;

            // Skip chunks currently being used for their densities
            if (chunk.density_refs > 0) return false;

            return switch (try world.genChunkDensity(
                chunk,
                chunk_index,
                THREAD,
                mip_level,
            )) {
                true => !THREAD,
                false => null,
            };
        }
        // Skip chunks which are already generated
        if (chunk.vertices_mip) |mip| if (mip <= mip_level) return true;

        // Whether all chunks ine surrounding 3x3 region have sufficity densities
        var all_ready = true;

        const min = if (Chunk.SURFACE.NEG_ADJ) 0 else 1;
        // Iterate over 3x3 region and generate any missing densities
        for (min..3) |k| {
            for (min..3) |j| {
                for (min..3) |i| {
                    // Find the chunk in the 3x3 neighbourhood
                    const neighbour_pos = (zm.f32x4(
                        @floatFromInt(i),
                        @floatFromInt(j),
                        @floatFromInt(k),
                        1,
                    ) - zm.f32x4s(1)) * zm.f32x4s(Chunk.SIZE) + pos;
                    const neighbour_index = try world.indexFromOffset(neighbour_pos, null);
                    const neighbour = &world.chunks[neighbour_index];

                    // Skip neighbours which are already being processed
                    if (neighbour.wip_mip) |_| {
                        all_ready = false;
                        continue;
                    }

                    // If the neighbour is already finished then move on
                    if (neighbour.density_mip) |mip| if (mip <= mip_level) continue;

                    if (THREAD) all_ready = false;

                    // Skip chunks currently being used for their densities
                    if (neighbour.density_refs > 0) continue;

                    if (!try world.genChunkDensity(
                        neighbour,
                        neighbour_index,
                        THREAD,
                        mip_level,
                    )) return null;
                }
            }
        }
        if (!all_ready) return false;
        // If all densities are already present then generate the vertices
        return switch (try world.genChunkVerts(
            chunk,
            chunk_index,
            THREAD,
            min,
        )) {
            true => !THREAD,
            false => null,
        };
    }

    fn sync(world: *World) !void {
        const min = if (Chunk.SURFACE.NEG_ADJ) 0 else 1;
        // Iterate over pool workers
        for (world.pool.workers) |*worker| {
            // Look for workers who are finished and waiting for a sync
            if (!worker.wait.load(.Unordered)) continue;
            // Reset worker state
            worker.wait.store(false, .Unordered);
            worker.busy = false;
            var chunk = worker.data.chunk;
            // If the task was to generate vertices
            if (worker.data.task == .vertices) {
                const splits = chunk.splits_copy.?;
                for (min..3) |z| {
                    for (min..3) |y| {
                        for (min..3) |x| {
                            const neighbour_pos = (zm.f32x4(
                                @floatFromInt(x),
                                @floatFromInt(y),
                                @floatFromInt(z),
                                1,
                            ) - zm.f32x4s(1)) * zm.f32x4s(Chunk.SIZE) + worker.data.offset;
                            const neighbour = &world.chunks[try world.indexFromOffset(neighbour_pos, splits)];
                            neighbour.density_refs -= 1;
                            if (neighbour.must_free and
                                neighbour.density_refs == 0 and
                                neighbour.wip_mip == null)
                            {
                                neighbour.free(world.chunk_alloc, true);
                            }
                        }
                    }
                }
            }
            if (chunk.wip_mip == null) continue; // Already freed

            // If the task was to generate vertices
            if (worker.data.task == .vertices) {
                // Upload the vertices
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

    const WorkerData = struct {
        pub const Task = enum {
            density,
            vertices,
        };

        task: Task,
        world: *World,
        chunk: *Chunk,
        offset: zm.Vec,
    };

    fn workerThread(data: WorkerData) void {
        switch (data.task) {
            .density => data.chunk.genDensity(data.offset) catch unreachable,
            .vertices => data.chunk.genVerts(data.world.*, data.offset) catch unreachable,
        }
    }
};
