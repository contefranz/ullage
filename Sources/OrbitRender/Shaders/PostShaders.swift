// Post (track R1 owns this module): the resolve's per-sample encoding, the
// first downsample with the luminance histogram, the bloom pyramid, the
// Sun's visibility, and the tone map with its dither into the output.
let postShaderSource = #"""
// -------------------------------------------------------------- post ---

constexpr sampler post_linear(filter::linear, address::clamp_to_edge);

#define POST_HISTOGRAM_BINS 256
#define POST_HISTOGRAM_DARK 256      // the weight too dark to count
#define POST_HISTOGRAM_SUN 257       // the Sun's visible samples, of 64
#define POST_FP16_MAX 60000.0

struct PostUniforms {
    float4 size;        // xy: destination size (px), zw: source size (px)
    float4 params;      // x: bloom mix of the level below (upsample), zw: the histogram's EV100 range
    float4 glare;       // x: k E⊙ (cd/m² at 1 rad), y: its share (0 off), z: its smallest angle (rad)
    float4 sunView;     // xyz: unit vector to the Sun (view axes)
};

// The Sun's visibility probe: 64 directions over its disc.
#define POST_MAX_OCCULTERS 8
struct SunProbeUniforms {
    float4 sun;         // xyz: unit, camera -> Sun (world), w: angular radius (rad)
    float4 axisU;       // xyz: unit, across the disc
    float4 axisV;       // xyz: unit, across the disc
    float4 params;      // x: bodies in use, y: drawn depth nearer than this (m) occludes, z: 1 to probe
    float4 bodies[POST_MAX_OCCULTERS];  // xyz: unit direction to a body's centre (world), w: cos of its angular radius
};

struct ToneUniforms {
    float4 params;      // x: bloom share, y: exposure over pre-exposure, z: curve (0 AgX, 1 Neutral), w: 1 dither
    float4 glare;       // x: veiling glare constant (cd/m² per lux at 1 rad), y: its share (0 off), z: Sun angular radius (rad)
    float4 sunView;     // xyz: unit vector to the Sun (view axes)
    float4 sunColor;    // rgb: the Sun's illuminance (lux, linear Rec. 709)
    float4 output;      // x: 1 when the output is sRGB (store linear), 0 to encode here
    float4 lut;         // x: points per axis, y: log2 of the first, z: log2 of the last
    float4 bloom;       // x: the share of the level below in the bloom's top
};

struct PostVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex PostVertexOut post_fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    PostVertexOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

// ------------------------------------------------------------- resolve ---

// Light in, finite and below half float's overflow: NaN and -∞ are no
// light, +∞ (light past half float's range, which a shader that does not
// clamp writes) saturates.
static float post_cleanChannel(float x) {
    uint b = as_type<uint>(x);
    if ((b & 0x7f800000u) == 0x7f800000u) {
        return (b & 0x807fffffu) == 0u ? POST_FP16_MAX : 0.0;
    }
    return clamp(x, 0.0, POST_FP16_MAX);
}
static float3 post_clean(float3 c) {
    return float3(post_cleanChannel(c.r), post_cleanChannel(c.g), post_cleanChannel(c.b));
}

// The Sun's veiling glare along a view ray (view axes), per lux of its
// illuminance at 1 rad: 1/θ², θ no smaller than `minAngle` (the disc's
// diameter). The tone map adds it, and the meter counts it. θ² comes from
// its series in 1 - cos θ, without acos: 2(1 - c)(1 + (1 - c)/3), within
// 1 % to 20° and 8 % at 90°, where the veil is faint.
static float post_glare(float3 ray, float3 sunView, float minAngle) {
    float k = 1.0 - clamp(dot(normalize(ray), sunView), -1.0, 1.0);
    float theta2 = 2.0 * k * (1.0 + k / 3.0);
    return 1.0 / max(theta2, minAngle * minAngle);
}

// The last draw of the scene: each sample's light is weighted by 1 / (1 +
// its brightest channel) (Karis 2013), the weight kept in alpha, so the
// hardware resolve's average is the weighted mean sum(w c) / sum(w), which
// does not let one bright sample alias an edge. Every pass before it blends
// in linear light. NaN and overflow stop here.
fragment float4 post_resolve_encode(PostVertexOut in [[stage_in]], float4 c [[color(0)]],
                                    uint sampleIndex [[sample_id]]) {
    float3 v = post_clean(c.rgb);
    float w = 1.0 / (1.0 + max(v.r, max(v.g, v.b)));
    return float4(v * w, w);
}

