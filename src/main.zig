const std = @import("std");
const zm = @import("zmath");
const gl = @import("gl");
const Window = @import("window.zig").Window;
const Shader = @import("shader.zig").Shader;
const Mesh = @import("mesh.zig").Mesh;
const Camera = @import("camera.zig").Camera;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var window = try Window.init(alloc);
    defer window.kill();

    var shader = try Shader.init(
        "white",
        null,
        "mandelbulb",
    );
    defer shader.kill();

    var mesh = try Mesh(.{.{
        .{ .name = "position", .size = 3, .type = gl.FLOAT },
    }}).init(shader);
    const verts = [_]f32{
        -1.0, -1.0, 0.0,
        1.0,  1.0,  0.0,
        -1.0, 1.0,  1.0,

        1.0,  1.0,  0.0,
        -1.0, -1.0, 0.0,
        1.0,  -1.0, 1.0,
    };
    try mesh.upload(.{&verts});
    defer mesh.kill();

    var camera = Camera.init(window.resolution);

    // Wait for the user to close the window.
    while (window.ok()) {
        camera.turn(window.mouse_delta);
        camera.step(window.input, window.delta);
        camera.scroll(window.scroll_delta);
        window.clearColour(0.1, 0, 0.2, 1);

        shader.use();
        shader.set("POSITION", f32, &[3]f32{
            camera.position[0],
            camera.position[1],
            camera.position[2],
        });
        shader.set("LOOK", f32, &[3]f32{
            camera.look[0],
            camera.look[1],
            camera.look[2],
        });
        shader.set("RIGHT", f32, &[3]f32{
            camera.right[0],
            camera.right[1],
            camera.right[2],
        });
        shader.set("ABOVE", f32, &[3]f32{
            camera.above[0],
            camera.above[1],
            camera.above[2],
        });
        shader.set("WIDTH", f32, window.resolution[0]);
        shader.set("HEIGHT", f32, window.resolution[1]);
        shader.set("POWER", f32, (@sin(window.time orelse 0) + 2) * 4);
        mesh.draw(gl.TRIANGLES);

        window.swap();
    }
}
