const std = @import("std");
const glfw = @import("mach-glfw");
const gl = @import("gl");

const log = std.log.scoped(.Engine);

fn glGetProcAddress(p: glfw.GLProc, proc: [:0]const u8) ?gl.FunctionPointer {
    _ = p;
    return glfw.getProcAddress(proc);
}

/// Default GLFW error handling callback
fn errorCallback(error_code: glfw.ErrorCode, description: [:0]const u8) void {
    std.log.err("glfw: {}: {s}\n", .{ error_code, description });
}

pub fn main() !void {
    glfw.setErrorCallback(errorCallback);
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const monitor = glfw.Monitor.getPrimary() orelse {
        std.log.err("failed to get primary monitor: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    };

    const mode = glfw.Monitor.getVideoMode(monitor) orelse {
        std.log.err("failed to get video mode of primary monitor: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    };

    const scale: f32 = 900.0 / 1080.0;
    const width: f32 = @floatFromInt(mode.getWidth());
    const height: f32 = @floatFromInt(mode.getHeight());

    // Create our window
    const window = glfw.Window.create(
        @intFromFloat(width * scale),
        @intFromFloat(height * scale),
        "mach-glfw + zig-opengl",
        null,
        null,
        .{
            .opengl_profile = .opengl_core_profile,
            .context_version_major = 4,
            .context_version_minor = 1,
        },
    ) orelse {
        std.log.err("failed to create GLFW window: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    };
    defer window.destroy();

    const scale_gap = (1 - scale) / 2;
    window.setPos(.{
        @intFromFloat(width * scale_gap),
        @intFromFloat(height * scale_gap),
    });

    glfw.makeContextCurrent(window);

    const proc: glfw.GLProc = undefined;
    try gl.load(proc, glGetProcAddress);

    // Wait for the user to close the window.
    while (!window.shouldClose()) {
        glfw.pollEvents();

        gl.clearColor(0.1, 0, 0.2, 1);
        gl.clear(gl.COLOR_BUFFER_BIT);

        window.swapBuffers();
    }
}
