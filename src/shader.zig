const std = @import("std");
const gl = @import("gl");

pub const Shader = struct {
    id: ?gl.GLuint,

    pub fn init(
        comptime vertex: []const u8,
        comptime geometry: ?[]const u8,
        comptime fragment: []const u8,
    ) !Shader {
        const vert = compile(vertex, gl.VERTEX_SHADER);
        const geom = if (geometry) |g| compile(g, gl.GEOMETRY_SHADER) else null;
        const frag = compile(fragment, gl.FRAGMENT_SHADER);

        var shader = Shader{
            .id = null,
        };

        if (vert != 0 and frag != 0 and (geometry == null or geom != 0)) {
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
            if (compileError(id, true, fragment)) {
                shader.kill();
            }
        }

        return if (shader.id == null) error.ShaderInitFailure else shader;
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

    pub fn set(shader: Shader, name: [:0]const u8, comptime T: type, value: anytype) void {
        const id = shader.id.?;
        const location = gl.getUniformLocation(id, name);
        if (location == -1) {
            std.log.err("Failed to find uniform {s}", .{name});
            return;
        }
        comptime var indexable = std.meta.trait.isIndexable(@TypeOf(value));
        if (indexable) {
            const vec = @as([]const T, value);
            const ptr: [*c]const T = &vec[0];
            switch (vec.len) {
                1 => (switch (T) {
                    gl.GLfloat => gl.uniform1fv,
                    gl.GLdouble => gl.uniform1dv,
                    gl.GLint => gl.uniform1iv,
                    gl.GLuint => gl.uniform1uiv,
                    else => {
                        std.log.err("Invalid uniform type {}", .{T});
                        unreachable;
                    },
                })(location, 1, ptr),
                2 => (switch (T) {
                    gl.GLfloat => gl.uniform2fv,
                    gl.GLdouble => gl.uniform2dv,
                    gl.GLint => gl.uniform2iv,
                    gl.GLuint => gl.uniform2uiv,
                    else => {
                        std.log.err("Invalid uniform type {}", .{T});
                        unreachable;
                    },
                })(location, 1, ptr),
                3 => (switch (T) {
                    gl.GLfloat => gl.uniform3fv,
                    gl.GLdouble => gl.uniform3dv,
                    gl.GLint => gl.uniform3iv,
                    gl.GLuint => gl.uniform3uiv,
                    else => {
                        std.log.err("Invalid uniform type {}", .{T});
                        unreachable;
                    },
                })(location, 1, ptr),
                4 => (switch (T) {
                    gl.GLfloat => gl.uniform4fv,
                    gl.GLdouble => gl.uniform4dv,
                    gl.GLint => gl.uniform4iv,
                    gl.GLuint => gl.uniform4uiv,
                    else => {
                        std.log.err("Invalid uniform type {}", .{T});
                        unreachable;
                    },
                })(location, 1, ptr),
                9 => (switch (T) {
                    gl.GLfloat => gl.uniformMatrix3fv,
                    gl.GLdouble => gl.uniformMatrix3dv,
                    else => {
                        std.log.err("Invalid uniform type {}", .{T});
                        unreachable;
                    },
                })(location, 1, gl.FALSE, ptr),
                16 => (switch (T) {
                    gl.GLfloat => gl.uniformMatrix4fv,
                    gl.GLdouble => gl.uniformMatrix4dv,
                    else => {
                        std.log.err("Invalid uniform type {} for length {}", .{ T, vec.len });
                        unreachable;
                    },
                })(location, 1, gl.FALSE, ptr),
                else => {
                    std.log.err("Invalid uniform length {}", .{vec.len});
                    unreachable;
                },
            }
        } else {
            (switch (T) {
                gl.GLfloat => gl.uniform1f,
                gl.GLdouble => gl.uniform1d,
                gl.GLint => gl.uniform1i,
                gl.GLuint => gl.uniform1ui,
                else => {
                    std.log.err("Invalid uniform type {}", .{T});
                    unreachable;
                },
            })(location, @as(T, value));
        }
    }
};

fn compile(comptime name: []const u8, comptime stage: gl.GLenum) gl.GLuint {
    comptime std.debug.assert(std.mem.trim(u8, name, &std.ascii.whitespace).len > 0);
    comptime var path = "glsl/" ++ name ++ switch (stage) {
        gl.VERTEX_SHADER => ".vert",
        gl.GEOMETRY_SHADER => ".geom",
        gl.FRAGMENT_SHADER => ".frag",
        else => {
            std.log.err("Invalid shader stage {}", .{stage});
            return 0;
        },
    };
    const buffer: [*c]const [*c]const u8 = &&@embedFile(path)[0];
    const id = gl.createShader(stage);
    gl.shaderSource(id, 1, buffer, null);
    gl.compileShader(id);
    if (compileError(id, false, path)) return 0;
    return id;
}

fn compileError(id: gl.GLuint, comptime is_program: bool, path: []const u8) bool {
    const max_length = 1024;
    var ok: gl.GLint = gl.FALSE;
    var log: [max_length]gl.GLchar = undefined;

    if (is_program) {
        gl.getProgramiv(id, gl.LINK_STATUS, &ok);
    } else {
        gl.getShaderiv(id, gl.COMPILE_STATUS, &ok);
    }

    if (ok == gl.FALSE) {
        var len: gl.GLsizei = undefined;
        (if (is_program) gl.getProgramInfoLog else gl.getShaderInfoLog)(id, max_length, &len, &log);
        std.log.err("Failed to {s} {s}\n{s}", .{
            if (is_program) "link shader program with vertex shader file" else "compile shader file",
            path,
            log[0..@intCast(len)],
        });
    }
    return ok == gl.FALSE;
}
