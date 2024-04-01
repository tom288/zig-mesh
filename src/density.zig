const zm = @import("zmath");
const znoise = @import("znoise");
const Chunk = @import("chunk.zig").Chunk;

pub const Empty = struct {
    pub fn gen(chunk: *Chunk, offset: zm.Vec) void {
        _ = offset;
        for (0..chunk.density.len) |i| {
            chunk.density[i] = 0;
        }
    }
};

pub const Full = struct {
    pub fn gen(chunk: *Chunk, offset: zm.Vec) void {
        _ = offset;
        for (0..chunk.density.len) |i| {
            chunk.density[i] = 0;
        }
    }
};

pub const HighVerts = struct {
    pub fn gen(chunk: *Chunk, offset: zm.Vec) void {
        _ = offset;
        for (0..chunk.density.len) |i| {
            chunk.density[i] = if (i % 9 > 0) 0 else 1;
        }
    }
};

pub const MaxVerts = struct {
    pub fn gen(chunk: *Chunk, offset: zm.Vec) void {
        _ = offset;
        for (0..chunk.density.len) |i| {
            const pos = chunk.posFromIndex(i);
            chunk.density[i] = @mod(
                pos[0] + pos[1] + pos[2] +
                    if (Chunk.SIZE % 4 != 1) 0 else 1 -
                    if (Chunk.SIZE % 2 > 0) 0 else 0.5,
                2,
            );
        }
    }
};

pub const Perlin = struct {
    const FREQ = 0.75;
    pub fn gen(chunk: *Chunk, offset: zm.Vec) void {
        const noise = znoise.FnlGenerator{
            .frequency = FREQ / @as(f32, Chunk.SIZE),
            .noise_type = .perlin,
        };
        for (0..chunk.density.len) |i| {
            const pos = chunk.posFromIndex(i) + offset;
            chunk.density[i] = noise.noise3(pos[0], pos[1], pos[2]);
        }
    }
};

pub const Simplex = struct {
    const FREQ = 0.5;
    pub fn gen(chunk: *Chunk, offset: zm.Vec) void {
        const noise = znoise.FnlGenerator{
            .frequency = FREQ / @as(f32, Chunk.SIZE),
        };
        for (0..chunk.density.len) |i| {
            const pos = chunk.posFromIndex(i) + offset;
            chunk.density[i] = noise.noise3(pos[0], pos[1], pos[2]);
        }
    }
};

pub const Sphere = struct {
    const RAD = Chunk.SIZE * 3;
    const DIST = Chunk.SIZE * 2;
    pub fn gen(chunk: *Chunk, offset: zm.Vec) void {
        for (0..chunk.density.len) |i| {
            const pos = chunk.posFromIndex(i) + offset +
                zm.f32x4(0, 0, RAD + DIST, 0);
            chunk.density[i] = RAD - zm.length3(pos)[0];
        }
    }
};

pub const SplatteredSphere = struct {
    const RAD = Chunk.SIZE * 3;
    const DIST = Chunk.SIZE * 2;
    const FREQ = 4;
    const BIAS = 0.92;
    pub fn gen(chunk: *Chunk, offset: zm.Vec) void {
        const noise = znoise.FnlGenerator{ .frequency = @as(
            f32,
            @floatFromInt(FREQ),
        ) / @as(
            f32,
            @floatFromInt(RAD),
        ) };
        for (0..chunk.density.len) |i| {
            const pos = chunk.posFromIndex(i) + offset +
                zm.f32x4(0, 0, RAD + DIST, 0);
            chunk.density[i] = RAD * BIAS - zm.length3(pos)[0];
            const sample = noise.noise3(pos[0], pos[1], pos[2]);
            chunk.density[i] += sample * RAD * 0.1;
        }
    }
};

pub const ChunkCorners = struct {
    pub fn gen(chunk: *Chunk, offset: zm.Vec) void {
        _ = offset;
        for (0..chunk.density.len) |i| {
            const pos = @abs(chunk.posFromIndex(i));
            const diff = @abs(pos - zm.f32x4s(@as(f32, Chunk.SIZE - 1) / 2));
            const corner = zm.all(diff <= zm.f32x4s(0.5), 3);
            chunk.density[i] = if (corner) 1 else 0;
        }
    }
};
