// The planet tile cache's lookup in MSL (track E1): a figure direction to
// its cube face and face coordinates, the finest resident tile there
// through the indirection texture (and the deep table past its levels),
// and the atlas coordinates inside that tile's borders. It mirrors
// CubeSphere.faceCoordinates, TileKey.id and PlanetTileIndirection.lookup
// (OrbitCore, OrbitScene), which the GPU tests hold it to.
//
// E2's planet shader includes the header (`ShaderHeader.planetTileCommon`)
// and binds a layer as PlanetTileCache.bind does: its atlas
// (texture2d_array<float>), indirection (texture2d_array<uint>), deep
// table (device uint4 *) and PlanetTileLayer uniforms.
let planetTileCommonSource = #"""
// ------------------------------------------------------- planet tiles (E1) ---

struct PlanetTileLayer {
    float4 atlas;     // x: tile size n, y: border b, z: n + 2b, w: the atlas's deepest mip
    int4 levels;      // x: the layer's deepest level, y: the indirection texture's,
                      // z: the deep table's mask (capacity - 1), w: its longest probe
    float4 value;     // x: scale, y: offset (raw layers: value = sample × scale + offset),
                      // z: 1 when the layer is live, w: 1 for colour (sRGB atlas)
};

struct PlanetTileHit {
    uint slot;        // atlas slice
    int level;        // the tile's level
    float2 local;     // tile-local (u, v), 0...1 inside its edges
    float2 st;        // atlas coordinates, inside the borders
    float scale;      // d(st)/d(face uv): 2^level · n / (n + 2b)
    bool found;
};

// Per face: its outward normal, then the directions u and v increase along
// (CubeSphere.Face: posX, posY, negX, negY, posZ, negZ).
constant float3 PLANET_TILE_AXES[18] = {
    float3( 1, 0, 0), float3( 0, 1, 0), float3( 0, 0, 1),
    float3( 0, 1, 0), float3(-1, 0, 0), float3( 0, 0, 1),
    float3(-1, 0, 0), float3( 0,-1, 0), float3( 0, 0, 1),
    float3( 0,-1, 0), float3( 1, 0, 0), float3( 0, 0, 1),
    float3( 0, 0, 1), float3( 0, 1, 0), float3(-1, 0, 0),
    float3( 0, 0,-1), float3( 0, 1, 0), float3( 1, 0, 0),
};

// The face whose cone holds d (any non-zero vector) and its face
// coordinates there: gnomonic, each axis warped by (4/π) atan.
inline uint planet_tile_face(float3 d, thread float2 &uv) {
    float3 a = abs(d);
    uint face;
    if (a.x >= a.y && a.x >= a.z) { face = d.x >= 0.0 ? 0u : 2u; }
    else if (a.y >= a.z) { face = d.y >= 0.0 ? 1u : 3u; }
    else { face = d.z >= 0.0 ? 4u : 5u; }
    float3 n = PLANET_TILE_AXES[3 * face], u = PLANET_TILE_AXES[3 * face + 1], v = PLANET_TILE_AXES[3 * face + 2];
    float2 ab = float2(dot(d, u), dot(d, v)) / dot(d, n);
    uv = clamp((atan(ab) * (4.0 / M_PI_F) + 1.0) * 0.5, 0.0, 1.0);
    return face;
}

// The change in face coordinates for a change dd of the direction d, on
// face `face`: for screen derivatives, so the hardware filters each tile
// with the true (anisotropic) footprint and nothing jumps at tile edges.
inline float2 planet_tile_uv_delta(uint face, float3 d, float3 dd) {
    float3 n = PLANET_TILE_AXES[3 * face], u = PLANET_TILE_AXES[3 * face + 1], v = PLANET_TILE_AXES[3 * face + 2];
    float k = dot(d, n);
    float2 ab = float2(dot(d, u), dot(d, v)) / k;
    float2 dab = (float2(dot(dd, u), dot(dd, v)) - ab * dot(dd, n)) / k;
    return dab * (2.0 / M_PI_F) / (1.0 + ab * ab);
}

