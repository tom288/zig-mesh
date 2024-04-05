const std = @import("std");
const gl = @import("gl");
const zm = @import("zmath");
const Window = @import("window.zig").Window;
const Shader = @import("shader.zig").Shader;
const World = @import("world.zig").World;
const Camera = @import("camera.zig").Camera;
const Quad = @import("quad.zig").Quad;
const Texture = @import("texture.zig").Texture;

const TECHNIQUE = enum {
    ForwardRendering,
    DeferredShading,
}.DeferredShading;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) unreachable;
    const alloc = gpa.allocator();

    var camera = Camera.init();

    var window = try Window.init(
        alloc,
        .{ .title = "zig-mesh" },
    );
    defer window.kill();
    window.clearColour(0.1, 0, 0.2, 1);

    var forward_shader = try Shader.init(
        alloc,
        "perspective",
        null,
        "perspective",
    );
    defer forward_shader.kill();

    var gbuffer_shader = try Shader.init(
        alloc,
        "defer/gbuffer",
        null,
        "defer/gbuffer",
    );
    defer gbuffer_shader.kill();

    var ssao_shader = try Shader.init(
        alloc,
        "defer/quad",
        null,
        "defer/ssao",
    );
    defer ssao_shader.kill();

    var blur_shader = try Shader.init(
        alloc,
        "defer/quad",
        null,
        "defer/blur",
    );
    defer blur_shader.kill();

    var compose_shader = try Shader.init(
        alloc,
        "defer/quad",
        null,
        "defer/compose",
    );
    defer compose_shader.kill();

    var density_shader = try Shader.initComp(alloc, "density");
    defer density_shader.kill();
    density_shader.bindBlock("density_block", 0);

    var surface_shader = try Shader.initComp(alloc, "surface");
    defer surface_shader.kill();
    surface_shader.bindBlock("density_block", 0);
    surface_shader.bindBlock("surface_block", 1);

    var world = try World.init(
        alloc,
        if (TECHNIQUE == .DeferredShading) gbuffer_shader else forward_shader,
        density_shader,
        surface_shader,
        camera.position,
    );
    defer world.kill() catch unreachable;

    var quad: ?Quad = if (TECHNIQUE == .DeferredShading) try Quad.init(.{
        .shader = compose_shader,
    }) else null;
    defer if (quad) |_| quad.?.kill();
    const w: gl.GLint = @intFromFloat(window.resolution[0]);
    const h: gl.GLint = @intFromFloat(window.resolution[1]);

    var g_buffer: gl.GLuint = undefined;
    gl.genFramebuffers(1, &g_buffer);
    defer gl.deleteFramebuffers(1, &g_buffer);
    gl.bindFramebuffer(gl.FRAMEBUFFER, g_buffer);

    var g_pos = Texture.init(.{
        .width = w,
        .height = h,
        .format = gl.RGBA,
        .internal_format = gl.RGBA16F,
        .wrap_s = gl.CLAMP_TO_EDGE,
        .wrap_t = gl.CLAMP_TO_EDGE,
        .fbo_attach = gl.COLOR_ATTACHMENT0,
    });
    defer g_pos.kill();

    var g_norm = Texture.init(.{
        .width = w,
        .height = h,
        .format = gl.RGBA,
        .internal_format = gl.RGBA16F,
        .fbo_attach = gl.COLOR_ATTACHMENT1,
    });
    defer g_norm.kill();

    var g_albedo_spec = Texture.init(.{
        .width = w,
        .height = h,
        .format = gl.RGBA,
        .internal_format = gl.RGBA,
        .type = gl.UNSIGNED_BYTE,
        .fbo_attach = gl.COLOR_ATTACHMENT2,
    });
    defer g_albedo_spec.kill();

    // Choose which attachments of this framebuffer will be used for rendering
    gl.drawBuffers(3, &[3]gl.GLuint{
        gl.COLOR_ATTACHMENT0,
        gl.COLOR_ATTACHMENT1,
        gl.COLOR_ATTACHMENT2,
    });

    // Create and attach depth buffer
    var rbo_depth: gl.GLuint = undefined;
    gl.genRenderbuffers(1, &rbo_depth);
    defer gl.deleteRenderbuffers(1, &rbo_depth);
    gl.bindRenderbuffer(gl.RENDERBUFFER, rbo_depth);
    gl.renderbufferStorage(
        gl.RENDERBUFFER,
        gl.DEPTH_COMPONENT,
        w,
        h,
    );
    gl.bindRenderbuffer(gl.RENDERBUFFER, 0);

    gl.framebufferRenderbuffer(
        gl.FRAMEBUFFER,
        gl.DEPTH_ATTACHMENT,
        gl.RENDERBUFFER,
        rbo_depth,
    );

    std.debug.assert(gl.checkFramebufferStatus(gl.FRAMEBUFFER) == gl.FRAMEBUFFER_COMPLETE);
    gl.bindFramebuffer(gl.FRAMEBUFFER, 0);

    // Create framebuffer for SSAO result
    var ssao_buffer: gl.GLuint = undefined;
    gl.genFramebuffers(1, &ssao_buffer);
    defer gl.deleteFramebuffers(1, &ssao_buffer);
    gl.bindFramebuffer(gl.FRAMEBUFFER, ssao_buffer);
    var ssao_tex = Texture.init(.{
        .width = w,
        .height = h,
        .format = gl.RED,
        .internal_format = gl.RED,
        .wrap_s = gl.CLAMP_TO_EDGE,
        .wrap_t = gl.CLAMP_TO_EDGE,
        .fbo_attach = gl.COLOR_ATTACHMENT0,
    });
    defer ssao_tex.kill();
    std.debug.assert(gl.checkFramebufferStatus(gl.FRAMEBUFFER) == gl.FRAMEBUFFER_COMPLETE);
    gl.bindFramebuffer(gl.FRAMEBUFFER, 0);

    // Create framebuffer for SSAO blur result
    var blur_buffer: gl.GLuint = undefined;
    gl.genFramebuffers(1, &blur_buffer);
    defer gl.deleteFramebuffers(1, &blur_buffer);
    gl.bindFramebuffer(gl.FRAMEBUFFER, blur_buffer);
    var blur_texture = Texture.init(.{
        .width = w,
        .height = h,
        .format = gl.RED,
        .internal_format = gl.RED,
        .fbo_attach = gl.COLOR_ATTACHMENT0,
    });
    defer blur_texture.kill();
    std.debug.assert(gl.checkFramebufferStatus(gl.FRAMEBUFFER) == gl.FRAMEBUFFER_COMPLETE);
    gl.bindFramebuffer(gl.FRAMEBUFFER, 0);

    // Generate sample kernel
    var rng = std.rand.DefaultPrng.init(0);
    const SSAO_KERNEL_SAMPLES = 64;
    const SSAO_KERNEL_COMPONENTS = 3;
    var ssao_kernel: [SSAO_KERNEL_SAMPLES * SSAO_KERNEL_COMPONENTS]f32 = undefined;
    for (0..SSAO_KERNEL_SAMPLES) |i| {
        var sample = zm.f32x4(
            rng.random().float(f32) * 2 - 1,
            rng.random().float(f32) * 2 - 1,
            rng.random().float(f32),
            0,
        );
        sample = zm.normalize3(sample);
        sample *= @splat(rng.random().float(f32));
        var scale: f32 = @floatFromInt(i);
        scale /= 64;

        // Scale samples to be more aligned to center of kernel
        scale = 0.1 + scale * scale * 0.9;
        sample *= @splat(scale);
        for (0..SSAO_KERNEL_COMPONENTS) |c| {
            ssao_kernel[i * SSAO_KERNEL_COMPONENTS + c] = sample[c];
        }
    }

    // Generate noise texture
    const SSAO_NOISE_SIZE = 5;
    const SSAO_NOISE_COMPONENTS = 2;
    var ssao_noise: [SSAO_NOISE_SIZE * SSAO_NOISE_SIZE * SSAO_NOISE_COMPONENTS]f32 = undefined;
    for (0..SSAO_NOISE_SIZE * SSAO_NOISE_SIZE) |i| {
        var noise = zm.f32x4s(0);
        for (0..SSAO_NOISE_COMPONENTS) |c| {
            noise[c] = rng.random().float(f32) * 2 - 1;
        }
        noise = (switch (SSAO_NOISE_COMPONENTS) {
            2 => zm.normalize2,
            3 => zm.normalize3,
            4 => zm.normalize4,
            else => unreachable,
        })(noise);
        for (0..SSAO_NOISE_COMPONENTS) |c| {
            ssao_noise[i * SSAO_NOISE_COMPONENTS + c] = noise[c];
        }
    }

    var noise_texture = Texture.init(.{
        .width = SSAO_NOISE_SIZE,
        .height = SSAO_NOISE_SIZE,
        .format = gl.RG,
        .internal_format = gl.RGBA16F,
        .pixels = &ssao_noise[0],
    });
    defer noise_texture.kill();

    ssao_shader.use();
    ssao_shader.set("g_pos", gl.GLint, 0);
    ssao_shader.set("g_norm", gl.GLint, 1);
    ssao_shader.set("noise", gl.GLint, 2);
    ssao_shader.set("resolution", f32, zm.vecToArr2(window.resolution));

    blur_shader.use();
    blur_shader.set("tex", gl.GLint, 0);

    compose_shader.use();
    // compose_shader.set("g_pos", gl.GLint, 0);
    // compose_shader.set("g_norm", gl.GLint, 1);
    compose_shader.set("g_albedo_spec", gl.GLint, 2);
    compose_shader.set("ssao", gl.GLint, 3);

    // Wait for the user to close the window.
    while (window.ok()) {
        camera.turn(window.mouse_delta);
        camera.step(window.input, window.delta);
        camera.scroll(window.scroll_delta);

        try world.updateSplits(camera.position);
        if (window.active(.attack1)) {
            const RAD = 5;
            try world.dig(camera.position + camera.look * zm.f32x4s(RAD), RAD);
        }
        try world.gen();

        if (window.resized) {
            camera.calcAspect(window.resolution);

            if (TECHNIQUE == .DeferredShading) {
                const new_w: gl.GLint = @intFromFloat(window.resolution[0]);
                const new_h: gl.GLint = @intFromFloat(window.resolution[1]);
                const size = .{ .width = new_w, .height = new_h };

                g_pos.resize(size);
                g_norm.resize(size);
                g_albedo_spec.resize(size);
                ssao_tex.resize(size);
                blur_texture.resize(size);

                gl.bindRenderbuffer(gl.RENDERBUFFER, rbo_depth);
                gl.renderbufferStorage(
                    gl.RENDERBUFFER,
                    gl.DEPTH_COMPONENT,
                    new_w,
                    new_h,
                );
                gl.bindRenderbuffer(gl.RENDERBUFFER, 0);
            }
        }

        switch (TECHNIQUE) {
            .DeferredShading => {
                // Render geometry to G-buffer
                gl.bindFramebuffer(gl.FRAMEBUFFER, g_buffer);
                window.clear();
                gbuffer_shader.use();
                try world.draw(camera.position, camera.view, camera.proj.?);
                gl.bindFramebuffer(gl.FRAMEBUFFER, 0);

                // Generate SSAO texture
                gl.bindFramebuffer(gl.FRAMEBUFFER, ssao_buffer);
                gl.clear(gl.COLOR_BUFFER_BIT);
                ssao_shader.use();
                ssao_shader.set_n("samples", f32, SSAO_KERNEL_SAMPLES, ssao_kernel);
                ssao_shader.set("proj", f32, zm.matToArr(camera.proj.?));
                g_pos.activate(gl.TEXTURE0);
                g_norm.activate(gl.TEXTURE1);
                noise_texture.activate(gl.TEXTURE2);
                quad.?.draw();
                gl.bindFramebuffer(gl.FRAMEBUFFER, 0);

                // Blur SSAO texture
                gl.bindFramebuffer(gl.FRAMEBUFFER, blur_buffer);
                gl.clear(gl.COLOR_BUFFER_BIT);
                blur_shader.use();
                ssao_tex.activate(gl.TEXTURE0);
                quad.?.draw();
                gl.bindFramebuffer(gl.FRAMEBUFFER, 0);

                // Compose geometry and lighting for final image
                window.clear();
                compose_shader.use();
                // g_pos.activate(gl.TEXTURE0);
                // g_norm.activate(gl.TEXTURE1);
                g_albedo_spec.activate(gl.TEXTURE2);
                blur_texture.activate(gl.TEXTURE3);
                quad.?.draw();
            },
            .ForwardRendering => {
                window.clear();
                forward_shader.use();
                try world.draw(camera.position, camera.view, camera.proj.?);
            },
        }

        window.swap();
    }
}
