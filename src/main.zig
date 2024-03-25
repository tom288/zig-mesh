const std = @import("std");
const zm = @import("zmath");
const Window = @import("window.zig").Window;
const Shader = @import("shader.zig").Shader;
const World = @import("world.zig").World;
const Camera = @import("camera.zig").Camera;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) unreachable;
    const alloc = gpa.allocator();

    var camera = Camera.init();
    var window = try Window.init(
        alloc,
        &camera,
        "zig-mesh",
        true,
        null,
    );
    defer window.kill();

    var shader = try Shader.init(
        alloc,
        "perspective",
        null,
        "perspective",
    );
    defer shader.kill();

    var density_shader = try Shader.initComp(alloc, "density");
    defer density_shader.kill();
    density_shader.bindBlock("density_block", 0);

    var surface_shader = try Shader.initComp(alloc, "surface");
    defer surface_shader.kill();
    surface_shader.bindBlock("density_block", 0);
    surface_shader.bindBlock("surface_block", 1);

    var world = try World.init(
        alloc,
        shader,
        density_shader,
        surface_shader,
        camera.position,
    );
    defer world.kill() catch unreachable;

    // Wait for the user to close the window.
    while (window.ok()) {
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
