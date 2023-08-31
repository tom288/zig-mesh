const std = @import("std");
const gl = @import("gl");

pub const Shader = struct {
    id: ?gl.GLuint,

    pub fn init(
        comptime vertex: []const u8,
        comptime geometry: ?[]const u8,
        comptime fragment: []const u8,
    ) ?Shader {
        const vert = compile(vertex, gl.VERTEX_SHADER);
        const geom = if (geometry) |g| compile(g, gl.GEOMETRY_SHADER) else null;
        const frag = compile(fragment, gl.FRAGMENT_SHADER);

        var shader = Shader{
            .id = null,
        };

        var ok = vert != 0 and frag != 0 and (geometry == null or geom != 0);

        if (ok) {
            shader.id = gl.createProgram();
            if (shader.id) |id| {
                gl.attachShader(id, vert);
                if (geom) |g| gl.attachShader(id, g);
                gl.attachShader(id, frag);
                gl.linkProgram(id);
            }
        }

        gl.deleteShader(vert);
        if (geom) |g| gl.deleteShader(g);
        gl.deleteShader(frag);

        if (shader.id) |id| {
            if (compile_error(id, true, fragment)) {
                shader.kill();
            }
        }

        return if (shader.id == null) null else shader;
    }

    pub fn kill(shader: *Shader) void {
        if (shader.id) |id| {
            gl.deleteProgram(id);
            shader.id = null;
        }
    }

    pub fn use(shader: Shader) void {
        if (shader.id) |id| {
            gl.useProgram(id);
        }
    }
};

fn compile(comptime path: []const u8, stage: gl.GLenum) gl.GLuint {
    const buffer: [*c]const [*c]const u8 = @ptrCast(&@embedFile(path));
    const id = gl.createShader(stage);
    gl.shaderSource(id, 1, buffer, null);
    gl.compileShader(id);
    return id;
}

fn compile_error(id: gl.GLuint, comptime is_program: bool, path: []const u8) bool {
    const max_length = 1024;
    var ok: gl.GLint = 0;
    var log: [max_length]gl.GLchar = undefined;

    if (is_program) {
        gl.getProgramiv(id, gl.LINK_STATUS, &ok);
    } else {
        gl.getShaderiv(id, gl.COMPILE_STATUS, &ok);
    }

    if (ok == 0) {
        var len: gl.GLsizei = undefined;
        (if (is_program) gl.getProgramInfoLog else gl.getShaderInfoLog)(id, max_length, &len, &log);
        std.log.err("Failed to {s} {s}\n{s}", .{
            if (is_program) "link shader program with vertex shader file" else "compile shader file",
            path,
            log[0..@intCast(len)],
        });
    }
    return ok == 0;
}
