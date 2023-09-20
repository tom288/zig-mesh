const std = @import("std");
const zm = @import("zmath");
const World = @import("world.zig").World;
const Chunk = @import("chunk.zig").Chunk;

pub const Pool = struct {
    busy_bools: []bool,
    vert_bools: []bool,
    wait_bools: []std.atomic.Atomic(bool),
    chunks: []usize,

    const Task = enum {
        density,
        vertices,
    };

    pub fn init(alloc: std.mem.Allocator) !Pool {
        const count = @max(try std.Thread.getCpuCount() - 1, 1);
        var busy_bools = try alloc.alloc(bool, count);
        errdefer alloc.free(busy_bools);
        const vert_bools = try alloc.alloc(bool, count);
        errdefer alloc.free(vert_bools);
        const wait_bools = try alloc.alloc(std.atomic.Atomic(bool), count);
        errdefer alloc.free(wait_bools);
        const chunks = try alloc.alloc(usize, count);
        errdefer alloc.free(chunks);

        for (0.., wait_bools) |i, *wait_bool| {
            busy_bools[i] = false;
            vert_bools[i] = false;
            wait_bool.* = @TypeOf(wait_bool.*).init(false);
            chunks[i] = 0;
        }

        return .{
            .busy_bools = busy_bools,
            .vert_bools = vert_bools,
            .wait_bools = wait_bools,
            .chunks = chunks,
        };
    }

    pub fn kill(pool: *@This(), alloc: std.mem.Allocator) void {
        alloc.free(pool.chunks);
        pool.chunks = &.{};
        alloc.free(pool.wait_bools);
        pool.wait_bools = &.{};
        alloc.free(pool.vert_bools);
        pool.vert_bools = &.{};
        alloc.free(pool.busy_bools);
        pool.busy_bools = &.{};
    }

    // Return true if all workers are busy or if any workers are doing the task specified
    pub fn busy(pool: @This(), task: ?Task) bool {
        var free = false;
        for (pool.busy_bools, pool.vert_bools) |busy_bool, vert_bool| {
            if (task) |t| {
                if (busy_bool) {
                    if ((t == .vertices) == vert_bool) return true;
                } else free = true;
            } else if (busy_bool) return false;
        }
        return if (task) |_| !free else true;
    }

    pub fn work(
        pool: *@This(),
        world: World,
        chunk_index: usize,
        task: Task,
    ) !bool {
        for (0.., pool.wait_bools) |i, *wait_bool| {
            if (pool.busy_bools[i]) continue;
            pool.busy_bools[i] = true;
            pool.vert_bools[i] = task == .vertices;
            wait_bool.store(false, .Unordered);
            pool.chunks[i] = chunk_index;

            const offset = world.offsetFromIndex(chunk_index);
            (try std.Thread.spawn(
                .{},
                function,
                .{ wait_bool, task, world, chunk_index, offset },
            )).detach();
            return true;
        }
        return false;
    }

    fn function(wait_bool: *std.atomic.Atomic(bool), task: Task, world: World, i: usize, offset: zm.Vec) !void {
        var chunk = &world.chunks[i];
        switch (task) {
            .density => try chunk.genDensity(offset),
            .vertices => try chunk.genVerts(world, offset),
        }
        wait_bool.store(true, .Unordered);
    }
};
