const std = @import("std");
const win = @import("window.zig");
const sdr = @import("shader.zig");
const rec = @import("rectangle.zig");

pub fn main() !void {
    var window = try win.Window.init();
    defer window.kill();

    var shader = try sdr.Shader.init(
        "glsl/wobble.vert",
        null,
        "glsl/wobble.frag",
    );
    defer shader.kill();

    var rectangle = rec.Rectangle.init();
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
        shader.setFloat("uv_zoom", 1.9);
        shader.setFloat("time", window.time orelse 0);
        rectangle.draw();
        window.swap();
    }
}