// The resolved scene's light, pre-exposed.
static float3 post_decode(float4 e) {
    return post_clean(e.rgb / max(e.a, 1e-7));
}

// ---------------------------------------------------- downsample, histogram ---

static float post_luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

// Jimenez (2014) 13-tap downsample of `src` at the destination texel `gid`,
// from linear light, by bilinear taps at texel corners.
static float3 post_downsample13(texture2d<float> src, uint2 gid, float2 srcSize) {
    float2 c = (float2(gid) * 2.0 + 1.0) / srcSize;
    float2 t = 1.0 / srcSize;
    float3 s[13];
    const float2 o[13] = { float2(-2, -2), float2(0, -2), float2(2, -2), float2(-1, -1), float2(1, -1),
                           float2(-2, 0), float2(0, 0), float2(2, 0), float2(-1, 1), float2(1, 1),
                           float2(-2, 2), float2(0, 2), float2(2, 2) };
    for (int i = 0; i < 13; i++) {
        s[i] = post_clean(src.sample(post_linear, c + o[i] * t, level(0)).rgb);
    }
    return 0.125 * (s[3] + s[4] + s[8] + s[9])
         + 0.03125 * (s[0] + s[2] + s[10] + s[12]) + 0.0625 * (s[1] + s[5] + s[7] + s[11]) + 0.125 * s[6];
}

kernel void post_clear_histogram(device atomic_uint *histogram [[buffer(0)]], uint i [[thread_position_in_grid]]) {
    if (i < POST_HISTOGRAM_BINS + 2) { atomic_store_explicit(&histogram[i], 0u, memory_order_relaxed); }
}

