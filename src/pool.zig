const std = @import("std");
const zm = @import("zmath");
const World = @import("world.zig").World;
const Chunk = @import("chunk.zig").Chunk;

pub fn Pool(comptime Data: type) type {
    return struct {
        workers: []Worker,

        const Worker = struct {
            busy: bool,
            wait: std.atomic.Atomic(bool),
            data: Data,
        };

        pub fn init(alloc: std.mem.Allocator) !@This() {
            const thread_count = @max(try std.Thread.getCpuCount() - 1, 1);

            var workers = try alloc.alloc(Worker, thread_count);
            errdefer alloc.free(workers);

            for (workers) |*worker| {
                worker.busy = false;
                worker.wait = @TypeOf(worker.wait).init(false);
            }

            return .{ .workers = workers };
        }

        pub fn kill(pool: *@This(), alloc: std.mem.Allocator) void {
            alloc.free(pool.workers);
            pool.workers = &.{};
        }

        pub fn work(
            pool: *@This(),
            comptime func: fn (data: Data) void,
            data: Data,
        ) !bool {
            for (pool.workers) |*worker| {
                if (worker.busy) continue;
                worker.busy = true;
                worker.wait.store(false, .Unordered);
                worker.data = data;
                (try std.Thread.spawn(
                    .{},
                    thread,
                    .{ &worker.wait, func, worker.data },
                )).detach();
                return true;
            }
            return false;
        }

        fn thread(wait: *std.atomic.Atomic(bool), comptime func: fn (data: Data) void, data: Data) !void {
            func(data);
            wait.store(true, .Unordered);
        }
    };
}
