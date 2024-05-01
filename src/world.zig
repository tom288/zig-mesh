//! The World manages the visible environment and by subdividing it into Chunks.
//! These Chunk densities and surfaces are generated on separate Pool threads.

const std = @import("std");
const gl = @import("gl");
const zm = @import("zmath");
const Chunk = @import("chunk.zig").Chunk;
const Shader = @import("shader.zig").Shader;
const Pool = @import("pool.zig").Pool;
const Surface = @import("surface.zig");
const Mesh = @import("mesh.zig").Mesh;

pub const World = struct {
    alloc: std.mem.Allocator,
    shader: Shader,
    density_shader: ?Shader = null,
    surface_shader: ?Shader = null,
    chunks: []Chunk,
    cam_pos: zm.Vec,
    splits: zm.Vec,
    dist_done: usize = 0,
    index_done: usize = 0,
    pool: Pool(WorkerData),
    planes: Mesh(.{.{
        .{ .name = "position", .size = 3, .type = gl.FLOAT },
        .{ .name = "axis", .size = 1, .type = gl.UNSIGNED_INT },
    }}),

    const SIZE = Chunk.SIZE * CHUNKS;
    const CHUNKS = 16;
    const MIP0_DIST = CHUNKS / 2; // CHUNKS / 2 = Whole world
    const THREADING = enum {
        single,
        multi,
        compute,
    }.multi;
    pub const OVERDRAW = enum {
        naive,
        greedy,
        global_lattice,
    }.global_lattice;

    pub fn init(
        alloc: std.mem.Allocator,
        shader: Shader,
        cam_pos: ?zm.Vec,
    ) !@This() {
        var world = @This(){
            .alloc = alloc,
            .shader = shader,
            .chunks = undefined,
            .cam_pos = cam_pos orelse zm.f32x4s(0),
            .splits = undefined,
            .pool = undefined,
            .planes = undefined,
        };

        world.density_shader = try Shader.initComp(alloc, "density");
        errdefer {
            world.density_shader.?.kill();
            world.density_shader = null;
        }
        world.density_shader.?.bindBlock("density_block", 0);

        switch (OVERDRAW) {
            .global_lattice => {
                // Radius of global lattice
                const rad = 16;
                // Vertex position data for global lattice planes
                var plane_verts = std.ArrayList(f32).init(world.alloc);
                defer plane_verts.deinit();
                // Iterate over plane dimensions
                for (0..3) |d| {
                    // Iterate over planes for a given dimension
                    for (0..rad * 2 + 1) |p| {
                        // Iterate over vertices of a particular plane
                        for (0..6) |v| {
                            var max = zm.f32x4s(rad);
                            max[3] = 0;
                            max[d] = @as(f32, @floatFromInt(p)) - rad;
                            if (v % 2 == 0) {
                                max[if (d == 0) 1 else 0] *= -1;
                            }
                            if (v < 2 or v == 3) {
                                max[if (d == 1) 2 else 1] *= -1;
                            }
                            try plane_verts.appendSlice(&zm.vecToArr3(max));
                            try plane_verts.append(@bitCast(@as(gl.GLuint, @intCast(d))));
                        }
                    }
                }
                world.planes = try @TypeOf(world.planes).init(world.shader);
                errdefer world.planes.kill();
                try world.planes.upload(.{plane_verts.items});
            },
            else => {
                world.surface_shader = try Shader.initComp(alloc, "surface");
                errdefer {
                    world.surface_shader.?.kill();
                    world.surface_shader = null;
                }
                world.surface_shader.?.bindBlock("density_block", 0);
                world.surface_shader.?.bindBlock("surface_block", 1);

                world.chunks = try alloc.alloc(Chunk, CHUNKS * CHUNKS * CHUNKS);
                errdefer {
                    alloc.free(world.chunks);
                    world.chunks = &.{};
                }

                var count: usize = 0;
                errdefer for (0..count) |i| {
                    world.chunks[i].kill(alloc);
                };

                // Assign uninitialised chunks
                for (world.chunks) |*chunk| {
                    chunk.* = .{
                        .density = &.{},
                        .surface = null,
                        .mesh = try @TypeOf(chunk.mesh).init(shader),
                        .must_free = false,
                        .density_mip = null,
                        .surface_mip = null,
                        .gpu_mip = null,
                        .wip_mip = null,
                        .density_refs = 0,
                        .splits_copy = null,
                        .density_buffer = null,
                        .atomics_buffer = null,
                    };
                    if (THREADING == .compute) {
                        const max_cubes = std.math.pow(usize, Chunk.SIZE, 3);

                        chunk.density_buffer = undefined;
                        gl.genBuffers(1, &chunk.density_buffer.?);
                        gl.bindBuffer(gl.SHADER_STORAGE_BUFFER, chunk.density_buffer.?);
                        gl.bufferData(gl.SHADER_STORAGE_BUFFER, @intCast(max_cubes * @sizeOf(f32)), null, gl.STATIC_DRAW);
                        gl.bindBuffer(gl.SHADER_STORAGE_BUFFER, 0);

                        chunk.atomics_buffer = undefined;
                        gl.genBuffers(1, &chunk.atomics_buffer.?);
                        gl.bindBuffer(gl.ATOMIC_COUNTER_BUFFER, chunk.atomics_buffer.?);
                        gl.bufferData(gl.ATOMIC_COUNTER_BUFFER, @sizeOf(gl.GLuint) * 4, null, gl.DYNAMIC_DRAW);
                        gl.bindBuffer(gl.ATOMIC_COUNTER_BUFFER, 0);

                        switch (Chunk.SURFACE) {
                            Surface.Voxel => {
                                try chunk.mesh.resizeVBOs((max_cubes - max_cubes / 2) * 6 * 2 * 3);
                            },
                            Surface.MarchingCubes => {
                                try chunk.mesh.resizeVBOs(max_cubes * 5 * 3); // TODO reduce this further
                            },
                            else => unreachable,
                        }
                    }
                    count += 1;
                }
            },
        }

        world.splits = splitsFromPos(world.cam_pos);

        world.pool = try @TypeOf(world.pool).init(alloc);
        errdefer world.pool.kill(alloc);

        try world.updateSplits(cam_pos);
        try world.gen();

        return world;
    }

    pub fn kill(world: *@This()) !void {
        // Wait for the other threads
        for (world.pool.workers) |*worker| {
            while (worker.busy) {
                try world.sync();
                std.time.sleep(100_000); // 0.1 ms
            }
        }
        world.pool.kill(world.alloc);
        // Free everything
        switch (OVERDRAW) {
            .global_lattice => {
                world.planes.kill();
            },
            else => {
                for (world.chunks) |*chunk| {
                    chunk.kill(world.alloc);
                }
                world.alloc.free(world.chunks);
                world.chunks = &.{};
            },
        }
        // Free shaders
        inline for (&.{
            &world.density_shader,
            &world.surface_shader,
        }) |*shader| {
            if (shader.*.*) |_| {
                shader.*.*.?.kill();
                shader.*.* = null;
            }
        }
    }

    pub fn draw(world: @This(), pos: zm.Vec, view: zm.Mat, proj: zm.Mat) !void {
        world.shader.set("view", f32, zm.matToArr(view));
        world.shader.set("proj", f32, zm.matToArr(proj));
        if (OVERDRAW == .global_lattice) {
            world.shader.set("model", f32, zm.matToArr(zm.identity()));
            world.planes.draw(gl.TRIANGLES, null, null);
            return;
        }
        var timer = try std.time.Timer.start();
        defer if (false) {
            const ns: f32 = @floatFromInt(timer.read());
            std.debug.print("Culling took {d:.3} ms\n", .{ns / 1_000_000});
        };

        const cull = true;
        const count = false;
        var attempts: usize = 0;
        var draws: usize = 0;
        for (0.., world.chunks) |i, chunk| {
            if (chunk.gpu_mip == null) continue; // The chunk has no surface
            attempts += 1;
            const offset = world.offsetFromIndex(i, null);
            const model = zm.translationV(offset);
            const world_to_clip = zm.mul(view, proj);
            const model_to_clip = zm.mul(model, world_to_clip);

            // Draw the chunk we are inside of no matter what
            // Chunk.SIZE * 1.3 is not sufficient at 16:9 so let's try 1.4
            if (zm.all(@abs(pos - offset) < zm.f32x4s(Chunk.SIZE) * zm.f32x4s(1.4), 3)) {
                world.shader.set("model", f32, zm.matToArr(model));
                chunk.mesh.draw(gl.TRIANGLES, null, chunk.atomics_buffer);
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
                world.shader.set("model", f32, zm.matToArr(model));
                chunk.mesh.draw(gl.TRIANGLES, null, chunk.atomics_buffer);
                draws += 1;
                break :corners;
            }
        }
        if (count) std.debug.print("{} / {}\n", .{ draws, attempts });
    }

    // Chunk boundaries occur at multiples of Chunk.SIZE
    // The group of closest chunks changes halfway between these boundaries
    pub fn updateSplits(world: *@This(), cam_pos: ?zm.Vec) !void {
        var timer = try std.time.Timer.start();
        defer if (false) {
            const ns: f32 = @floatFromInt(timer.read());
            std.debug.print("Splits took {d:.3} ms\n", .{ns / 1_000_000});
        };

        if (cam_pos) |pos| {
            world.cam_pos = (pos / zm.f32x4s(Chunk.SIZE)) - zm.f32x4s(0.5);
            world.cam_pos = zm.ceil(world.cam_pos) * zm.f32x4s(Chunk.SIZE);
            world.cam_pos[3] = 0;
        }
        const new_splits = splitsFromPos(world.cam_pos);

        try world.sync();

        if (false) {
            const ns: f32 = @floatFromInt(timer.lap());
            std.debug.print("Sync took {d:.3} ms\n", .{ns / 1_000_000});
        }

        if (zm.any(world.splits != new_splits, 3)) {
            var diff = new_splits - world.splits;
            const neg = diff < zm.f32x4s(0);
            diff = @abs(diff);
            var min = [3]usize{ 0, 0, 0 };
            var max = [3]usize{ CHUNKS, CHUNKS, CHUNKS };
            world.splits = new_splits;

            for (0..3) |d| {
                const d1 = (d + 1) % 3;
                const d2 = (d + 2) % 3;

                for (0..@intFromFloat(diff[d])) |_| {
                    // Clear whole plane
                    for (min[d1]..max[d1]) |i| {
                        for (min[d2]..max[d2]) |j| {
                            var pos = zm.f32x4s(Chunk.SIZE);
                            // We are using the new splits, so the chunks we
                            // are interested in have already wrapped around
                            pos[d] *= @floatFromInt(if (neg[d]) min[d] else max[d] - 1);
                            pos[d1] *= @floatFromInt(i);
                            pos[d2] *= @floatFromInt(j);
                            pos += world.cam_pos - zm.f32x4s(SIZE - Chunk.SIZE) / zm.f32x4s(2);
                            switch (OVERDRAW) {
                                .global_lattice => {},
                                else => {
                                    const chunk_index = try world.indexFromOffset(pos, null);
                                    const chunk = &world.chunks[chunk_index];
                                    if (chunk.wip_mip != null or chunk.density_refs > 0) {
                                        chunk.must_free = true;
                                    } else {
                                        chunk.free(world.alloc, true);
                                    }
                                },
                            }
                        }
                    }
                    if (neg[d]) min[d] += 1 else max[d] -= 1;
                    if (min[d] == max[d]) break;
                }
            }

            const max_diff: usize = @intFromFloat(@max(diff[0], @max(diff[1], diff[2])));
            world.dist_done = @min(MIP0_DIST, world.dist_done) -| max_diff; // Saturating sub on usize
            world.index_done = 0;
        }
    }

    pub fn gen(world: *@This()) !void {
        var timer = try std.time.Timer.start();
        defer if (false) {
            const ns: f32 = @floatFromInt(timer.read());
            std.debug.print("Generation took {d:.3} ms\n", .{ns / 1_000_000});
        };

        const max_dist = CHUNKS / 2;

        var start_index = world.index_done;
        var all_done = true;

        outer: for (world.dist_done..max_dist) |dist| {
            const big = dist + 1;
            const edge = big == max_dist;
            const max_index = 8 * (3 * big * dist + 1);
            if (all_done) world.dist_done = dist;
            for (start_index..max_index) |index| {
                if (all_done) world.index_done = index;
                var i = index;
                var pos = zm.f32x4s(0);

                // Determine the axis in that the plane is fixed
                var plane: usize = 2;
                var thresh = 8 * big * big;
                if (i >= thresh) {
                    i -= thresh;
                    plane -= 1;
                    thresh = 8 * big * dist;
                    if (i >= thresh) {
                        i -= thresh;
                        plane -= 1;
                        thresh = 8 * dist * dist;
                    }
                }

                pos[plane] = @floatFromInt(dist);
                if (i < thresh / 2) {
                    pos[plane] = -pos[plane] - 1;
                } else {
                    i -= thresh / 2;
                }

                // Create a nested function without language support
                const signedDist = struct {
                    fn f(l: usize, r: usize) f32 {
                        const signed_dist = @as(isize, @intCast(l)) -
                            @as(isize, @intCast(r));
                        return @floatFromInt(signed_dist);
                    }
                }.f;

                const base1 = if (plane < 1) dist else big;
                const base2 = if (plane < 2) dist else big;
                pos[if (plane < 1) 1 else 0] = signedDist(i % (base1 * 2), base1);
                pos[if (plane > 1) 1 else 2] = signedDist(i / (base1 * 2), base2);

                if (try world.genChunk(
                    world.cam_pos + pos * zm.f32x4s(Chunk.SIZE),
                    if (dist < MIP0_DIST) 0 else 2,
                    edge,
                )) |done| {
                    all_done = all_done and done;
                } else break :outer;
            }
            start_index = 0;
            if (all_done and big < max_dist) world.index_done = 0;
        }
    }

    pub fn genChunkDensity(
        world: *@This(),
        chunk: *Chunk,
        chunk_index: usize,
        mip_level: usize,
    ) !bool {
        chunk.free(world.alloc, false);
        const mip_scale = std.math.pow(f32, 2, @floatFromInt(mip_level));
        const size = Chunk.SIZE / @as(usize, @intFromFloat(mip_scale));
        if (THREADING != .compute) chunk.density = try world.alloc.alloc(f32, size * size * size);

        const offset = world.offsetFromIndex(chunk_index, null);
        const old_mip = chunk.density_mip;

        chunk.density_mip = null;
        chunk.wip_mip = mip_level;
        chunk.splits_copy = world.splits;

        switch (THREADING) {
            .single => {
                try chunk.genDensity(offset);
            },
            .multi => {
                if (!try world.pool.work(
                    workerThread,
                    .{
                        .task = .density,
                        .world = world,
                        .chunk = chunk,
                        .offset = offset,
                    },
                )) {
                    world.alloc.free(chunk.density);
                    chunk.density = &.{};
                    chunk.density_mip = old_mip;
                    chunk.wip_mip = null;
                    chunk.splits_copy = null;
                    return false;
                }
                return true;
            },
            .compute => {
                var timer = try std.time.Timer.start();
                defer if (false) {
                    const ns: f32 = @floatFromInt(timer.read());
                    std.debug.print("Density compute shader took {d:.3} ms\n", .{ns / 1_000_000});
                };
                gl.bindBufferBase(gl.SHADER_STORAGE_BUFFER, 0, chunk.density_buffer.?); // 0 is the index chosen in main
                const density_shader = world.density_shader.?;
                density_shader.use();
                density_shader.set("chunk_size", gl.GLuint, @as(gl.GLuint, @intCast(Chunk.SIZE)));
                density_shader.set("offset", f32, zm.vecToArr3(offset));

                const groups = Chunk.SIZE / 4;
                gl.dispatchCompute(groups, groups, groups);
                gl.memoryBarrier(gl.BUFFER_UPDATE_BARRIER_BIT);
            },
        }
        chunk.density_mip = chunk.wip_mip;
        chunk.wip_mip = null;
        chunk.splits_copy = null;
        return true;
    }

    pub fn genChunkSurface(
        world: *@This(),
        chunk: *Chunk,
        chunk_index: usize,
    ) !bool {
        const min = if (Chunk.SURFACE.NEG_ADJ) 0 else 1;
        const offset = world.offsetFromIndex(chunk_index, null);
        const old_mip = chunk.surface_mip;
        chunk.surface_mip = null;
        chunk.wip_mip = chunk.density_mip;
        chunk.splits_copy = world.splits;
        if (THREADING != .compute) {
            // TODO why does it segfault if I use this instead?
            // if (chunk.surface) |_| chunk.surface.?.clearAndFree();
            // chunk.surface = std.ArrayList(f32).init(world.alloc);

            if (chunk.surface) |_| {
                chunk.surface.?.clearRetainingCapacity();
            } else {
                chunk.surface = std.ArrayList(f32).init(world.alloc);
            }
        }
        switch (THREADING) {
            .single => {
                try chunk.genSurface(world.*, offset);
                try chunk.mesh.upload(.{chunk.surface.?.items});
            },
            .multi => {
                if (!try world.pool.work(
                    workerThread,
                    .{
                        .task = .surface,
                        .world = world,
                        .chunk = chunk,
                        .offset = offset,
                    },
                )) {
                    chunk.surface.?.clearAndFree();
                    chunk.surface = null;
                    chunk.surface_mip = old_mip;
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
                return true;
            },
            .compute => {
                var timer = try std.time.Timer.start();
                defer if (false) {
                    const ns: f32 = @floatFromInt(timer.read());
                    std.debug.print("Surface compute shader took {d:.3} ms\n", .{ns / 1_000_000});
                };
                var values = [_]gl.GLuint{ 0, 1, 0, 0 };
                gl.bindBuffer(gl.ATOMIC_COUNTER_BUFFER, chunk.atomics_buffer.?);
                defer gl.bindBuffer(gl.ATOMIC_COUNTER_BUFFER, 0);
                gl.bufferSubData(gl.ATOMIC_COUNTER_BUFFER, 0, @sizeOf(@TypeOf(values)), &values);

                gl.bindBufferBase(gl.ATOMIC_COUNTER_BUFFER, 0, chunk.atomics_buffer.?); // 0 is the binding in the shader
                gl.bindBufferBase(gl.SHADER_STORAGE_BUFFER, 0, chunk.density_buffer.?); // 0 is the index chosen in main
                gl.bindBufferBase(gl.SHADER_STORAGE_BUFFER, 1, chunk.mesh.vbos.?[0]); // 1 is the index chosen in main
                const surface_shader = world.surface_shader.?;
                surface_shader.use();
                surface_shader.set("chunk_size", gl.GLuint, @as(gl.GLuint, @intCast(Chunk.SIZE)));
                surface_shader.set("mip_scale", f32, std.math.pow(f32, 2, @floatFromInt(chunk.wip_mip.?)));
                surface_shader.set("offset", f32, zm.vecToArr3(offset));

                const groups = Chunk.SIZE / 4;
                gl.dispatchCompute(groups, groups, groups);
                gl.memoryBarrier(gl.BUFFER_UPDATE_BARRIER_BIT | gl.ATOMIC_COUNTER_BARRIER_BIT);
            },
        }
        chunk.surface_mip = chunk.wip_mip;
        chunk.gpu_mip = chunk.surface_mip;
        chunk.wip_mip = null;
        chunk.splits_copy = null;
        return true;
    }

    // Return false if work for the chunk is pending
    // Return null if we have ran out of threads so that the caller can break
    // Return true if the chunk is already generated at a sufficient mip level
    pub fn genChunk(world: *@This(), pos: zm.Vec, mip_level: usize, edge: bool) !?bool {
        if (OVERDRAW == .global_lattice) return true;
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
                mip_level,
            )) {
                true => THREADING == .single,
                false => null,
            };
        }
        // Skip chunks which are already generated
        if (chunk.surface_mip) |mip| if (mip <= mip_level) return true;

        // Whether all relevant neighbours have sufficient generated densities
        var all_ready = true;

        const min = if (Chunk.SURFACE.NEG_ADJ) 0 else 1;
        // Iterate over neighbour region and generate any missing densities
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

                    // If we are about to schedule work then we are not all ready
                    if (THREADING != .single) all_ready = false;

                    // Skip chunks currently being used for their densities
                    if (neighbour.density_refs > 0) continue;

                    if (!try world.genChunkDensity(
                        neighbour,
                        neighbour_index,
                        mip_level,
                    )) return null;
                }
            }
        }
        if (!all_ready) return false;
        // All densities are present so lets generate the surface
        return switch (try world.genChunkSurface(chunk, chunk_index)) {
            true => THREADING == .single,
            false => null,
        };
    }

    fn sync(world: *@This()) !void {
        const min = if (Chunk.SURFACE.NEG_ADJ) 0 else 1;
        // Iterate over pool workers
        for (world.pool.workers) |*worker| {
            // Find workers who are finished and waiting for a sync
            if (!worker.finish()) continue;
            var chunk = worker.data.chunk;
            // If the task was to generate surface
            if (worker.data.task == .surface) {
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
                                neighbour.free(world.alloc, true);
                            }
                        }
                    }
                }
            }
            if (chunk.wip_mip == null) continue; // Already freed

            // If the task was to generate the surface
            if (worker.data.task == .surface) {
                // Upload the surface verts
                chunk.mesh.upload(.{chunk.surface.?.items}) catch |e| {
                    chunk.wip_mip = null;
                    chunk.splits_copy = null;
                    return e;
                };
                chunk.surface_mip = chunk.wip_mip;
                chunk.gpu_mip = chunk.wip_mip;
            } else {
                chunk.density_mip = chunk.wip_mip;
            }
            chunk.wip_mip = null;
            chunk.splits_copy = null;
        }
    }

    pub fn dig(world: *@This(), pos: zm.Vec, rad: f32) !void {
        std.debug.assert(rad >= 0);
        const last = rad * 2;
        const iters: usize = @intFromFloat(@ceil(last / Chunk.SIZE) + 1);
        var skip_last: [3]bool = undefined;
        var corner = pos - zm.f32x4s(rad);
        corner[3] = 0;

        for (0..3) |d| {
            var other = corner;
            other[d] += @mod(last, Chunk.SIZE);
            skip_last[d] = try world.indexFromOffset(corner, null) ==
                try world.indexFromOffset(other, null);
        }

        // Density
        for (0..iters) |k| {
            var z = @as(f32, @floatFromInt(k)) * Chunk.SIZE;
            if (k + 1 == iters and rad > 0) {
                if (skip_last[2]) continue;
                z = last;
            }
            for (0..iters) |j| {
                var y = @as(f32, @floatFromInt(j)) * Chunk.SIZE;
                if (j + 1 == iters and rad > 0) {
                    if (skip_last[1]) continue;
                    y = last;
                }

                for (0..iters) |i| {
                    var x = @as(f32, @floatFromInt(i)) * Chunk.SIZE;
                    if (i + 1 == iters and rad > 0) {
                        if (skip_last[0]) continue;
                        x = last;
                    }

                    const chunk_pos = corner + zm.f32x4(x, y, z, 0);
                    const chunk_index = try world.indexFromOffset(chunk_pos, null);
                    const offset = world.offsetFromIndex(chunk_index, null);
                    switch (OVERDRAW) {
                        .global_lattice => {},
                        else => {
                            var chunk = world.chunks[chunk_index];
                            switch (THREADING) {
                                // TODO .multi should do this on another thread
                                .single, .multi => try chunk.dig(pos - offset, rad),
                                .compute => @panic("Digging is not implemented in compute shaders"),
                            }
                        },
                    }
                }
            }
        }
        // Surface
        if (OVERDRAW == .global_lattice) {
            return;
        }
        for (0..iters) |k| {
            var z = @as(f32, @floatFromInt(k)) * Chunk.SIZE;
            if (k + 1 == iters and rad > 0) {
                if (skip_last[2]) continue;
                z = last;
            }
            for (0..iters) |j| {
                var y = @as(f32, @floatFromInt(j)) * Chunk.SIZE;
                if (j + 1 == iters and rad > 0) {
                    if (skip_last[1]) continue;
                    y = last;
                }

                for (0..iters) |i| {
                    var x = @as(f32, @floatFromInt(i)) * Chunk.SIZE;
                    if (i + 1 == iters and rad > 0) {
                        if (skip_last[0]) continue;
                        x = last;
                    }

                    const chunk_pos = corner + zm.f32x4(x, y, z, 0);
                    const min = if (Chunk.SURFACE.NEG_ADJ) 0 else 1;
                    for (min..3) |c| {
                        for (min..3) |b| {
                            for (min..3) |a| {
                                // TODO ideally all of these chunks would wait to be visually updated all at the same time
                                const neighbour_pos = (zm.f32x4(
                                    @floatFromInt(a),
                                    @floatFromInt(b),
                                    @floatFromInt(c),
                                    1,
                                ) - zm.f32x4s(1)) * zm.f32x4s(Chunk.SIZE) + chunk_pos;
                                const neighbour = &world.chunks[try world.indexFromOffset(neighbour_pos, null)];
                                if (neighbour.density_refs == 0 and neighbour.wip_mip == null) {
                                    neighbour.surface_mip = null; // Request surface regen
                                } // TODO else add to a queue in the case of .multi
                            }
                        }
                    }
                }
            }
        }
        // TODO ought to consider distance to the pos, minus radius
        world.dist_done = 0;
        world.index_done = 0;
    }

    pub fn indexFromOffset(world: @This(), _pos: zm.Vec, splits: ?zm.Vec) !usize {
        const spl = splits orelse world.splits;
        const pos = zm.floor(_pos / zm.f32x4s(Chunk.SIZE));
        var index: usize = 0;
        for (0..3) |d| {
            const i = 2 - d;
            var f = pos[i] - @floor(spl[i] / CHUNKS) * CHUNKS;
            if (@mod(f, CHUNKS) >=
                @mod(spl[i], CHUNKS)) f += CHUNKS;
            if (f < 0 or f >= CHUNKS) return error.PositionOutsideWorld;
            index *= CHUNKS;
            index += @intFromFloat(f);
        }
        return index;
    }

    pub fn offsetFromIndex(world: @This(), index: usize, splits: ?zm.Vec) zm.Vec {
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
        task: enum { density, surface },
        world: *World,
        chunk: *Chunk,
        offset: zm.Vec,
    };

    fn workerThread(data: WorkerData) void {
        (switch (data.task) {
            .density => data.chunk.genDensity(data.offset),
            .surface => data.chunk.genSurface(data.world.*, data.offset),
        }) catch unreachable;
    }
};
