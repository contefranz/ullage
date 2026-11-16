// The environment probe: the cube faces, GGX prefiltering, irradiance and SH9 (track R3 owns this module), and the
// SH9 header the plumes and particles read (`.sphericalHarmonics`). OrbitScene's `EnvironmentProbe` and `SH9` are the
// Swift reference of every function here.

// What other modules read from the probe: SH9 and the night floor. A module
// adds `.sphericalHarmonics` to its headers (after ShaderCommon).
let sphericalHarmonicsSource = #"""
// ------------------------------------------------- spherical harmonics ---
//
// LightingUniforms.sh9 (buffer 29), written by R3's probe before P1, valid
// while lighting.probe.w > 0.5 (zero otherwise): rgb the coefficients of
// E(n)/pi, the luminance of a white Lambertian surface facing n (cd/m2,
// linear Rec. 709, NOT pre-exposed: multiply by FrameUniforms.exposure.x
// when writing), the Sun excluded (it is the analytic light), the night floor
// excluded (orbit_probeNightFloor). Real SH in world (ICRF) axes, n toward
// the light, in the order (0,0) (1,-1) (1,0) (1,1) (2,-2) (2,-1) (2,0) (2,1)
// (2,2): 0.282095, 0.488603 (y, z, x), 1.092548 xy, 1.092548 yz,
// 0.315392 (3z^2 - 1), 1.092548 xz, 0.546274 (x^2 - y^2). The radiance's own
// coefficients are these times 1, 3/2 and 4 for bands 0, 1 and 2
// (Ramamoorthi and Hanrahan's A_l/pi = 1, 2/3, 1/4).

// E(n)/pi, cd/m2, at the unit n: Lambertian ambient. Clamped at 0.
inline float3 orbit_sh9Irradiance(constant LightingUniforms &l, float3 n) {
    float x = n.x, y = n.y, z = n.z;
    float3 e = l.sh9[0].rgb * 0.282095
        + (l.sh9[1].rgb * y + l.sh9[2].rgb * z + l.sh9[3].rgb * x) * 0.488603
        + l.sh9[4].rgb * (1.092548 * x * y) + l.sh9[5].rgb * (1.092548 * y * z)
        + l.sh9[6].rgb * (0.315392 * (3.0 * z * z - 1.0)) + l.sh9[7].rgb * (1.092548 * x * z)
        + l.sh9[8].rgb * (0.546274 * (x * x - y * y));
    return max(e, float3(0.0));
}

// The radiance a medium scatters toward the eye per unit albedo, cd/m2:
// integral L(w) p(w.v) dw with Henyey-Greenstein's phase of asymmetry g, v
// the unit view ray (camera to the point). By Funk and Hecke,
// sum g^l L_lm Y_lm(v); g = 0 is the mean radiance. Clamped at 0.
inline float3 orbit_sh9InScatter(constant LightingUniforms &l, float3 v, float g) {
    float x = v.x, y = v.y, z = v.z;
    float g1 = 1.5 * g, g2 = 4.0 * g * g;
    float3 s = l.sh9[0].rgb * 0.282095
        + (l.sh9[1].rgb * y + l.sh9[2].rgb * z + l.sh9[3].rgb * x) * (0.488603 * g1)
        + (l.sh9[4].rgb * (1.092548 * x * y) + l.sh9[5].rgb * (1.092548 * y * z)
           + l.sh9[6].rgb * (0.315392 * (3.0 * z * z - 1.0)) + l.sh9[7].rgb * (1.092548 * x * z)
           + l.sh9[8].rgb * (0.546274 * (x * x - y * y))) * g2;
    return max(s, float3(0.0));
}

// The mean radiance over the sphere, (1/4 pi) integral L dw, cd/m2: an
// isotropic scatterer's light per unit albedo.
inline float3 orbit_sh9MeanRadiance(constant LightingUniforms &l) {
    return max(l.sh9[0].rgb * 0.282095, float3(0.0));
}

// The night floor (lighting.ambient.rgb: E/pi in cd/m2 a white surface shows
// at a fixed share of the exposure's white) merged into x (an E/pi or a
// radiance) as a soft maximum, x + f^2/(x + f): it lifts only what is darker
// than it. EnvironmentProbe.floored.
inline float3 orbit_probeNightFloor(float3 x, constant LightingUniforms &l) {
    float3 f = max(l.ambient.rgb, float3(0.0));
    return x + f * f / (max(x, float3(0.0)) + max(f, float3(1e-30)));
}
"""#

let probeShaderSource = #"""
// ------------------------------------------------------------- probe ---

