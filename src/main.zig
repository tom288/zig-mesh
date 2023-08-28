const std = @import("std");
const glfw = @import("mach-glfw");
const gl = @import("gl");
const win = @import("window.zig");

pub fn main() !void {
    const window = try win.init();
    defer win.kill(window);

    // Wait for the user to close the window.
    while (!window.shouldClose()) {
        gl.clearColor(0.1, 0, 0.2, 1);
        gl.clear(gl.COLOR_BUFFER_BIT);
        glfw.pollEvents();

        window.swapBuffers();
    }
}
