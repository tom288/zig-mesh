//! A Pool holds a collection of threads and the logic to execute tasks on them

const std = @import("std");

pub fn Pool(comptime Data: type) type {
    return struct {
        workers: []Worker,

        const Worker = struct {
            // Whether the worker is busy or is able to receive new work
            // This is managed by the main thread in work() and finish()
            busy: bool,
            // Whether the worker has finished work and is waiting for a sync
            // This is set to false by main thread and true by worker thread
            wait: std.atomic.Value(bool),
            data: Data,

            pub fn finish(worker: *Worker) bool {
                if (!worker.wait.load(.unordered)) return false;
                // Reset worker state
                worker.wait.store(false, .unordered);
                worker.busy = false;
                return true;
            }
        };

        pub fn init(alloc: std.mem.Allocator) !@This() {
            const thread_count = @max(try std.Thread.getCpuCount() - 1, 1);

            const workers = try alloc.alloc(Worker, thread_count);
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
                worker.wait.store(false, .unordered);
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

        fn thread(
            wait: *std.atomic.Value(bool),
            comptime func: fn (data: Data) void,
            data: Data,
        ) !void {
            func(data);
            wait.store(true, .unordered);
        }
    };
}
