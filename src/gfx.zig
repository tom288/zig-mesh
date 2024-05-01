const std = @import("std");
const gl = @import("gl");
const zm = @import("zmath");
const Shader = @import("shader.zig").Shader;
const Quad = @import("quad.zig").Quad;
const Texture = @import("texture.zig").Texture;
const Window = @import("window.zig").Window;
const Framebuffer = @import("framebuffer.zig").Framebuffer;
const World = @import("world.zig").World; // TODO change to some global config

pub const DeferredShading = struct {
    quad: ?Quad = null,

    gbuffer_shader: ?Shader = null,
    ssao_shader: ?Shader = null,
    blur_shader: ?Shader = null,
    compose_shader: ?Shader = null,

    g_buffer: ?Framebuffer(.{ "g_pos", "g_norm", "g_albedo_spec" }) = null,

    ssao_buffer: ?Framebuffer(.{"raw"}) = null,
    ssao_kernel: [SSAO_KERNEL_SAMPLES * SSAO_KERNEL_COMPONENTS]f32,
    ssao_noise: [SSAO_NOISE_SIZE * SSAO_NOISE_SIZE * SSAO_NOISE_COMPONENTS]f32,
    noise_texture: ?Texture = null,

    blur_buffer: ?Framebuffer(.{"ssao"}) = null,

    const SSAO_KERNEL_SAMPLES = 64;
    const SSAO_KERNEL_COMPONENTS = 3;
    const SSAO_NOISE_SIZE = 5; // Should match defer/blur.frag RAD * 2 + 1
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
            (if (World.OVERDRAW == .global_lattice) "global_lattice/" else "") ++ "defer/gbuffer",
            null,
            (if (World.OVERDRAW == .global_lattice) "global_lattice/" else "") ++ "defer/gbuffer",
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
        gfx.g_buffer = @TypeOf(gfx.g_buffer.?).init(.{
            .colour = .{
                .{
                    .width = size.width,
                    .height = size.height,
                    .format = gl.RGBA,
                    .internal_format = gl.RGBA16F,
                    .wrap_s = gl.CLAMP_TO_EDGE,
                    .wrap_t = gl.CLAMP_TO_EDGE,
                    .fbo_attach = gl.COLOR_ATTACHMENT0,
                },
                .{
                    .width = size.width,
                    .height = size.height,
                    .format = gl.RGBA,
                    .internal_format = gl.RGBA16F,
                    .fbo_attach = gl.COLOR_ATTACHMENT1,
                },
                .{
                    .width = size.width,
                    .height = size.height,
                    .format = gl.RGBA,
                    .internal_format = gl.RGBA,
                    .type = gl.UNSIGNED_BYTE,
                    .fbo_attach = gl.COLOR_ATTACHMENT2,
                },
            },
            .depth = size,
        });

        // Create framebuffer for SSAO result
        gfx.ssao_buffer = undefined;
        gfx.ssao_buffer = @TypeOf(gfx.ssao_buffer.?).init(.{ .colour = .{
            .{
                .width = size.width,
                .height = size.height,
                .format = gl.RED,
                .internal_format = gl.RED,
                .wrap_s = gl.CLAMP_TO_EDGE,
                .wrap_t = gl.CLAMP_TO_EDGE,
                .fbo_attach = gl.COLOR_ATTACHMENT0,
            },
        } });

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
        gfx.blur_buffer = @TypeOf(gfx.blur_buffer.?).init(.{ .colour = .{
            .{
                .width = size.width,
                .height = size.height,
                .format = gl.RED,
                .internal_format = gl.RED,
                .fbo_attach = gl.COLOR_ATTACHMENT0,
            },
        } });

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
        gfx.compose_shader.?.set("g_albedo_spec", gl.GLint, 0);
        gfx.compose_shader.?.set("ssao", gl.GLint, 1);

        return gfx;
    }

    pub fn kill(gfx: *@This()) void {
        inline for (&.{
            &gfx.blur_buffer,
            &gfx.noise_texture,
            &gfx.ssao_buffer,
            &gfx.g_buffer,
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

        gfx.g_buffer.?.resize(size);
        gfx.ssao_buffer.?.resize(size);
        gfx.blur_buffer.?.resize(size);
    }

    pub fn prep(gfx: @This()) void {
        // Render geometry to G-buffer
        gfx.g_buffer.?.bind();
        gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
        gfx.gbuffer_shader.?.use();
    }

    pub fn compose(gfx: @This(), proj: zm.Mat) void {
        gl.bindFramebuffer(gl.FRAMEBUFFER, 0);

        // Generate SSAO texture
        gfx.ssao_buffer.?.bind();
        gl.clear(gl.COLOR_BUFFER_BIT);
        gfx.ssao_shader.?.use();
        gfx.ssao_shader.?.setN("samples", f32, SSAO_KERNEL_SAMPLES, gfx.ssao_kernel);
        gfx.ssao_shader.?.set("proj", f32, zm.matToArr(proj));
        gfx.g_buffer.?.activate("g_pos", 0);
        gfx.g_buffer.?.activate("g_norm", 1);
        gfx.noise_texture.?.activate(gl.TEXTURE2);
        gfx.quad.?.draw();
        gl.bindFramebuffer(gl.FRAMEBUFFER, 0);

        // Blur SSAO texture
        gfx.blur_buffer.?.bind();
        gl.clear(gl.COLOR_BUFFER_BIT);
        gfx.blur_shader.?.use();
        gfx.ssao_buffer.?.activate("raw", 0);
        gfx.quad.?.draw();
        gl.bindFramebuffer(gl.FRAMEBUFFER, 0);

        // Compose geometry and lighting for final image
        gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
        gfx.compose_shader.?.use();
        // g_pos.activate(gl.TEXTURE0);
        // g_norm.activate(gl.TEXTURE1);
        gfx.g_buffer.?.activate("g_albedo_spec", 0);
        gfx.blur_buffer.?.activate("ssao", 1);
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
            if (World.OVERDRAW == .global_lattice) "global_lattice/defer/gbuffer" else "perspective",
            null,
            (if (World.OVERDRAW == .global_lattice) "global_lattice/" else "") ++ "perspective",
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
