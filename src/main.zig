const std = @import("std");
const zm = @import("zmath");
const Window = @import("window.zig").Window;
const Shader = @import("shader.zig").Shader;
const Rectangle = @import("rectangle.zig").Rectangle;
const Camera = @import("camera.zig").Camera;

pub fn main() !void {
    var window = try Window.init();
    defer window.kill();

    var shader = try Shader.init(
        "glsl/perspective.vert",
        null,
        "glsl/perspective.frag",
    );
    defer shader.kill();

    var rectangle = Rectangle.init();
    defer rectangle.kill();

    var camera = Camera.init(window.resolution);

    // Wait for the user to close the window.
    while (window.ok()) {
        camera.step(window.input, window.delta);
        camera.mouseMouse(window.mouse_delta);
        window.clearColour(0.1, 0, 0.2, 1);

        shader.use();
        shader.set("model", f32, &zm.matToArr(zm.identity()));
        shader.set("view", f32, &zm.matToArr(camera.view));
        shader.set("projection", f32, &zm.matToArr(camera.proj));

        rectangle.draw();
        window.swap();
    }
}
