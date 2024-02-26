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

    var camera = Camera.init();
    var window = try Window.init(alloc, &camera);
    defer window.kill();

    var shader = try Shader.init(
        "perspective",
        null,
        "perspective",
    );
    defer shader.kill();

    var density_shader = try Shader.init_comp("density");
    defer density_shader.kill();
    density_shader.bind_block("density_block", 0);

    var surface_shader = try Shader.init_comp("surface");
    defer surface_shader.kill();
    surface_shader.bind_block("density_block", 0);
    surface_shader.bind_block("surface_block", 1);

    var world = try World.init(
        alloc,
        chunk_alloc,
        shader,
        density_shader,
        surface_shader,
        camera.position,
    );
    defer world.kill() catch unreachable;

    // Wait for the user to close the window.
    while (try window.ok()) {
        camera.turn(window.mouse_delta);
        camera.step(window.input, window.delta);
        camera.scroll(window.scroll_delta);
        window.clearColour(0.1, 0, 0.2, 1);

        try world.gen(camera.position);

        shader.use();
        try world.draw(camera.position, camera.world_to_clip);

        window.swap();
    }
}