// The level whose texels match a pixel's footprint (its face-coordinate
// derivatives), allowing 8× anisotropy, plus `bias` levels.
inline int planet_tile_level(constant PlanetTileLayer &layer, float2 duvdx, float2 duvdy, float bias) {
    float n = layer.atlas.x;
    float lx = length(duvdx) * n, ly = length(duvdy) * n;
    float f = max(min(lx, ly), max(lx, ly) / 8.0);
    float l = -log2(max(f, 1e-12)) + bias;
    return int(clamp(floor(l), 0.0, float(layer.levels.x)));
}

// TileHashTable.home: MurmurHash3's finaliser of the id's two halves.
inline uint planet_tile_home(uint lo, uint hi) {
    uint h = lo ^ (hi * 0x9E3779B1u);
    h ^= h >> 16; h *= 0x85EBCA6Bu;
    h ^= h >> 13; h *= 0xC2B2AE35u;
    h ^= h >> 16;
    return h;
}

// The finest resident tile at `level` or coarser holding face coordinates
// uv on `face`: the deep table from `level` up to the texture's deepest
// level, then the indirection texture (mip = its deepest level - level).
inline PlanetTileHit planet_tile_find(texture2d_array<uint, access::read> indirection, const device uint4 *deep,
                                      constant PlanetTileLayer &layer, uint face, float2 uv, int level) {
    PlanetTileHit h;
    h.found = false; h.slot = 0; h.level = 0; h.local = float2(0.0); h.st = float2(0.0); h.scale = 0.0;
    int l = clamp(level, 0, layer.levels.x);
    int top = layer.levels.y;
    uint entry = 0;
    uint mask = uint(layer.levels.z);
    while (l > top && entry == 0) {
        uint side = 1u << uint(l);
        uint2 t = min(uint2(uv * float(side)), uint2(side - 1u));
        uint lo = t.x | (t.y << 27), hi = (t.y >> 5) | (uint(l) << 23) | (face << 28);
        uint i = planet_tile_home(lo, hi) & mask;
        for (int k = 0; k <= layer.levels.w; k++) {
            uint4 b = deep[i];
            if (b.x == 0xFFFFFFFFu && b.y == 0xFFFFFFFFu) { break; }
            if (b.x == lo && b.y == hi) { entry = b.z; break; }
            i = (i + 1u) & mask;
        }
        if (entry == 0) { l--; }
    }
    if (entry == 0) {
        int lt = min(l, top);
        uint side = 1u << uint(lt);
        uint2 t = min(uint2(uv * float(side)), uint2(side - 1u));
        entry = indirection.read(t, face, uint(top - lt)).x;
    }
    if ((entry >> 31) == 0) { return h; }
    h.slot = entry & 0xFFFFu;
    h.level = int((entry >> 16) & 31u);
    float side = float(1u << uint(h.level));
    float2 g = uv * side;
    float2 t = min(floor(g), float2(side - 1.0));
    h.local = g - t;
    float n = layer.atlas.x, b = layer.atlas.y, m = layer.atlas.z;
    h.st = (h.local * n + b) / m;
    h.scale = side * n / m;
    h.found = true;
    return h;
}

// The tile's texels at h, filtered for a pixel whose face coordinates
// change by duvdx and duvdy (planet_tile_uv_delta).
inline float4 planet_tile_sample(texture2d_array<float> atlas, sampler smp, PlanetTileHit h, float2 duvdx, float2 duvdy) {
    return atlas.sample(smp, h.st, h.slot, gradient2d(duvdx * h.scale, duvdy * h.scale));
}