#define PROBE_PI 3.14159265358979

// Metal's (OpenGL's) cube convention (EnvironmentProbe.direction): face
// coordinates s rightwards, t downwards, each in -1..1.
inline float3 probe_direction(uint face, float s, float t) {
    switch (face) {
        case 0: return float3(1.0, -t, -s);
        case 1: return float3(-1.0, -t, s);
        case 2: return float3(s, 1.0, t);
        case 3: return float3(s, -1.0, -t);
        case 4: return float3(s, -t, 1.0);
        default: return float3(-s, -t, -1.0);
    }
}

inline float3 probe_texelDirection(uint2 xy, uint face, float size) {
    float2 st = (float2(xy) + 0.5) / size * 2.0 - 1.0;
    return normalize(probe_direction(face, st.x, st.y));
}

// Radiance as the cube stores it, R1's rule per channel: NaN and -inf are
// no light, +inf saturates, the rest is clamped to [0, 6e4], below half
// float's overflow. The bit test comes before any min(), which would turn a
// NaN into its other argument.
inline float probe_cleanChannel(float x) {
    uint b = as_type<uint>(x);
    if ((b & 0x7f800000u) == 0x7f800000u) { return (b & 0x807fffffu) == 0u ? 60000.0 : 0.0; }
    return clamp(x, 0.0, 60000.0);
}
inline float4 probe_clean(float3 c) {
    return float4(probe_cleanChannel(c.r), probe_cleanChannel(c.g), probe_cleanChannel(c.b), 1.0);
}

// The faces as drawn, cleaned in place before their mips and the derived
// maps read them: the fixed-function blends that build a face (A2's sky over
// the ground, the clouds over both) add terms each below 6e4, so a sum can
// pass half float's 65504 and be stored as +inf, which would spread through
// every mip, the irradiance and SH9.
kernel void probe_cleanFaces(texture2d_array<float, access::read_write> faces [[texture(0)]],
                             uint3 gid [[thread_position_in_grid]]) {
    uint n = faces.get_width();
    if (gid.x >= n || gid.y >= n || gid.z >= 6u) { return; }
    faces.write(probe_clean(faces.read(gid.xy, gid.z).rgb), gid.xy, gid.z);
}

// ------------------------------------------ the look-dev environments ---

struct ProbeLookDev {
    float4 kind;          // x: 1 furnace, 2 Earth below, 3 the same lit evenly
    float4 radiance;      // rgb: the furnace's (cd/m2)
    float4 body;          // xyz: unit, to the body's centre; w: sin^2 of its angular radius
    float4 reflectance;   // rgb: the ground's, albedo x colour / pi (per lux)
    float4 toSun;         // xyz: unit
    float4 sun;           // rgb: the Sun's illuminance (lux)
};

// EnvironmentProbe.LookDevEnvironment.radiance, into the radiance cube's mip 0.
kernel void probe_lookDev(texture2d_array<float, access::write> out [[texture(0)]],
                          constant ProbeLookDev &u [[buffer(0)]],
                          uint3 gid [[thread_position_in_grid]]) {
    uint n = out.get_width();
    if (gid.x >= n || gid.y >= n || gid.z >= 6u) { return; }
    float3 d = probe_texelDirection(gid.xy, gid.z, float(n));
    float3 radiance = float3(0.0);
    if (u.kind.x < 1.5) {
        radiance = u.radiance.rgb;
    } else if (u.body.w > 0.0) {
        float r = rsqrt(u.body.w);
        float b = dot(d, u.body.xyz) * r;
        float disc = b * b - (r * r - 1.0);
        if (disc >= 0.0 && b > 0.0) {
            float t = b - sqrt(disc);
            float3 normal = normalize(d * t - u.body.xyz * r);
            float cosine = u.kind.x > 2.5 ? 1.0 : max(dot(normal, u.toSun.xyz), 0.0);
            radiance = u.reflectance.rgb * u.sun.rgb * cosine;
        }
    }
    out.write(probe_clean(radiance), gid.xy, gid.z);
}

// ------------------------------------------------- GGX prefiltering ---

