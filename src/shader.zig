//! A Shader uses GLSL source files at the provided paths to generate programs
//! that execute on the GPU. The function named set performs uniform assignment.

const std = @import("std");
const gl = @import("gl");

const GLSL_PATH = "src/glsl/";

pub const Shader = struct {
    id: ?gl.GLuint,

    pub fn init(
        alloc: std.mem.Allocator,
        comptime vertex: []const u8,
        comptime geometry: ?[]const u8,
        comptime fragment: []const u8,
    ) !Shader {
        return initShader(
            alloc,
            &[_]?[]const u8{ vertex, geometry, fragment },
            &[_]gl.GLenum{ gl.VERTEX_SHADER, gl.GEOMETRY_SHADER, gl.FRAGMENT_SHADER },
        );
    }

    pub fn initComp(alloc: std.mem.Allocator, comptime compute: []const u8) !Shader {
        return initShader(
            alloc,
            &[_]?[]const u8{compute},
            &[_]gl.GLenum{gl.COMPUTE_SHADER},
        );
    }

    fn initShader(
        alloc: std.mem.Allocator,
        comptime names: []const ?[]const u8,
        comptime stages: []const gl.GLenum,
    ) !Shader {
        comptime std.debug.assert(names.len == stages.len);
        var ids: [names.len]?gl.GLuint = undefined;
        var zero = false;
        inline for (names, stages, &ids) |name, stage, *id| {
            id.* = try compile(alloc, name, stage);
            zero = zero or id.* == 0;
        }

        var shader = Shader{
            .id = null,
        };

        if (!zero) {
            shader.id = gl.createProgram();
            if (shader.id) |program_id| {
                for (ids) |id| if (id) |i| gl.attachShader(program_id, i);
                gl.linkProgram(program_id);
            }
        }

        for (ids) |id| if (id) |i| gl.deleteShader(i);

        if (shader.id) |id| {
            var path: ?[]const u8 = null;
            inline for (names, stages) |_name, stage| {
                const name = _name orelse continue;
                const tmp: ?[]const u8 = getNameWithExt(name, stage) catch null;
                if (tmp) |t| path = t;
            }
            if (compileError(id, true, path, null)) {
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
        if (shader.id) |id| gl.useProgram(id);
    }

    pub fn set(shader: Shader, name: [:0]const u8, comptime T: type, value: anytype) void {
        shader.set_n(name, T, 1, value);
    }

    pub fn set_n(shader: Shader, name: [:0]const u8, comptime T: type, n: gl.GLint, value: anytype) void {
        const id = shader.id.?;
        const location = gl.getUniformLocation(id, name);
        if (location == -1) {
            std.log.err("Failed to find uniform {s}", .{name});
            return;
        }
        switch (@typeInfo(@TypeOf(value))) {
            .Array, .Pointer => {
                const vec = @as([]const T, switch (@typeInfo(@TypeOf(value))) {
                    .Array => &value,
                    else => value,
                });
                const ptr: [*c]const T = &vec[0];
                const _n: usize = @intCast(n);
                std.debug.assert(vec.len % _n == 0);
                switch (vec.len / _n) {
                    1 => (switch (T) {
                        gl.GLfloat => gl.uniform1fv,
                        gl.GLdouble => gl.uniform1dv,
                        gl.GLint => gl.uniform1iv,
                        gl.GLuint => gl.uniform1uiv,
                        else => {
                            std.log.err("Invalid uniform type {}", .{T});
                            unreachable;
                        },
                    })(location, n, ptr),
                    2 => (switch (T) {
                        gl.GLfloat => gl.uniform2fv,
                        gl.GLdouble => gl.uniform2dv,
                        gl.GLint => gl.uniform2iv,
                        gl.GLuint => gl.uniform2uiv,
                        else => {
                            std.log.err("Invalid uniform type {}", .{T});
                            unreachable;
                        },
                    })(location, n, ptr),
                    3 => (switch (T) {
                        gl.GLfloat => gl.uniform3fv,
                        gl.GLdouble => gl.uniform3dv,
                        gl.GLint => gl.uniform3iv,
                        gl.GLuint => gl.uniform3uiv,
                        else => {
                            std.log.err("Invalid uniform type {}", .{T});
                            unreachable;
                        },
                    })(location, n, ptr),
                    4 => (switch (T) {
                        gl.GLfloat => gl.uniform4fv,
                        gl.GLdouble => gl.uniform4dv,
                        gl.GLint => gl.uniform4iv,
                        gl.GLuint => gl.uniform4uiv,
                        else => {
                            std.log.err("Invalid uniform type {}", .{T});
                            unreachable;
                        },
                    })(location, n, ptr),
                    9 => (switch (T) {
                        gl.GLfloat => gl.uniformMatrix3fv,
                        gl.GLdouble => gl.uniformMatrix3dv,
                        else => {
                            std.log.err("Invalid uniform type {}", .{T});
                            unreachable;
                        },
                    })(location, n, gl.FALSE, ptr),
                    16 => (switch (T) {
                        gl.GLfloat => gl.uniformMatrix4fv,
                        gl.GLdouble => gl.uniformMatrix4dv,
                        else => {
                            std.log.err("Invalid uniform type {} for length {}", .{ T, vec.len });
                            unreachable;
                        },
                    })(location, n, gl.FALSE, ptr),
                    else => {
                        std.log.err("Invalid uniform length {}", .{vec.len});
                        unreachable;
                    },
                }
            },
            else => {
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
            },
        }
    }

    pub fn bindBlock(shader: Shader, name: [:0]const u8, binding: gl.GLuint) void {
        if (shader.id) |id| {
            const index = gl.getProgramResourceIndex(id, gl.SHADER_STORAGE_BLOCK, name);
            gl.shaderStorageBlockBinding(id, index, binding);
        }
    }
};

fn compile(alloc: std.mem.Allocator, comptime _name: ?[]const u8, comptime stage: gl.GLenum) !?gl.GLuint {
    const name = _name orelse return null;
    comptime std.debug.assert(std.mem.trim(
        u8,
        name,
        &std.ascii.whitespace,
    ).len > 0);

    const needle = "#include";
    const initial_path = getNameWithExt(name, stage) catch |e| {
        std.log.err("Invalid shader stage {s}", .{stage});
        return e;
    };
    var data = try std.fmt.allocPrintZ(
        alloc,
        "{s} {s}",
        .{ needle, initial_path },
    );
    defer alloc.free(data);

    while (std.mem.indexOf(u8, data, needle)) |needle_start| {
        // Walk over whitespace, ensuring there is at least 1 character
        const needle_end = needle_start + needle.len;
        var name_start = needle_end;
        while (name_start < data.len and std.ascii.isWhitespace(data[name_start])) name_start += 1;
        std.debug.assert(name_start != needle_end);
        // Walk length of file name, ensuring there is at least 1 character
        var name_end = name_start;
        while (name_end < data.len and !std.ascii.isWhitespace(data[name_end])) name_end += 1;
        std.debug.assert(name_end != name_start);
        // Construct file path
        const path = try std.fmt.allocPrint(
            alloc,
            "{s}{s}",
            .{ GLSL_PATH, data[name_start..name_end] },
        );
        defer alloc.free(path);
        // Open file and read contents
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const contents = try file.readToEndAlloc(
            alloc,
            1024 * 1024, // 1 MB
        );
        defer alloc.free(contents);
        // Insert file contents into data, along with a null terminator
        const new_data = try std.fmt.allocPrintZ(
            alloc,
            "{s}\n{s}\n{s}",
            .{
                std.mem.trim(u8, data[0..needle_start], &std.ascii.whitespace),
                std.mem.trim(u8, contents, &std.ascii.whitespace),
                std.mem.trim(u8, data[name_end..], &std.ascii.whitespace),
            },
        );
        // Free old data, use new data
        alloc.free(data);
        data = new_data;
    }

    // Create shader using file
    const id = gl.createShader(stage);
    gl.shaderSource(id, 1, &&data[0], null);
    gl.compileShader(id);
    if (compileError(id, false, initial_path, data)) return 0;
    return id;
}

fn compileError(id: gl.GLuint, comptime is_program: bool, path: ?[]const u8, data: ?[:0]u8) bool {
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
            if (is_program) "link shader program with shader file" else "compile shader file",
            path orelse "NO_PATH_GIVEN",
            log[0..@intCast(len)],
        });
        if (data) |d| std.debug.print("{s}\n", .{d});
    }
    return ok == gl.FALSE;
}

fn getNameWithExt(comptime name: []const u8, comptime stage: gl.GLenum) ![]const u8 {
    return name ++ switch (stage) {
        gl.VERTEX_SHADER => ".vert",
        gl.GEOMETRY_SHADER => ".geom",
        gl.FRAGMENT_SHADER => ".frag",
        gl.COMPUTE_SHADER => ".comp",
        else => return error.BadExtension,
    };
}
