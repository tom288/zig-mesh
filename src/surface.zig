//! A Surface describes the transformation of Chunk densities into surface verts

const std = @import("std");
const zm = @import("zmath");
const znoise = @import("znoise");
const World = @import("world.zig").World;
const Chunk = @import("chunk.zig").Chunk;

pub const Voxel = struct {
    //! Cubes are centered around their position.
    //! Noise is sampled at the center of each cube to obtain densities.
    pub const CELL_OFFSET = 0.5;

    // Cube face visibility is calculated from neighbours in all directions
    pub const NEG_ADJ = true;

    pub fn gen(chunk: *Chunk, world: World, noise: znoise.FnlGenerator, pos: zm.Vec, offset: zm.Vec) !void {
        if (empty(chunk, world, pos, offset, false, null).?) return;
        const mip_level = chunk.wip_mip.?;
        const mip_scale = std.math.pow(f32, 2, @floatFromInt(mip_level));
        const AVG_COLOUR = false;
        const OCCLUSION = false;
        const avg_colour = sampleColour(pos + offset, noise);
        // Faces
        for (0..6) |f| {
            var neighbour = pos;
            neighbour[f / 2] += if (f % 2 > 0) mip_scale else -mip_scale;
            if (full(chunk, world, neighbour, offset, false, null) orelse false) continue;
            var occlusion: [8]bool = undefined;
            // Sample voxel occlusion
            if (OCCLUSION) for (0..4) |e| {
                // Voxels that share edges
                var occluder = neighbour;
                occluder[(e / 2 + f / 2 + 1) % 3] += if (e % 2 > 0) mip_scale else -mip_scale;
                occlusion[e] = full(chunk, world, occluder, offset, true, null) orelse false;
                // Voxels that share corners
                occluder = neighbour;
                occluder[(f / 2 + 1) % 3] += if (e % 2 > 0) mip_scale else -mip_scale;
                occluder[(f / 2 + 2) % 3] += if (e / 2 > 0) mip_scale else -mip_scale;
                occlusion[e + 4] = full(chunk, world, occluder, offset, true, null) orelse false;
            };

            var norm = zm.f32x4s(0);
            norm[f / 2] = if (f % 2 > 0) 1 else -1;
            // Triangles
            for (0..2) |t| {
                // Vertices
                for (0..3) |v| {
                    var vert = (pos + neighbour) / zm.f32x4s(2);
                    const x = (t + v + f) % 2 > 0;
                    const y = v / 2 == t;
                    vert[(f / 2 + 1) % 3] += if (x) mip_scale * 0.5 else mip_scale * -0.5;
                    vert[(f / 2 + 2) % 3] += if (y) mip_scale * 0.5 else mip_scale * -0.5;
                    // Vertex positions
                    try chunk.surface.?.appendSlice(&zm.vecToArr3(vert));
                    try appendColour(chunk, zm.f32x4s(0)); // Padding
                    try chunk.surface.?.appendSlice(&zm.vecToArr3(norm));
                    // Vertex colours
                    var colour = if (AVG_COLOUR) avg_colour else sampleColour(vert + offset, noise);
                    if (OCCLUSION) {
                        // Accumulate occlusion
                        var occ: f32 = 0;
                        if (occlusion[if (x) 1 else 0]) occ += 1;
                        if (occlusion[if (y) 3 else 2]) occ += 1;
                        if (occlusion[
                            4 + @as(usize, if (x) 1 else 0) +
                                @as(usize, if (y) 2 else 0)
                        ]) occ += 1;
                        // Darken occluded vertices
                        colour /= @splat(std.math.pow(f32, 1.1, occ));
                    }
                    try appendColour(chunk, colour);
                }
            }
        }
    }
};