struct ProbePrefilter {
    float4 params;        // x: alpha, y: samples, z: the source's face size (mip 0), w: the source's mips
    float4 lod;           // x: the lod's bias (Krivanek and Colbert's 1), y: the coarsest source mip read
};

inline float2 probe_hammersley(uint i, uint n) {
    return float2((float(i) + 0.5) / float(n), float(reverse_bits(i)) * 2.3283064365386963e-10);
}

// One mip of the specular cube: Karis' (2013) split-sum prefilter with
// n = v = r, sum L(l) n.l / sum n.l over GGX-sampled half vectors, each
// sample reading the source mip its solid angle covers (Krivanek and
// Colbert 2008: lod = log2(Omega_s / Omega_p) / 2 + bias). Its limit is
// EnvironmentProbe.prefilterReference. A SIMD group of 32 per texel, each
// lane a 32nd of the samples (the grid is 32 wide per texel): the loop is
// short, so the few texels of the rough mips do not wait on it.
kernel void probe_prefilter(texturecube<float> source [[texture(0)]],
                            texture2d_array<float, access::write> out [[texture(1)]],
                            constant ProbePrefilter &u [[buffer(0)]],
                            uint3 gid [[thread_position_in_grid]],
                            uint lane [[thread_index_in_simdgroup]]) {
    constexpr sampler trilinear(filter::linear, mip_filter::linear, address::clamp_to_edge);
    uint n = out.get_width();
    uint2 xy = uint2(gid.x / 32u, gid.y);
    float3 normal = probe_texelDirection(xy, gid.z, float(n));
    float alpha = u.params.x, a2 = alpha * alpha;
    uint count = max(uint(u.params.y), 1u);
    float3 up = abs(normal.z) < 0.999 ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0);
    float3 tx = normalize(cross(up, normal)), ty = cross(normal, tx);
    float texel = 4.0 * PROBE_PI / (6.0 * u.params.z * u.params.z);
    float maxLod = clamp(u.lod.y, 0.0, max(u.params.w - 1.0, 0.0));
    float3 sum = float3(0.0);
    float weight = 0.0;
    for (uint i = lane; i < count; i += 32u) {
        float2 xi = probe_hammersley(i, count);
        float phi = 2.0 * PROBE_PI * xi.x;
        float cosT = sqrt((1.0 - xi.y) / (1.0 + (a2 - 1.0) * xi.y));
        float sinT = sqrt(max(1.0 - cosT * cosT, 0.0));
        float3 h = tx * (sinT * cos(phi)) + ty * (sinT * sin(phi)) + normal * cosT;
        float3 l = 2.0 * cosT * h - normal;
        float nl = dot(normal, l);
        if (nl <= 0.0) { continue; }
        float d = cosT * cosT * (a2 - 1.0) + 1.0;
        float pdf = a2 / (PROBE_PI * d * d) * 0.25;   // D (n.h) / (4 v.h), n.h = v.h
        float lod = clamp(0.5 * log2(1.0 / (float(count) * pdf * texel + 1e-12)) + u.lod.x, 0.0, maxLod);
        sum += source.sample(trilinear, l, level(lod)).rgb * nl;
        weight += nl;
    }
    sum = simd_sum(sum);
    weight = simd_sum(weight);
    if (lane == 0u && xy.x < n && xy.y < n) {
        out.write(probe_clean(weight > 0.0 ? sum / weight : float3(0.0)), xy, gid.z);
    }
}

// ---------------------------------------------- irradiance and SH9 ---

// The source texels (a 32^2 downsample): xyz their direction, w their solid
// angle (EnvironmentProbe.texels), face by face, row by row.

