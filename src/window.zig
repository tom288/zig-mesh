const std = @import("std");
const glfw = @import("mach-glfw");
const gl = @import("gl");

const log = std.log.scoped(.Engine);
var windows: usize = 0;

fn glGetProcAddress(p: glfw.GLProc, proc: [:0]const u8) ?gl.FunctionPointer {
    _ = p;
    return glfw.getProcAddress(proc);
}

fn errorCallback(error_code: glfw.ErrorCode, description: [:0]const u8) void {
    std.log.err("glfw: {}: {s}\n", .{ error_code, description });
}

fn keyCallback(window: glfw.Window, key: glfw.Key, scancode: i32, action: glfw.Action, mods: glfw.Mods) void {
    _ = mods;
    _ = action;
    _ = scancode;
    if (key == glfw.Key.escape) window.setShouldClose(true);
}

const InitError = error{
    GlfwInitFailure,
    MonitorUnobtainable,
    VideoModeUnobtainable,
    WindowCreationFailure,
    OpenGlLoadFailure,
};

pub fn init() InitError!glfw.Window {
    // Ensure GLFW errors are logged
    glfw.setErrorCallback(errorCallback);

    // If we currently have no windows then initialise GLFW
    if (windows == 0 and !glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        return InitError.GlfwInitFailure;
    }
    errdefer if (windows == 0) glfw.terminate();

    // Obtain primary monitor
    const monitor = glfw.Monitor.getPrimary() orelse {
        std.log.err("failed to get primary monitor: {?s}", .{glfw.getErrorString()});
        return InitError.MonitorUnobtainable;
    };

    // Obtain video mode of monitor
    const mode = glfw.Monitor.getVideoMode(monitor) orelse {
        std.log.err("failed to get video mode of primary monitor: {?s}", .{glfw.getErrorString()});
        return InitError.VideoModeUnobtainable;
    };

    // Use scale to make window smaller than primary monitor
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
        return InitError.WindowCreationFailure;
    };
    errdefer window.destroy();

    // Centre the window
    const scale_gap = (1 - scale) / 2;
    window.setPos(.{
        @intFromFloat(width * scale_gap),
        @intFromFloat(height * scale_gap),
    });

    // Listen to window input
    window.setKeyCallback(keyCallback);
    glfw.makeContextCurrent(window);

    const proc: glfw.GLProc = undefined;
    gl.load(proc, glGetProcAddress) catch |err| {
        std.log.err("failed to load OpenGL: {}", .{err});
        return InitError.OpenGlLoadFailure;
    };

    // Update window count
    windows += 1;
    return window;
}

pub fn kill(window: glfw.Window) void {
    window.destroy();
    windows -= 1;
    // When we have no windows we have no use for GLFW
    if (windows == 0) glfw.terminate();
}
