const gl = @import("gl");

pub const Texture = struct {
    id: ?gl.GLuint = null,
    cfg: struct {
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
    },

    pub const Size2D = struct {
        width: ?gl.GLsizei,
        height: ?gl.GLsizei,
    };

    pub fn init(cfg: @TypeOf(@as(@This(), undefined).cfg)) @This() {
        var tex = @This(){ .cfg = cfg };
        errdefer tex.kill();
        tex.id = undefined;
        gl.genTextures(1, &tex.id.?);
        tex.bind();
        defer unbind();
        tex.upload();
        gl.texParameteri(
            gl.TEXTURE_2D,
            gl.TEXTURE_MIN_FILTER,
            tex.cfg.min_filter,
        );
        gl.texParameteri(
            gl.TEXTURE_2D,
            gl.TEXTURE_MAG_FILTER,
            tex.cfg.mag_filter,
        );
        if (tex.cfg.wrap_s) |wrap_s| gl.texParameteri(
            gl.TEXTURE_2D,
            gl.TEXTURE_WRAP_S,
            wrap_s,
        );
        if (tex.cfg.wrap_t) |wrap_t| gl.texParameteri(
            gl.TEXTURE_2D,
            gl.TEXTURE_WRAP_T,
            wrap_t,
        );
        if (tex.cfg.fbo_attach) |attach| gl.framebufferTexture2D(
            gl.FRAMEBUFFER,
            attach,
            gl.TEXTURE_2D,
            tex.id.?,
            0,
        );

        return tex;
    }

    pub fn kill(tex: *@This()) void {
        if (tex.id) |id| {
            gl.deleteTextures(1, &id);
            tex.id = null;
        }
    }

    pub fn resize(tex: *@This(), size: Size2D) void {
        if (size.width) |width| tex.cfg.width = width;
        if (size.height) |height| tex.cfg.height = height;
        tex.bind();
        defer unbind();
        tex.upload();
    }

    fn upload(tex: @This()) void {
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

    pub fn activate(tex: @This(), unit: gl.GLenum) void {
        gl.activeTexture(unit);
        tex.bind();
    }

    fn _bind(id: gl.GLuint) void {
        gl.bindTexture(gl.TEXTURE_2D, id);
    }

    fn bind(tex: @This()) void {
        _bind(tex.id.?);
    }

    fn unbind() void {
        _bind(0);
    }
};
