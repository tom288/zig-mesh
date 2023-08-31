const std = @import("std");
const win = @import("window.zig");
const shader = @import("shader.zig");

pub fn main() !void {
    var window = try win.Window.init();
    defer window.kill();

    // Wait for the user to close the window.
    while (window.ok()) {
        if (window.mouse_pos) |mouse| {
            const pos = mouse / window.resolution;
            window.clearColour(pos[0], pos[1], 0.5, 1);
        } else {
            window.clearColour(0.1, 0, 0.2, 1);
        }
        window.swap();
    }
}