// The first bloom level, at half resolution, from the resolved scene: the
// same kernel, but on texels each decoded before they are averaged (a
// bilinear tap of the weighted texels would be a weighted mean, which loses
// light at bright edges). Each output texel takes the 6×6 texels around its
// 2×2 with the weights the 13 taps give them, A_i A_j / 32 + C_i C_j / 128,
// A = (0 1 1 1 1 0), C = (1 1 2 2 1 1); so each source texel gives a
// quarter of its light to the level, and the pyramid conserves energy.
// Threadgroups of 16×16 share their 36×36 decoded texels.
#define POST_TILE 36
kernel void post_downsample_first(texture2d<float> hdr [[texture(0)]],
                                  texture2d<float, access::write> dst [[texture(1)]],
                                  constant PostUniforms &u [[buffer(1)]],
                                  uint2 gid [[thread_position_in_grid]],
                                  uint2 group [[threadgroup_position_in_grid]],
                                  uint lid [[thread_index_in_threadgroup]]) {
    threadgroup half4 tile[POST_TILE * POST_TILE];
    int2 origin = int2(group) * 32 - 2;
    int2 last = int2(hdr.get_width(), hdr.get_height()) - 1;
    for (uint i = lid; i < POST_TILE * POST_TILE; i += 256u) {
        int2 p = clamp(origin + int2(i % POST_TILE, i / POST_TILE), int2(0), last);
        tile[i] = half4(half3(post_decode(hdr.read(uint2(p)))), 1.0h);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (gid.x >= uint(u.size.x) || gid.y >= uint(u.size.y)) { return; }
    const float a[6] = { 0.0, 1.0, 1.0, 1.0, 1.0, 0.0 };
    const float c[6] = { 1.0, 1.0, 2.0, 2.0, 1.0, 1.0 };
    uint2 corner = (gid - group * 16u) * 2u;
    float3 sum = 0.0;
    for (int j = 0; j < 6; j++) {
        float3 ra = 0.0, rc = 0.0;
        for (int i = 0; i < 6; i++) {
            float3 t = float3(tile[(corner.y + j) * POST_TILE + corner.x + i].rgb);
            ra += a[i] * t;
            rc += c[i] * t;
        }
        sum += ra * (a[j] / 32.0) + rc * (c[j] / 128.0);
    }
    dst.write(float4(sum, 1.0), gid);
}

// The luminance histogram, centre-weighted, in EV100 bins, of a bloom level
// at an eighth of the resolution: a meter of zones, in which stars and
// other points spread below the darkest bin and only extended light counts.
// It counts the Sun's veiling glare as the tone map will add it (the
// visibility probe runs first), so that the glare cannot white out a frame
// the meter thought dark.
kernel void post_histogram(texture2d<float> src [[texture(0)]],
                           device atomic_uint *histogram [[buffer(0)]],
                           constant PostUniforms &u [[buffer(1)]],
                           constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]],
                           uint2 gid [[thread_position_in_grid]],
                           uint lid [[thread_index_in_threadgroup]],
                           uint2 tgSize [[threads_per_threadgroup]]) {
    threadgroup atomic_uint local[POST_HISTOGRAM_BINS + 1];
    uint threads = tgSize.x * tgSize.y;
    for (uint i = lid; i < POST_HISTOGRAM_BINS + 1; i += threads) {
        atomic_store_explicit(&local[i], 0u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float2 size = float2(src.get_width(), src.get_height());
    if (gid.x < uint(size.x) && gid.y < uint(size.y)) {
        float3 c = post_clean(src.read(gid).rgb);
        // Centre weighting: 1 at the corners, 4 at the centre.
        float2 p = (float2(gid) + 0.5) / size * 2.0 - 1.0;
        uint w = uint(16.0 * (1.0 + 3.0 * max(0.0, 1.0 - 0.5 * dot(p, p))) + 0.5);
        float l = post_luma(c) / max(frame.exposure.x, 1e-30);   // cd/m²
        if (u.glare.y > 0.0) {
            float2 pixel = (float2(gid) + 0.5) / size * frame.viewport.xy;
            float seen = float(atomic_load_explicit(&histogram[POST_HISTOGRAM_SUN], memory_order_relaxed)) / 64.0;
            l += u.glare.x * u.glare.y * seen * post_glare(orbit_viewRay(pixel, frame), u.sunView.xyz, u.glare.z);
        }
        float ev = log2(max(l, 1e-30) * 8.0);
        uint bin = POST_HISTOGRAM_DARK;
        if (ev >= u.params.z) {
            float x = (ev - u.params.z) / (u.params.w - u.params.z);
            bin = min(uint(x * float(POST_HISTOGRAM_BINS)), uint(POST_HISTOGRAM_BINS - 1));
        }
        atomic_fetch_add_explicit(&local[bin], w, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint i = lid; i < POST_HISTOGRAM_BINS + 1; i += threads) {
        uint v = atomic_load_explicit(&local[i], memory_order_relaxed);
        if (v > 0u) { atomic_fetch_add_explicit(&histogram[i], v, memory_order_relaxed); }
    }
}

// The next bloom level down.
kernel void post_downsample(texture2d<float> src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            constant PostUniforms &u [[buffer(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= uint(u.size.x) || gid.y >= uint(u.size.y)) { return; }
    dst.write(float4(post_downsample13(src, gid, u.size.zw), 1.0), gid);
}

// One level up: (1 - r) of this level plus r of the level below, spread by
// a 3×3 tent. Each level conserves the image's mean, so the pyramid does too.
kernel void post_upsample(texture2d<float> below [[texture(0)]],
                          texture2d<float> here [[texture(1)]],
                          texture2d<float, access::write> dst [[texture(2)]],
                          constant PostUniforms &u [[buffer(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= uint(u.size.x) || gid.y >= uint(u.size.y)) { return; }
    float2 uv = (float2(gid) + 0.5) / u.size.xy;
    float2 t = 1.0 / u.size.xy;
    float3 s = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float w = (x == 0 ? 2.0 : 1.0) * (y == 0 ? 2.0 : 1.0) / 16.0;
            s += w * post_clean(below.sample(post_linear, uv + float2(x, y) * t, level(0)).rgb);
        }
    }
    float3 h = post_clean(here.read(gid).rgb);
    dst.write(float4(mix(h, s, u.params.x), 1.0), gid);
}

// The bloom's top: (1 - r) of the first level plus r of the level below,
// bilinear (that level is already smooth). It is the pyramid's last
// upsample, done where the tone map reads it, at full resolution, so it is
// never stored.
static float3 post_bloomTop(texture2d<float> first, texture2d<float> below, float2 uv, float r) {
    return mix(post_clean(first.sample(post_linear, uv, level(0)).rgb),
               post_clean(below.sample(post_linear, uv, level(0)).rgb), r);
}

// The bloom's top at every pixel, for the tests.
kernel void post_bloom_capture(texture2d<float> first [[texture(0)]],
                               texture2d<float> below [[texture(1)]],
                               texture2d<float, access::write> dst [[texture(2)]],
                               constant PostUniforms &u [[buffer(1)]],
                               uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    dst.write(float4(post_bloomTop(first, below, uv, u.params.x), 1.0), gid);
}

// ------------------------------------------------------ the Sun's visibility ---

// 64 directions over the Sun's disc (a Vogel spiral). A direction is hidden
// by a body whose disc holds it (on screen or off: the Earth hides an
// eclipsed Sun outside the frame too), or, on screen, by drawn depth nearer
// than `params.y` (vessels, the pad). Farther depth is a planet's, which the
// discs already account for, or the legacy sky's, which is translucent and
// does not hide the Sun. One threadgroup of 64.
kernel void post_sun_visibility(depth2d<float> depth [[texture(0)]],
                                device atomic_uint *histogram [[buffer(0)]],
                                constant SunProbeUniforms &u [[buffer(1)]],
                                constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]],
                                uint i [[thread_index_in_threadgroup]]) {
    if (i >= 64u) { return; }
    bool seen = u.params.z > 0.5;
    float r = u.sun.w * sqrt((float(i) + 0.5) / 64.0);
    float a = float(i) * 2.39996323;
    float3 d = normalize(u.sun.xyz + tan(r) * (cos(a) * u.axisU.xyz + sin(a) * u.axisV.xyz));
    for (int b = 0; b < min(int(u.params.x), POST_MAX_OCCULTERS); b++) {
        if (dot(d, u.bodies[b].xyz) >= u.bodies[b].w) { seen = false; }
    }
    float4 clip = frame.viewProjection * float4(d, 1.0);
    if (seen && clip.w > 0.0) {
        float2 ndc = clip.xy / clip.w;
        float2 p = float2((ndc.x + 1.0) * 0.5 * frame.viewport.x, (1.0 - ndc.y) * 0.5 * frame.viewport.y);
        float2 size = float2(depth.get_width(), depth.get_height());
        if (all(p >= 0.0) && all(p < size)) {
            float z = depth.read(uint2(p));
            float distance = orbit_linearDepth(z, frame.camera.x) * length(orbit_viewRay(p, frame));
            if (z > 0.0 && distance < u.params.y) { seen = false; }
        }
    }
    atomic_fetch_add_explicit(&histogram[POST_HISTOGRAM_SUN], seen ? 1u : 0u, memory_order_relaxed);
}

// -------------------------------------------------------------- tone map ---

// AgX from the LUT over log2 input (ToneCurves.swift bakes it).
static float3 post_agx(float3 c, texture3d<float> lut, constant ToneUniforms &u) {
    float n = u.lut.x;
    float3 l = (log2(max(c, 1e-30)) - u.lut.y) / (u.lut.z - u.lut.y);
    float3 t = (clamp(l, 0.0, 1.0) * (n - 1.0) + 0.5) / n;
    return lut.sample(post_linear, t).rgb;
}

// Khronos PBR Neutral (ToneCurves.neutral).
static float3 post_neutral(float3 c) {
    const float f90 = 0.04, start = 0.8 - 0.04, desaturation = 0.15;
    float x = min(c.r, min(c.g, c.b));
    float offset = x < 2.0 * f90 ? x - x * x / (4.0 * f90) : f90;
    c -= offset;
    float peak = max(c.r, max(c.g, c.b));
    if (peak < start) { return c; }
    float d = 1.0 - start;
    float newPeak = 1.0 - d * d / (peak + d - start);
    c *= newPeak / peak;
    float g = 1.0 - 1.0 / (desaturation * (peak - newPeak) + 1.0);
    return mix(c, float3(newPeak), g);
}

static float3 post_toneCurve(float3 c, texture3d<float> lut, constant ToneUniforms &u) {
    return u.params.z > 0.5 ? clamp(post_neutral(c), 0.0, 1.0) : post_agx(c, lut, u);
}

static float post_srgbEncode(float x) {
    x = clamp(x, 0.0, 1.0);
    return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1.0 / 2.4) - 0.055;
}
// About the linear light one step of the sRGB encoding spans at linear `x`:
// dx/de = 2.4 x / (e + 0.055), with e ≈ 1.13 √x (within 15 % above the
// linear toe), enough for a dither's amplitude.
static float3 post_srgbStep(float3 x) {
    return select(2.4 * x / (1.13 * sqrt(x) + 0.055), float3(1.0 / 12.92), x <= 0.0031308);
}

// The resolved scene plus its bloom and the Sun's veiling glare, exposed,
// through the tone curve, dithered by ±1 step of the 8-bit output (blue
// noise shaped to a triangle), into the output.
fragment float4 post_tonemap_fragment(PostVertexOut in [[stage_in]],
                                      texture2d<float> hdr [[texture(0)]],
                                      texture2d<float> bloomFirst [[texture(1)]],
                                      texture2d<float> bloomBelow [[texture(2)]],
                                      device const uint *histogram [[buffer(0)]],
                                      constant ToneUniforms &u [[buffer(1)]],
                                      constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]],
                                      texture2d<float> noise [[texture(ORBIT_TEXTURE_BLUE_NOISE)]],
                                      texture3d<float> lut [[texture(ORBIT_TEXTURE_TONE_LUT)]]) {
    uint2 xy = uint2(in.position.xy);
    float3 c = post_decode(hdr.read(xy));
    if (u.params.x > 0.0) {
        c = mix(c, post_bloomTop(bloomFirst, bloomBelow, in.uv, u.bloom.x), u.params.x);
    }
    if (u.glare.y > 0.0) {
        // Veiling glare around the Sun, L = k E / θ², scaled by the share of
        // its disc in view and faded out as it leaves the frame.
        float seen = float(histogram[POST_HISTOGRAM_SUN]) / 64.0;
        float g = post_glare(orbit_viewRay(in.position.xy, frame), u.sunView.xyz, 2.0 * u.glare.z);
        c += u.sunColor.rgb * (u.glare.x * u.glare.y * seen * frame.exposure.x * g);
    }
    c = post_clean(c * u.params.y);
    float3 o = post_toneCurve(c, lut, u);
    if (u.params.w > 0.5) {
        uint2 n = (xy + uint2(frame.jitter.zw)) % uint2(noise.get_width(), noise.get_height());
        float v = noise.read(n).r;
        float t = v < 0.5 ? sqrt(2.0 * v) - 1.0 : 1.0 - sqrt(2.0 - 2.0 * v);
        if (u.output.x > 0.5) {
            // ±1 step in the encoding, as linear light for the sRGB store.
            o = clamp(o + post_srgbStep(o) * (t / 255.0), 0.0, 1.0);
        } else {
            float3 e = float3(post_srgbEncode(o.r), post_srgbEncode(o.g), post_srgbEncode(o.b));
            o = clamp(e + t / 255.0, 0.0, 1.0);
        }
    } else if (u.output.x < 0.5) {
        o = float3(post_srgbEncode(o.r), post_srgbEncode(o.g), post_srgbEncode(o.b));
    }
    return float4(o, 1.0);
}

// ------------------------------------------------------------- captures ---

// The resolved scene's light (pre-exposed) for a debug view, a snapshot's
// PFM or a test.
kernel void post_decode_scene(texture2d<float> hdr [[texture(0)]],
                              texture2d<float, access::write> dst [[texture(1)]],
                              uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    dst.write(float4(post_decode(hdr.read(gid)), 1.0), gid);
}

// The tone curve alone on a list of colours, for the tests.
kernel void post_tone_probe(device const float4 *in [[buffer(0)]],
                            device float4 *out [[buffer(2)]],
                            constant ToneUniforms &u [[buffer(1)]],
                            texture3d<float> lut [[texture(ORBIT_TEXTURE_TONE_LUT)]],
                            uint i [[thread_position_in_grid]]) {
    out[i] = float4(post_toneCurve(in[i].rgb, lut, u), 1.0);
}
"""#

extension ShaderModule {
    public static let post = ShaderModule(name: "Post", source: postShaderSource)
}
