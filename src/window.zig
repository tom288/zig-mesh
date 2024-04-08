//! The Window manages the viewport and accumulates user input

const std = @import("std");
const glfw = @import("glfw");
const gl = @import("gl");
const zm = @import("zmath");

pub const Window = struct {
    window: ?glfw.Window = null,
    clear_mask: gl.GLbitfield,
    resolution: zm.Vec,
    viewport: ?glfw.Window.Size = null,
    time: ?f32 = null,
    delta: f32,
    mouse_pos: ?zm.Vec = null,
    mouse_delta: zm.Vec,
    scroll_delta: zm.Vec,
    binds: ?std.AutoHashMap(glfw.Key, Action) = null,
    mouse_binds: ?std.AutoHashMap(glfw.MouseButton, Action) = null,
    actionState: [@typeInfo(Action).Enum.fields.len]bool,
    input: zm.Vec,
    min_delta: f32,
    resized: bool,

    var windows: usize = 0;

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

    pub fn init(cfg: struct {
        alloc: std.mem.Allocator,
        title: [*:0]const u8 = "",
        vsync: bool = true,
        min_delta: f32 = 0.1,
        windowed: bool = true,
        resizable: bool = false,
        show_cursor: bool = false,
        raw_input: bool = true,
        cull_faces: bool = true,
        test_depth: bool = true,
        wireframe: bool = false,
        msaa_samples: ?u31 = 16,
        clear_buffers: bool = true,
    }) !@This() {
        var win = @This(){
            .clear_mask = 0,
            .resolution = undefined,
            .delta = 0,
            .mouse_delta = @splat(0),
            .scroll_delta = @splat(0),
            .actionState = std.mem.zeroes(@TypeOf(@as(@This(), undefined).actionState)),
            .input = @splat(0),
            .min_delta = cfg.min_delta,
            .resized = true,
        };
        errdefer win.kill();

        // Ensure GLFW errors are logged
        glfw.setErrorCallback(errorCallback);

        // If we currently have no windows then initialise GLFW
        if (windows == 0 and !glfw.init(.{})) {
            std.log.err("Failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
            return error.GlfwInitFailure;
        }

        win.resolution = try calcResolution(cfg.windowed);

        // Obtain primary monitor
        const monitor = if (cfg.windowed) null else glfw.Monitor.getPrimary() orelse {
            std.log.err("Failed to get primary monitor: {?s}", .{glfw.getErrorString()});
            return error.MonitorUnobtainable;
        };

        // Create our window
        win.window = glfw.Window.create(
            @intFromFloat(win.resolution[0]),
            @intFromFloat(win.resolution[1]),
            cfg.title,
            monitor,
            null,
            .{
                .opengl_profile = .opengl_core_profile,
                .context_version_major = 4,
                .context_version_minor = 6,
                .resizable = cfg.resizable,
                .samples = cfg.msaa_samples,
                .position_x = @intFromFloat(win.resolution[2]),
                .position_y = @intFromFloat(win.resolution[3]),
            },
        ) orelse {
            std.log.err("Failed to create GLFW window: {?s}", .{glfw.getErrorString()});
            return error.WindowCreationFailure;
        };

        // Listen to window input
        const window = win.window.?;
        window.setKeyCallback(keyCallback);
        window.setMouseButtonCallback(mouseButtonCallback);
        window.setCursorPosCallback(cursorPosCallback);
        window.setScrollCallback(scrollCallback);
        glfw.makeContextCurrent(window);

        // Configure input
        if (!cfg.show_cursor) {
            window.setInputModeCursor(glfw.Window.InputModeCursor.disabled);
        }
        if (cfg.raw_input and glfw.rawMouseMotionSupported()) {
            // Disable mouse motion acceleration and scaling
            window.setInputModeRawMouseMotion(true);
        }

        const proc: glfw.GLProc = undefined;
        gl.load(proc, glGetProcAddress) catch |err| {
            std.log.err("Failed to load OpenGL: {}", .{err});
            return err;
        };

        // Configure triangle visibility
        if (cfg.cull_faces) gl.enable(gl.CULL_FACE);
        if (cfg.test_depth) gl.enable(gl.DEPTH_TEST);
        if (cfg.wireframe) gl.polygonMode(gl.FRONT_AND_BACK, gl.LINE);

        // Configure additional window properties
        glfw.swapInterval(if (cfg.vsync) 1 else 0);
        if (cfg.msaa_samples orelse 0 > 1) gl.enable(gl.MULTISAMPLE);

        // Determine which buffers get cleared
        if (cfg.clear_buffers) {
            win.clear_mask |= gl.COLOR_BUFFER_BIT;
            if (cfg.test_depth) {
                win.clear_mask |= gl.DEPTH_BUFFER_BIT;
            }
        }

        win.binds = std.AutoHashMap(glfw.Key, Action).init(cfg.alloc);
        var binds = &(win.binds.?);
        try binds.put(.w, .forward);
        try binds.put(.s, .backward);
        try binds.put(.a, .left);
        try binds.put(.d, .right);
        try binds.put(.space, .ascend);
        try binds.put(.caps_lock, .descend);
        try binds.put(.left_shift, .descend);
        try binds.put(.left_control, .descend);

        win.mouse_binds = std.AutoHashMap(glfw.MouseButton, Action).init(cfg.alloc);
        var mouse_binds = &(win.mouse_binds.?);
        try mouse_binds.put(.left, .attack1);
        try mouse_binds.put(.right, .attack2);
        try win.calcViewport();

        // Update window count
        windows += 1;
        return win;
    }

    pub fn kill(win: *@This()) void {
        if (win.mouse_binds) |_| {
            win.mouse_binds.?.clearAndFree();
            win.mouse_binds = null;
        }
        if (win.binds) |_| {
            win.binds.?.clearAndFree();
            win.binds = null;
        }
        win.mouse_pos = null;
        win.time = null;
        win.viewport = null;
        win.resolution = zm.f32x4s(0);
        if (win.window) |window| {
            window.destroy();
            win.window = null;
        }
        windows -= 1;
        // When we have no windows we have no use for GLFW
        if (windows == 0) glfw.terminate();
    }

    pub fn ok(win: *@This()) bool {
        // Clear mouse delta
        win.mouse_delta = @splat(0);
        win.scroll_delta = @splat(0);

        // Update deltaTime
        const new_time: f32 = @floatCast(glfw.getTime());
        if (win.time) |time| {
            win.resized = false;
            // Limit delta to 100 ms to avoid massive jumps
            win.delta = @min(new_time - time, win.min_delta);
            if (false and @floor(time) != @floor(new_time)) {
                const fps: usize = @intFromFloat(@min(1 / win.delta, 999999));
                var b: [10:0]u8 = undefined;
                const slice = std.fmt.bufPrint(&b, "{} FPS", .{fps}) catch unreachable;
                std.debug.print("{s}\n", .{slice});
                b[slice.len] = 0;
                win.window.setTitle(&b);
            }
        } else {
            // Set the user pointer if we are about to poll the first events
            win.window.?.setUserPointer(win);
        }
        win.time = new_time;

        win.set_active(.attack1, false);
        win.set_active(.attack2, false);
        glfw.pollEvents();
        win.input = @splat(0);
        if (win.active(.left)) win.input[0] -= 1;
        if (win.active(.right)) win.input[0] += 1;
        if (win.active(.descend)) win.input[1] -= 1;
        if (win.active(.ascend)) win.input[1] += 1;
        if (win.active(.backward)) win.input[2] -= 1;
        if (win.active(.forward)) win.input[2] += 1;
        if (win.resized) if (win.viewport) |viewport| {
            gl.viewport(0, 0, @intCast(viewport.width), @intCast(viewport.height));
            win.mouse_pos = null;
        };
        return !win.window.?.shouldClose();
    }

    pub fn clear(win: @This()) void {
        gl.clear(win.clear_mask);
    }

    pub fn clearColour(win: @This(), r: f32, g: f32, b: f32, a: f32) void {
        _ = win;
        gl.clearColor(r, g, b, a);
    }

    pub fn swap(win: @This()) void {
        win.window.?.swapBuffers();
    }

    pub fn active(win: @This(), action: Action) bool {
        return win.actionState[@intFromEnum(action)];
    }

    fn set_active(win: *@This(), action: Action, b: bool) void {
        win.actionState[@intFromEnum(action)] = b;
    }

    fn toggleWindowed(win: *@This()) !void {
        const windowed = win.window.?.getMonitor() == null;

        const monitor = if (windowed) (glfw.Monitor.getPrimary() orelse {
            std.log.err("Failed to get primary monitor: {?s}", .{glfw.getErrorString()});
            return error.MonitorUnobtainable;
        }) else null;

        win.resolution = try calcResolution(!windowed);
        win.window.?.setMonitor(
            monitor,
            @intFromFloat(win.resolution[2]),
            @intFromFloat(win.resolution[3]),
            @intFromFloat(win.resolution[0]),
            @intFromFloat(win.resolution[1]),
            null,
        );
        try win.calcViewport();
    }

    fn calcViewport(win: *@This()) !void {
        const size = win.window.?.getFramebufferSize();
        if (size.width == 0 or size.height == 0) {
            std.log.err("Failed to get primary monitor: {?s}", .{glfw.getErrorString()});
            return error.FramebufferUnobtainable;
        }
        win.resized = true;
        if (win.viewport) |viewport| {
            win.resized = viewport.width != size.width or viewport.height == size.height;
        }
        win.viewport = size;
    }

    fn calcResolution(windowed: bool) !zm.Vec {
        // Obtain primary monitor
        const monitor = glfw.Monitor.getPrimary() orelse {
            std.log.err("Failed to get primary monitor: {?s}", .{glfw.getErrorString()});
            return error.MonitorUnobtainable;
        };

        // Obtain video mode of monitor
        const mode = glfw.Monitor.getVideoMode(monitor) orelse {
            std.log.err("Failed to get video mode of primary monitor: {?s}", .{glfw.getErrorString()});
            return error.VideoModeUnobtainable;
        };

        // Use scale to make window smaller than primary monitor
        const scale: f32 = if (windowed) 900.0 / 1080.0 else 1;
        const scale_gap = (1 - scale) / 2;
        const size = zm.f32x4(
            @floatFromInt(mode.getWidth()),
            @floatFromInt(mode.getHeight()),
            @floatFromInt(mode.getWidth()),
            @floatFromInt(mode.getHeight()),
        ) * zm.f32x4(scale, scale, scale_gap, scale_gap);
        return size;
    }

    fn glGetProcAddress(p: glfw.GLProc, proc: [:0]const u8) ?gl.FunctionPointer {
        _ = p;
        return glfw.getProcAddress(proc);
    }

    fn errorCallback(error_code: glfw.ErrorCode, description: [:0]const u8) void {
        std.log.err("GLFW: {}: {s}", .{ error_code, description });
    }

    fn keyCallback(window: glfw.Window, key: glfw.Key, scancode: i32, action: glfw.Action, mods: glfw.Mods) void {
        _ = scancode;
        if (key == .escape) window.setShouldClose(true);
        const win = window.getUserPointer(@This()).?;
        if ((key == .enter or key == .kp_enter) and action == .press and mods.alt) {
            win.toggleWindowed() catch unreachable;
        }
        const target = win.binds.?.get(key) orelse return;
        win.actionState[@intFromEnum(target)] = action != .release;
    }

    fn mouseButtonCallback(window: glfw.Window, button: glfw.MouseButton, action: glfw.Action, mods: glfw.Mods) void {
        _ = mods;
        const win = window.getUserPointer(@This()).?;
        const target = win.mouse_binds.?.get(button) orelse return;
        win.actionState[@intFromEnum(target)] = action != .release;
    }

    fn cursorPosCallback(window: glfw.Window, xpos: f64, ypos: f64) void {
        const win = window.getUserPointer(@This()).?;
        const new_pos = zm.loadArr2([2]f32{
            @floatCast(xpos),
            @floatCast(win.resolution[1] - ypos - 1),
        });
        if (win.mouse_pos) |pos| win.mouse_delta += new_pos - pos;
        win.mouse_pos = new_pos;
    }

    fn scrollCallback(window: glfw.Window, xoffset: f64, yoffset: f64) void {
        const win = window.getUserPointer(@This()).?;
        win.scroll_delta += zm.loadArr2([2]f32{ @floatCast(xoffset), @floatCast(yoffset) });
    }
};
