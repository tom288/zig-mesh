const std = @import("std");
const gl = @import("gl");
const zm = @import("zmath");
const Mesh = @import("mesh.zig").Mesh;

pub const Cube = struct {
    verts: std.ArrayList(f32),
    mesh: Mesh(.{.{
        .{ .name = "position", .size = 3, .type = gl.FLOAT },
        .{ .name = "colour", .size = 3, .type = gl.FLOAT },
    }}),

    pub fn init(alloc: std.mem.Allocator) !Cube {
        var cube = Cube{
            .verts = std.ArrayList(f32).init(alloc),
            .mesh = undefined,
        };
        errdefer cube.verts.deinit();
        try cube.buildVerts();

        cube.mesh = try @TypeOf(cube.mesh).init(null);
        errdefer cube.mesh.kill();
        try cube.mesh.upload(.{cube.verts.items});

        return cube;
    }

    pub fn kill(cube: *Cube) void {
        cube.mesh.kill();
        cube.verts.deinit();
    }

    pub fn draw(cube: Cube) void {
        cube.mesh.draw(gl.TRIANGLES);
    }

    fn buildVerts(cube: *Cube) !void {
        // Faces
        for (0..6) |n| {
            var centre = zm.f32x4s(0);
            centre[n / 2] += @as(f32, @floatFromInt(n % 2)) - 0.5;
            // Triangles
            for (0..2) |t| {
                // Vertices
                for (0..3) |v| {
                    var vertex = centre;
                    vertex[(n / 2 + 1) % 3] += if ((t + v + n % 2) % 2 == 0) -0.5 else 0.5;
                    vertex[(n / 2 + 2) % 3] += if (v / 2 == t) -0.5 else 0.5;
                    // Vertex positions
                    for (0..3) |d| try cube.verts.append(vertex[d]);
                    // Vertex colours
                    for (0..3) |d| try cube.verts.append(vertex[d] + 0.5);
                }
            }
        }
    }
};
