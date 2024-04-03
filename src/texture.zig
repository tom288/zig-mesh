const gl = @import("gl");

pub const Texture = struct {
    id: ?gl.GLuint,
    cfg: CFG,

    const CFG = struct {
        width: gl.GLsizei,
        height: gl.GLsizei,
        format: gl.GLenum,
        internal_format: gl.GLint,
        type: gl.GLenum = gl.FLOAT,
        pixels: ?*const anyopaque = null,
        min_filter: gl.GLint = gl.NEAREST,
        mag_filter: gl.GLint = gl.NEAREST,
        wrap_s: ?gl.GLint = null,
        wrap_t: ?gl.GLint = null,
        fbo_attach: ?gl.GLenum = null,
    };

    pub fn init(cfg: CFG) Texture {
        var texture = Texture{ .id = null, .cfg = cfg };
        errdefer texture.kill();
        texture.id = undefined;
        gl.genTextures(1, &texture.id.?);
        texture.bind();
        defer unbind();
        texture.upload();
        gl.texParameteri(
            gl.TEXTURE_2D,
            gl.TEXTURE_MIN_FILTER,
            texture.cfg.min_filter,
        );
        gl.texParameteri(
            gl.TEXTURE_2D,
            gl.TEXTURE_MAG_FILTER,
            texture.cfg.mag_filter,
        );
        if (texture.cfg.wrap_s) |wrap_s| gl.texParameteri(
            gl.TEXTURE_2D,
            gl.TEXTURE_WRAP_S,
            wrap_s,
        );
        if (texture.cfg.wrap_t) |wrap_t| gl.texParameteri(
            gl.TEXTURE_2D,
            gl.TEXTURE_WRAP_T,
            wrap_t,
        );
        if (texture.cfg.fbo_attach) |attach| gl.framebufferTexture2D(
            gl.FRAMEBUFFER,
            attach,
            gl.TEXTURE_2D,
            texture.id.?,
            0,
        );

        return texture;
    }

    pub fn kill(tex: *Texture) void {
        if (tex.id) |id| {
            gl.deleteTextures(1, &id);
            tex.id = null;
        }
    }

    pub fn resize(tex: *Texture, size: struct {
        width: ?gl.GLsizei,
        height: ?gl.GLsizei,
    }) void {
        if (size.width) |width| tex.cfg.width = width;
        if (size.height) |height| tex.cfg.height = height;
        tex.bind();
        tex.upload();
        unbind();
    }

    fn upload(tex: Texture) void {
        gl.texImage2D(
            gl.TEXTURE_2D,
            0,
            tex.cfg.internal_format,
            tex.cfg.width,
            tex.cfg.height,
            0,
            tex.cfg.format,
            tex.cfg.type,
            tex.cfg.pixels,
        );
    }

    pub fn activate(tex: Texture, unit: gl.GLenum) void {
        gl.activeTexture(unit);
        tex.bind();
    }

    fn _bind(id: gl.GLuint) void {
        gl.bindTexture(gl.TEXTURE_2D, id);
    }

    fn bind(tex: Texture) void {
        _bind(tex.id.?);
    }

    fn unbind() void {
        _bind(0);
    }
};
