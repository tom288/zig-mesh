const gl = @import("gl");
const std = @import("std");
const Mesh = @import("mesh.zig").Mesh;
const Shader = @import("shader.zig").Shader;
const glTypeEnum = @import("mesh.zig").glTypeEnum;

pub const Quad = QuadT(f32);

fn QuadT(T: type) type {
    const QuadMesh = Mesh(.{.{
        .{ .name = "position", .size = 2, .type = glTypeEnum(T) catch unreachable },
    }});

    const CFG = struct {
        min: ?T = switch (@typeInfo(T)) {
            .Int => if (std.math.minInt(T) > MIN) null else MIN,
            else => MIN,
        },
        max: ?T = switch (@typeInfo(T)) {
            .Int => if (std.math.maxInt(T) < MAX) null else MAX,
            else => MAX,
        },
        shader: ?Shader = null,

        const MIN = -1;
        const MAX = 1;
    };

    return struct {
        mesh: ?QuadMesh,

        pub fn init(cfg: CFG) !@This() {
            var quad = @This(){ .mesh = null };
            errdefer quad.kill();
            quad.mesh = try QuadMesh.init(cfg.shader);
            const min = cfg.min orelse unreachable; // Default min CFG.MIN incompatible with T
            const max = cfg.max orelse unreachable; // Default max CFG.MAX incompatible with T
            try quad.mesh.?.upload(.{&[_]T{
                min, min,
                max, min,
                min, max,
                max, max,
            }});
            return quad;
        }

        pub fn kill(quad: *@This()) void {
            if (quad.mesh) |_| {
                quad.mesh.?.kill();
                quad.mesh = null;
            }
        }

        pub fn draw(quad: @This()) void {
            // Assume init has been called more recently than kill
            quad.mesh.?.draw(gl.TRIANGLE_STRIP, null, null);
        }
    };
}
