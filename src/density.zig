const zm = @import("zmath");
const znoise = @import("znoise");
const Chunk = @import("chunk.zig").Chunk;
const CFG = @import("cfg.zig");

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
                    if (CFG.chunk_blocks % 4 != 1) 0 else 1 -
                    if (CFG.chunk_blocks % 2 > 0) 0 else 0.5,
                2,
            );
        }
    }
};

pub const Perlin = struct {
    const FREQ = 0.75;
    const NOISE = znoise.FnlGenerator{
        .frequency = FREQ / @as(f32, CFG.chunk_blocks),
        .noise_type = .perlin,
    };
    pub fn gen(chunk: *Chunk, offset: zm.Vec) void {
        for (0..chunk.density.len) |i| {
            const pos = chunk.posFromIndex(i) + offset;
            chunk.density[i] = NOISE.noise3(pos[0], pos[1], pos[2]);
        }
    }
};

pub const Simplex = struct {
    const FREQ = 0.5;
    const NOISE = znoise.FnlGenerator{
        .frequency = FREQ / @as(f32, CFG.chunk_blocks),
    };
    pub fn gen(chunk: *Chunk, offset: zm.Vec) void {
        for (0..chunk.density.len) |i| {
            const pos = chunk.posFromIndex(i) + offset;
            chunk.density[i] = NOISE.noise3(pos[0], pos[1], pos[2]);
        }
    }
};

pub const Sphere = struct {
    const RAD = CFG.chunk_blocks * 3;
    const DIST = CFG.chunk_blocks * 2;
    pub fn gen(chunk: *Chunk, offset: zm.Vec) void {
        for (0..chunk.density.len) |i| {
            const pos = chunk.posFromIndex(i) + offset +
                zm.f32x4(0, 0, RAD + DIST, 0);
            chunk.density[i] = RAD - zm.length3(pos)[0];
        }
    }
};

pub const SplatteredSphere = struct {
    const RAD = CFG.chunk_blocks * 3;
    const DIST = CFG.chunk_blocks * 2;
    const FREQ = 4;
    const BIAS = 0.92;
    const NOISE = znoise.FnlGenerator{ .frequency = @as(
        f32,
        @floatFromInt(FREQ),
    ) / @as(
        f32,
        @floatFromInt(RAD),
    ) };
    pub fn gen(chunk: *Chunk, offset: zm.Vec) void {
        for (0..chunk.density.len) |i| {
            const pos = chunk.posFromIndex(i) + offset +
                zm.f32x4(0, 0, RAD + DIST, 0);
            chunk.density[i] = RAD * BIAS - zm.length3(pos)[0];
            const sample = NOISE.noise3(pos[0], pos[1], pos[2]);
            chunk.density[i] += sample * RAD * 0.1;
        }
    }
};

pub const ChunkCorners = struct {
    pub fn gen(chunk: *Chunk, offset: zm.Vec) void {
        _ = offset;
        for (0..chunk.density.len) |i| {
            const pos = @abs(chunk.posFromIndex(i));
            const diff = @abs(pos - zm.f32x4s(@as(f32, CFG.chunk_blocks - 1) / 2));
            const corner = zm.all(diff <= zm.f32x4s(0.5), 3);
            chunk.density[i] = if (corner) 1 else 0;
        }
    }
};
