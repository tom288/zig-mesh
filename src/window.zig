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
    time: ?f32,
    delta: f32,
    mouse_pos: ?zm.Vec,
    mouse_delta: zm.Vec,
    binds: std.AutoHashMap(glfw.Key, Action),
    actionState: [@typeInfo(Action).Enum.fields.len]bool,
    input: zm.Vec,
    scroll_delta: zm.Vec,

    const InitError = error{
        GlfwInitFailure,
        MonitorUnobtainable,
        VideoModeUnobtainable,
        WindowCreationFailure,
    };

    pub fn init(alloc: std.mem.Allocator) !Window {
        // Ensure GLFW errors are logged
        glfw.setErrorCallback(errorCallback);

        const fullscreen = false;
        const resizable = false;
        const show_cursor = false;
        const raw_input = true;
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
            "zig-mesh",
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
            return err;
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

        var binds = std.AutoHashMap(glfw.Key, Action).init(alloc);
        errdefer binds.deinit();
        try binds.put(glfw.Key.w, Action.forward);
        try binds.put(glfw.Key.s, Action.backward);
        try binds.put(glfw.Key.a, Action.left);
        try binds.put(glfw.Key.d, Action.right);
        try binds.put(glfw.Key.space, Action.ascend);
        try binds.put(glfw.Key.caps_lock, Action.descend);
        try binds.put(glfw.Key.left_shift, Action.descend);
        try binds.put(glfw.Key.left_control, Action.descend);

        return Window{
            .window = window,
            .clear_mask = clear_mask,
            .resolution = zm.loadArr2([2]f32{ width * scale, height * scale }),
            .time = null,
            .delta = 0,
            .mouse_pos = null,
            .mouse_delta = @splat(0),
            .binds = binds,
            .actionState = undefined,
            .input = @splat(0),
            .scroll_delta = @splat(0),
        };
    }

    pub fn kill(win: *Window) void {
        win.binds.deinit();
        win.window.destroy();
        windows -= 1;
        // When we have no windows we have no use for GLFW
        if (windows == 0) glfw.terminate();
    }

    pub fn ok(win: *Window) bool {
        // Clear mouse delta
        win.mouse_delta = @splat(0);
        win.scroll_delta = @splat(0);

        // Update deltaTime
        const new_time: f32 = @floatCast(glfw.getTime());
        if (win.time) |time| {
            win.delta = new_time - time;
        } else {
            // Set the user pointer if we are about to poll the first events
            win.window.setUserPointer(win);
            win.actionState = std.mem.zeroes(@TypeOf(win.actionState));
        }
        win.time = new_time;

        // Create a closure without language support
        const action = (struct {
            state: @TypeOf(win.actionState),
            fn active(self: @This(), a: Action) bool {
                return self.state[@intFromEnum(a)];
            }
        }{ .state = win.actionState });

        glfw.pollEvents();
        win.input = @splat(0);
        if (action.active(Action.left)) win.input[0] -= 1;
        if (action.active(Action.right)) win.input[0] += 1;
        if (action.active(Action.descend)) win.input[1] -= 1;
        if (action.active(Action.ascend)) win.input[1] += 1;
        if (action.active(Action.backward)) win.input[2] -= 1;
        if (action.active(Action.forward)) win.input[2] += 1;
        return !win.window.shouldClose();
    }

    pub fn clear(win: Window) void {
        gl.clear(win.clear_mask);
    }

    pub fn clearColour(win: Window, r: f32, g: f32, b: f32, a: f32) void {
        gl.clearColor(r, g, b, a);
        win.clear();
    }

    pub fn swap(win: Window) void {
        win.window.swapBuffers();
    }
};

const Action = enum {
    left,
    right,
    ascend,
    descend,
    forward,
    backward,
    attack1,
    attack2,
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
    _ = scancode;
    if (key == glfw.Key.escape) window.setShouldClose(true);
    const win = window.getUserPointer(Window) orelse unreachable;
    const target = win.binds.get(key) orelse return;
    win.actionState[@intFromEnum(target)] = action != glfw.Action.release;
}

fn mouseButtonCallback(window: glfw.Window, button: glfw.MouseButton, action: glfw.Action, mods: glfw.Mods) void {
    _ = mods;
    _ = action;
    _ = button;
    _ = window;
}

fn cursorPosCallback(window: glfw.Window, xpos: f64, ypos: f64) void {
    const win = window.getUserPointer(Window) orelse unreachable;
    const new_pos = zm.loadArr2([2]f32{
        @floatCast(xpos),
        @floatCast(win.resolution[1] - ypos - 1),
    });
    if (win.mouse_pos) |pos| win.mouse_delta += new_pos - pos;
    win.mouse_pos = new_pos;
}

fn scrollCallback(window: glfw.Window, xoffset: f64, yoffset: f64) void {
    const win = window.getUserPointer(Window) orelse unreachable;
    win.scroll_delta += zm.loadArr2([2]f32{ @floatCast(xoffset), @floatCast(yoffset) });
}
