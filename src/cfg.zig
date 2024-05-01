const Surface = @import("surface.zig");
const Density = @import("density.zig");
const GFX = @import("gfx.zig");

// Number of blocks along each axis on a single chunk
pub const chunk_blocks: usize = 16;

// Number of chunks along each axis in the world
pub const world_chunks: usize = 16;

// Density data generation method
pub const density = Density.Perlin;

// Type of surface to assemble from density data
pub const surface = Surface.Voxel;

// Graphics technique
pub const gfx = GFX.DeferredShading;

// Type of threading to use for density and surface generation
pub const threading = enum {
    single,
    multi,
    compute,
}.multi;

// Tradeoff between overdraw and voxel world vertex count
pub const overdraw = enum {
    naive,
    binary_greedy,
    global_lattice,
}.global_lattice;
