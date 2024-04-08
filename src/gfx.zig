const std = @import("std");
const gl = @import("gl");
const zm = @import("zmath");
const Shader = @import("shader.zig").Shader;
const Quad = @import("quad.zig").Quad;
const Texture = @import("texture.zig").Texture;
const Window = @import("window.zig").Window;

pub const DeferredShading = struct {
    quad: ?Quad = null,

    gbuffer_shader: ?Shader = null,
    ssao_shader: ?Shader = null,
    blur_shader: ?Shader = null,
    compose_shader: ?Shader = null,

    g_buffer: ?gl.GLuint = null,
    g_pos: ?Texture = null,
    g_norm: ?Texture = null,
    g_albedo_spec: ?Texture = null,

    rbo_depth: ?gl.GLuint = null,

    ssao_buffer: ?gl.GLuint = null,
    ssao_kernel: [SSAO_KERNEL_SAMPLES * SSAO_KERNEL_COMPONENTS]f32,
    noise_texture: ?Texture = null,
    ssao_noise: [SSAO_NOISE_SIZE * SSAO_NOISE_SIZE * SSAO_NOISE_COMPONENTS]f32,
    ssao_tex: ?Texture = null,

    blur_buffer: ?gl.GLuint = null,
    blur_texture: ?Texture = null,

    const SSAO_KERNEL_SAMPLES = 64;
    const SSAO_KERNEL_COMPONENTS = 3;
    const SSAO_NOISE_SIZE = 5;
    const SSAO_NOISE_COMPONENTS = 2;

    pub fn init(alloc: std.mem.Allocator, resolution: zm.Vec) !@This() {
        var gfx = @This(){
            .ssao_kernel = undefined,
            .ssao_noise = undefined,
        };
        errdefer gfx.kill();

        gfx.quad = try Quad.init(.{
            .shader = gfx.compose_shader,
        });

        gfx.gbuffer_shader = try Shader.init(
            alloc,
            "defer/gbuffer",
            null,
            "defer/gbuffer",
        );

        gfx.ssao_shader = try Shader.init(
            alloc,
            "defer/quad",
            null,
            "defer/ssao",
        );

        gfx.blur_shader = try Shader.init(
            alloc,
            "defer/quad",
            null,
            "defer/blur",
        );

        gfx.compose_shader = try Shader.init(
            alloc,
            "defer/quad",
            null,
            "defer/compose",
        );

        const res: @Vector(4, gl.GLint) = @intFromFloat(resolution);
        const size = .{ .width = res[0], .height = res[1] };

        gfx.g_buffer = undefined;
        gl.genFramebuffers(1, &gfx.g_buffer.?);
        gl.bindFramebuffer(gl.FRAMEBUFFER, gfx.g_buffer.?);

        gfx.g_pos = Texture.init(.{
            .width = size.width,
            .height = size.height,
            .format = gl.RGBA,
            .internal_format = gl.RGBA16F,
            .wrap_s = gl.CLAMP_TO_EDGE,
            .wrap_t = gl.CLAMP_TO_EDGE,
            .fbo_attach = gl.COLOR_ATTACHMENT0,
        });

        gfx.g_norm = Texture.init(.{
            .width = size.width,
            .height = size.height,
            .format = gl.RGBA,
            .internal_format = gl.RGBA16F,
            .fbo_attach = gl.COLOR_ATTACHMENT1,
        });

        gfx.g_albedo_spec = Texture.init(.{
            .width = size.width,
            .height = size.height,
            .format = gl.RGBA,
            .internal_format = gl.RGBA,
            .type = gl.UNSIGNED_BYTE,
            .fbo_attach = gl.COLOR_ATTACHMENT2,
        });

        // Choose which attachments of this framebuffer will be used for rendering
        gl.drawBuffers(3, &[3]gl.GLuint{
            gl.COLOR_ATTACHMENT0,
            gl.COLOR_ATTACHMENT1,
            gl.COLOR_ATTACHMENT2,
        });

        // Create and attach depth buffer
        gfx.rbo_depth = undefined;
        gl.genRenderbuffers(1, &gfx.rbo_depth.?);
        gl.bindRenderbuffer(gl.RENDERBUFFER, gfx.rbo_depth.?);
        gl.renderbufferStorage(
            gl.RENDERBUFFER,
            gl.DEPTH_COMPONENT,
            size.width,
            size.height,
        );
        gl.bindRenderbuffer(gl.RENDERBUFFER, 0);

        gl.framebufferRenderbuffer(
            gl.FRAMEBUFFER,
            gl.DEPTH_ATTACHMENT,
            gl.RENDERBUFFER,
            gfx.rbo_depth.?,
        );

        std.debug.assert(gl.checkFramebufferStatus(gl.FRAMEBUFFER) == gl.FRAMEBUFFER_COMPLETE);
        gl.bindFramebuffer(gl.FRAMEBUFFER, 0);

        // Create framebuffer for SSAO result
        gfx.ssao_buffer = undefined;
        gl.genFramebuffers(1, &gfx.ssao_buffer.?);
        gl.bindFramebuffer(gl.FRAMEBUFFER, gfx.ssao_buffer.?);
        gfx.ssao_tex = Texture.init(.{
            .width = size.width,
            .height = size.height,
            .format = gl.RED,
            .internal_format = gl.RED,
            .wrap_s = gl.CLAMP_TO_EDGE,
            .wrap_t = gl.CLAMP_TO_EDGE,
            .fbo_attach = gl.COLOR_ATTACHMENT0,
        });
        std.debug.assert(gl.checkFramebufferStatus(gl.FRAMEBUFFER) == gl.FRAMEBUFFER_COMPLETE);
        gl.bindFramebuffer(gl.FRAMEBUFFER, 0);

        // Generate sample kernel
        var rng = std.rand.DefaultPrng.init(0);

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
                gfx.ssao_kernel[i * SSAO_KERNEL_COMPONENTS + c] = sample[c];
            }
        }

        // Create framebuffer for SSAO blur result
        gfx.blur_buffer = undefined;
        gl.genFramebuffers(1, &gfx.blur_buffer.?);
        gl.bindFramebuffer(gl.FRAMEBUFFER, gfx.blur_buffer.?);
        gfx.blur_texture = Texture.init(.{
            .width = size.width,
            .height = size.height,
            .format = gl.RED,
            .internal_format = gl.RED,
            .fbo_attach = gl.COLOR_ATTACHMENT0,
        });
        std.debug.assert(gl.checkFramebufferStatus(gl.FRAMEBUFFER) == gl.FRAMEBUFFER_COMPLETE);
        gl.bindFramebuffer(gl.FRAMEBUFFER, 0);

        // Generate noise texture
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
                gfx.ssao_noise[i * SSAO_NOISE_COMPONENTS + c] = noise[c];
            }
        }

        gfx.noise_texture = Texture.init(.{
            .width = SSAO_NOISE_SIZE,
            .height = SSAO_NOISE_SIZE,
            .format = gl.RG,
            .internal_format = gl.RGBA16F,
            .pixels = &gfx.ssao_noise[0],
        });

        const ssao_shader = gfx.ssao_shader.?;
        ssao_shader.use();
        ssao_shader.set("g_pos", gl.GLint, 0);
        ssao_shader.set("g_norm", gl.GLint, 1);
        ssao_shader.set("noise", gl.GLint, 2);
        ssao_shader.set("resolution", f32, zm.vecToArr2(resolution));

        gfx.blur_shader.?.use();
        gfx.blur_shader.?.set("tex", gl.GLint, 0);

        gfx.compose_shader.?.use();
        // gfx.compose_shader.?.set("g_pos", gl.GLint, 0);
        // gfx.compose_shader.?.set("g_norm", gl.GLint, 1);
        gfx.compose_shader.?.set("g_albedo_spec", gl.GLint, 2);
        gfx.compose_shader.?.set("ssao", gl.GLint, 3);

        return gfx;
    }

    pub fn kill(gfx: *@This()) void {
        inline for (&.{
            &gfx.g_buffer,
            &gfx.ssao_buffer,
            &gfx.blur_buffer,
        }) |*fbo| {
            if (fbo.*.*) |f| {
                gl.deleteFramebuffers(1, &f);
                fbo.*.* = null;
            }
        }

        if (gfx.rbo_depth) |rbo| {
            gl.deleteRenderbuffers(1, &rbo);
            gfx.rbo_depth = null;
        }

        inline for (&.{
            &gfx.blur_texture,
            &gfx.noise_texture,
            &gfx.ssao_tex,
            &gfx.g_albedo_spec,
            &gfx.g_norm,
            &gfx.g_pos,
            &gfx.compose_shader,
            &gfx.blur_shader,
            &gfx.ssao_shader,
            &gfx.gbuffer_shader,
            &gfx.quad,
        }) |*resource| {
            if (resource.*.*) |_| {
                resource.*.*.?.kill();
                resource.*.* = null;
            }
        }
    }

    pub fn getWorldShader(gfx: @This()) Shader {
        return gfx.gbuffer_shader.?;
    }

    pub fn resize(gfx: *@This(), resolution: zm.Vec) void {
        const res: @Vector(4, gl.GLint) = @intFromFloat(resolution);
        const size = .{ .width = res[0], .height = res[1] };

        gfx.g_pos.?.resize(size);
        gfx.g_norm.?.resize(size);
        gfx.g_albedo_spec.?.resize(size);
        gfx.ssao_tex.?.resize(size);
        gfx.blur_texture.?.resize(size);

        gl.bindRenderbuffer(gl.RENDERBUFFER, gfx.rbo_depth.?);
        gl.renderbufferStorage(
            gl.RENDERBUFFER,
            gl.DEPTH_COMPONENT,
            size.width,
            size.height,
        );
        gl.bindRenderbuffer(gl.RENDERBUFFER, 0);
    }

    pub fn prep(gfx: @This()) void {
        // Render geometry to G-buffer
        gl.bindFramebuffer(gl.FRAMEBUFFER, gfx.g_buffer.?);
        gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
        gfx.gbuffer_shader.?.use();
    }

    pub fn compose(gfx: @This(), proj: zm.Mat) void {
        gl.bindFramebuffer(gl.FRAMEBUFFER, 0);

        // Generate SSAO texture
        gl.bindFramebuffer(gl.FRAMEBUFFER, gfx.ssao_buffer.?);
        gl.clear(gl.COLOR_BUFFER_BIT);
        gfx.ssao_shader.?.use();
        gfx.ssao_shader.?.set_n("samples", f32, SSAO_KERNEL_SAMPLES, gfx.ssao_kernel);
        gfx.ssao_shader.?.set("proj", f32, zm.matToArr(proj));
        gfx.g_pos.?.activate(gl.TEXTURE0);
        gfx.g_norm.?.activate(gl.TEXTURE1);
        gfx.noise_texture.?.activate(gl.TEXTURE2);
        gfx.quad.?.draw();
        gl.bindFramebuffer(gl.FRAMEBUFFER, 0);

        // Blur SSAO texture
        gl.bindFramebuffer(gl.FRAMEBUFFER, gfx.blur_buffer.?);
        gl.clear(gl.COLOR_BUFFER_BIT);
        gfx.blur_shader.?.use();
        gfx.ssao_tex.?.activate(gl.TEXTURE0);
        gfx.quad.?.draw();
        gl.bindFramebuffer(gl.FRAMEBUFFER, 0);

        // Compose geometry and lighting for final image
        gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
        gfx.compose_shader.?.use();
        // g_pos.activate(gl.TEXTURE0);
        // g_norm.activate(gl.TEXTURE1);
        gfx.g_albedo_spec.?.activate(gl.TEXTURE2);
        gfx.blur_texture.?.activate(gl.TEXTURE3);
        gfx.quad.?.draw();
    }
};

pub const ForwardRendering = struct {
    forward_shader: ?Shader = null,

    pub fn init(alloc: std.mem.Allocator, resolution: zm.Vec) !@This() {
        _ = resolution;
        var gfx = @This(){};
        errdefer gfx.kill();

        gfx.forward_shader = try Shader.init(
            alloc,
            "perspective",
            null,
            "perspective",
        );

        return gfx;
    }

    pub fn kill(gfx: *@This()) void {
        if (gfx.forward_shader) |_| {
            gfx.forward_shader.?.kill();
            gfx.forward_shader = null;
        }
    }

    pub fn getWorldShader(gfx: @This()) Shader {
        return gfx.forward_shader.?;
    }

    pub fn resize(gfx: *@This(), resolution: zm.Vec) void {
        _ = gfx;
        _ = resolution;
    }

    pub fn prep(gfx: @This()) void {
        gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
        gfx.forward_shader.?.use();
    }

    pub fn compose(gfx: @This(), proj: zm.Mat) void {
        _ = gfx;
        _ = proj;
    }
};
