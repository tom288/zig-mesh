const std = @import("std");
const gl = @import("gl");
const zm = @import("zmath");

pub const Cube = struct {
    vao: ?gl.GLuint,
    vbo: ?gl.GLuint,
    verts: std.ArrayList(f32),

    pub fn init(alloc: std.mem.Allocator) !Cube {
        var verts = std.ArrayList(f32).init(alloc);

        // Faces
        for (0..6) |n| {
            var centre = zm.f32x4s(0);
            centre[n / 2] += @as(f32, @floatFromInt(n % 2)) - 0.5;
            // Triangles
            for (0..2) |t| {
                // Vertices
                for (0..3) |v| {
                    var vertex = centre;
                    const a: f32 = @floatFromInt((t + 3 - v - n % 2) % 2);
                    const b: f32 = @floatFromInt(if (v < 1) 1 - t else t);
                    vertex[(n / 2 + 1) % 3] += a - 0.5;
                    vertex[(n / 2 + 2) % 3] += b - 0.5;
                    // Vertex positions
                    for (0..3) |d| try verts.append(vertex[d]);
                    // Vertex colours
                    for (0..3) |d| try verts.append(vertex[d] + 0.5);
                }
            }
        }

        var vao: gl.GLuint = undefined;
        var vbo: gl.GLuint = undefined;
        gl.genVertexArrays(1, &vao);
        errdefer gl.deleteVertexArrays(0, @ptrCast(&vao));
        gl.genBuffers(1, &vbo);
        errdefer gl.deleteBuffers(1, &vbo);
        gl.bindVertexArray(vao);
        gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
        gl.bufferData(
            gl.ARRAY_BUFFER,
            @intCast(@sizeOf(@TypeOf(verts.items[0])) * verts.items.len),
            @ptrCast(verts.items),
            gl.STATIC_DRAW,
        );
        gl.vertexAttribPointer(
            0,
            3,
            gl.FLOAT,
            gl.FALSE,
            @sizeOf(@TypeOf(verts.items[0])) * 6,
            null,
        );
        gl.enableVertexAttribArray(0);
        gl.vertexAttribPointer(
            1,
            3,
            gl.FLOAT,
            gl.FALSE,
            @sizeOf(@TypeOf(verts.items[0])) * 6,
            @ptrFromInt(@sizeOf(@TypeOf(verts.items[0])) * 3),
        );
        gl.enableVertexAttribArray(1);
        gl.bindBuffer(gl.ARRAY_BUFFER, 0);
        gl.bindVertexArray(0);

        return Cube{
            .vao = vao,
            .vbo = vbo,
            .verts = verts,
        };
    }

    pub fn kill(cube: *Cube) void {
        if (cube.vbo) |vbo| {
            gl.deleteBuffers(1, &vbo);
            cube.vbo = null;
        }
        if (cube.vao) |vao| {
            gl.deleteVertexArrays(0, @ptrCast(&vao));
            cube.vao = null;
        }
    }

    pub fn draw(cube: Cube) void {
        const vao = cube.vao orelse return;
        gl.bindVertexArray(vao);
        gl.drawArrays(
            gl.TRIANGLES,
            0,
            @intCast(cube.verts.items.len / 6),
        );
    }
};
