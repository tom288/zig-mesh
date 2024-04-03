const std = @import("std");
const gl = @import("gl");
const zm = @import("zmath");
const Window = @import("window.zig").Window;
const Shader = @import("shader.zig").Shader;
const World = @import("world.zig").World;
const Camera = @import("camera.zig").Camera;
const Mesh = @import("mesh.zig").Mesh;

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
        "zig-mesh",
        true,
        null,
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

    var quad: ?Mesh(.{.{
        .{ .name = "position", .size = 2, .type = gl.FLOAT },
    }}) = null;
    defer if (quad) |_| quad.?.kill();
    if (TECHNIQUE == .DeferredShading) {
        quad = try @TypeOf(quad.?).init(null);
        try quad.?.upload(.{&[_]f32{
            -1.0, -1.0,
            1.0,  -1.0,
            -1.0, 1.0,
            1.0,  1.0,
        }});
    }
    const w: gl.GLint = @intFromFloat(window.resolution[0]);
    const h: gl.GLint = @intFromFloat(window.resolution[1]);

    var g_buffer: gl.GLuint = undefined;
    gl.genFramebuffers(1, &g_buffer);
    defer gl.deleteFramebuffers(1, &g_buffer);
    gl.bindFramebuffer(gl.FRAMEBUFFER, g_buffer);

    var g_pos: gl.GLuint = undefined;
    gl.genTextures(1, &g_pos);
    defer gl.deleteTextures(1, &g_pos);
    gl.bindTexture(gl.TEXTURE_2D, g_pos);
    gl.texImage2D(
        gl.TEXTURE_2D,
        0,
        gl.RGBA16F,
        w,
        h,
        0,
        gl.RGBA,
        gl.FLOAT,
        null,
    );
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.framebufferTexture2D(
        gl.FRAMEBUFFER,
        gl.COLOR_ATTACHMENT0,
        gl.TEXTURE_2D,
        g_pos,
        0,
    );

    var g_norm: gl.GLuint = undefined;
    gl.genTextures(1, &g_norm);
    defer gl.deleteTextures(1, &g_norm);
    gl.bindTexture(gl.TEXTURE_2D, g_norm);
    gl.texImage2D(
        gl.TEXTURE_2D,
        0,
        gl.RGBA16F,
        w,
        h,
        0,
        gl.RGBA,
        gl.FLOAT,
        null,
    );
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.framebufferTexture2D(
        gl.FRAMEBUFFER,
        gl.COLOR_ATTACHMENT1,
        gl.TEXTURE_2D,
        g_norm,
        0,
    );

    var g_albedo_spec: gl.GLuint = undefined;
    gl.genTextures(1, &g_albedo_spec);
    defer gl.deleteTextures(1, &g_albedo_spec);
    gl.bindTexture(gl.TEXTURE_2D, g_albedo_spec);
    gl.texImage2D(
        gl.TEXTURE_2D,
        0,
        gl.RGBA,
        w,
        h,
        0,
        gl.RGBA,
        gl.UNSIGNED_BYTE,
        null,
    );
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.framebufferTexture2D(
        gl.FRAMEBUFFER,
        gl.COLOR_ATTACHMENT2,
        gl.TEXTURE_2D,
        g_albedo_spec,
        0,
    );

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
    var ssao_tex: gl.GLuint = undefined;
    gl.genTextures(1, &ssao_tex);
    defer gl.deleteTextures(1, &ssao_tex);
    gl.bindTexture(gl.TEXTURE_2D, ssao_tex);
    gl.texImage2D(
        gl.TEXTURE_2D,
        0,
        gl.RED,
        w,
        h,
        0,
        gl.RED,
        gl.FLOAT,
        null,
    );
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.framebufferTexture2D(
        gl.FRAMEBUFFER,
        gl.COLOR_ATTACHMENT0,
        gl.TEXTURE_2D,
        ssao_tex,
        0,
    );
    std.debug.assert(gl.checkFramebufferStatus(gl.FRAMEBUFFER) == gl.FRAMEBUFFER_COMPLETE);

    // Create framebuffer for SSAO blur result
    var blur_buffer: gl.GLuint = undefined;
    gl.genFramebuffers(1, &blur_buffer);
    defer gl.deleteFramebuffers(1, &blur_buffer);
    gl.bindFramebuffer(gl.FRAMEBUFFER, blur_buffer);
    var blur_tex: gl.GLuint = undefined;
    gl.genTextures(1, &blur_tex);
    defer gl.deleteTextures(1, &blur_tex);
    gl.bindTexture(gl.TEXTURE_2D, blur_tex);
    gl.texImage2D(
        gl.TEXTURE_2D,
        0,
        gl.RED,
        w,
        h,
        0,
        gl.RED,
        gl.FLOAT,
        null,
    );
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.framebufferTexture2D(
        gl.FRAMEBUFFER,
        gl.COLOR_ATTACHMENT0,
        gl.TEXTURE_2D,
        blur_tex,
        0,
    );
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
    var noise_texture: gl.GLuint = undefined;
    gl.genTextures(1, &noise_texture);
    defer gl.deleteTextures(1, &noise_texture);
    gl.bindTexture(gl.TEXTURE_2D, noise_texture);
    gl.texImage2D(
        gl.TEXTURE_2D,
        0,
        gl.RGBA16F,
        SSAO_NOISE_SIZE,
        SSAO_NOISE_SIZE,
        0,
        gl.RG,
        gl.FLOAT,
        &ssao_noise[0],
    );
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);

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
        try world.gen(camera.position);

        if (window.resized) {
            camera.calcAspect(window.resolution);

            if (TECHNIQUE == .DeferredShading) {
                const new_w: gl.GLint = @intFromFloat(window.resolution[0]);
                const new_h: gl.GLint = @intFromFloat(window.resolution[1]);

                gl.bindTexture(gl.TEXTURE_2D, g_pos);
                gl.texImage2D(
                    gl.TEXTURE_2D,
                    0,
                    gl.RGBA16F,
                    new_w,
                    new_h,
                    0,
                    gl.RGBA,
                    gl.FLOAT,
                    null,
                );

                gl.bindTexture(gl.TEXTURE_2D, g_norm);
                gl.texImage2D(
                    gl.TEXTURE_2D,
                    0,
                    gl.RGBA16F,
                    new_w,
                    new_h,
                    0,
                    gl.RGBA,
                    gl.FLOAT,
                    null,
                );

                gl.bindTexture(gl.TEXTURE_2D, g_albedo_spec);
                gl.texImage2D(
                    gl.TEXTURE_2D,
                    0,
                    gl.RGBA,
                    new_w,
                    new_h,
                    0,
                    gl.RGBA,
                    gl.UNSIGNED_BYTE,
                    null,
                );

                gl.bindTexture(gl.TEXTURE_2D, ssao_tex);
                gl.texImage2D(
                    gl.TEXTURE_2D,
                    0,
                    gl.RED,
                    new_w,
                    new_h,
                    0,
                    gl.RED,
                    gl.FLOAT,
                    null,
                );

                gl.bindTexture(gl.TEXTURE_2D, blur_tex);
                gl.texImage2D(
                    gl.TEXTURE_2D,
                    0,
                    gl.RED,
                    new_w,
                    new_h,
                    0,
                    gl.RED,
                    gl.FLOAT,
                    null,
                );

                gl.bindTexture(gl.TEXTURE_2D, noise_texture);
                gl.texImage2D(
                    gl.TEXTURE_2D,
                    0,
                    gl.RGBA16F,
                    SSAO_NOISE_SIZE,
                    SSAO_NOISE_SIZE,
                    0,
                    gl.RG,
                    gl.FLOAT,
                    &ssao_noise[0],
                );

                gl.bindTexture(gl.TEXTURE_2D, 0);

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
                try world.draw(camera.position, camera.view, camera.proj);
                gl.bindFramebuffer(gl.FRAMEBUFFER, 0);

                // Generate SSAO texture
                gl.bindFramebuffer(gl.FRAMEBUFFER, ssao_buffer);
                gl.clear(gl.COLOR_BUFFER_BIT);
                ssao_shader.use();
                ssao_shader.set_n("samples", f32, SSAO_KERNEL_SAMPLES, ssao_kernel);
                ssao_shader.set("proj", f32, zm.matToArr(camera.proj));
                gl.activeTexture(gl.TEXTURE0);
                gl.bindTexture(gl.TEXTURE_2D, g_pos);
                gl.activeTexture(gl.TEXTURE1);
                gl.bindTexture(gl.TEXTURE_2D, g_norm);
                gl.activeTexture(gl.TEXTURE2);
                gl.bindTexture(gl.TEXTURE_2D, noise_texture);
                quad.?.draw(gl.TRIANGLE_STRIP, null, null);
                gl.bindFramebuffer(gl.FRAMEBUFFER, 0);

                // Blur SSAO texture
                gl.bindFramebuffer(gl.FRAMEBUFFER, blur_buffer);
                gl.clear(gl.COLOR_BUFFER_BIT);
                blur_shader.use();
                gl.activeTexture(gl.TEXTURE0);
                gl.bindTexture(gl.TEXTURE_2D, ssao_tex);
                quad.?.draw(gl.TRIANGLE_STRIP, null, null);
                gl.bindFramebuffer(gl.FRAMEBUFFER, 0);

                // Compose geometry and lighting for final image
                window.clear();
                compose_shader.use();
                // gl.activeTexture(gl.TEXTURE0);
                // gl.bindTexture(gl.TEXTURE_2D, g_pos);
                // gl.activeTexture(gl.TEXTURE1);
                // gl.bindTexture(gl.TEXTURE_2D, g_norm);
                gl.activeTexture(gl.TEXTURE2);
                gl.bindTexture(gl.TEXTURE_2D, g_albedo_spec);
                gl.activeTexture(gl.TEXTURE3);
                gl.bindTexture(gl.TEXTURE_2D, blur_tex);
                quad.?.draw(gl.TRIANGLE_STRIP, null, null);
            },
            .ForwardRendering => {
                window.clear();
                forward_shader.use();
                try world.draw(camera.position, camera.view, camera.proj);
            },
        }

        window.swap();
    }
}
