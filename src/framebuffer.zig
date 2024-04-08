const std = @import("std");
const gl = @import("gl");
const Texture = @import("texture.zig").Texture;

const TextureCFG = @TypeOf(@as(Texture, undefined).cfg);

pub fn Framebuffer(tex_count: usize) type {
    return struct {
        id: ?gl.GLuint = null,
        textures: [tex_count]Texture,
        depth: ?gl.GLuint = null,

        pub fn init(cfg: struct {
            colour: [tex_count]TextureCFG,
            depth: ?Texture.Size2D = null,
        }) @This() {
            var fbo = @This(){
                .textures = undefined,
            };
            errdefer fbo.kill();

            fbo.id = undefined;
            gl.genFramebuffers(1, &fbo.id.?);

            fbo.bind();
            defer unbind();

            var buffers: [tex_count]gl.GLenum = undefined;

            for (0.., cfg.colour) |i, colour| {
                fbo.textures[i] = Texture.init(colour);
                buffers[i] = gl.COLOR_ATTACHMENT0 + @as(gl.GLenum, @intCast(i));
            }

            if (cfg.depth) |size| {
                // Choose which attachments of this framebuffer will be used for rendering
                gl.drawBuffers(tex_count, &buffers);

                fbo.depth = undefined;
                gl.genRenderbuffers(1, &fbo.depth.?);
                gl.bindRenderbuffer(gl.RENDERBUFFER, fbo.depth.?);
                gl.renderbufferStorage(
                    gl.RENDERBUFFER,
                    gl.DEPTH_COMPONENT,
                    size.width.?,
                    size.height.?,
                );
                gl.bindRenderbuffer(gl.RENDERBUFFER, 0);
                gl.framebufferRenderbuffer(
                    gl.FRAMEBUFFER,
                    gl.DEPTH_ATTACHMENT,
                    gl.RENDERBUFFER,
                    fbo.depth.?,
                );
            }
            std.debug.assert(gl.checkFramebufferStatus(gl.FRAMEBUFFER) == gl.FRAMEBUFFER_COMPLETE);

            return fbo;
        }

        pub fn kill(fbo: *@This()) void {
            if (fbo.depth) |depth| {
                gl.deleteRenderbuffers(1, &depth);
                fbo.depth = null;
            }
            for (&fbo.textures) |*tex| {
                tex.kill();
                tex.* = undefined;
            }
            if (fbo.id) |id| {
                gl.deleteFramebuffers(1, &id);
                fbo.id = null;
            }
        }

        pub fn resize(fbo: *@This(), size: Texture.Size2D) void {
            for (&fbo.textures) |*tex| {
                tex.resize(size);
            }
            if (fbo.depth) |depth| {
                gl.bindRenderbuffer(gl.RENDERBUFFER, depth);
                gl.renderbufferStorage(
                    gl.RENDERBUFFER,
                    gl.DEPTH_COMPONENT,
                    size.width.?,
                    size.height.?,
                );
                gl.bindRenderbuffer(gl.RENDERBUFFER, 0);
            }
        }

        fn _bind(id: gl.GLuint) void {
            gl.bindFramebuffer(gl.FRAMEBUFFER, id);
        }

        pub fn bind(fbo: @This()) void {
            _bind(fbo.id.?);
        }

        pub fn unbind() void {
            _bind(0);
        }

        pub fn activate(fbo: @This(), index: usize, unit: usize) void {
            fbo.textures[index].activate(gl.TEXTURE0 + @as(gl.GLenum, @intCast(unit)));
        }
    };
}