pub const MarchingCubes = struct {
    //! Triangles are generated based on the densities of all 8 corners.
    //! Noise is sampled on the integer grid.
    pub const CELL_OFFSET = 0;

    // Triangle config is derived using only positive direction neighbours
    pub const NEG_ADJ = false;

    const triTable = [256]u60{
        0xfffffffffffffff, 0x083ffffffffffff, 0x019ffffffffffff, 0x183981fffffffff,
        0x12affffffffffff, 0x08312afffffffff, 0x92a029fffffffff, 0x2832a8a98ffffff,
        0x3b2ffffffffffff, 0x0b28b0fffffffff, 0x19023bfffffffff, 0x1b219b98bffffff,
        0x3a1ba3fffffffff, 0x0a108a8baffffff, 0x3903b9ba9ffffff, 0x98aa8bfffffffff,
        0x478ffffffffffff, 0x430734fffffffff, 0x019847fffffffff, 0x419471731ffffff,
        0x12a847fffffffff, 0x34730412affffff, 0x92a902847ffffff, 0x2a9297273794fff,
        0x8473b2fffffffff, 0xb47b24204ffffff, 0x90184723bffffff, 0x47b94b9b2921fff,
        0x3a13ba784ffffff, 0x1ba14b1047b4fff, 0x47890b9bab03fff, 0x47b4b99baffffff,
        0x954ffffffffffff, 0x954083fffffffff, 0x054150fffffffff, 0x854835315ffffff,
        0x12a954fffffffff, 0x30812a495ffffff, 0x52a542402ffffff, 0x2a5325354348fff,
        0x95423bfffffffff, 0x0b208b495ffffff, 0x05401523bffffff, 0x21525828b485fff,
        0xa3ba13954ffffff, 0x4950818a18bafff, 0x54050b5bab03fff, 0x54858aa8bffffff,
        0x978579fffffffff, 0x930953573ffffff, 0x078017157ffffff, 0x153357fffffffff,
        0x978957a12ffffff, 0xa12950530573fff, 0x802825857a52fff, 0x2a5253357ffffff,
        0x7957893b2ffffff, 0x95797292027bfff, 0x23b018178157fff, 0xb21b17715ffffff,
        0x958857a13a3bfff, 0x5705097b010aba0, 0xba0b03a50807570, 0xba57b5fffffffff,
        0xa65ffffffffffff, 0x0835a6fffffffff, 0x9015a6fffffffff, 0x1831985a6ffffff,
        0x165261fffffffff, 0x165126308ffffff, 0x965906026ffffff, 0x598582526328fff,
        0x23ba65fffffffff, 0xb08b20a65ffffff, 0x01923b5a6ffffff, 0x5a61929b298bfff,
        0x63b653513ffffff, 0x08b0b50515b6fff, 0x3b6036065059fff, 0x65969bb98ffffff,
        0x5a6478fffffffff, 0x43047365affffff, 0x1905a6847ffffff, 0xa65197173794fff,
        0x612651478ffffff, 0x125526304347fff, 0x847905065026fff, 0x739794329596269,
        0x3b2784a65ffffff, 0x5a647242027bfff, 0x01947823b5a6fff, 0x9219b294b7b45a6,
        0x8473b53515b6fff, 0x51b5b610b7b404b, 0x059065036b63847, 0x65969b4797b9fff,
        0xa4964afffffffff, 0x4a649a083ffffff, 0xa01a60640ffffff, 0x83181686461afff,
        0x149124264ffffff, 0x308129249264fff, 0x024426fffffffff, 0x832824426ffffff,
        0xa49a64b23ffffff, 0x08228b49a4a6fff, 0x3b201606461afff, 0x64161a48121b8b1,
        0x964936913b63fff, 0x8b1810b61914641, 0x3b6360064ffffff, 0x648b68fffffffff,
        0x7a678a89affffff, 0x0730a709a67afff, 0xa671a7178180fff, 0xa67a71173ffffff,
        0x126168189867fff, 0x269291679093739, 0x780706602ffffff, 0x732672fffffffff,
        0x23ba68a89867fff, 0x20727b09767a9a7, 0x1801781a767a23b, 0xb21b17a61671fff,
        0x896867916b63136, 0x091b67fffffffff, 0x7807063b0b60fff, 0x7b6ffffffffffff,
        0x76bffffffffffff, 0x308b76fffffffff, 0x019b76fffffffff, 0x819831b76ffffff,
        0xa126b7fffffffff, 0x12a3086b7ffffff, 0x2902a96b7ffffff, 0x6b72a3a83a98fff,
        0x723627fffffffff, 0x708760620ffffff, 0x276237019ffffff, 0x162186198876fff,
        0xa76a17137ffffff, 0xa7617a187108fff, 0x03707a0a96a7fff, 0x76a7a88a9ffffff,
        0x684b86fffffffff, 0x36b306046ffffff, 0x86b846901ffffff, 0x946963931b36fff,
        0x6846b82a1ffffff, 0x12a30b06b046fff, 0x4b846b0292a9fff, 0xa93a32943b36463,
        0x823842462ffffff, 0x042462fffffffff, 0x190234246438fff, 0x194142246ffffff,
        0x8138618466a1fff, 0xa10a06604ffffff, 0x4634386a3039a93, 0xa946a4fffffffff,
        0x49576bfffffffff, 0x083495b76ffffff, 0x50154076bffffff, 0xb76834354315fff,
        0x954a1276bffffff, 0x6b712a083495fff, 0x76b54a42a402fff, 0x348354325a52b76,
        0x723762549ffffff, 0x954086062687fff, 0x362376150540fff, 0x628687218485158,
        0x954a16176137fff, 0x16a176107870954, 0x40a4a503a6a737a, 0x76a7a854a48afff,
        0x6956b9b89ffffff, 0x36b063056095fff, 0x0b805b01556bfff, 0x6b3635531ffffff,
        0x12a95b9b8b56fff, 0x0b306b09656912a, 0xb85b56805a52025, 0x6b36352a3a53fff,
        0x589528562382fff, 0x956960062ffffff, 0x158180568382628, 0x156216fffffffff,
        0x13616a386569896, 0xa10a06950560fff, 0x03856afffffffff, 0xa56ffffffffffff,
        0xb5a75bfffffffff, 0xb5ab75830ffffff, 0x5b75ab190ffffff, 0xa75ab7981831fff,
        0xb12b71751ffffff, 0x08312717572bfff, 0x9759279022b7fff, 0x75272b592328982,
        0x25a235375ffffff, 0x820852875a25fff, 0x9015a35373a2fff, 0x982921872a25752,
        0x135375fffffffff, 0x087071175ffffff, 0x903935537ffffff, 0x987597fffffffff,
        0x5845a8ab8ffffff, 0x5045b05abb30fff, 0x01984a8aba45fff, 0xab4a45b34941314,
        0x2512852b8458fff, 0x04b0b345b2b151b, 0x0250592b5458b85, 0x9452b3fffffffff,
        0x25a352345384fff, 0x5a2524420ffffff, 0x3a235a385458019, 0x5a2524192942fff,
        0x845853351ffffff, 0x045105fffffffff, 0x845853905035fff, 0x945ffffffffffff,
        0x4b749b9abffffff, 0x0834979b79abfff, 0x1ab1b414074bfff, 0x3143481a474bab4,
        0x4b79b492b912fff, 0x9749b791b2b1083, 0xb74b42240ffffff, 0xb74b42834324fff,
        0x29a279237749fff, 0x9a7974a27870207, 0x37a3a274a1a040a, 0x1a2874fffffffff,
        0x491417713ffffff, 0x491417081871fff, 0x403743fffffffff, 0x487ffffffffffff,
        0x9a8ab8fffffffff, 0x30939bb9affffff, 0x01a0a88abffffff, 0x31ab3afffffffff,
        0x12b1b99b8ffffff, 0x30939b1292b9fff, 0x02b80bfffffffff, 0x32bffffffffffff,
        0x23828aa89ffffff, 0x9a2092fffffffff, 0x23828a0181a8fff, 0x1a2ffffffffffff,
        0x138918fffffffff, 0x091ffffffffffff, 0x038ffffffffffff, 0xfffffffffffffff,
    };

    fn lerpVert(chunk: *Chunk, world: World, l: zm.Vec, r: zm.Vec, offset: zm.Vec) zm.Vec {
        const EPS = 1e-5;
        const BUMPY = false;
        const MODE = enum {
            primitive,
            risky,
            complex,
        }.complex;
        switch (MODE) {
            .primitive => return (l + r) / zm.f32x4s(2),
            .risky => {
                const sample_l = densityFromPos(chunk, world, l, offset, null, null).?;
                const sample_r = densityFromPos(chunk, world, r, offset, null, null).?;
                const sample_diff = sample_r - sample_l;
                if (@abs(sample_l) < EPS) return l;
                if (@abs(sample_r) < EPS) return r;
                if (@abs(sample_diff) < EPS) return l;
                return l + (l - r) * switch (BUMPY) {
                    true => zm.f32x4s(-sample_r / sample_diff),
                    false => zm.f32x4s(sample_l / sample_diff),
                };
            },
            .complex => {
                // Determine if l is 'less' than r
                var less = false;
                for (0..3) |d| {
                    if (l[d] != r[d]) {
                        less = l[d] < r[d];
                        break;
                    }
                }
                const a = if (less) l else r;
                const b = if (less) r else l;
                const sample_a = densityFromPos(chunk, world, a, offset, null, null).?;
                const sample_b = densityFromPos(chunk, world, b, offset, null, null).?;
                const sample_diff = sample_b - sample_a;

                var result = a;
                if (@abs(sample_diff) > EPS) {
                    result += (a - b) * switch (BUMPY) {
                        false => zm.f32x4s(sample_a / sample_diff),
                        true => zm.f32x4s(-sample_b / sample_diff),
                    };
                }
                return result;
            },
        }
    }

    pub fn gen(chunk: *Chunk, world: World, noise: znoise.FnlGenerator, pos: zm.Vec, offset: zm.Vec) !void {
        var corners: [8]zm.Vec = undefined;
        var config: u8 = 0;
        for (0..corners.len) |i| {
            corners[i] = pos + zm.f32x4(
                if ((i + 1) / 2 % 2 > 0) 1 else 0,
                if (i / 4 > 0) 1 else 0,
                if (i / 2 % 2 > 0) 1 else 0,
                0,
            );
            if (empty(chunk, world, corners[i], offset, false, null).?) continue;
            config |= @as(u8, 1) << @intCast(i);
        }

        const AVG_COLOUR = true;
        var tri_verts: [3]zm.Vec = undefined;

        for (0..15) |i| {
            const v = triTable[config] >> (14 - @as(u6, @intCast(i))) * 4 & 0xf;
            if (v == 0xf) break;
            const other = @as(u64, 0o123056744567) >> // Octal
                (11 - @as(u6, @intCast(v))) * 3 & 7;
            const vert = lerpVert(chunk, world, corners[v % 8], corners[other], offset);
            tri_verts[i % tri_verts.len] = vert;
            if (1 + i % tri_verts.len == tri_verts.len) {
                // Sample colour at the average vertex
                var avg = zm.f32x4s(0);
                for (tri_verts) |t| avg += t;
                avg /= @splat(tri_verts.len);
                const avg_colour = sampleColour(avg + offset, noise);
                // Calculate (flat) normal vector TODO try smooth normals
                const norm = zm.cross3(tri_verts[0] - tri_verts[1], tri_verts[1] - tri_verts[2]);
                for (tri_verts) |t| {
                    try chunk.surface.?.appendSlice(&zm.vecToArr3(t));
                    try appendColour(chunk, zm.f32x4s(0)); // Padding
                    try chunk.surface.?.appendSlice(&zm.vecToArr3(norm));
                    const vert_colour = sampleColour(t + offset, noise);
                    try appendColour(chunk, if (AVG_COLOUR) avg_colour else vert_colour);
                }
            }
        }
    }
};

