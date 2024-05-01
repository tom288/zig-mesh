const std = @import("std");
const gl = @import("gl");
const zm = @import("zmath");
const Window = @import("window.zig").Window;
const Shader = @import("shader.zig").Shader;
const World = @import("world.zig").World;
const Camera = @import("camera.zig").Camera;
const CFG = @import("cfg.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) unreachable;
    const alloc = gpa.allocator();

    var camera = Camera.init();

    var window = try Window.init(.{
        .alloc = alloc,
        .title = "zig-mesh",
    });
    defer window.kill();
    window.clearColour(0.1, 0, 0.2, 1);

    var gfx = try CFG.gfx.init(alloc, window.resolution);
    defer gfx.kill();

    var world = try World.init(
        alloc,
        gfx.getWorldShader(),
        camera.position,
    );
    defer world.kill() catch unreachable;

    // Wait for the user to close the window.
    while (window.ok()) {
        camera.turn(window.mouse_delta);
        camera.step(window.input, window.delta);
        camera.scroll(window.scroll_delta);

        try world.updateSplits(camera.position);
        if (window.active(.attack1)) {
            const RAD = 5;
            try world.dig(camera.position + camera.look * zm.f32x4s(RAD), RAD);
        }
        try world.gen();

        if (window.resized) {
            camera.calcAspect(window.resolution);
            gfx.resize(window.resolution);
        }

        gfx.prep();
        try world.draw(camera.position, camera.view, camera.proj.?);
        gfx.compose(camera.proj.?);
        window.swap();
    }
}