// The same at an explicit mip (compute, or no derivatives).
inline float4 planet_tile_sample_level(texture2d_array<float> atlas, sampler smp, PlanetTileHit h, float lod) {
    return atlas.sample(smp, h.st, h.slot, level(min(lod, 16.0)));
}
"""#

// Probes for the GPU tests: each probe's direction (xyz) and level (w)
// through the lookup, returning what it found and the texel there.
let planetTileProbeSource = #"""
kernel void planet_tile_probe(const device float4 *probes [[buffer(0)]],
                              device float4 *values [[buffer(1)]],
                              device uint4 *hits [[buffer(2)]],
                              constant PlanetTileLayer &layer [[buffer(3)]],
                              const device uint4 *deep [[buffer(4)]],
                              constant uint &count [[buffer(5)]],
                              texture2d_array<float> atlas [[texture(0)]],
                              texture2d_array<uint, access::read> indirection [[texture(1)]],
                              sampler smp [[sampler(0)]],
                              uint id [[thread_position_in_grid]]) {
    if (id >= count) { return; }
    float4 p = probes[id];
    float2 uv;
    uint face = planet_tile_face(normalize(p.xyz), uv);
    PlanetTileHit h = planet_tile_find(indirection, deep, layer, face, uv, int(p.w));
    hits[id] = uint4(h.found ? 1u : 0u, h.slot, uint(h.level), face);
    values[id] = h.found ? planet_tile_sample_level(atlas, smp, h, 0.0) : float4(-1.0);
}
"""#

extension ShaderHeader {
    /// The tile lookup, for any module that samples a planet tile layer.
    public static let planetTileCommon = ShaderHeader(name: "PlanetTileCommon", source: planetTileCommonSource)
}

// E2 replaces: E1's albedo hook. The planet module with the tile store:
// planetShaderSource (E2's, unchanged) with the tile arguments added after
// its sampler and the tile lookup before its grid, so the plain `.planet`
// module, which every draw without tiles uses, is exactly what it was. If
// the planet shader no longer has those anchors the module carries an
// #error: ShaderCompileTests says so, and the Earth keeps its fallback look.
let planetTiledShaderSource: String = {
    let arguments = "                                       sampler smp [[sampler(0)]],\n"
    let lookup = "    if (u.options.x > 0.5) {"
    guard planetShaderSource.contains(arguments), planetShaderSource.contains(lookup) else {
        return "#error \"E1's tile hook: planet_fragment's anchors moved (PlanetTileShaders.swift)\"\n"
    }
    return planetShaderSource
        .replacingOccurrences(of: arguments, with: arguments + """
                                       texture2d_array<float> tileAtlas [[texture(5)]],
                                       texture2d_array<uint, access::read> tileIndirection [[texture(6)]],
                                       const device uint4 *tileDeep [[buffer(1)]],
                                       constant PlanetTileLayer &tileLayer [[buffer(2)]],
                                       sampler tileSampler [[sampler(1)]],

        """)
        .replacingOccurrences(of: lookup, with: """
            {
                // E1's albedo tiles at the hit's figure direction, filtered
                // by its screen footprint.
                float3 dirF = normalize(p);
                float2 uv;
                uint face = planet_tile_face(dirF, uv);
                float2 dx = planet_tile_uv_delta(face, dirF, dfdx(dirF)), dy = planet_tile_uv_delta(face, dirF, dfdy(dirF));
                PlanetTileHit tile = planet_tile_find(tileIndirection, tileDeep, tileLayer, face, uv,
                                                      planet_tile_level(tileLayer, dx, dy, 0.0));
                if (tile.found) { albedo = planet_tile_sample(tileAtlas, tileSampler, tile, dx, dy).rgb; }
            }

        """ + lookup)
}()

extension ShaderModule {
    /// E2 replaces: the planet shader with E1's albedo tiles, for the tiled Earth.
    public static let planetTiled = ShaderModule(name: "PlanetTiled",
                                                 headers: [.shadowCommon, .atmosphereCommon, .cloudShadow, .planetTileCommon],
                                                 source: planetTiledShaderSource)

    /// The tile lookup's probe kernel (the GPU tests, `PlanetTileCache.probe`).
    public static let planetTiles = ShaderModule(name: "PlanetTiles", headers: [.planetTileCommon],
                                                 source: planetTileProbeSource)
}
