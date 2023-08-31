const gl = @import("gl");

const vertices = [_]f32{
    -0.5, -0.5, 0.0, 0.0, 0.0, 1.0,
    0.5,  0.5,  0.0, 0.0, 1.0, 0.0,
    -0.5, 0.5,  1.0, 1.0, 0.0, 0.0,

    0.5,  0.5,  0.0, 0.0, 0.0, 1.0,
    -0.5, -0.5, 0.0, 0.0, 1.0, 0.0,
    0.5,  -0.5, 1.0, 1.0, 0.0, 0.0,
};

pub const Rectangle = struct {
    vao: ?gl.GLuint,
    vbo: ?gl.GLuint,

    pub fn init() Rectangle {
        var vao: gl.GLuint = undefined;
        var vbo: gl.GLuint = undefined;
        gl.genVertexArrays(1, &vao);
        gl.genBuffers(1, &vbo);
        gl.bindVertexArray(vao);
        gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
        gl.bufferData(
            gl.ARRAY_BUFFER,
            @sizeOf(@TypeOf(vertices)),
            &vertices,
            gl.STATIC_DRAW,
        );
        gl.vertexAttribPointer(
            0,
            3,
            gl.FLOAT,
            gl.FALSE,
            @sizeOf(@TypeOf(vertices)) / 6,
            null,
        );
        gl.enableVertexAttribArray(0);
        gl.vertexAttribPointer(
            1,
            3,
            gl.FLOAT,
            gl.FALSE,
            @sizeOf(@TypeOf(vertices)) / 6,
            @ptrFromInt(@sizeOf(@TypeOf(vertices[0])) * 3),
        );
        gl.enableVertexAttribArray(1);
        gl.bindBuffer(gl.ARRAY_BUFFER, 0);
        gl.bindVertexArray(0);

        return Rectangle{
            .vao = vao,
            .vbo = vbo,
        };
    }

    pub fn kill(rectangle: *Rectangle) void {
        if (rectangle.vao) |vao| {
            gl.deleteVertexArrays(0, @ptrCast(&vao));
            rectangle.vao = null;
        }
        if (rectangle.vbo) |vbo| {
            gl.deleteBuffers(1, &vbo);
            rectangle.vbo = null;
        }
    }

    pub fn draw(rectangle: Rectangle) void {
        const vao = rectangle.vao orelse return;
        gl.bindVertexArray(vao);
        gl.drawArrays(
            gl.TRIANGLES,
            0,
            6,
        );
    }
};