// The irradiance cube: E/pi = (1/pi) sum L max(0, n.l) Omega over every
// source texel, by brute force (EnvironmentProbe.irradianceReference):
// exact, without SH's ringing at the terminator. A threadgroup of 256 holds
// one row of 16 texels of one face, 16 threads to a texel each taking a
// sixteenth of every chunk of 256 source texels, which the group loads into
// threadgroup memory once (96 groups, each source texel read 96 times).
#define PROBE_IRRADIANCE_CHUNK 256u
kernel void probe_irradiance(texture2d_array<float> source [[texture(0)]],
                             texture2d_array<float, access::write> out [[texture(1)]],
                             const device float4 *texels [[buffer(0)]],
                             uint3 group [[threadgroup_position_in_grid]],
                             uint ti [[thread_index_in_threadgroup]]) {
    threadgroup float4 directions[PROBE_IRRADIANCE_CHUNK];
    threadgroup float4 radiance[PROBE_IRRADIANCE_CHUNK];
    threadgroup float3 partial[16][16];
    uint n = out.get_width(), m = source.get_width();
    uint perFace = m * m, total = 6u * perFace;
    uint o = ti % 16u, q = ti / 16u;
    uint2 xy = uint2(o, group.y);
    float3 normal = probe_texelDirection(xy, group.z, float(n));
    float3 e = float3(0.0);
    for (uint base = 0; base < total; base += PROBE_IRRADIANCE_CHUNK) {
        uint k = base + ti;
        if (k < total) {
            uint face = k / perFace, r = k - face * perFace;
            directions[ti] = texels[k];
            radiance[ti] = source.read(uint2(r % m, r / m), face);
        } else {
            directions[ti] = float4(0.0);
            radiance[ti] = float4(0.0);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint j = q * 16u; j < q * 16u + 16u; j++) {
            float4 t = directions[j];
            e += radiance[j].rgb * (max(dot(normal, t.xyz), 0.0) * t.w);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    partial[q][o] = e;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (q == 0u && xy.x < n && xy.y < n) {
        float3 s = float3(0.0);
        for (uint k = 0; k < 16u; k++) { s += partial[k][o]; }
        out.write(probe_clean(s / PROBE_PI), xy, group.z);
    }
}

// SH9 of the same source in one threadgroup: L_lm = sum L Y_lm Omega, then
// the published E/pi coefficients A_l/pi L_lm (SH9.irradianceOverPi), into
// nine float4 (rgb, w = 0) that the probe pass copies into LightingUniforms.
kernel void probe_sh9(texture2d_array<float> source [[texture(0)]],
                      const device float4 *texels [[buffer(0)]],
                      device float4 *out [[buffer(1)]],
                      uint ti [[thread_index_in_threadgroup]],
                      uint threads [[threads_per_threadgroup]],
                      uint si [[simdgroup_index_in_threadgroup]],
                      uint li [[thread_index_in_simdgroup]],
                      uint simdgroups [[simdgroups_per_threadgroup]]) {
    threadgroup float3 partial[32][9];
    uint m = source.get_width(), perFace = m * m, total = 6u * perFace;
    float3 c[9];
    for (uint i = 0; i < 9u; i++) { c[i] = float3(0.0); }
    for (uint k = ti; k < total; k += threads) {
        float4 t = texels[k];
        uint face = k / perFace, r = k - face * perFace;
        float3 l = source.read(uint2(r % m, r / m), face).rgb * t.w;
        float x = t.x, y = t.y, z = t.z;
        c[0] += l * 0.282095;
        c[1] += l * (0.488603 * y);
        c[2] += l * (0.488603 * z);
        c[3] += l * (0.488603 * x);
        c[4] += l * (1.092548 * x * y);
        c[5] += l * (1.092548 * y * z);
        c[6] += l * (0.315392 * (3.0 * z * z - 1.0));
        c[7] += l * (1.092548 * x * z);
        c[8] += l * (0.546274 * (x * x - y * y));
    }
    for (uint i = 0; i < 9u; i++) {
        float3 s = simd_sum(c[i]);
        if (li == 0u) { partial[si][i] = s; }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (ti < 9u) {
        float3 s = float3(0.0);
        for (uint g = 0; g < simdgroups; g++) { s += partial[g][ti]; }
        float band = ti == 0u ? 1.0 : (ti < 4u ? 2.0 / 3.0 : 0.25);
        float3 v = s * band;
        out[ti] = float4(orbit_isNotFinite(v) ? float3(0.0) : v, 0.0);
    }
}
"""#

extension ShaderHeader {
    /// SH9 and the night floor for the modules that light with the probe's
    /// low frequencies (plumes, particles): `orbit_sh9Irradiance`,
    /// `orbit_sh9InScatter`, `orbit_sh9MeanRadiance`, `orbit_probeNightFloor`.
    public static let sphericalHarmonics = ShaderHeader(name: "SphericalHarmonics", source: sphericalHarmonicsSource)
}

extension ShaderModule {
    public static let probe = ShaderModule(name: "Probe", headers: [.sphericalHarmonics], source: probeShaderSource)
}
