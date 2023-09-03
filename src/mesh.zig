const std = @import("std");
const gl = @import("gl");
const Shader = @import("shader.zig").Shader;

pub fn Mesh(comptime vbo_num: usize) type {
    return struct {
        vao: ?gl.GLuint,
        vbos: ?[vbo_num]gl.GLuint,
        ebo: ?gl.GLuint,
        strides: [vbo_num]usize,
        vert_count: ?usize,

        pub const Attr = struct {
            name: ?[]const u8,
            size: usize,
            type: gl.GLenum,
        };

        pub fn init(attrs: [vbo_num][]Attr, verts: anytype, indices: ?[]gl.GLuint, shader: ?Shader) !@This() {
            if (attrs.len == 0 or attrs.len != verts.len) return error.BadAttrs;
            var vao: gl.GLuint = undefined;
            gl.genVertexArrays(1, &vao);
            errdefer gl.deleteVertexArrays(0, &vao);
            gl.bindVertexArray(vao);

            var mesh = @This(){
                .vao = vao,
                .vbos = null,
                .ebo = null,
                .strides = undefined,
                .vert_count = null,
            };

            errdefer mesh.kill();
            mesh.upload(verts);
            const vbos = mesh.vbos orelse return error.UploadFailure;

            inline for (0..attrs.len) |i| {
                gl.bindBuffer(gl.ARRAY_BUFFER, vbos[i]);

                try init_attrs(attrs[i], &mesh.strides[i], shader);

                mesh.strides[i] /= try glSizeOf(attrs[i][0].type);
            }

            if (indices) |ids| {
                const usage: gl.GLenum = gl.STATIC_DRAW;
                var ebo: gl.GLuint = undefined;
                gl.genBuffers(1, &ebo);
                gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, ebo);
                gl.bufferData(
                    gl.ELEMENT_ARRAY_BUFFER,
                    @intCast(ids.len * @sizeOf(@TypeOf(ids[0]))),
                    @ptrCast(ids),
                    usage,
                );
                mesh.ebo = ebo;
            }

            mesh.vert_count = verts[0].len / mesh.strides[0];

            gl.enableVertexAttribArray(0);
            gl.bindBuffer(gl.ARRAY_BUFFER, 0);
            gl.bindVertexArray(0);

            try glError();

            return mesh;
        }

        pub fn kill(mesh: *@This()) void {
            if (mesh.ebo) |ebo| {
                gl.deleteBuffers(1, &ebo);
                mesh.ebo = null;
            }
            if (mesh.vbos) |vbos| {
                gl.deleteBuffers(vbo_num, &vbos);
                mesh.vbos = null;
            }
            if (mesh.vao) |vao| {
                gl.deleteVertexArrays(1, &vao);
                mesh.vao = null;
            }
        }

        pub fn draw(mesh: @This(), mode: gl.GLenum) void {
            const vert_count = mesh.vert_count orelse return;
            const vao = mesh.vao orelse return;
            if (mesh.vbos == null) return;

            gl.bindVertexArray(vao);
            if (mesh.ebo == null) {
                gl.drawArrays(
                    mode,
                    0,
                    @intCast(vert_count),
                );
            } else {
                gl.drawElements(
                    mode,
                    @intCast(vert_count),
                    gl.UNSIGNED_INT,
                    null,
                );
            }
            gl.bindVertexArray(0);
        }

        pub fn upload(mesh: *@This(), verts: anytype) void {
            if (mesh.vbos == null) {
                var vbos: [vbo_num]gl.GLuint = undefined;
                gl.genBuffers(@intCast(verts.len), @ptrCast(&vbos));
                mesh.vbos = vbos;
            }
            const vbos = mesh.vbos orelse unreachable;

            // Get the current buffer size
            var signed_size: gl.GLint64 = undefined;
            gl.bindBuffer(gl.ARRAY_BUFFER, vbos[0]);
            gl.getBufferParameteri64v(gl.ARRAY_BUFFER, gl.BUFFER_SIZE, @ptrCast(&signed_size));
            const size: usize = @intCast(signed_size);
            const size_needed: usize = verts[0].len * @sizeOf(@TypeOf(verts[0][0]));

            // If we already have enough size then avoid reallocation
            // Reallocate if we have much more than we need
            const reuse = size >= size_needed and
                (size < size_needed * 2 or size - size_needed < 64);

            inline for (vbos, verts) |vbo, vert| {
                const vert_size: gl.GLsizeiptr = @intCast(vert.len * @sizeOf(@TypeOf(vert[0])));
                gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
                if (reuse) {
                    gl.bufferSubData(gl.ARRAY_BUFFER, 0, vert_size, @ptrCast(vert));
                } else {
                    // TODO allocate a little extra to reduce resize frequency
                    gl.bufferData(gl.ARRAY_BUFFER, vert_size, @ptrCast(vert), gl.STATIC_DRAW);
                }
            }

            gl.bindBuffer(gl.ARRAY_BUFFER, 0);
        }

        fn init_attrs(attrs: []Attr, stride: *usize, shader: ?Shader) !void {
            stride.* = 0;
            for (attrs) |attr| stride.* += attr.size * try glSizeOf(attr.type);

            var first: usize = 0;
            var location_index: gl.GLuint = 0;

            for (attrs) |attr| {
                // Skip nameless attributes, allowing them to act as gaps
                if (attr.name) |name| {
                    // If shader is null then use location indices instead
                    var index = location_index;
                    location_index += 1;

                    if (shader) |s| {
                        const id = s.id orelse return error.ShaderWithoutId;
                        const name_index = gl.getAttribLocation(
                            id,
                            @ptrCast(name),
                        );
                        if (name_index == -1) {
                            std.log.err("Failed to find {s} in shader\n", .{name});
                            return error.AttrNotFound;
                        } else {
                            index = @intCast(name_index);
                        }
                    }

                    init_attr(index, attr, @intCast(stride.*), first);
                }
                first += attr.size * try glSizeOf(attr.type);
            }
        }

        fn init_attr(index: gl.GLuint, attr: Attr, stride: gl.GLsizei, first: usize) void {
            gl.enableVertexAttribArray(index);

            const force_cast_to_float = false;
            const normalise_fixed_point_values = gl.FALSE;
            const size: gl.GLint = @intCast(attr.size);
            const f: ?*const anyopaque = if (first == 0) null else @ptrFromInt(first);

            if (!force_cast_to_float) switch (attr.type) {
                gl.BYTE, gl.UNSIGNED_BYTE, gl.SHORT, gl.UNSIGNED_SHORT, gl.INT, gl.UNSIGNED_INT => {
                    gl.vertexAttribIPointer(index, size, attr.type, stride, f);
                    return;
                },
                gl.DOUBLE => {
                    gl.vertexAttribLPointer(index, size, attr.type, stride, f);
                    return;
                },
                else => {},
            };

            gl.vertexAttribPointer(
                index,
                size,
                attr.type,
                normalise_fixed_point_values,
                stride,
                f,
            );
        }

        fn glError() !void {
            while (true) {
                const error_code = gl.getError();
                if (error_code == gl.NO_ERROR) break;
                const error_str = switch (error_code) {
                    gl.INVALID_ENUM => "INVALID_ENUM",
                    gl.INVALID_VALUE => "INVALID_VALUE",
                    gl.INVALID_OPERATION => "INVALID_OPERATION",
                    gl.OUT_OF_MEMORY => "OUT_OF_MEMORY",
                    gl.INVALID_FRAMEBUFFER_OPERATION => "INVALID_FRAMEBUFFER_OPERATION",
                    else => {
                        std.log.err("OpenGL error code {} missing from glError\n", .{error_code});
                        return error.OpenGlError;
                    },
                };
                std.log.err("OpenGL error {s}\n", .{error_str});
                return error.OpenGlError;
            }
        }

        fn glSizeOf(T: gl.GLenum) !usize {
            return switch (T) {
                gl.BYTE, gl.UNSIGNED_BYTE => @sizeOf(gl.GLbyte),
                gl.SHORT, gl.UNSIGNED_SHORT => @sizeOf(gl.GLshort),
                gl.INT_2_10_10_10_REV, gl.INT, gl.UNSIGNED_INT_2_10_10_10_REV, gl.UNSIGNED_INT => @sizeOf(gl.GLint),
                gl.FLOAT => @sizeOf(gl.GLfloat),
                gl.DOUBLE => @sizeOf(gl.GLdouble),
                gl.FIXED => @sizeOf(gl.GLfixed),
                gl.HALF_FLOAT => @sizeOf(gl.GLhalf),
                else => error.UnknownOpenGlEnum,
            };
        }
    };
}
