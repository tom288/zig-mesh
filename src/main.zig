const std = @import("std");
const Window = @import("window.zig").Window;
const Shader = @import("shader.zig").Shader;
const Rectangle = @import("rectangle.zig").Rectangle;
const zm = @import("zmath");

pub fn main() !void {
    var window = try Window.init();
    defer window.kill();

    var shader = try Shader.init(
        "glsl/wobble.vert",
        null,
        "glsl/wobble.frag",
    );
    defer shader.kill();

    var rectangle = Rectangle.init();
    defer rectangle.kill();

    // Wait for the user to close the window.
    while (window.ok()) {
        if (window.mouse_pos) |mouse| {
            const pos = mouse / window.resolution;
            window.clearColour(pos[0], pos[1], 0.5, 1);
        } else {
            window.clearColour(0.1, 0, 0.2, 1);
        }
        shader.use();
        shader.set("uv_zoom", f32, 1.9);
        shader.set("time", f32, window.time orelse 0);
        shader.set("identity", f32, &zm.matToArr(zm.identity()));
        if (window.mouse_pos) |mouse| shader.set("offset", f32, @as([4]f32, mouse / window.resolution)[0..2]);

        rectangle.draw();
        window.swap();
    }
}
