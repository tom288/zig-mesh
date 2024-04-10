//! A Quad is a mesh with pre-determined rectangular contents
//! Primarily useful in full-screen shaders for deferred shading

const gl = @import("gl");
const std = @import("std");
const Mesh = @import("mesh.zig").Mesh;
const Shader = @import("shader.zig").Shader;
const glTypeEnum = @import("mesh.zig").glTypeEnum;

pub const Quad = QuadT(f32);

fn QuadT(T: type) type {
    return struct {
        mesh: ?Mesh(.{.{
            .{ .name = "position", .size = 2, .type = glTypeEnum(T) catch unreachable },
        }}),

        // Return an initialised Quad with pre-uploaded vertices
        pub fn init(
            cfg: struct {
                // Minimum X & Y position values
                min: ?T = switch (@typeInfo(T)) {
                    .Int => if (std.math.minInt(T) > MIN) null else MIN,
                    .Float => MIN,
                    else => unreachable, // Reject comptime and non-numeric types
                },
                // Maximum X & Y position values
                max: ?T = switch (@typeInfo(T)) {
                    .Int => if (std.math.maxInt(T) < MAX) null else MAX,
                    .Float => MAX,
                    else => unreachable, // Reject comptime and non-numeric types
                },
                // Shader to query input locations of
                shader: ?Shader = null,

                // Default min
                const MIN = -1;
                // Default max
                const MAX = 1;
            },
        ) !@This() {
            var quad = @This(){ .mesh = null };
            errdefer quad.kill();
            quad.mesh = undefined;
            quad.mesh = try (@TypeOf(quad.mesh.?)).init(cfg.shader);
            const min = cfg.min.?; // Default min CFG.MIN incompatible with T
            const max = cfg.max.?; // Default max CFG.MAX incompatible with T
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
