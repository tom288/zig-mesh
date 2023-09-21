const std = @import("std");
const zm = @import("zmath");
const Window = @import("window.zig").Window;
const Shader = @import("shader.zig").Shader;
const World = @import("world.zig").World;
const Camera = @import("camera.zig").Camera;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) unreachable;
    const chunk_alloc = gpa.allocator();

    var window = try Window.init(alloc);
    defer window.kill();

    var shader = try Shader.init(
        "perspective",
        null,
        "perspective",
    );
    defer shader.kill();
    var camera = Camera.init(window.resolution);
    var world = try World.init(alloc, chunk_alloc, shader, camera.position);
    defer world.kill();

    // Wait for the user to close the window.
    while (window.ok()) {
        camera.turn(window.mouse_delta);
        camera.step(window.input, window.delta);
        camera.scroll(window.scroll_delta);
        window.clearColour(0.1, 0, 0.2, 1);

        try world.gen(camera.position);

        shader.use();
        shader.set("view", f32, &zm.matToArr(camera.view));
        shader.set("projection", f32, &zm.matToArr(camera.proj));
        world.draw(shader);

        window.swap();
    }
}
