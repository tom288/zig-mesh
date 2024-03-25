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
        comptime srcs: []const ?[]const u8,
        comptime stages: []const gl.GLenum,
    ) !Shader {
        comptime std.debug.assert(srcs.len == stages.len);
        var ids: [srcs.len]?gl.GLuint = undefined;
        var zero = false;
        inline for (srcs, stages, &ids) |src, stage, *id| {
            id.* = try compile(alloc, src, stage);
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
            inline for (srcs, stages) |src, stage| {
                if (src == null) continue;
                const tmp: ?[]const u8 = makePath(src, stage) catch null;
                if (tmp) |t| path = t;
            }
            if (compileError(id, true, path)) {
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

fn compile(alloc: std.mem.Allocator, comptime src: ?[]const u8, comptime stage: gl.GLenum) !?gl.GLuint {
    if (src == null) return null;
    comptime std.debug.assert(std.mem.trim(
        u8,
        src.?,
        &std.ascii.whitespace,
    ).len > 0);
    // Get file path
    const path = comptime makePath(src, stage) catch |e| {
        std.log.err("Invalid shader stage {}", .{stage});
        return e;
    };
    // Open the file
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    // Read file contents
    var data = try file.readToEndAllocOptions(
        alloc,
        1024 * 1024, // 1 MB max
        null, // Default sizing
        @alignOf(u8), // Default alignment
        0, // Null terminator
    );
    defer alloc.free(data);

    const needle = "#include";

    while (true) {
        // Find index of first needle, if any
        const index = std.mem.indexOf(u8, data, needle);
        if (index == null) break;
        // Walk over whitespace, ensuring there is at least 1 character
        const needle_end = index.? + needle.len;
        var start = needle_end;
        while (std.ascii.isWhitespace(data[start])) start += 1;
        std.debug.assert(start != needle_end);
        // Walk length of file name
        var end = start;
        while (!std.ascii.isWhitespace(data[end])) end += 1;
        // Construct file path
        const new_path = try std.fmt.allocPrint(alloc, "{s}{s}", .{ GLSL_PATH, data[start..end] });
        defer alloc.free(new_path);
        // Open file
        const new_file = try std.fs.cwd().openFile(new_path, .{});
        defer new_file.close();
        // Read contents without a null terminator
        const new_contents = try new_file.readToEndAlloc(
            alloc,
            1024 * 1024, // 1 MB max
        );
        defer alloc.free(new_contents);
        // Insert file contents
        const new_data = try std.fmt.allocPrintZ(
            alloc,
            "{s}\n{s}\n{s}",
            .{
                std.mem.trim(u8, data[0..index.?], &std.ascii.whitespace),
                std.mem.trim(u8, new_contents, &std.ascii.whitespace),
                std.mem.trim(u8, data[end..], &std.ascii.whitespace),
            },
        );
        alloc.free(data);
        data = new_data;
    }

    // Create shader using file
    const id = gl.createShader(stage);
    gl.shaderSource(id, 1, &&data[0], null);
    gl.compileShader(id);
    if (compileError(id, false, path)) return 0;
    return id;
}

fn compileError(id: gl.GLuint, comptime is_program: bool, path: ?[]const u8) bool {
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
    }
    return ok == gl.FALSE;
}

fn makePath(comptime src: ?[]const u8, comptime stage: gl.GLenum) ![]const u8 {
    return GLSL_PATH ++ src.? ++ switch (stage) {
        gl.VERTEX_SHADER => ".vert",
        gl.GEOMETRY_SHADER => ".geom",
        gl.FRAGMENT_SHADER => ".frag",
        gl.COMPUTE_SHADER => ".comp",
        else => return error.BadExtension,
    };
}