fn sampleColour(pos: zm.Vec, noise: znoise.FnlGenerator) zm.Vec {
    var colour = zm.f32x4s(0);
    for (0..3) |c| {
        var c_pos = pos;
        c_pos[c] += Chunk.SIZE * 99;
        colour[c] += (noise.noise3(c_pos[0], c_pos[1], c_pos[2]) + 1) / 2;
    }
    return colour;
}

fn appendColour(chunk: *Chunk, colour: zm.Vec) !void {
    const c: @Vector(4, u8) = @intFromFloat(zm.f32x4s(255.999) * colour);
    try chunk.surface.?.append(@bitCast(c));
}

pub fn full(
    chunk: *Chunk,
    world: World,
    pos: zm.Vec,
    offset: zm.Vec,
    occ: bool,
    splits: ?zm.Vec,
) ?bool {
    if (densityFromPos(chunk, world, pos, offset, occ, splits)) |d| {
        return d > 0;
    } else {
        return null;
    }
}

pub fn empty(
    chunk: *Chunk,
    world: World,
    pos: zm.Vec,
    offset: zm.Vec,
    occ: bool,
    splits: ?zm.Vec,
) ?bool {
    return if (full(chunk, world, pos, offset, occ, splits)) |e| !e else null;
}

pub fn densityFromPos(
    chunk: *Chunk,
    world: World,
    pos: zm.Vec,
    offset: zm.Vec,
    occ: ?bool,
    splits: ?zm.Vec,
) ?f32 {
    const spl = splits orelse chunk.splits_copy.?;
    if (densityLocal(chunk, pos)) |d| return d;
    if (chunk.wip_mip != 0 and occ == false) return 0;
    const i = world.indexFromOffset(pos + offset, spl) catch unreachable;
    const off = world.offsetFromIndex(i, spl);
    return densityFromPos(&world.chunks[i], world, pos + offset - off, off, occ, spl);
}

fn densityLocal(chunk: *Chunk, pos: zm.Vec) ?f32 {
    return chunk.density[chunk.indexFromPos(pos) catch return null];
}
