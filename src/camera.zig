//! The Camera uses user input to smoothly influence it's position and rotation.
//! This state is used to derive view and projection matrices for rendering.

const std = @import("std");
const zm = @import("zmath");
const Chunk = @import("chunk.zig").Chunk;
const World = @import("world.zig").World;

// todo: implement hovercraft movement

pub const Camera = struct {
    // Kinematics
    position: zm.Vec,
    velocity: zm.Vec,
    // Scalars
    yaw: f32,
    pitch: f32,
    aspect: f32,
    fov: f32,
    // Vectors
    look: zm.Vec,
    right: zm.Vec,
    above: zm.Vec,
    // Matrices
    view: zm.Mat,
    proj: zm.Mat,
    world_to_clip: zm.Mat,

    pub fn init(resolution: zm.Vec) Camera {
        var cam = Camera{
            .position = @splat(0),
            .velocity = @splat(0),

            .yaw = -90,
            .pitch = 0,
            .aspect = resolution[0] / resolution[1],
            .fov = undefined,

            .look = undefined,
            .right = undefined,
            .above = undefined,

            .view = undefined,
            .proj = undefined,
            .world_to_clip = undefined,
        };

        cam.calcVecs();
        cam.setFov(75);

        return cam;
    }

    pub fn turn(cam: *Camera, mouse_delta: zm.Vec) void {
        if (mouse_delta[0] == 0 and mouse_delta[1] == 0) return;
        cam.setAngle(
            cam.yaw + mouse_delta[0] * SENS,
            cam.pitch + mouse_delta[1] * SENS,
        );
    }

    // todo: implement hovercraft movement
    // lots of needed into in cam (it's passed in to this func and it's a Camera)

    pub fn step(cam: *Camera, input: zm.Vec, time_delta: f32) void {
        var acc = zm.f32x4s(0);
        acc += zm.f32x4s(input[0]) * cam.right;
        acc += zm.f32x4s(input[1]) * UP;
        acc += zm.f32x4s(input[2]) * cam.look;

        if (zm.lengthSq3(acc)[0] > 0) {
            if (zm.lengthSq3(acc)[0] > 1) {
                acc = zm.normalize3(acc);
            }

            cam.velocity += zm.f32x4s(time_delta * SPEED / ACC_TIME) * acc;

            if (zm.length3(cam.velocity)[0] > SPEED) {
                cam.velocity = zm.normalize3(cam.velocity) * zm.f32x4s(SPEED);
            }
        } else if (zm.lengthSq3(cam.velocity)[0] == 0) return;

        const power = time_delta * (1 - zm.length3(acc)[0]) * FRICTION;
        cam.velocity *= @splat(std.math.pow(f32, 2, -power));
        cam.position += cam.velocity * zm.f32x4s(time_delta);

        cam.calcView();
    }

    var frame_temp: u32 = 0;
    var pass_temp: u64 = 0; // todo: remove me

    pub fn hovercraft_step(cam: *Camera, world: World, time_delta: f32) !void {
        const gravity = 20.0;
        const air_resistance = 0.2; // 0 for none
        const ground_effect_force = 1000.0;
        _ = ground_effect_force;
        const ground_effect_variable_force = false;
        _ = ground_effect_variable_force;
        const ground_effect_min_radius = 4;
        const ground_effect_max_radius = 5;

        var acc = zm.f32x4s(0); // acceleration x y z 0

        // todo: accelerate using keyboard input
        // reconsider whether power should use acc,
        // or a grounded check instead

        if (zm.lengthSq3(acc)[0] > 1) {
            acc = zm.normalize3(acc);
        }

        // apply air resistance
        const power = time_delta * (1 - zm.length3(acc)[0]) * air_resistance;
        cam.velocity *= @splat(std.math.pow(f32, 2, -power));

        acc -= UP * zm.f32x4s(gravity);

        // nearby blocks apply a force to push the craft
        for (0..ground_effect_max_radius * 2) |x| {
            for (0..ground_effect_max_radius * 2) |y| {
                const x2: f32 = @floatFromInt(x);
                const y2: f32 = @floatFromInt(y);
                var offset = zm.f32x4(x2 - ground_effect_max_radius, y2 - ground_effect_max_radius, 0, 0);
                // * zm.f32x4s(Chunk.SIZE);

                const offset_len = zm.length3(offset)[0];
                if (offset_len > ground_effect_min_radius and offset_len < ground_effect_max_radius) {
                    // get the blocks density at the camera position and additional offset provided
                    const pos = cam.position + offset;
                    const chunk_index = try world.indexFromOffset(pos, null);
                    var chunk = world.chunks[chunk_index];
                    const chunk_world_pos = world.offsetFromIndex(chunk_index, null);
                    const density = chunk.densityFromPos(
                        world,
                        pos - chunk_world_pos,
                        chunk_world_pos,
                        false,
                        world.splits,
                    ) orelse 0;

                    if (density > 0) {
                        offset[3] = 0; // todo: remove me
                        acc[3] = 0; // todo: remove me
                        // apply the force (scale [if used] / block_distance)
                        acc -= zm.f32x4s(1) * zm.f32x4s(1000.0) / (zm.length3(offset) + zm.f32x4s(1));
                        // acc -= (if (ground_effect_variable_force) zm.normalize3(offset) else zm.f32x4s(1)) *
                        //     zm.f32x4s(ground_effect_force) /
                        //     (zm.length3(offset) + zm.f32x4s(1));
                    }
                }
            }
        }

        // speed cap
        // if (zm.length3(cam.velocity)[0] > SPEED) {
        //     cam.velocity = zm.normalize3(cam.velocity) * zm.f32x4s(SPEED);
        // }

        cam.velocity += zm.f32x4s(time_delta) * acc; // velocity x y z 0
        cam.position += cam.velocity * zm.f32x4s(time_delta);
        std.debug.print(
            "frame: {} --> vel: {d}, pos: {d}, power: {d}\n",
            .{ frame_temp, cam.velocity, cam.position, power },
        );
        cam.calcView();
    }

    pub fn scroll(cam: *Camera, input: zm.Vec) void {
        if (input[1] == 0) return;
        cam.position += cam.look * zm.f32x4s(input[1] * SPEED * SCROLL);
        cam.calcView();
    }

    fn setAngle(cam: *Camera, yaw: f32, pitch: f32) void {
        cam.yaw = @mod(yaw, 360);
        cam.pitch = zm.clamp(pitch, -PITCH_MAX, PITCH_MAX);
        cam.calcVecs();
    }

    fn calcVecs(cam: *Camera) void {
        const y = std.math.degreesToRadians(f32, cam.yaw);
        const p = std.math.degreesToRadians(f32, cam.pitch);
        const c = @cos(p);
        cam.look = zm.normalize3(zm.f32x4(@cos(y) * c, @sin(p), @sin(y) * c, 0));
        cam.right = zm.normalize3(zm.cross3(cam.look, UP));
        cam.above = zm.normalize3(zm.cross3(cam.look, cam.right));
        cam.calcView();
    }

    fn setFov(cam: *Camera, fov: f32) void {
        cam.fov = std.math.degreesToRadians(f32, fov);
        cam.calcProj();
    }

    fn calcView(cam: *Camera) void {
        cam.view = zm.lookToRh(cam.position, cam.look, UP);
        cam.world_to_clip = zm.mul(cam.view, cam.proj);
    }

    fn calcProj(cam: *Camera) void {
        cam.proj = zm.perspectiveFovRhGl(cam.fov, cam.aspect, NEAR, FAR);
        cam.world_to_clip = zm.mul(cam.view, cam.proj);
    }
};

const SPEED = @as(f32, Chunk.SIZE) * 2.5;
const SCROLL = 0.2;
const ACC_TIME = 0.125;
const FRICTION = 12.5;

const SENS = 0.022 * 4;
const PITCH_MAX = 89;
const UP = zm.f32x4(0, 1, 0, 0);

const NEAR = std.math.pow(f32, 2, -4);
const FAR = std.math.pow(f32, 2, 12);
