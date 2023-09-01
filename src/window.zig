const std = @import("std");
const glfw = @import("mach-glfw");
const gl = @import("gl");
const zm = @import("zmath");

const log = std.log.scoped(.Engine);
var windows: usize = 0;

pub const Window = struct {
    window: glfw.Window,
    clear_mask: gl.GLbitfield,
    resolution: zm.Vec,
    mouse_pos: ?zm.Vec,
    time: ?f32,
    delta: ?f32,

    const InitError = error{
        GlfwInitFailure,
        MonitorUnobtainable,
        VideoModeUnobtainable,
        WindowCreationFailure,
        OpenGlLoadFailure,
    };

    pub fn init() InitError!Window {
        // Ensure GLFW errors are logged
        glfw.setErrorCallback(errorCallback);

        const fullscreen = false;
        const resizable = false;
        const show_cursor = true;
        const raw_input = false;
        const cull_faces = true;
        const test_depth = true;
        const wireframe = false;
        const vertical_sync = true;
        const msaa_samples = 16;
        const clear_buffers = true;

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
        const scale: f32 = if (fullscreen) 1 else 900.0 / 1080.0;
        const scale_gap = (1 - scale) / 2;
        const width: f32 = @floatFromInt(mode.getWidth());
        const height: f32 = @floatFromInt(mode.getHeight());

        // Create our window
        const window = glfw.Window.create(
            @intFromFloat(width * scale),
            @intFromFloat(height * scale),
            "mach-glfw + zig-opengl",
            if (fullscreen) monitor else null,
            null,
            .{
                .opengl_profile = .opengl_core_profile,
                .context_version_major = 4,
                .context_version_minor = 1,
                .resizable = resizable,
                .samples = msaa_samples,
            },
        ) orelse {
            std.log.err("failed to create GLFW window: {?s}", .{glfw.getErrorString()});
            return InitError.WindowCreationFailure;
        };
        errdefer window.destroy();

        // Centre the window
        if (!fullscreen) window.setPos(.{
            @intFromFloat(width * scale_gap),
            @intFromFloat(height * scale_gap),
        });

        // Listen to window input
        window.setKeyCallback(keyCallback);
        window.setMouseButtonCallback(mouseButtonCallback);
        window.setCursorPosCallback(cursorPosCallback);
        window.setScrollCallback(scrollCallback);
        glfw.makeContextCurrent(window);

        // Configure input
        if (!show_cursor) {
            window.setInputModeCursor(glfw.Window.InputModeCursor.disabled);
        }
        if (raw_input and glfw.rawMouseMotionSupported()) {
            // Disable mouse motion acceleration and scaling
            window.setInputModeRawMouseMotion(true);
        }

        const proc: glfw.GLProc = undefined;
        gl.load(proc, glGetProcAddress) catch |err| {
            std.log.err("failed to load OpenGL: {}", .{err});
            return InitError.OpenGlLoadFailure;
        };

        // Configure triangle visibility
        if (cull_faces) gl.enable(gl.CULL_FACE);
        if (test_depth) gl.enable(gl.DEPTH_TEST);
        if (wireframe) gl.polygonMode(gl.FRONT_AND_BACK, gl.LINE);

        // Configure additional window properties
        if (!vertical_sync) glfw.swapInterval(0);
        if (msaa_samples > 1) gl.enable(gl.MULTISAMPLE);

        // Determine which buffers get cleared
        var clear_mask: gl.GLbitfield = 0;
        if (clear_buffers) {
            clear_mask |= gl.COLOR_BUFFER_BIT;
            if (test_depth) {
                clear_mask |= gl.DEPTH_BUFFER_BIT;
            }
        }

        // Update window count
        windows += 1;

        return Window{
            .window = window,
            .clear_mask = clear_mask,
            .resolution = zm.f32x4(width * scale, height * scale, 0, 0),
            .mouse_pos = null,
            .time = null,
            .delta = null,
        };
    }

    pub fn kill(window: *Window) void {
        window.window.destroy();
        windows -= 1;
        // When we have no windows we have no use for GLFW
        if (windows == 0) glfw.terminate();
    }

    pub fn ok(window: *Window) bool {
        // Update deltaTime
        const new_time: f32 = @floatCast(glfw.getTime());
        if (window.time) |time| {
            window.delta = new_time - time;
        }
        window.time = new_time;

        // Set the user pointer if we are about to poll the first events
        if (window.delta == null) {
            window.window.setUserPointer(window);
        }

        glfw.pollEvents();
        return !window.window.shouldClose();
    }

    pub fn clear(window: Window) void {
        gl.clear(window.clear_mask);
    }

    pub fn clearColour(window: Window, r: f32, g: f32, b: f32, a: f32) void {
        gl.clearColor(r, g, b, a);
        window.clear();
    }

    pub fn swap(window: Window) void {
        window.window.swapBuffers();
    }
};

fn glGetProcAddress(p: glfw.GLProc, proc: [:0]const u8) ?gl.FunctionPointer {
    _ = p;
    return glfw.getProcAddress(proc);
}

fn errorCallback(error_code: glfw.ErrorCode, description: [:0]const u8) void {
    std.log.err("glfw: {}: {s}", .{ error_code, description });
}

fn keyCallback(window: glfw.Window, key: glfw.Key, scancode: i32, action: glfw.Action, mods: glfw.Mods) void {
    _ = mods;
    _ = action;
    _ = scancode;
    if (key == glfw.Key.escape) window.setShouldClose(true);
}

fn mouseButtonCallback(window: glfw.Window, button: glfw.MouseButton, action: glfw.Action, mods: glfw.Mods) void {
    _ = mods;
    _ = action;
    _ = button;
    _ = window;
}

fn cursorPosCallback(window: glfw.Window, xpos: f64, ypos: f64) void {
    const ptr = window.getUserPointer(Window) orelse {
        std.log.err("Window user pointer not set", .{});
        return;
    };
    ptr.mouse_pos = zm.f32x4(@floatCast(xpos), @floatCast(ptr.resolution[1] - ypos - 1), 0, 0);
}

fn scrollCallback(window: glfw.Window, xoffset: f64, yoffset: f64) void {
    _ = yoffset;
    _ = xoffset;
    _ = window;
}
