// Volumetric clouds (track C2 owns this module): the noise volumes, the
// weather map, the cloud shadow map, the march (near and orbit regimes), the
// far surface layer, the fibrous cirrus, the temporal resolve, and the
// writer into R6's clouds layer. Its Swift mirrors are OrbitScene's
// CloudNoise (the volumes, line for line), CloudScattering (the lighting),
// CloudSlab (the far LUT), CloudWeatherMap (the weather) and CloudFrame.
//
// Positions are camera-relative in the Earth's body axes ("q", metres);
// the camera's figure position (body axes with z stretched by a/b, where the
// ellipsoid is a sphere) comes from the CPU in Double, rounded once.
let cloudShaderSource = #"""
// ------------------------------------------------------------- cloud ---

#define CLOUD_PI 3.14159265358979
// The light march's samples (CloudLighting.lightSamples).
#define CLOUD_LIGHT_SAMPLES 4

struct CloudUniforms {
    float4x4 worldToBody;     // camera-relative world -> body axes (rotation)
    float4x4 bodyToWorld;
    float4x4 reprojection;    // this frame's camera-relative world -> last frame's clip (body-fixed points)
    float4 cameraFigure;      // xyz: camera, figure coordinates (m), w: stretch a/b
    float4 radii;             // x: a (m), y: camera altitude (m), z: shell top height (m), w: top of the air (m above a)
    float4 shell;             // |o|²-r² for x: the ground, y: the shell's top, z: the cirrus, w: the low reference
    float4 shellMid;          // x: |o|²-r² for the mid reference, y: cirrus height (m), z: low ref height, w: mid ref height
    float4 sun;               // xyz: unit, body axes, to the Sun; w: exposure x Sun's lux scale (unused)
    float4 sunLight;          // rgb: the Sun's illuminance above the air (lux) x pre-exposure, w: pre-exposure
    float4 noiseLow;          // xyz: low layer's noise origin (body, wrapped, m), w: shape period (m)
    float4 noiseMid;          // xyz: mid layer's, w: mid shape period (m)
    float4 noiseHigh;         // xyz: cirrus's, w: detail period (m)
    float4 windHigh;          // xyz: unit body axis of the cirrus's streaks, w: curl period (m)
    // The cirrus's streak frames (CirrusFrame), current and fading out: axes
    // along the wind, across and up (body), the camera's noise coordinate
    // (noise-space m); cirrusAlong.w the fading frame's weight.
    float4 cirrusAlong;
    float4 cirrusAcross;
    float4 cirrusUp;
    float4 cirrusOrigin;
    float4 cirrusAlong2;
    float4 cirrusAcross2;
    float4 cirrusUp2;
    float4 cirrusOrigin2;
    // The low layer's detail curl's own frame (its wind the low layer's):
    // axes along and across, the camera's coordinate.
    float4 detailAlong;       // w: the fading frame's weight
    float4 detailAcross;
    float4 detailOrigin;
    float4 detailAlong2;      // the frame fading out
    float4 detailAcross2;
    float4 detailOrigin2;
    float4 extinction;        // x: low, y: mid, z: cirrus in-cloud extinction (1/m), w: density scale
    float4 layers;            // x: mid base, y: mid top, z: cirrus base, w: cirrus top (m)
    float4 march;             // x: steps, y: unused, z: light distance (m), w: near reach (m)
    float4 mie;               // x: g HG, y: g Draine, z: Draine alpha, w: Draine weight
    float4 lighting;          // x: two-stream backscatter b, y: least Sun cosine, z: detail, w: cirrus g
    float4 regime;            // x: near weight, y: orbit, z: far, w: in-cloud density factor for the far layer
    float4 footprint;         // x: pixel angle (rad), y: far blend start (m), z: far blend end (m), w: global coverage modulation
    float4 checker;           // xy: this frame's checkerboard texel, z: 1 marching one texel in four, w: frame index
    float4 lookDev;           // x: 1 a uniform homogeneous layer, y: its cover, z: its optical depth, w: 1 force far, 2 force march
    float4 lookDevSlab;       // x: the slab's base, y: its top (m above the ground)
    float4 target;            // xy: the march target's size, zw: frame pixels per texel
    float4 lut;               // x: LUT depths, y: cosines, z: least depth, w: ln(most / least)
    float4 lut2;              // x: least cosine, y: 1 with a field, z, w: the low layer's base and top at the camera (m)
    float4 shadow;            // x: extent (m), y: texels, z: 1 drawn, w: steps
    float4 shadowCenter;      // xyz: the map's centre minus the camera, body axes (m)
    float4 shadowU;           // xyz: the map's u axis (body)
    float4 shadowV;           // xyz: v axis
    float4 shadowLevels;      // the altitudes (m) the map's channels hold the optical depth above
    float4 coverage[9];       // the coverage thresholds θ(c) at c = 0, 1/32 ... 1, four to an entry
    // CloudCoverage's statistics over the same covers: the march's density
    // scale for the low and mid layers, the cirrus's thresholds and scale.
    float4 densityLow[9];
    float4 densityMid[9];
    float4 cirrusTheta[9];
    float4 cirrusScale[9];
    // The march's optical depth down a cloudy column of the mid layer over
    // C1's (CloudCoverage.columnDepth): its lenses fill a twelfth of the layer.
    float4 columnMid[9];
    // The same for the low layer (a quarter to a third of its depth).
    float4 columnLow[9];
};

inline float cloud_remap(float x, float a, float b, float c, float d) {
    return c + (x - a) / max(b - a, 1e-6) * (d - c);
}

// ------------------------------------------------- noise (CloudNoise) ---

inline uint3 cloud_pcg3d(uint3 v) {
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z;
    v.y += v.z * v.x;
    v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z;
    v.y += v.z * v.x;
    v.z += v.x * v.y;
    return v;
}

inline uint cloud_wrap(int v, int period) {
    int m = v % period;
    return uint(m < 0 ? m + period : m);
}

inline uint3 cloud_cellHash(int3 c, int period, uint seed) {
    return cloud_pcg3d(uint3(cloud_wrap(c.x, period) + seed, cloud_wrap(c.y, period) + seed * 3u,
                             cloud_wrap(c.z, period) + seed * 7u));
}

inline float cloud_unit(uint h) { return float(h >> 8u) * (1.0 / 16777216.0); }

inline float cloud_gradientDot(uint h, float x, float y, float z) {
    switch (h % 12u) {
        case 0u: return x + y;
        case 1u: return -x + y;
        case 2u: return x - y;
        case 3u: return -x - y;
        case 4u: return x + z;
        case 5u: return -x + z;
        case 6u: return x - z;
        case 7u: return -x - z;
        case 8u: return y + z;
        case 9u: return -y + z;
        case 10u: return y - z;
        default: return -y - z;
    }
}

inline float cloud_fade(float t) { return t * t * t * (t * (t * 6.0 - 15.0) + 10.0); }

inline float cloud_perlin(float3 p, int period, uint seed) {
    float3 f = floor(p);
    int3 i = int3(f);
    float3 w = p - f;
    float c[8];
    for (int k = 0; k < 8; k++) {
        int3 o = int3(k & 1, (k >> 1) & 1, (k >> 2) & 1);
        uint h = cloud_cellHash(i + o, period, seed).x;
        c[k] = cloud_gradientDot(h, w.x - float(o.x), w.y - float(o.y), w.z - float(o.z));
    }
    float3 s = float3(cloud_fade(w.x), cloud_fade(w.y), cloud_fade(w.z));
    float x00 = mix(c[0], c[1], s.x), x10 = mix(c[2], c[3], s.x);
    float x01 = mix(c[4], c[5], s.x), x11 = mix(c[6], c[7], s.x);
    return mix(mix(x00, x10, s.y), mix(x01, x11, s.y), s.z);
}

inline float cloud_perlinFBM(float3 p, int basePeriod, int octaves, uint seed) {
    float sum = 0.0, amplitude = 1.0, total = 0.0;
    int period = basePeriod;
    for (int o = 0; o < octaves; o++) {
        float s = float(period);
        sum += amplitude * cloud_perlin(p * s, period, seed + uint(o));
        total += amplitude;
        amplitude *= 0.5;
        period *= 2;
    }
    return clamp(0.5 + 0.5 * sum / total, 0.0, 1.0);
}

inline float cloud_worley(float3 p, int cells, uint seed) {
    float n = float(cells);
    float3 q = p * n;
    float3 f = floor(q);
    int3 i = int3(f);
    float best = 9.0;
    for (int c = -1; c <= 1; c++) {
        for (int b = -1; b <= 1; b++) {
            for (int a = -1; a <= 1; a++) {
                uint3 h = cloud_cellHash(i + int3(a, b, c), cells, seed);
                float3 d = f + float3(float(a), float(b), float(c)) + float3(cloud_unit(h.x), cloud_unit(h.y), cloud_unit(h.z)) - q;
                best = min(best, dot(d, d));
            }
        }
    }
    return clamp(1.0 - sqrt(best), 0.0, 1.0);
}

inline float cloud_worleyFBM(float3 p, int cells, uint seed) {
    return 0.625 * cloud_worley(p, cells, seed) + 0.25 * cloud_worley(p, cells * 2, seed + 1u)
         + 0.125 * cloud_worley(p, cells * 4, seed + 2u);
}

inline float cloud_perlinWorley(float p, float w) { return clamp((p + w) / (1.0 + w), 0.0, 1.0); }

kernel void cloud_noise_shape(texture3d<float, access::write> out [[texture(0)]], uint3 gid [[thread_position_in_grid]]) {
    if (any(gid >= uint3(out.get_width(), out.get_height(), out.get_depth()))) { return; }
    float3 p = (float3(gid) + 0.5) * (1.0 / float(out.get_width()));
    uint seed = 0xC2u;
    float perlin = cloud_perlinFBM(p, 4, 5, seed);
    float w0 = cloud_worleyFBM(p, 4, seed + 16u);
    float w1 = cloud_worleyFBM(p, 8, seed + 32u);
    float w2 = cloud_worleyFBM(p, 16, seed + 48u);
    out.write(float4(cloud_perlinWorley(perlin, w0), w0, w1, w2), gid);
}

kernel void cloud_noise_detail(texture3d<float, access::write> out [[texture(0)]], uint3 gid [[thread_position_in_grid]]) {
    if (any(gid >= uint3(out.get_width(), out.get_height(), out.get_depth()))) { return; }
    float3 p = (float3(gid) + 0.5) * (1.0 / float(out.get_width()));
    uint seed = 0x1C2u;
    out.write(float4(cloud_worleyFBM(p, 4, seed), cloud_worleyFBM(p, 8, seed + 16u), cloud_worleyFBM(p, 16, seed + 32u), 1.0), gid);
}

inline float cloud_stream(float2 p) { return cloud_perlinFBM(float3(p, 0.0), 4, 4, 0x2C2u) - 0.5; }

kernel void cloud_noise_curl(texture2d<float, access::write> out [[texture(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (any(gid >= uint2(out.get_width(), out.get_height()))) { return; }
    float s = 1.0 / float(out.get_width()), h = 0.5 * s;
    float2 p = (float2(gid) + 0.5) * s;
    float dv = (cloud_stream(p + float2(0.0, h)) - cloud_stream(p - float2(0.0, h))) / (2.0 * h);
    float du = (cloud_stream(p + float2(h, 0.0)) - cloud_stream(p - float2(h, 0.0))) / (2.0 * h);
    out.write(float4(clamp(dv * 0.08, -1.0, 1.0), clamp(-du * 0.08, -1.0, 1.0), 0.0, 0.0), gid);
}

// ---------------------------------------- the weather (CloudWeatherMap) ---

struct CloudWeatherParams {
    float4 snapshots;     // x: the second's weight, y: 1 with a field, z: the field's weight, w: 1 when the two differ
    float4 counts;        // x: overrides
    float4 overridePlace[2];   // x: latitude, y: longitude (rad), z: radius (m), w: weight in time
    float4 overrideSky[2];     // x: low, y: mid, z: high, w: 1 convective
    float4 layerModel;    // x: default low base, y: mid base, z: low depth, w: cumulonimbus top (m)
    float4 structure;     // x: 1 with the procedural weather as the weather elsewhere, y: the first row
};

inline float cloud_smoothstep(float a, float b, float x) {
    float t = clamp((x - a) / (b - a), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

// C1's great-circle distance on a 6,371 km sphere, m.
inline float cloud_distance(float lat1, float lon1, float lat2, float lon2) {
    float a = sin((lat2 - lat1) * 0.5), b = sin((lon2 - lon1) * 0.5);
    float h = a * a + cos(lat1) * cos(lat2) * b * b;
    return 2.0 * 6371000.0 * asin(min(sqrt(h), 1.0));
}

// ------------------------------- the procedural weather (ProceduralWeather) ---
// Its nodes (720 x 361, `cloud_procedural`), line for line in Float, and
// each row's calibration against the climatology (`cloud_calibrate`).

struct ProceduralUniforms {
    float4 phase0;      // xyz: the noise phase's offset, w: its weight
    float4 phase1;
    float4 ages;        // x, y: the phases' ages (s), z: 1/sqrt(w0^2 + w1^2), w: the systems' count
    float4 sky;         // x: subsolar longitude, y: declination, z: the ITCZ over the sea, w: over the continents (rad)
    float4 rows;        // x: the first node row this dispatch makes (a band of a sweep)
};

struct ProceduralSystem {
    float4 centre;      // xyz: unit, body-fixed; w: kind (0 cyclone, 1 cluster, 2 tropical cyclone)
    float4 east;        // xyz; w: reach (rad)
    float4 poleward;    // xyz; w: size (m)
    float4 params;      // x: intensity, y: stage, z: top (m), w: tilt (rad)
    float4 turn;        // x: cos of the reach, y, z: cos and sin of the tilt
};

struct ProceduralBand {
    float4 a;           // steering (rad/s), subtropics, stratocumulus, desert
    float4 b;           // mid-latitude desert, trades, polar sea, ice
    float4 c;           // the climatology's low, mid and high cover
};

#define PW_EARTH_RADIUS 6371000.0
// ProceduralWeather.noiseScale.
#define PW_NOISE_SCALE 3.1
// ProceduralWeather.gains: low, mid, high.
#define PW_GAINS float3(2.5, 3.0, 5.0)
#define PW_COLUMNS 720u
#define PW_ROWS 361u

// Perlin's twelve edge gradients (cloud_gradientDot's, as a table: no branches).
constant float3 pw_gradients[12] = {
    float3(1, 1, 0), float3(-1, 1, 0), float3(1, -1, 0), float3(-1, -1, 0),
    float3(1, 0, 1), float3(-1, 0, 1), float3(1, 0, -1), float3(-1, 0, -1),
    float3(0, 1, 1), float3(0, -1, 1), float3(0, 1, -1), float3(0, -1, -1)
};

inline float3 pw_noise3(float3 p) {
    float3 f = floor(p);
    int3 i = int3(f);
    float3 w = p - f;
    float3 c[8];
    for (int k = 0; k < 8; k++) {
        int3 o = int3(k & 1, (k >> 1) & 1, (k >> 2) & 1);
        uint3 h = cloud_pcg3d(as_type<uint3>(i + o)) % 12u;
        float3 d = w - float3(o);
        c[k] = float3(dot(pw_gradients[h.x], d), dot(pw_gradients[h.y], d), dot(pw_gradients[h.z], d));
    }
    float3 s = float3(cloud_fade(w.x), cloud_fade(w.y), cloud_fade(w.z));
    float3 x00 = mix(c[0], c[1], s.x), x10 = mix(c[2], c[3], s.x);
    float3 x01 = mix(c[4], c[5], s.x), x11 = mix(c[6], c[7], s.x);
    return mix(mix(x00, x10, s.y), mix(x01, x11, s.y), s.z);
}

// ProceduralWeather.fbm: six octaves from cells of about 3,200 km.
inline float3 pw_fbm(float3 p, float3 offset) {
    float3 sum = float3(0.0);
    float amplitude = 1.0, f = 2.0;
    for (int o = 0; o < 6; o++) {
        float shift = float(o) * 17.31;
        sum += amplitude * pw_noise3(p * f + offset + shift);
        amplitude *= 0.6;
        f *= 2.03;
    }
    return sum * PW_NOISE_SCALE;
}

inline float3 pw_weatherNoise(float lat, float lon, float steer, constant ProceduralUniforms &p) {
    float cl = cos(lat), sl = sin(lat);
    float l0 = lon - steer * p.ages.x, l1 = lon - steer * p.ages.y;
    float3 n = p.phase0.w * pw_fbm(float3(cl * cos(l0), cl * sin(l0), sl), p.phase0.xyz)
             + p.phase1.w * pw_fbm(float3(cl * cos(l1), cl * sin(l1), sl), p.phase1.xyz);
    return n * p.ages.z;
}

struct PWContribution {
    float low;
    float mid;
    float high;
    float frontal;
    float cells;
    float deep;
};

inline float pw_wrap(float x) { return x - floor(x / (2.0 * CLOUD_PI)) * 2.0 * CLOUD_PI; }
inline float pw_wrapSigned(float x) { return x - rint(x / (2.0 * CLOUD_PI)) * 2.0 * CLOUD_PI; }

// ProceduralWeather.cycloneTemplate.
inline PWContribution pw_cyclone(float u, float v, constant ProceduralSystem &s, float sea) {
    float w = s.params.y, i = s.params.x;
    float r = sqrt(u * u + v * v), theta = atan2(v, u);
    float tu = 0.30 * w + 0.05, tv = -0.08 * w;
    float along = u - tu, dw = (v - tv) + 0.27 * along;
    float bow = 0.35 * exp(-(along - 0.8) * (along - 0.8));
    #define PW_SHIELD(reach, depth) (cloud_smoothstep(-0.5, 0.0, along) * (1.0 - cloud_smoothstep((reach) - 0.6, (reach), along)) \
        * cloud_smoothstep(-0.25, 0.02, dw) * (1.0 - cloud_smoothstep((depth) - 0.4, (depth) + bow, dw)))
    float shieldHigh = PW_SHIELD(2.2, 1.3), shieldMid = PW_SHIELD(1.7, 1.0), shieldLow = PW_SHIELD(1.1, 0.55);
    #undef PW_SHIELD
    float sc = max(tv - v, 0.0);
    float dc = u - (tu - 0.25 * sc - 0.14 * sc * sc);
    float fade = cloud_smoothstep(-0.15, 0.1, tv - v) * (1.0 - cloud_smoothstep(1.3, 2.7, sc));
    #define PW_BAND(width) (cloud_smoothstep(-0.16, -0.04, dc) * (1.0 - cloud_smoothstep((width) - 0.18, (width), dc)) * fade)
    float frontHigh = PW_BAND(0.70), frontMid = PW_BAND(0.48), frontLow = PW_BAND(0.36);
    #undef PW_BAND
    float line = (1.0 - cloud_smoothstep(0.03, 0.10, abs(dc))) * fade * (1.0 - cloud_smoothstep(1.0, 2.0, sc));
    float warmSector = cloud_smoothstep(0.36, 0.55, dc) * cloud_smoothstep(0.0, 0.2, -dw) * (1.0 - cloud_smoothstep(1.4, 2.2, r));
    float cold = (1.0 - cloud_smoothstep(-0.4, -0.15, dc)) * (1.0 - cloud_smoothstep(2.0, 2.9, r))
               * (1.0 - cloud_smoothstep(0.1, 0.7, v - tv));
    float span = (0.7 + 1.3 * w) * CLOUD_PI;
    float start = pw_wrap(theta - 0.05 * CLOUD_PI);
    float arm = 0.0;
    for (int k = 0; k < 2; k++) {
        float a = start + 2.0 * CLOUD_PI * float(k);
        if (a > span) { break; }
        float x = (r - 0.95 * exp(-0.22 * a)) / (0.34 * exp(-0.1 * a));
        arm = max(arm, exp(-0.5 * x * x) * cloud_smoothstep(0.0, 0.6, a) * (1.0 - cloud_smoothstep(span - 0.8, span, a)));
    }
    float off = pw_wrapSigned(theta + 0.6 * CLOUD_PI - 0.35 * CLOUD_PI * w);
    float dry = (1.0 - cloud_smoothstep(0.8, 1.3, r)) * cloud_smoothstep(0.05, 0.2, r) * (1.0 - cloud_smoothstep(-0.1, 0.0, dc))
              * (1.0 - cloud_smoothstep(0.35 * CLOUD_PI, 0.6 * CLOUD_PI, abs(off))) * (1.0 - arm);
    float head = (1.0 - cloud_smoothstep(0.6, 1.05, r)) * cloud_smoothstep(-0.05, 0.25, v) * (1.0 - dry);
    arm = max(arm, 0.8 * head);
    float outside = cold * (1.0 - arm) * (1.0 - dry);
    PWContribution c;
    c.high = i * (3.2 * max(shieldHigh, frontHigh) + 3.0 * arm - 3.0 * dry - 1.2 * outside);
    c.mid = i * (3.4 * max(shieldMid, frontMid) + 3.2 * arm - 3.0 * dry - 1.5 * outside);
    c.low = i * (2.8 * max(shieldLow, frontLow) + 2.2 * arm + 1.0 * warmSector - 1.2 * dry + (1.0 * sea - 0.5) * outside);
    c.frontal = i * max(max(shieldLow, frontLow), 0.8 * arm);
    c.cells = i * outside * sea;
    c.deep = 0.8 * i * line;
    return c;
}

inline float pw_lumps(float theta, float phase) {
    return 1.0 + 0.22 * sin(3.0 * theta + phase) + 0.12 * sin(5.0 * theta + 2.3 * phase);
}

// ProceduralWeather.clusterTemplate.
inline PWContribution pw_cluster(float u, float v, constant ProceduralSystem &s, float land, float hour, float rough) {
    float phase = s.params.z * 0.0037;
    float theta = atan2(v, u);
    float r = sqrt(u * u + 1.56 * v * v) / pw_lumps(theta, phase) + 0.15 * rough;
    float ua = u + 0.5;
    float ra = sqrt(0.6 * ua * ua + 1.69 * v * v) / pw_lumps(atan2(v, ua), phase + 1.7) + 0.15 * rough;
    float core = 1.0 - cloud_smoothstep(0.4, 1.0, r);
    float anvil = 1.0 - cloud_smoothstep(1.0, 2.6, ra);
    float diurnal = 1.0 - land + land * (0.3 + 0.7 * (0.5 + 0.5 * cos(hour - 1.3)));
    float ic = s.params.x * diurnal, ia = s.params.y;
    PWContribution c;
    c.low = 2.6 * core * ic;
    c.mid = 2.0 * core * ic + 0.8 * anvil * ia;
    c.high = 3.6 * anvil * ia;
    c.frontal = 0.0;
    c.cells = 0.0;
    c.deep = core * ic;
    return c;
}

// ProceduralWeather.tropicalTemplate.
inline PWContribution pw_tropical(float u, float v, constant ProceduralSystem &s, float rough) {
    float r = sqrt(u * u + v * v), theta = atan2(v, u);
    float eye = 1.0 - cloud_smoothstep(0.08, 0.14, r);
    float cdo = 1.0 - cloud_smoothstep(0.85, 1.25, r * (1.0 + 0.1 * sin(4.0 * theta + s.params.w)) + 0.1 * rough);
    float bands = 0.0;
    if (r > 0.3) {
        for (int k = 0; k < 2; k++) {
            float d = pw_wrapSigned(theta - (float(k) * CLOUD_PI - 1.2 * log(r)));
            bands = max(bands, exp(-0.5 * d * d / (0.38 * 0.38)) * (1.0 - cloud_smoothstep(2.6, 4.0, r))
                               * cloud_smoothstep(0.6, 1.0, r));
        }
    }
    float outflow = 1.0 - cloud_smoothstep(1.4, 3.8, r * pw_lumps(theta, s.params.w));
    float i = s.params.x;
    PWContribution c;
    c.high = i * (4.0 * cdo + 1.8 * bands + 1.2 * outflow - 7.0 * eye);
    c.mid = i * (3.0 * cdo + 1.6 * bands - 7.0 * eye);
    c.low = i * (3.0 * cdo + 2.4 * bands - 7.0 * eye);
    c.frontal = 0.0;
    c.cells = 0.0;
    c.deep = i * max(0.9 * cdo, 0.6 * bands) * (1.0 - eye);
    return c;
}

// ProceduralWeather.node at node gid: the latent low, mid and high cover
// and the low layer's base (latent), its top and how cumuliform (layer).
kernel void cloud_procedural(texture2d<float, access::write> outLatent [[texture(0)]],
                             texture2d<float, access::write> outLayer [[texture(1)]],
                             texture2d<float, access::read> geoA [[texture(2)]],
                             texture2d<float, access::read> geoB [[texture(3)]],
                             constant ProceduralUniforms &p [[buffer(0)]],
                             constant ProceduralBand *bands [[buffer(1)]],
                             constant ProceduralSystem *systems [[buffer(2)]],
                             uint2 tid [[thread_position_in_grid]]) {
    uint2 gid = uint2(tid.x, tid.y + uint(p.rows.x));
    if (gid.x >= PW_COLUMNS || gid.y >= PW_ROWS) { return; }
    float phi = (90.0 - 0.5 * float(gid.y)) * (CLOUD_PI / 180.0);
    float lambda = 0.5 * float(gid.x) * (CLOUD_PI / 180.0);
    ProceduralBand b = bands[gid.y];
    float4 ga = geoA.read(gid), gb = geoB.read(gid);
    float land = ga.x, continental = ga.y, inland = ga.z, iceSheet = ga.w;
    float seaEastLand = gb.x, landEastSea = gb.z, landWestSea = gb.w;
    float3 n = pw_weatherNoise(phi, lambda, b.a.x, p);
    float nl = n.x, nm = n.y, nh = n.z;
    float sea = 1.0 - land;
    float hour = lambda - p.sky.x;
    float sunUp = sin(phi) * sin(p.sky.y) + cos(phi) * cos(p.sky.y) * cos(hour - 0.785);
    float heat = max(sunUp, 0.0) * (1.0 - iceSheet);
    float itczLat = p.sky.z + continental * (p.sky.w - p.sky.z);
    float itczWidth = (4.0 + 1.0 * continental) * (CLOUD_PI / 180.0);
    float x = (phi - itczLat) / itczWidth;
    float itcz = exp(-0.5 * x * x);
    float desert = land * b.a.w * (0.35 + 0.65 * max(inland, landWestSea)) * (1.0 - landEastSea) * (1.0 - 0.7 * itcz)
                 + 0.6 * land * b.b.x * inland;
    float sc = sea * seaEastLand * (1.0 - gb.y) * b.a.z * (1.0 - itcz);
    float deck = min(1.5 * sc, 1.0);
    float trades = sea * b.b.y * (1.0 - deck);
    float polar = sea * b.b.z;
    float ice = land * b.b.w * (0.4 + 0.6 * inland);
    float tropics = 1.0 - cloud_smoothstep(20.0, 35.0, abs(phi) * (180.0 / CLOUD_PI));
    float low = 3.0 * sc - 2.8 * desert + 0.8 * polar - 1.4 * ice + land * (1.3 * heat - 0.55) * (1.0 - desert)
              + 0.4 * sc * cos(hour + 1.83) + 0.5 * itcz + (0.8 - 0.5 * deck - 0.35 * trades - 0.35 * desert) * nl;
    float mid = -1.8 * desert - 1.0 * sc - 0.6 * b.a.y * sea + 1.1 * itcz + 0.3 * land * heat * (1.0 - desert)
              + (0.85 - 0.3 * b.a.y) * nm;
    float high = -1.8 * desert - 0.9 * sc - 0.6 * b.a.y + 1.7 * itcz + 0.5 * land * heat * tropics * (1.0 - desert)
               + 0.7 * nh;
    float seaBase = 600.0 + 150.0 * trades - 120.0 * deck - 250.0 * polar;
    float landBase = 900.0 + 900.0 * max(desert, 0.5 * inland) + 450.0 * heat - 500.0 * ice;
    float seaTop = 2100.0 + 300.0 * trades - 750.0 * deck - 600.0 * polar;
    float landTop = landBase + 1100.0 + 1400.0 * heat;
    float base = sea * seaBase + land * landBase;
    float top = sea * seaTop + land * landTop;
    float cumuliform = sea * (1.0 - 0.85 * deck - 0.6 * polar) + land * (0.5 + 0.5 * heat - 0.3 * iceSheet);

    float3 pos = float3(cos(phi) * cos(lambda), cos(phi) * sin(lambda), sin(phi));
    float frontal = 0.0, deep = 0.0, deepTop = 0.0, cells = 0.0;
    int count = int(p.ages.w);
    for (int k = 0; k < count; k++) {
        constant ProceduralSystem &s = systems[k];
        float d = dot(pos, s.centre.xyz);
        // Outside its reach's cone: nothing.
        if (d <= s.turn.x) { continue; }
        float e = dot(pos, s.east.xyz), q = dot(pos, s.poleward.xyz);
        float lateral = sqrt(e * e + q * q);
        float angle = atan2(lateral, d);
        if (angle >= s.east.w) { continue; }
        float kk = lateral > 0.0 ? angle * PW_EARTH_RADIUS / (s.poleward.w * lateral) : 0.0;
        float u0 = e * kk, v0 = q * kk;
        float ct = s.turn.y, st = s.turn.z;
        float u = u0 * ct + v0 * st, v = -u0 * st + v0 * ct;
        PWContribution c;
        int kind = int(s.centre.w + 0.5);
        if (kind == 0) { c = pw_cyclone(u + 0.18 * nm, v + 0.18 * nh, s, sea); }
        else if (kind == 1) { c = pw_cluster(u, v, s, land, hour, nh); }
        else { c = pw_tropical(u, v, s, nh); }
        low += c.low;
        mid += c.mid;
        high += c.high;
        frontal = max(frontal, c.frontal);
        cells = max(cells, c.cells);
        if (c.deep > deep) {
            deep = c.deep;
            deepTop = s.params.z;
        }
    }
    base += frontal * (450.0 - base);
    top += frontal * (max(top, 2900.0) - top);
    cumuliform += frontal * (0.15 - cumuliform);
    top += cells * (max(top, 2800.0) - top);
    cumuliform += cells * (1.0 - cumuliform);
    base += deep * (900.0 - base);
    top += deep * (max(deepTop, top) - top);
    cumuliform += deep * (1.0 - cumuliform);
    top = max(top, base + 300.0);
    outLatent.write(float4(low, mid, high, base), gid);
    outLayer.write(float4(top, cumuliform, 0.0, 0.0), gid);
}

// ProceduralWeather.offset for each row (one threadgroup a row): the
// offsets of the latent low, mid and high cover that make the row's mean
// cover the climatology's, by bisection.
kernel void cloud_calibrate(texture2d<float, access::read> latent [[texture(0)]],
                            constant ProceduralUniforms &p [[buffer(0)]],
                            constant ProceduralBand *bands [[buffer(1)]],
                            device float4 *offsets [[buffer(3)]],
                            uint group [[threadgroup_position_in_grid]],
                            uint tid [[thread_index_in_threadgroup]],
                            uint threads [[threads_per_threadgroup]],
                            uint lane [[thread_index_in_simdgroup]],
                            uint simd [[simdgroup_index_in_threadgroup]]) {
    uint row = group + uint(p.rows.x);
    if (row >= PW_ROWS) { return; }
    threadgroup float3 partial[32];
    float3 z[4];
    int count = 0;
    for (uint c = tid; c < PW_COLUMNS && count < 4; c += threads) {
        z[count] = latent.read(uint2(c, row)).xyz;
        count++;
    }
    float3 target = clamp(bands[row].c.xyz, 0.003, 0.997);
    float3 lo = float3(-10.0), hi = float3(10.0);
    uint groups = (threads + 31u) / 32u;
    for (int it = 0; it < 16; it++) {
        float3 m = 0.5 * (lo + hi);
        float3 sum = float3(0.0);
        for (int k = 0; k < count; k++) { sum += 1.0 / (1.0 + exp(-PW_GAINS * (z[k] + m))); }
        sum = simd_sum(sum);
        if (lane == 0) { partial[simd] = sum; }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        float3 total = float3(0.0);
        for (uint g = 0; g < groups; g++) { total += partial[g]; }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        bool3 below = total / float(PW_COLUMNS) < target;
        lo = select(lo, m, below);
        hi = select(m, hi, below);
    }
    if (tid == 0) { offsets[row] = float4(0.5 * (lo + hi), 0.0); }
}

// ProceduralWeather.smoothed: row j's offsets, a triangle over ±4 rows.
inline float3 pw_offset(constant float4 *offsets, int j) {
    float3 sum = float3(0.0);
    for (int i = -4; i <= 4; i++) {
        int jj = clamp(j + i, 0, int(PW_ROWS) - 1);
        sum += float(5 - abs(i)) * offsets[jj].xyz;
    }
    return sum / 25.0;
}

// CloudWeatherMap.texel at grid point gid: the three covers and the low
// layer's base (A), its top and how cumuliform it is (B). The weather
// elsewhere is the procedural weather's nodes (bilinear: every other grid
// point is one) with its rows' smoothed offsets when p.structure.x is 1,
// else the climatology's rows.
kernel void cloud_weather(texture2d<uint, access::read> first [[texture(0)]],
                          texture2d<uint, access::read> second [[texture(1)]],
                          texture2d<float, access::write> outA [[texture(2)]],
                          texture2d<float, access::write> outB [[texture(3)]],
                          texture3d<float> shape [[texture(4)]],
                          texture2d<float, access::read> procLatent [[texture(5)]],
                          texture2d<float, access::read> procLayer [[texture(6)]],
                          sampler wrap [[sampler(0)]],
                          constant float4 *climate [[buffer(0)]],
                          constant CloudWeatherParams &p [[buffer(1)]],
                          constant float4 *procOffsets [[buffer(2)]],
                          uint2 tid [[thread_position_in_grid]]) {
    // A band of rows from structure.y (a sweep's), or all of them.
    uint2 gid = uint2(tid.x, tid.y + uint(p.structure.y));
    uint w = outA.get_width(), hgt = outA.get_height();
    if (gid.x >= w || gid.y >= hgt) { return; }
    float4 c = climate[gid.y];
    float low = c.x, mid = c.y, high = c.z;
    bool procOn = p.structure.x > 0.5;
    float procBase = 0.0, procTop = 0.0, procCum = 0.5;
    if (procOn) {
        uint j0 = gid.y / 2u, c0 = gid.x / 2u;
        uint j1 = min(j0 + 1u, PW_ROWS - 1u), c1 = (c0 + 1u) % PW_COLUMNS;
        float fy = (gid.y & 1u) != 0u ? 0.5 : 0.0, fx = (gid.x & 1u) != 0u ? 0.5 : 0.0;
        float4 l00 = procLatent.read(uint2(c0, j0)), l01 = procLatent.read(uint2(c1, j0));
        float4 l10 = procLatent.read(uint2(c0, j1)), l11 = procLatent.read(uint2(c1, j1));
        float4 h00 = procLayer.read(uint2(c0, j0)), h01 = procLayer.read(uint2(c1, j0));
        float4 h10 = procLayer.read(uint2(c0, j1)), h11 = procLayer.read(uint2(c1, j1));
        float4 l = mix(mix(l00, l01, fx), mix(l10, l11, fx), fy);
        float4 h = mix(mix(h00, h01, fx), mix(h10, h11, fx), fy);
        float3 off = mix(pw_offset(procOffsets, int(j0)), pw_offset(procOffsets, int(j1)), fy);
        float3 cover = 1.0 / (1.0 + exp(-PW_GAINS * (l.xyz + off)));
        low = cover.x;
        mid = cover.y;
        high = cover.z;
        procBase = l.w;
        procTop = h.x;
        procCum = h.y;
    }
    float x = 1.0;
    float fieldBase = -1.0;
    if (p.snapshots.y > 0.5) {
        uint4 a = first.read(gid), b = second.read(gid);
        float sw = p.snapshots.x;
        bool both = p.snapshots.w > 0.5 && sw > 0.0;
        float4 scale = float4(1.0 / 254.0, 1.0 / 254.0, 1.0 / 254.0, 60.0);
        float4 v;
        bool4 known;
        for (int k = 0; k < 4; k++) {
            bool ka = a[k] != 255u, kb = b[k] != 255u;
            float va = float(a[k]) * scale[k], vb = float(b[k]) * scale[k];
            if (ka && kb) { v[k] = both ? va + sw * (vb - va) : va; known[k] = true; }
            else { known[k] = sw < 0.5 ? ka : kb; v[k] = sw < 0.5 ? va : vb; }
        }
        if (known.x && known.y && known.z) {
            x = 1.0 - p.snapshots.z;
            float3 f = clamp(v.xyz, 0.0, 1.0);
            low = f.x + x * (low - f.x);
            mid = f.y + x * (mid - f.y);
            high = f.z + x * (high - f.z);
            if (known.w) { fieldBase = v.w; }
        }
    }
    float lat = (90.0 - 180.0 * float(gid.y) / float(hgt - 1)) * (CLOUD_PI / 180.0);
    float lon = 2.0 * CLOUD_PI * float(gid.x) / float(w);
    bool convective = false;
    for (int i = 0; i < int(p.counts.x); i++) {
        float4 o = p.overridePlace[i], s = p.overrideSky[i];
        float d = cloud_distance(lat, lon, o.x, o.y);
        float wo = (1.0 - cloud_smoothstep(o.z * 0.5, o.z, d)) * o.w;
        if (wo <= 0.0) { continue; }
        low += wo * (s.x - low);
        mid += wo * (s.y - mid);
        high += wo * (s.z - high);
        if (wo >= 0.5) { convective = s.w > 0.5; }
    }
    float lowBase = p.layerModel.x, lowTop, cumuliform = 0.5;
    if (procOn) {
        if (fieldBase >= 0.0 && fieldBase < p.layerModel.y) { lowBase = max(fieldBase, 0.0); }
        float fieldTop = lowBase + p.layerModel.z;
        lowTop = fieldTop + x * (procTop - fieldTop);
        lowBase += x * (procBase - lowBase);
        cumuliform += x * (procCum - cumuliform);
    } else {
        if (x < 0.5 && fieldBase >= 0.0 && fieldBase < p.layerModel.y) { lowBase = max(fieldBase, 0.0); }
        lowTop = lowBase + p.layerModel.z;
    }
    if (convective) { lowTop = p.layerModel.w; }
    outA.write(float4(low, mid, high, lowBase), gid);
    outB.write(float4(lowTop, cumuliform, 0.0, 0.0), gid);
}

// ------------------------------------------------- the cloud field ---

struct CloudSample {
    float sigma;          // extinction (1/m)
    float column;         // the column's optical depth: σ times the layer's thickness
    float h01;            // height in the layer
    float layer;          // 0 low, 1 mid
};

// The camera-relative body point q in figure coordinates.
inline float3 cloud_figure(float3 q, constant CloudUniforms &u) {
    return u.cameraFigure.xyz + float3(q.x, q.y, q.z * u.cameraFigure.w);
}

// Height above the ellipsoid (m), from figure coordinates.
inline float cloud_height(float3 pf, constant CloudUniforms &u) { return length(pf) - u.radii.x; }

// The weather map's uv at figure point pf: geodetic latitude from the
// ellipsoid's normal, ERA5's grid of 1440 x 721 points at texel centres.
inline float2 cloud_weatherUV(float3 pf, constant CloudUniforms &u) {
    float lon = atan2(pf.y, pf.x);
    float lat = atan2(pf.z * u.cameraFigure.w, length(pf.xy));
    float uu = lon * (0.5 / CLOUD_PI) + 0.5 / 1440.0;
    float vv = (0.5 - lat / CLOUD_PI) * (720.0 / 721.0) + 0.5 / 721.0;
    return float2(uu, vv);
}

// A table over the cover c = 0, 1/32 ... 1 (CloudCoverage), four entries to
// a float4, linear between its 33 entries.
inline float cloud_table(constant float4 *t, float cover) {
    float x = clamp(cover, 0.0, 1.0) * 32.0;
    int i = min(int(x), 31);
    float a = t[i / 4][i % 4], b = t[(i + 1) / 4][(i + 1) % 4];
    return mix(a, b, x - float(i));
}

// The coverage threshold θ(c): the shape value above which a fraction c of
// the sky is cloud.
inline float cloud_threshold(float cover, constant CloudUniforms &u) { return cloud_table(u.coverage, cover); }

inline float cloud_profileLow(float h) {
    return clamp(cloud_remap(h, 0.0, 0.08, 0.0, 1.0), 0.0, 1.0) * clamp(cloud_remap(h, 0.4, 1.0, 1.0, 0.0), 0.0, 1.0);
}

// The mid layer's clouds (altocumulus, altostratus) are lenses: the profile
// peaks at 0.35 of the layer and rounds off both ways, so a patch is as
// thick as its density is over the cover's threshold (a plateau would cut
// every patch flat at the same two heights: boxes seen edge-on from afar).
inline float cloud_profileMid(float h) {
    return cloud_smoothstep(0.0, 0.35, h) * (1.0 - cloud_smoothstep(0.35, 0.9, h));
}

// One layer's base density in [0, 1]: Schneider's low-frequency shape (the
// Perlin-Worley dilated by the Worley fBm), shaped by the height profile and
// cut at the coverage threshold.
inline float cloud_baseDensity(float4 shape, float cover, float profile, constant CloudUniforms &u) {
    float fbm = shape.g * 0.625 + shape.b * 0.25 + shape.a * 0.125;
    float base = clamp(cloud_remap(shape.r, fbm - 1.0, 1.0, 0.0, 1.0), 0.0, 1.0) * profile;
    return clamp(cloud_remap(base, cloud_threshold(cover, u), 1.0, 0.0, 1.0), 0.0, 1.0);
}

// The base density eroded by the detail: wispy below, billowy above.
inline float cloud_erode(float d, float detailValue, float detailAmount, float h01) {
    float modifier = mix(detailValue, 1.0 - detailValue, clamp(h01 * 4.0, 0.0, 1.0)) * 0.35 * detailAmount;
    return clamp(cloud_remap(d, modifier, 1.0, 0.0, 1.0), 0.0, 1.0);
}

struct CloudTextures {
    texture3d<float> shape;
    texture3d<float> detail;
    texture2d<float> curl;
    texture2d<float> weatherA;
    texture2d<float> weatherB;
};

// The large-scale structure at figure point pf: the shape volume's
// Perlin-Worley on the sphere in two octaves (400 km and 100 km to a
// period) moving partial cover up and down about its value, 4c(1 - c) of
// the strength (u.footprint.w), so ERA5's 28 km grid does not show. The
// march and the far layer apply it alike.
inline float2 cloud_structure(float3 pf, float2 cover, thread const CloudTextures &t, sampler wrap,
                              constant CloudUniforms &u) {
    if (u.footprint.w <= 0.0 || u.lookDev.x > 0.5) { return cover; }
    float3 dir = normalize(pf);
    float g = 0.6 * t.shape.sample(wrap, dir * (u.radii.x / 400000.0), level(0.0)).r
            + 0.4 * t.shape.sample(wrap, dir * (u.radii.x / 100000.0), level(0.0)).r - 0.5;
    return clamp(cover + g * u.footprint.w * 4.0 * cover * (1.0 - cover), 0.0, 1.0);
}

// The weather where a sample is: the covers and the low layer's base (a),
// its top, and the large-scale structure (the shape volume's Perlin-Worley
// over 400 km of the sphere); only what the sample needs is fetched.
struct CloudWeatherSample {
    float4 a;          // low, mid, high cover (the large-scale structure in), low base (m)
    float lowTop;      // m
    float topmost;     // the highest layer top with any cover here (m), 0 for none
    float lowest;      // the lowest layer base with any cover here (m), 1e9 for none
};

inline CloudWeatherSample cloud_weatherAt(float3 pf, thread const CloudTextures &t, sampler wrap, sampler weather,
                                          constant CloudUniforms &u) {
    CloudWeatherSample w;
    if (u.lookDev.x > 0.5) {
        w.a = float4(u.lookDev.y, 0.0, 0.0, u.lookDevSlab.x);
        w.lowTop = u.lookDevSlab.y;
        w.topmost = u.lookDevSlab.y;
        w.lowest = u.lookDevSlab.x;
        return w;
    }
    float2 uv = cloud_weatherUV(pf, u);
    w.a = t.weatherA.sample(weather, uv, level(0.0));
    if (w.a.x > 0.002 || w.a.y > 0.002) { w.a.xy = cloud_structure(pf, w.a.xy, t, wrap, u); }
    bool low = w.a.x > 0.002, mid = w.a.y > 0.002;
    w.lowTop = low ? max(t.weatherB.sample(weather, uv, level(0.0)).x, w.a.w + 100.0) : 0.0;
    w.topmost = max(low ? w.lowTop : 0.0, mid ? u.layers.y : 0.0);
    w.lowest = low ? w.a.w : (mid ? u.layers.x : 1e9);
    return w;
}

// The curl (m, along and across) at camera-relative point q in a streak
// frame's tangent plane: continuous as its origin wraps (by whole curl
// periods: the shape period, and eight of it along).
inline float2 cloud_tangentCurl(float3 q, float3 a, float3 b, float3 o, thread const CloudTextures &t, sampler wrap,
                                constant CloudUniforms &u) {
    float2 m = float2(o.x * 8.0 + dot(q, a), o.y + dot(q, b));
    return t.curl.sample(wrap, m / u.windHigh.w, level(0.0)).xy;
}

// The cloud at camera-relative body point q (figure point pf, height h)
// with the weather there. `detailAmount` fades the erosion with distance;
// `cheap` leaves it and the curl out and reads the shape's coarser mip (the
// light march, the shadow map).
inline CloudSample cloud_density(float3 q, float h, CloudWeatherSample w, float detailAmount, bool cheap,
                                 thread const CloudTextures &t, sampler wrap, constant CloudUniforms &u) {
    CloudSample s = {0.0, 0.0, 0.0, -1.0};
    float4 wa = w.a;
    float lowBase = wa.w, lowTop = w.lowTop;
    bool inLow = wa.x > 0.002 && h >= lowBase && h <= lowTop;
    bool inMid = !inLow && wa.y > 0.002 && h >= u.layers.x && h <= u.layers.y;
    if (!inLow && !inMid) { return s; }
    if (u.lookDev.x > 0.5) {
        // A homogeneous slab: the far LUT's own case.
        s.sigma = u.lookDev.z / (lowTop - lowBase);
        s.column = u.lookDev.z;
        s.h01 = (h - lowBase) / (lowTop - lowBase);
        s.layer = 0.0;
        return s;
    }
    if (inLow) {
        float h01 = (h - lowBase) / (lowTop - lowBase);
        float4 shape = t.shape.sample(wrap, (u.noiseLow.xyz + q) / u.noiseLow.w, level(cheap ? 2.0 : 0.0));
        float d = cloud_baseDensity(shape, wa.x, cloud_profileLow(h01), u);
        if (d > 0.0 && !cheap && detailAmount > 0.0) {
            // The curl in the tangent plane of the detail's own frame (its
            // wind the low layer's, not the cirrus's), warping the detail
            // sideways, not up.
            float2 c = cloud_tangentCurl(q, u.detailAlong.xyz, u.detailAcross.xyz, u.detailOrigin.xyz, t, wrap, u);
            float3 warp = u.detailAlong.xyz * c.x + u.detailAcross.xyz * c.y;
            if (u.detailAlong.w > 0.0) {
                // A re-anchored frame fades in: the two frames' warps mix.
                float2 c2 = cloud_tangentCurl(q, u.detailAlong2.xyz, u.detailAcross2.xyz, u.detailOrigin2.xyz, t, wrap, u);
                warp = mix(warp, u.detailAlong2.xyz * c2.x + u.detailAcross2.xyz * c2.y, u.detailAlong.w);
            }
            warp *= 300.0 * (1.0 - h01);
            float3 pd = (u.noiseLow.xyz + q + warp) / u.noiseHigh.w;
            float3 dv = t.detail.sample(wrap, pd, level(0.0)).rgb;
            d = cloud_erode(d, dv.r * 0.625 + dv.g * 0.25 + dv.b * 0.125, detailAmount, h01);
        }
        // In cloud the extinction averages C1's (CloudCoverage's scale: the
        // thresholded shape alone averages 0.1-0.2 of it).
        s.sigma = d * cloud_table(u.densityLow, wa.x) * u.extinction.x * u.extinction.w;
        s.column = s.sigma * (lowTop - lowBase);
        s.h01 = h01;
        s.layer = 0.0;
    } else {
        float h01 = (h - u.layers.x) / (u.layers.y - u.layers.x);
        float4 shape = t.shape.sample(wrap, (u.noiseMid.xyz + q) / u.noiseMid.w, level(cheap ? 2.0 : 0.0));
        float d = cloud_baseDensity(shape, wa.y, cloud_profileMid(h01), u);
        if (d > 0.0 && !cheap && detailAmount > 0.0) {
            float3 dv = t.detail.sample(wrap, (u.noiseMid.xyz + q) / (2.0 * u.noiseHigh.w), level(0.0)).rgb;
            d = cloud_erode(d, dv.r * 0.625 + dv.g * 0.25 + dv.b * 0.125, detailAmount, h01);
        }
        s.sigma = d * cloud_table(u.densityMid, wa.y) * u.extinction.y * u.extinction.w;
        // The column the light sees: the lens's own depth, not the layer's
        // 3 km (lit as 3 km deep, a lens of optical depth 2 shone like an
        // altostratus of 28).
        s.column = s.sigma * (u.layers.y - u.layers.x) * cloud_table(u.columnMid, wa.y);
        s.h01 = h01;
        s.layer = 1.0;
    }
    return s;
}

// The extinction the light march sees at q (height h) with the weather of
// the sample it started from: the base shape at the shape volume's coarser
// mip, no detail.
inline float cloud_lightDensity(float3 q, float h, CloudWeatherSample w, thread const CloudTextures &t,
                                sampler wrap, constant CloudUniforms &u) {
    float4 wa = w.a;
    if (u.lookDev.x > 0.5) {
        return h >= wa.w && h <= w.lowTop ? u.lookDev.z / (w.lowTop - wa.w) : 0.0;
    }
    if (wa.x > 0.002 && h >= wa.w && h <= w.lowTop) {
        float h01 = (h - wa.w) / (w.lowTop - wa.w);
        float4 shape = t.shape.sample(wrap, (u.noiseLow.xyz + q) / u.noiseLow.w, level(2.0));
        return cloud_baseDensity(shape, wa.x, cloud_profileLow(h01), u) * cloud_table(u.densityLow, wa.x)
             * u.extinction.x * u.extinction.w;
    }
    if (wa.y > 0.002 && h >= u.layers.x && h <= u.layers.y) {
        float h01 = (h - u.layers.x) / (u.layers.y - u.layers.x);
        float4 shape = t.shape.sample(wrap, (u.noiseMid.xyz + q) / u.noiseMid.w, level(2.0));
        return cloud_baseDensity(shape, wa.y, cloud_profileMid(h01), u) * cloud_table(u.densityMid, wa.y)
             * u.extinction.y * u.extinction.w;
    }
    return 0.0;
}

// The cloud at q, its weather fetched there.
inline CloudSample cloud_sample(float3 q, float detailAmount, bool cheap, thread const CloudTextures &t,
                                sampler wrap, sampler weather, constant CloudUniforms &u) {
    float3 pf = cloud_figure(q, u);
    float h = cloud_height(pf, u);
    if (h < 0.0 || h > u.radii.z) { return CloudSample{0.0, 0.0, 0.0, -1.0}; }
    return cloud_density(q, h, cloud_weatherAt(pf, t, wrap, weather, u), detailAmount, cheap, t, wrap, u);
}

// ------------------------------------------------- the air (stand-in) ---
// A1's transmittance and sky-irradiance tables (OrbitCore's AtmosphereLUT,
// uploaded by CloudPass until A2's AtmosphereContext is there), with A1's
// parametrisation (docs/m16/atmosphere-luts.md).

inline float cloud_texcoord(float x, float size) { return 0.5 / size + x * (1.0 - 1.0 / size); }

// The air's transmittance from height h (m) towards cosine mu to the top.
inline float3 cloud_airTransmittance(float h, float mu, texture2d<float> lut, sampler s, constant CloudUniforms &u) {
    float R = u.radii.x, top = u.radii.w;
    h = clamp(h, 0.0, top);
    float r = R + h, Rtop = R + top;
    float H = sqrt(top * (2.0 * R + top)), rho = sqrt(h * (2.0 * R + h));
    float d = max(-r * mu + sqrt(max((top - h) * (Rtop + r) + r * r * mu * mu, 0.0)), 0.0);
    float dmin = top - h, dmax = rho + H;
    float xmu = (d - dmin) / max(dmax - dmin, 1e-3), xr = rho / H;
    float2 uv = float2(cloud_texcoord(xmu, float(lut.get_width())), cloud_texcoord(xr, float(lut.get_height())));
    return lut.sample(s, uv).rgb;
}

// The Sun's transmittance at height h, cosine muS of the Sun from the
// zenith, faded over the Sun's disc as it sets behind the planet.
inline float3 cloud_sunTransmittance(float h, float muS, texture2d<float> lut, sampler s, constant CloudUniforms &u) {
    float r = u.radii.x + max(h, 0.0);
    float sinH = u.radii.x / r, cosH = -sqrt(max(1.0 - sinH * sinH, 0.0));
    float fade = cloud_smoothstep(-sinH * 0.00465, sinH * 0.00465, muS - cosH);
    return cloud_airTransmittance(h, muS, lut, s, u) * fade;
}

// The sky's irradiance on a level surface at height h, per unit solar irradiance.
inline float3 cloud_skyIrradiance(float h, float muS, texture2d<float> lut, sampler s, constant CloudUniforms &u) {
    float x = sqrt(clamp(h / u.radii.w, 0.0, 1.0));
    float2 uv = float2(cloud_texcoord(muS * 0.5 + 0.5, float(lut.get_width())), cloud_texcoord(x, float(lut.get_height())));
    return lut.sample(s, uv).rgb;
}

// ------------------------------------------- lighting (CloudLighting) ---

inline float cloud_hg(float c, float g) {
    float d = 1.0 + g * g - 2.0 * g * c;
    return (1.0 - g * g) / (4.0 * CLOUD_PI * d * sqrt(d));
}

inline float cloud_mie(float c, constant CloudUniforms &u) {
    float draine = cloud_hg(c, u.mie.y) * (1.0 + u.mie.z * c * c) / (1.0 + u.mie.z * (1.0 + 2.0 * u.mie.y * u.mie.y) / 3.0);
    return (1.0 - u.mie.w) * cloud_hg(c, u.mie.x) + u.mie.w * draine;
}

inline float2 cloud_streams(float t, float tau, float b) {
    t = clamp(t, 0.0, tau);
    float k = 1.0 / (1.0 + b * tau);
    return float2(1.0 - b * t * k, b * (tau - t) * k);   // down, up
}

inline float cloud_streamRadiance(float2 s, float muUp) {
    float w = 0.5 * (1.0 + clamp(muUp, -1.0, 1.0));
    return (w * s.y + (1.0 - w) * s.x) * (1.0 / CLOUD_PI);
}

inline float cloud_sunDiffuse(float t, float tau, float mu0, float muUp, constant CloudUniforms &u) {
    float flux = max(mu0, u.lighting.y);
    float2 s = cloud_streams(t, tau, u.lighting.x);
    s.x = max(s.x - exp(-t / flux), 0.0);
    return flux * cloud_streamRadiance(s, muUp);
}

inline float cloud_skyDiffuse(float tau, float h01, float muUp, constant CloudUniforms &u) {
    return cloud_streamRadiance(cloud_streams(tau * (1.0 - clamp(h01, 0.0, 1.0)), tau, u.lighting.x), muUp);
}

// ---------------------------------------------------- ray and shells ---

// The nearest root t >= 0 of |o + t d|² = r² with c = |o|² − r² (Double on
// the CPU), or -1; `far` the other.
inline float2 cloud_shell(float3 o, float3 d, float c) {
    float b = dot(o, d), a = dot(d, d);
    float disc = b * b - a * c;
    if (disc < 0.0) { return float2(-1.0); }
    float s = sqrt(disc);
    // Stable roots.
    float q = -(b + (b >= 0.0 ? s : -s));
    float t0 = c / q, t1 = q / a;
    return float2(min(t0, t1), max(t0, t1));
}

// The ray in figure coordinates: origin and direction for world distance t.
inline float3 cloud_figureDir(float3 d, constant CloudUniforms &u) { return float3(d.x, d.y, d.z * u.cameraFigure.w); }

// --------------------------------------------------- the far surface ---

// The slab LUT (CloudSlabLUT) for block b (layer l from above: 2l, from
// below: 2l + 1) at optical depth tau, the Sun's cosine mu0 and the eye's
// mu (from the zenith above, the nadir below): single scattering without
// phase, the Sun's diffuse light, the sky's, the transmittance.
inline float4 cloud_slabLUT(texture3d<float> lut, sampler s, int b, float tau, float mu0, float mu, constant CloudUniforms &u) {
    float depths = u.lut.x, cosines = u.lut.y;
    float thin = clamp(tau / u.lut.z, 0.0, 1.0);
    float k = log(max(tau, u.lut.z) / u.lut.z) / u.lut.w * (depths - 1.0);
    float x = clamp((mu - u.lut2.x) / (1.0 - u.lut2.x), 0.0, 1.0) * (cosines - 1.0);
    float y = clamp((mu0 - u.lut2.x) / (1.0 - u.lut2.x), 0.0, 1.0) * (cosines - 1.0);
    float z = float(b) * depths + clamp(k, 0.0, depths - 1.0);
    float3 uvw = (float3(x, y, z) + 0.5) / float3(cosines, cosines, 4.0 * depths);
    float4 v = lut.sample(s, uvw);
    // Below the least depth the light grows as the optical depth.
    return float4(v.rgb * thin, thin < 1.0 ? exp(-tau / max(mu, 0.02)) : v.a);
}

struct CloudResult {
    float4 color;     // premultiplied radiance (pre-exposed), 1 - T
    float front;      // m: where it becomes visible (R6's rule)
    float mean;       // m: its opacity-weighted distance
    float entry;      // m: where the ray first meets cloud
};

// One layer of the far regime at its reference shell (radius constant c,
// height h): cover from the weather, in-cloud optical depth from the layer
// model, the light from the slab LUT.
inline CloudResult cloud_farLayer(float3 of, float3 df, float3 d, float c, float href, int layer,
                                  thread const CloudTextures &t, texture3d<float> lut, texture2d<float> trans,
                                  texture2d<float> irr, sampler wrap, sampler linear, sampler weather,
                                  constant CloudUniforms &u) {
    CloudResult r = {float4(0.0), 1e30, 1e30, 1e30};
    float2 hit = cloud_shell(of, df, c);
    float th = hit.x >= 0.0 ? hit.x : hit.y;
    // None where the ray meets the ground first (the shell's far side
    // beyond the Earth).
    float2 ground = cloud_shell(of, df, u.shell.x);
    if (th < 0.0 || (ground.x >= 0.0 && ground.x < th)) { return r; }
    float3 pf = of + df * th;
    float3 up = normalize(float3(pf.x, pf.y, pf.z * u.cameraFigure.w));
    // Seen from above (the eye's cosine from the zenith) or from below
    // (from the nadir).
    float muSigned = -dot(d, up);
    bool below = muSigned < 0.0;
    float mu = max(abs(muSigned), 0.02);
    float mu0 = dot(u.sun.xyz, up);
    float4 wa, wb;
    if (u.lookDev.x > 0.5) {
        wa = float4(u.lookDev.y, 0.0, 0.0, u.lookDevSlab.x);
        wb = float4(u.lookDevSlab.y, 0.0, 0.0, 0.0);
    } else {
        float2 uv = cloud_weatherUV(pf, u);
        wa = t.weatherA.sample(weather, uv, level(0.0));
        wb = t.weatherB.sample(weather, uv, level(0.0));
        wa.xy = cloud_structure(pf, wa.xy, t, wrap, u);
    }
    float cover, thickness, beta;
    if (layer == 0) {
        cover = wa.x;
        thickness = max(wb.x - wa.w, 100.0);
        beta = u.extinction.x;
    } else {
        cover = wa.y;
        thickness = u.layers.y - u.layers.x;
        beta = u.extinction.y;
    }
    if (cover <= 0.002) { return r; }
    // Seen from below, the cover along the ray: a slant ray crosses the
    // layer over a span of thickness × tan θ, and sees through only where
    // the gaps of every cell on the way line up, 1 − (1 − c)^(1 + span /
    // cell), the cells a quarter of the layer's shape period. At the pad's
    // horizon (1° up) 1/10 cover is 0.76 opaque, as C2's own field
    // integrates (0.73-0.85); overhead it is the cover. From above the
    // cover itself: the deck's lit tops, as the march draws them from orbit
    // (testMarchAndFarAgreeOnABrokenDeck), whose oblique views see their
    // shadowed sides as well.
    // The mid layer's lens altocumulus fill only a band 200-280 m deep about
    // 0.35 of its 3 km (cloud_profileMid), so its span is that band's, an
    // effective 350 m fitted as the low layer's whole depth was: 0.19, 0.52
    // and 0.76 at 1/10, 3/10 and 5/10 1° up, the field 0.19-0.21, 0.49-0.53
    // and 0.74-0.80 (the #73 fix check's port).
    float cell = 0.25 * (layer == 0 ? u.noiseLow.w : u.noiseMid.w);
    float depth = layer == 0 ? thickness : 350.0;
    float span = depth * sqrt(max(1.0 - mu * mu, 0.0)) / mu;
    float seen = below ? 1.0 - pow(1.0 - min(cover, 1.0), 1.0 + span / cell) : cover;
    // C1's in-cloud optical depth, the march's own (its extinction averages
    // C1's where there is cloud), times farDensity.
    // The mid layer's lenses take the march's column depth (a twelfth of the
    // layer at low cover, CloudCoverage.columnDepth): C1's whole 3 km drew
    // them as an altostratus of optical depth 28 beside the march's 2-4,
    // a bright veil around a darker disc from orbit.
    if (layer == 1) { thickness *= cloud_table(u.columnMid, cover); }
    float tau = u.lookDev.x > 0.5 ? u.lookDev.z : beta * u.extinction.w * thickness * u.regime.w;
    float4 v = cloud_slabLUT(lut, linear, 2 * layer + (below ? 1 : 0), tau, mu0, mu, u);
    // The air above the layer's top, where its light comes from.
    float top = layer == 0 ? wb.x : u.layers.y;
    float3 sun = u.sunLight.rgb * cloud_sunTransmittance(top, mu0, trans, linear, u);
    float3 sky = u.sunLight.rgb * cloud_skyIrradiance(top, mu0, irr, linear, u);
    (void)href;
    float3 L = sun * (v.r * cloud_mie(dot(d, u.sun.xyz), u) + v.g) + sky * v.b;
    r.color = float4(L * seen, seen * (1.0 - v.a));
    r.front = th;
    r.entry = th;
    r.mean = th + 0.5 * thickness / mu;
    return r;
}

// The cirrus's optical depth (vertical) at camera-relative body point q on
// its shell, cover `cover`: fibres of the Worley fBm stretched eight times
// along the high wind, warped by the curl, cut at the cover's threshold;
// where the footprint `far` is large, the fibres' mean density.
// The cirrus's fibre value at q in one streak frame: the Worley fBm of 8
// and 16 cells, stretched eight times along the wind and warped 2 km by the
// curl in the tangent plane.
inline float cloud_cirrusFibres(float3 q, float3 a, float3 b, float3 n, float3 o, float lod,
                                thread const CloudTextures &t, sampler wrap, constant CloudUniforms &u) {
    float2 c = cloud_tangentCurl(q, a, b, o, t, wrap, u) * 2000.0;
    float3 pn = (o + float3((dot(q, a) + c.x) * 0.125, dot(q, b) + c.y, dot(q, n))) / u.noiseLow.w;
    float4 s = t.shape.sample(wrap, pn, level(lod));
    return s.b * 0.7 + s.a * 0.3;
}

// The fibres (128 m across, a texel of the shape volume) average out over
// footprints of 128-512 m: the weight of the deck's mean there. They are
// sampled at the shape's mip 0 or 1 only, since their thresholds and scale
// are mip 0's (coarser mips' values never cross them: partial cirrus
// vanished at 0.5-2.5 km footprints).
inline float cloud_cirrusFar(float footprint) { return cloud_smoothstep(128.0, 512.0, footprint); }

// The deck's mean optical depth where it is cloudy: C1's, through its depth
// (layers.w − layers.z: CloudPass.cirrusThickness).
inline float cloud_cirrusMeanDepth(constant CloudUniforms &u) {
    return u.extinction.z * (u.layers.w - u.layers.z) * u.extinction.w;
}

// The fibres' optical depth at q for a footprint (m), in the current
// streak frame (x) and, while a re-anchored one fades in, the one fading
// out (y; its weight cirrusAlong.w). The two are drawn and blended in light
// and opacity by the caller, a cross-fade (mixing their values before the
// threshold thinned partial cirrus to 0.17-0.58 of its depth mid-fade, and
// mixing their depths thickened it).
inline float2 cloud_cirrusDepth(float3 q, float cover, float footprint, thread const CloudTextures &t,
                                sampler wrap, constant CloudUniforms &u) {
    float lod = clamp(log2(max(footprint / 128.0, 1.0)), 0.0, 1.0);
    // The cirrus's own thresholds (CloudCoverage: the quantiles of its value,
    // not the shape's), and its scale, so its in-cloud optical depth averages
    // C1's.
    float theta = cloud_table(u.cirrusTheta, cover), k = cloud_table(u.cirrusScale, cover) * cloud_cirrusMeanDepth(u);
    float v = cloud_cirrusFibres(q, u.cirrusAlong.xyz, u.cirrusAcross.xyz, u.cirrusUp.xyz, u.cirrusOrigin.xyz, lod,
                                 t, wrap, u);
    float2 tau = float2(clamp(cloud_remap(v, theta, 1.0, 0.0, 1.0), 0.0, 1.0) * k, 0.0);
    if (u.cirrusAlong.w > 0.0) {
        float v2 = cloud_cirrusFibres(q, u.cirrusAlong2.xyz, u.cirrusAcross2.xyz, u.cirrusUp2.xyz, u.cirrusOrigin2.xyz,
                                      lod, t, wrap, u);
        tau.y = clamp(cloud_remap(v2, theta, 1.0, 0.0, 1.0), 0.0, 1.0) * k;
    }
    return tau;
}

// A thin slab of optical depth tau's light towards the eye (rgb, per unit of
// the Sun's light) and its opacity (a), seen at cosine mu of the zenith (m
// its magnitude), the Sun at mu0 (mu0c clamped), with ice's phase.
inline float4 cloud_cirrusLight(float tau, float mu, float m, float mu0, float mu0c, float phase, float3 sun, float3 sky,
                                constant CloudUniforms &u) {
    if (tau <= 1e-5) { return float4(0.0); }
    float single;
    if (mu > 0.0) {
        float k = 1.0 / mu0c + 1.0 / m;
        single = (1.0 - exp(-tau * k)) / (m * k);
    } else {
        float k = 1.0 / m - 1.0 / mu0c;
        single = abs(k) < 1e-3 ? tau / m * exp(-tau / m) : (exp(-tau / mu0c) - exp(-tau / m)) / (m * k);
    }
    // Beyond the once-scattered Sun, the light of the slab's diffuse streams
    // scattered towards the eye along the view, as the march takes it (at
    // mid-depth): the streams' outgoing flux already holds the first order,
    // which counted it twice (more light out than in at τ 0.2, μ0 0.12).
    float b = (1.0 - u.lighting.w) * 0.5;
    float2 st = cloud_streams(0.5 * tau, tau, b);
    float emit = 1.0 - exp(-tau / m);
    float2 sunSt = float2(max(st.x - exp(-0.5 * tau / mu0c), 0.0), st.y);
    float diffuse = mu0c * cloud_streamRadiance(sunSt, mu) * emit;
    float skyD = cloud_streamRadiance(st, mu) * emit;
    return float4(sun * (phase * single + diffuse) + sky * skyD, emit);
}

// The cirrus: a 2D layer of fibrous ice at its shell, its optical depth
// from the cover and streaks along the high wind; lit as a thin slab in
// closed form, from above or below, with ice's phase.
inline CloudResult cloud_cirrus(float3 of, float3 df, float3 d, float pixelAngle, thread const CloudTextures &t,
                                texture2d<float> trans, texture2d<float> irr, sampler wrap, sampler linear,
                                sampler weather, constant CloudUniforms &u) {
    CloudResult r = {float4(0.0), 1e30, 1e30, 1e30};
    if (u.lookDev.x > 0.5) { return r; }
    float2 hit = cloud_shell(of, df, u.shell.z);
    float th = hit.x >= 0.0 ? hit.x : hit.y;
    // None where the ray meets the ground first (from below the shell, its
    // far side beyond the Earth), as cloud_farLayer.
    float2 ground = cloud_shell(of, df, u.shell.x);
    if (th < 0.0 || (ground.x >= 0.0 && ground.x < th)) { return r; }
    float3 pf = of + df * th;
    float cover = t.weatherA.sample(weather, cloud_weatherUV(pf, u), level(0.0)).z;
    if (cover <= 0.002) { return r; }
    float3 up = normalize(float3(pf.x, pf.y, pf.z * u.cameraFigure.w));
    float mu = dot(-d, up), m = max(abs(mu), 0.03);
    float mu0 = dot(u.sun.xyz, up);
    float footprint = th * pixelAngle / m;
    float mu0c = max(mu0, u.lighting.y);
    float phase = cloud_hg(dot(d, u.sun.xyz), u.lighting.w);
    float h = u.shellMid.y;
    float3 sun = u.sunLight.rgb * cloud_sunTransmittance(h, mu0, trans, linear, u);
    float3 sky = u.sunLight.rgb * cloud_skyIrradiance(h, mu0, irr, linear, u);
    // The fibres, and far away the deck's mean: its in-cloud depth over the
    // cover's share. They blend in premultiplied light and opacity, each lit
    // at its own depth (blending the depth and the cover apart overshot the
    // deck's opacity 3-6 times at low cover).
    float far = cloud_cirrusFar(footprint);
    float4 c = float4(0.0);
    if (far < 1.0) {
        float2 tf = cloud_cirrusDepth(d * th, cover, footprint, t, wrap, u);
        float4 lf = cloud_cirrusLight(tf.x, mu, m, mu0, mu0c, phase, sun, sky, u);
        if (u.cirrusAlong.w > 0.0) {
            lf = mix(lf, cloud_cirrusLight(tf.y, mu, m, mu0, mu0c, phase, sun, sky, u), u.cirrusAlong.w);
        }
        c += (1.0 - far) * lf;
    }
    if (far > 0.0) {
        c += far * cover * cloud_cirrusLight(cloud_cirrusMeanDepth(u), mu, m, mu0, mu0c, phase, sun, sky, u);
    }
    if (c.a <= 1e-6) { return r; }
    r.color = c;
    r.front = th;
    r.mean = th;
    r.entry = th;
    return r;
}

// ------------------------------------------------------- the march ---

inline float cloud_noise(float2 p, float frame) {
    p += 5.588238 * fmod(frame, 64.0);
    return fract(52.9829189 * fract(dot(p, float2(0.06711056, 0.00583715))));
}

// The volumetric march of the low and mid layers along body direction d
// over [t0, t1]. Through clear air it takes the base step (uniform across
// the stretch, or growing with the distance when `near`); on meeting cloud
// it backs off half a base step and goes on in steps of at most 0.4 optical
// depth, so the light is integrated as finely in a thin slab as in a
// cumulus tower.
inline CloudResult cloud_march(float3 d, float t0, float t1, bool near, float jitter,
                               thread const CloudTextures &t, texture2d<float> trans, texture2d<float> irr,
                               sampler wrap, sampler linear, sampler weather, constant CloudUniforms &u,
                               constant EffectSlotUniforms &e) {
    CloudResult r = {float4(0.0), 1e30, 0.0, 1e30};
    int steps = int(u.march.x);
    float span = t1 - t0;
    // The base step: span / steps, or for the near field growing with the
    // distance (the quadratic spacing's local step).
    float base = span / float(steps);
    float3 L = float3(0.0);
    float T = 1.0, weightedDepth = 0.0, opacity = 0.0;
    float cosTheta = dot(d, u.sun.xyz);
    float phase = cloud_mie(cosTheta, u);
    float lightDistance = u.march.z;
    float tm = t0 + jitter * (near ? base * 0.05 : base);
    bool inCloud = false;
    // The last sample known to be in clear air: first contact finds the
    // cloud's edge between it and itself by bisection.
    float clear = t0;
    // The weather, fetched again once the ray has gone 4 km (its grid is 28 km).
    CloudWeatherSample w;
    float fetchedAt = -1e30;
    for (int i = 0; i < steps * 2 && tm < t1; i++) {
        float x = (tm - t0) / max(span, 1.0);
        float empty = near ? max(2.0 * x * span / float(steps), base * 0.05) : base;
        float3 q = d * tm;
        float3 pf = cloud_figure(q, u);
        float h = cloud_height(pf, u);
        float3 up = normalize(float3(pf.x, pf.y, pf.z * u.cameraFigure.w));
        float muUp = -dot(d, up);
        if (abs(tm - fetchedAt) > 4000.0) {
            w = cloud_weatherAt(pf, t, wrap, weather, u);
            fetchedAt = tm;
        }
        // Below every layer going down: nothing more to meet.
        if (!inCloud && muUp > 0.0 && h < w.lowest - 50.0 && h < u.layers.x) { break; }
        // Outside every layer here: straight to the nearest boundary the
        // ray reaches (above them going down, below them going up), on the
        // curved Earth, at most 20 km at a time (the weather changes).
        if (!inCloud && (h > w.topmost + 50.0 || h < w.lowest - 50.0)) {
            float R = u.radii.x, skip = 20000.0;
            float target = h > w.topmost ? w.topmost + 25.0 : w.lowest - 25.0;
            // h(s) = h + k s + s² / 2R along the ray, k its own upward
            // cosine (muUp is the light's, towards the eye).
            float k = -muUp;
            float disc = k * k + 2.0 * (target - h) / R;
            if (disc >= 0.0) {
                float sq = sqrt(disc);
                float r0 = R * (-k - sq), r1 = R * (-k + sq);
                float hit = r0 > 0.0 ? r0 : (r1 > 0.0 ? r1 : skip);
                skip = min(skip, hit);
            }
            clear = tm;
            tm += max(empty, skip);
            continue;
        }
        float detail = u.lighting.z * (1.0 - cloud_smoothstep(15000.0, 60000.0, tm));
        CloudSample c = h < 0.0 || h > u.radii.z ? CloudSample{0.0, 0.0, 0.0, -1.0}
                                                 : cloud_density(q, h, w, detail, false, t, wrap, u);
        // Within a layer, steps of at most a twelfth of its depth up or
        // down, in clear air and in cloud: a lens of altocumulus at low cover
        // is 200-280 m deep, which the orbit march's steps of 0.5-1 km hit or
        // missed by their jitter.
        float depth = h >= w.a.w && h <= w.lowTop ? w.lowTop - w.a.w
                    : (h >= u.layers.x && h <= u.layers.y ? u.layers.y - u.layers.x : 1e9);
        float within = min(empty, max(depth / 12.0 / max(abs(muUp), 0.05), 1.0));
        if (c.sigma <= 0.0) {
            inCloud = false;
            clear = tm;
            tm += within;
            continue;
        }
        // Steps of 0.4 optical depth through the cloud's first two (its
        // visible face, where the light changes fastest), then coarser
        // with the distance, up to 2 beyond 80 km.
        float maxTau = T > 0.135 ? 0.4 : min(0.4 * (1.0 + tm / 20000.0), 2.0);
        float dt = clamp(maxTau / c.sigma, 1.0, within);
        if (!inCloud) {
            // First contact: the edge between the last clear sample and
            // this one, by bisection (to a sixteenth), then the first
            // step's light at its middle (the midpoint rule, as the slab
            // LUT's bake).
            float a = clear, b = tm;
            for (int k = 0; k < 4; k++) {
                float m = 0.5 * (a + b);
                float3 qm = d * m;
                float hm = cloud_height(cloud_figure(qm, u), u);
                bool cloudy = hm >= 0.0 && hm <= u.radii.z && cloud_density(qm, hm, w, detail, false, t, wrap, u).sigma > 0.0;
                if (cloudy) { b = m; } else { a = m; }
            }
            r.entry = min(r.entry, b);
            inCloud = true;
            tm = b + 0.5 * clamp(0.4 / c.sigma, 1.0, within);
            continue;
        }
        float mu0 = dot(u.sun.xyz, up);
        // The light march towards the Sun, with this sample's weather;
        // fewer samples far away.
        float tauSun = 0.0, lastSigma = 0.0;
        // CloudLighting's light march: CLOUD_LIGHT_SAMPLES midpoints of
        // segments ending at (k/K)², unrolled so their fetches overlap.
        #pragma unroll
        for (int k = 0; k < CLOUD_LIGHT_SAMPLES; k++) {
            float a0 = float(k) / float(CLOUD_LIGHT_SAMPLES), a1 = float(k + 1) / float(CLOUD_LIGHT_SAMPLES);
            float e0 = a0 * a0, e1 = a1 * a1;
            float sl = lightDistance * 0.5 * (e0 + e1);
            lastSigma = cloud_lightDensity(q + u.sun.xyz * sl, h + sl * mu0, w, t, wrap, u);
            tauSun += lastSigma * lightDistance * (e1 - e0);
        }
        // CloudLighting.columnDepth: the light march's depth only if it came
        // out of the cloud.
        float byHeight = c.column * (1.0 - c.h01);
        float tcol = lastSigma <= 0.0 ? min(byHeight, tauSun * max(mu0, u.lighting.y)) : byHeight;
        float3 sunT = cloud_sunTransmittance(h, mu0, trans, linear, u);
        float3 sky = cloud_skyIrradiance(h, mu0, irr, linear, u);
        float3 source = u.sunLight.rgb * sunT * (phase * exp(-tauSun) + cloud_sunDiffuse(tcol, c.column, mu0, muUp, u))
                      + u.sunLight.rgb * sky * cloud_skyDiffuse(c.column, c.h01, muUp, u);
        float stepT = exp(-c.sigma * dt);
        L += T * source * (1.0 - stepT);
        float before = T;
        T *= stepT;
        weightedDepth += (before - T) * (tm + 0.5 * dt);
        opacity += before - T;
        if (r.front > 1e29 && orbit_frontReached(1.0 - T, L, e)) { r.front = tm; }
        tm += dt;
        if (T < 0.005) { break; }
    }
    r.color = float4(min(L, float3(6e4)), 1.0 - T);
    r.mean = opacity > 0.0 ? weightedDepth / opacity : 1e30;
    return r;
}

// One layer result over another (premultiplied), the nearer first.
inline CloudResult cloud_over(CloudResult nearer, CloudResult farther) {
    CloudResult r;
    r.color = nearer.color + (1.0 - nearer.color.a) * farther.color;
    r.front = min(nearer.front, farther.front);
    float wa = nearer.color.a, wb = (1.0 - nearer.color.a) * farther.color.a;
    r.mean = wa + wb > 0.0 ? (wa * min(nearer.mean, 1e12) + wb * min(farther.mean, 1e12)) / (wa + wb) : 1e30;
    r.entry = min(nearer.entry, farther.entry);
    return r;
}

// Depths in the cloud targets: log2 of the linear (view-axis) depth in
// half floats, CLOUD_NO_DEPTH where there is none.
#define CLOUD_NO_DEPTH 60.0
inline float cloud_encodeDepth(float z) { return z < 1e29 ? log2(max(z, 1.0 / 16384.0)) : CLOUD_NO_DEPTH; }
inline float cloud_decodeDepth(float c) { return c >= CLOUD_NO_DEPTH - 0.5 ? 1e30 : exp2(c); }

// A texel's ray: body direction, its figure origin and direction, the
// linear depth per metre along it, the stretch of the clouds' shell it
// crosses ([t0, t1], m), and the far layer's weight there (the footprint
// where it meets the low layer, or the regime).
struct CloudRay {
    float3 d;
    float3 of;
    float3 df;
    float depthPerMetre;
    float t0;
    float t1;
    float wFar;
    float reference;   // m along the ray to the low layer's reference shell (or the shell's start)
    float ground;      // m along the ray to the ground, 1e30 for none
    bool inside;
    bool valid;
};

inline CloudRay cloud_ray(float2 px, constant CloudUniforms &u, constant FrameUniforms &frame) {
    CloudRay r;
    float3 vr = orbit_viewRay(px, frame);
    float3 w = normalize((frame.viewToWorld * float4(vr, 0.0)).xyz);
    r.d = normalize((u.worldToBody * float4(w, 0.0)).xyz);
    r.depthPerMetre = 1.0 / length(vr);
    r.of = u.cameraFigure.xyz;
    r.df = cloud_figureDir(r.d, u);
    float2 top = cloud_shell(r.of, r.df, u.shell.y);
    float2 ground = cloud_shell(r.of, r.df, u.shell.x);
    float tGround = ground.x >= 0.0 ? ground.x : 1e30;
    r.ground = tGround;
    r.inside = u.radii.y <= u.radii.z;
    r.t0 = r.inside ? 0.0 : top.x;
    r.t1 = min(r.inside ? (top.y >= 0.0 ? top.y : top.x) : top.y, tGround);
    if (r.inside) { r.t1 = min(r.t1, u.march.w); }
    r.valid = !(top.x < 0.0 && top.y < 0.0) && r.t1 > r.t0 && r.t0 >= 0.0;
    // The footprint where the ray meets the low layer's reference shell,
    // from above or from below.
    float2 hitLow = cloud_shell(r.of, r.df, u.shell.w);
    float tl = hitLow.x >= 0.0 ? hitLow.x : (hitLow.y >= 0.0 ? hitLow.y : max(r.t0, 0.0));
    r.reference = tl;
    float3 pf = r.of + r.df * tl;
    float3 up = normalize(float3(pf.x, pf.y, pf.z * u.cameraFigure.w));
    float footprint = tl * u.footprint.x / max(abs(dot(r.d, up)), 0.02);
    // In the shell, the far layer only where the camera is clear of the
    // layers the ray meets: under the cloud base, over the mid layer, or
    // between the low layer's top and the mid layer's base looking down
    // (such a ray meets the low layer only, from above). The far layers lie
    // at their reference shells (2 and 4.5 km), so the camera must be on the
    // same side of those as of the weather's layers: under a base above 2 km
    // the low shell would be seen from above, over a fog's top under 2 km
    // from below. Inside a layer the march is everything.
    float hc = u.radii.y, lowBase = u.lut2.z, lowTop = u.lut2.w;
    float lowRef = u.shellMid.z, midRef = u.shellMid.w;
    float3 upCamera = normalize(float3(r.of.x, r.of.y, r.of.z * u.cameraFigure.w));
    float below = (1.0 - cloud_smoothstep(lowBase - 300.0, lowBase - 50.0, hc))
        * (1.0 - cloud_smoothstep(lowRef - 300.0, lowRef - 50.0, hc));
    float above = cloud_smoothstep(u.layers.y + 50.0, u.layers.y + 500.0, hc);
    float between = dot(r.d, upCamera) < 0.0
        ? cloud_smoothstep(lowTop + 50.0, lowTop + 300.0, hc) * (1.0 - cloud_smoothstep(u.layers.x - 100.0, u.layers.x + 50.0, hc))
          * cloud_smoothstep(lowRef + 50.0, lowRef + 300.0, hc) * (1.0 - cloud_smoothstep(midRef - 300.0, midRef - 50.0, hc))
        : 0.0;
    float clear = r.inside ? max(below, max(above, between)) : 1.0;
    // A ray that meets the ground before the low layer's shell (going down
    // under it: the shell's far side is beyond the Earth) has no far layer.
    if (hitLow.x < 0.0 && tGround < tl) { clear = 0.0; }
    r.wFar = max(u.regime.z, clear * cloud_smoothstep(u.footprint.y, u.footprint.z, footprint));
    if (u.lookDev.w > 1.5) { r.wFar = 0.0; }
    if (u.lookDev.w > 0.5 && u.lookDev.w < 1.5) { r.wFar = 1.0; }
    return r;
}

// The march of the low and mid layers at texel gid (one in each 2x2 block
// when reprojecting, every texel otherwise), where the far layer does not
// take it whole. Colour: premultiplied radiance (pre-exposed), 1 - T;
// depth: front, mean, entry (cloud_encodeDepth).
kernel void cloud_march_kernel(texture2d<float, access::write> outColor [[texture(0)]],
                               texture2d<float, access::write> outDepth [[texture(1)]],
                               texture3d<float> shape [[texture(2)]],
                               texture3d<float> detail [[texture(3)]],
                               texture2d<float> curl [[texture(4)]],
                               texture2d<float> weatherA [[texture(5)]],
                               texture2d<float> weatherB [[texture(6)]],
                               texture2d<float> trans [[texture(8)]],
                               texture2d<float> irr [[texture(9)]],
                               sampler wrap [[sampler(0)]],
                               sampler weather [[sampler(1)]],
                               sampler linear [[sampler(ORBIT_SAMPLER_LINEAR_CLAMP)]],
                               constant CloudUniforms &u [[buffer(0)]],
                               constant EffectSlotUniforms &e [[buffer(1)]],
                               constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]],
                               uint2 tid [[thread_position_in_grid]]) {
    uint2 gid = u.checker.z > 0.5 ? tid * 2u + uint2(u.checker.xy) : tid;
    if (gid.x >= uint(u.target.x) || gid.y >= uint(u.target.y)) { return; }
    CloudRay ray = cloud_ray((float2(gid) + 0.5) * u.target.zw, u, frame);
    if (!ray.valid || ray.wFar >= 1.0) {
        outColor.write(float4(0.0), gid);
        outDepth.write(float4(CLOUD_NO_DEPTH), gid);
        return;
    }
    CloudTextures t = {shape, detail, curl, weatherA, weatherB};
    float jitter = cloud_noise(float2(gid), u.checker.w);
    CloudResult m = cloud_march(ray.d, ray.t0, ray.t1, ray.inside, jitter, t, trans, irr, wrap, linear, weather, u, e);
    float4 c = m.color;
    if (orbit_isNotFinite(c.rgb) || orbit_isNotFinite(c.a)) { c = float4(0.0); }
    outColor.write(float4(min(c.rgb, float3(6e4)), clamp(c.a, 0.0, 1.0)), gid);
    // A texel with no cloud keeps, as its mean depth, the low layer's
    // reference shell along the ray: the resolve reprojects it from there.
    // At no depth it was reprojected as a direction, as if at infinity: from
    // LEO, clouds 200 km off then drifted half a pixel a frame against their
    // history, which smeared broken cloud into streaks along the motion. (The
    // slot weighs the mean by the opacity, none here.)
    float mean = m.mean < 1e29 ? m.mean : (ray.reference > 0.0 ? ray.reference : 1e30);
    outDepth.write(float4(cloud_encodeDepth(m.front * ray.depthPerMetre), cloud_encodeDepth(mean * ray.depthPerMetre),
                          cloud_encodeDepth(m.entry * ray.depthPerMetre), 0.0), gid);
}

// ------------------------------------------------- the temporal resolve ---

struct CloudResolveUniforms {
    float4x4 reprojection;   // camera-relative world now -> last frame's clip
    float4 target;           // xy: size, zw: frame pixels per texel
    float4 checker;          // xy: this frame's texel, z: 1 reprojecting, w: 1 history valid, -1 no march this frame
};

// Every texel of the march target: marched this frame, or last frame's at
// the same body-fixed point (its colour filtered, its depths the nearest
// texel's) clamped to the box of this frame's marched neighbours: the
// march's clouds, kept as the history and read by the slot copy.
kernel void cloud_resolve(texture2d<float, access::read> fresh [[texture(10)]],
                          texture2d<float, access::read> freshDepth [[texture(11)]],
                          texture2d<float> history [[texture(12)]],
                          texture2d<float, access::read> historyDepth [[texture(13)]],
                          texture2d<float, access::write> keepColor [[texture(14)]],
                          texture2d<float, access::write> keepDepth [[texture(15)]],
                          sampler linear [[sampler(ORBIT_SAMPLER_LINEAR_CLAMP)]],
                          constant CloudResolveUniforms &r [[buffer(1)]],
                          constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]],
                          uint2 gid [[thread_position_in_grid]]) {
    uint2 size = uint2(r.target.xy);
    if (gid.x >= size.x || gid.y >= size.y) { return; }
    bool marched = r.checker.z < 0.5 || all((gid & 1u) == uint2(r.checker.xy));
    float4 mc, md;
    if (r.checker.w < -0.5) {
        // No march this frame (the far layer takes every texel).
        mc = float4(0.0);
        md = float4(CLOUD_NO_DEPTH);
    } else if (marched) {
        mc = fresh.read(gid);
        md = freshDepth.read(gid);
        // Reprojecting, a marched texel averages with its history (the
        // march's jitter), unless the two disagree (disocclusion).
        if (r.checker.z > 0.5 && r.checker.w > 0.5) {
            float2 px = (float2(gid) + 0.5) * r.target.zw;
            float3 w = (frame.viewToWorld * float4(orbit_viewRay(px, frame), 0.0)).xyz;
            float z = cloud_decodeDepth(md.y);
            float4 clip = z < 1e12 ? r.reprojection * float4(w * z, 1.0) : r.reprojection * float4(w, 0.0);
            if (clip.w > 0.0) {
                float2 ndc = clip.xy / clip.w;
                float2 uv = float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
                if (all(uv >= 0.0) && all(uv <= 1.0)) {
                    float4 h = history.sample(linear, uv, level(0.0));
                    // Last frame's radiance at this frame's pre-exposure.
                    h.rgb *= frame.exposure.z;
                    if (abs(h.a - mc.a) < 0.25) { mc = mix(h, mc, 0.5); }
                }
            }
        }
    } else {
        // This frame's marched texels: this 2x2 block's and the three
        // blocks towards this texel.
        uint2 own = (gid & ~1u) + uint2(r.checker.xy);
        int2 step = int2(gid.x >= own.x ? 2 : -2, gid.y >= own.y ? 2 : -2);
        float4 n0 = fresh.read(own);
        float4 lo = n0, hi = n0;
        float4 nd = freshDepth.read(own);
        // The front and entry: the nearest of this frame's marched
        // neighbours'. (The history's, min'd with them, only ever came
        // nearer: three texels in four held stale entries, which flipped the
        // slot's order of the parts along the checkerboard's rows, lines in
        // the hand-over from orbit.)
        float2 nearest = nd.xz;
        int2 others[3] = {int2(own) + int2(step.x, 0), int2(own) + int2(0, step.y), int2(own) + step};
        for (int k = 0; k < 3; k++) {
            int2 p = clamp(others[k], int2(0), int2(size) - 1);
            float4 c = fresh.read(uint2(p));
            lo = min(lo, c);
            hi = max(hi, c);
            nearest = min(nearest, freshDepth.read(uint2(p)).xz);
        }
        mc = n0;
        md = nd;
        if (r.checker.w > 0.5) {
            // The point at the cloud's mean depth along this texel's ray,
            // in last frame's view (a direction where there is no cloud).
            float2 px = (float2(gid) + 0.5) * r.target.zw;
            float3 w = (frame.viewToWorld * float4(orbit_viewRay(px, frame), 0.0)).xyz;
            float z = cloud_decodeDepth(nd.y);
            float4 clip = z < 1e12 ? r.reprojection * float4(w * z, 1.0) : r.reprojection * float4(w, 0.0);
            if (clip.w > 0.0) {
                float2 ndc = clip.xy / clip.w;
                float2 uv = float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
                if (all(uv >= 0.0) && all(uv <= 1.0)) {
                    float4 h = history.sample(linear, uv, level(0.0));
                    h.rgb *= frame.exposure.z;
                    float4 margin = (hi - lo) * 0.1;
                    mc = clamp(h, lo - margin, hi + margin);
                    float4 hd = historyDepth.read(min(uint2(uv * r.target.xy), size - 1u));
                    md = float4(nearest.x, hd.y, nearest.y, 0.0);
                }
            }
        }
    }
    keepColor.write(mc, gid);
    keepDepth.write(md, gid);
}

// ------------------------------------------------ the cloud shadow map ---

// The sky's light reaching the ground at figure point pf through the clouds
// overhead, per unit of the clear sky's. Diffuse light comes through the
// cover over the whole sky, not along one line: each layer has gaps, which
// pass it whole, and cloudy columns of their mean optical depth
// (CloudCoverage.columnDepth), the layers overlapping at random. Over each
// of the eight cases (each layer cloudy or clear overhead, by the product
// of its cover or its gap), the cloudy layers pass it as conservative slabs
// stacked by the two-stream adding rule, 1/T = 1 + sum (1 - g_i) tau_i / 2
// (Bohren 1987; T12 = T1 T2 / (1 - R1 R2), the light reflected back and
// forth between decks; C2's own streams pass the sky's light down so, and
// the Sun's term adds the layers' depths alike), g 0.85 for water and 0.75
// for ice. The weather's covers are 25 km cells, about the scale of the sky
// a point sees through a deck 1-2 km up, so the sky's light does not follow
// the clouds' cast shadows as the Sun's does.
inline float cloud_skyColumn(float3 pf, thread const CloudTextures &t, sampler wrap, sampler weather,
                             constant CloudUniforms &u) {
    CloudWeatherSample w = cloud_weatherAt(pf, t, wrap, weather, u);
    float3 c = float3(w.a.x > 0.002 ? w.a.x : 0.0, w.a.y > 0.002 ? w.a.y : 0.0,
                      u.lookDev.x > 0.5 ? 0.0 : t.weatherA.sample(weather, cloud_weatherUV(pf, u), level(0.0)).z);
    float tauLow = u.lookDev.x > 0.5 ? u.lookDev.z
        : u.extinction.x * u.extinction.w * max(w.lowTop - w.a.w, 0.0) * cloud_table(u.columnLow, c.x);
    float tauMid = u.extinction.y * u.extinction.w * (u.layers.y - u.layers.x) * cloud_table(u.columnMid, c.y);
    // Each layer's (1 - g) tau / 2 when cloudy.
    float3 k = float3(0.075 * tauLow, 0.075 * tauMid, 0.125 * cloud_cirrusMeanDepth(u));
    float sum = 0.0;
    for (int m = 0; m < 8; m++) {
        float3 on = float3(float(m & 1), float((m >> 1) & 1), float((m >> 2) & 1));
        float3 p = mix(1.0 - c, c, on);
        sum += p.x * p.y * p.z / (1.0 + dot(on, k));
    }
    return sum;
}

// Where a line along the Sun from figure point pf0 (height hBase) is at
// height h: the roots of |pf0 + sF t|² = (R + h)² in figure space (heights
// are |pf| − R there, cloud_height), sF = cloud_figureDir(s), which
// stretches z by a/b; t is world distance. A t² + 2 b t = (h − hBase)(2R +
// h + hBase), A = |sF|², b = pf0 · sF, in a form exact in floats: x where
// the line rises toward the Sun, y where it falls; where it never comes
// down to h, both its lowest point, −b / A. (The sphere's own quadratic
// with A 1 and b (R + hBase) μ0 dropped the stretch: the line's heights
// were off by 0.3-1.4 km at mid latitudes, 2 km at a 20° Sun, and the
// march's window missed up to 40 % of the low deck at one end. Before
// that the parabola h = hBase + μ0 t + t²/2R, which drops 1 − μ0² as
// well, marched the low layer kilometres under its heights from orbit.)
inline float2 cloud_lineAt(float3 pf0, float3 sF, float hBase, float h, constant CloudUniforms &u) {
    float A = dot(sF, sF), b = dot(pf0, sF);
    float q = sqrt(max(b * b + A * (h - hBase) * (2.0 * u.radii.x + h + hBase), 0.0));
    return float2(-b + q, -b - q) / A;
}

// Texel gid's Sun ray through the shell: the optical depth above each of
// the four altitudes in u.shadowLevels; and in `sky` the sky's light on the
// ground (cloud_skyColumn) where the texel's line meets it: x where it
// rises toward the Sun (a ground point with the Sun up), y where it falls
// (with the Sun under its horizon, the line rising again beyond the Earth's
// limb). A line that passes over the ground takes its lowest point for both,
// where the two merge at tangency, so the map is continuous through the
// terminator (a clear 1 there bled into the band of ground near tangency
// through the bilinear filter).
kernel void cloud_shadow(texture2d<float, access::write> out [[texture(0)]],
                         texture2d<float, access::write> sky [[texture(1)]],
                         texture3d<float> shape [[texture(2)]],
                         texture3d<float> detail [[texture(3)]],
                         texture2d<float> curl [[texture(4)]],
                         texture2d<float> weatherA [[texture(5)]],
                         texture2d<float> weatherB [[texture(6)]],
                         sampler wrap [[sampler(0)]],
                         sampler weather [[sampler(1)]],
                         constant CloudUniforms &u [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    uint n = uint(u.shadow.y);
    if (gid.x >= n || gid.y >= n) { return; }
    CloudTextures t = {shape, detail, curl, weatherA, weatherB};
    float2 uv = (float2(gid) + 0.5) / float(n);
    float3 base = u.shadowCenter.xyz + u.shadowU.xyz * ((uv.x - 0.5) * u.shadow.x) + u.shadowV.xyz * ((uv.y - 0.5) * u.shadow.x);
    float3 s = u.sun.xyz;
    float3 pf0 = cloud_figure(base, u), sF = cloud_figureDir(s, u);
    float hBase = cloud_height(pf0, u);
    // Along the Sun from the map's plane, t at height h where the line
    // rises (cloud_lineAt: the heights in figure space, at any height of the
    // Sun; under the line's lowest point, the lowest point).
    #define CLOUD_RAY_AT(h) (cloud_lineAt(pf0, sF, hBase, (h), u).x)
    float4 tauAbove = float4(0.0);
    // The weather where the ray crosses the low and the mid layers (not at
    // the plane's point, kilometres off at a low Sun), for the heights the
    // layers span there.
    CloudWeatherSample wl = cloud_weatherAt(cloud_figure(base + s * CLOUD_RAY_AT(1500.0), u), t, wrap, weather, u);
    CloudWeatherSample wm = cloud_weatherAt(cloud_figure(base + s * CLOUD_RAY_AT(4500.0), u), t, wrap, weather, u);
    float topmost = max(wl.topmost, wm.topmost), lowest = min(wl.lowest, wm.lowest);
    if (topmost > 0.0) {
        float hTop = min(topmost + 300.0, u.radii.z), hBottom = max(lowest - 300.0, 0.0);
        // (The rising root: t may be negative, where the map's plane is above
        // the layer; the ray is the texel's whole line along the Sun.)
        float tTop = CLOUD_RAY_AT(hTop), tBottom = CLOUD_RAY_AT(hBottom);
        int steps = int(u.shadow.w);
        float dt = (tTop - tBottom) / float(steps);
        float fetchedAt = -1e30;
        CloudWeatherSample w = wl;
        for (int i = 0; i < steps; i++) {
            float tm = tBottom + (float(i) + 0.5) * dt;
            float3 q = base + s * tm;
            float3 pf = cloud_figure(q, u);
            float h = cloud_height(pf, u);
            // The weather where the sample is, again every 4 km.
            if (abs(tm - fetchedAt) > 4000.0) {
                w = cloud_weatherAt(pf, t, wrap, weather, u);
                fetchedAt = tm;
            }
            float add = cloud_density(q, h, w, 0.0, true, t, wrap, u).sigma * dt;
            for (int k = 0; k < 4; k++) {
                if (h >= u.shadowLevels[k]) { tauAbove[k] += add; }
            }
        }
    }
    // The cirrus, above every level but the top one, where the ray crosses
    // its shell: its transmittance over the texel (the fibres, or the deck's
    // mean as the texel grows, as the view's blend), along the Sun's slant
    // there.
    if (u.lookDev.x < 0.5) {
        float3 qc = base + s * CLOUD_RAY_AT(u.shellMid.y);
        float3 pfc = cloud_figure(qc, u);
        float cover = t.weatherA.sample(weather, cloud_weatherUV(pfc, u), level(0.0)).z;
        if (cover > 0.002) {
            float3 upc = normalize(float3(pfc.x, pfc.y, pfc.z * u.cameraFigure.w));
            float muc = max(dot(s, upc), 0.02);
            float texel = u.shadow.x / u.shadow.y, far = cloud_cirrusFar(texel);
            float2 df = far < 1.0 ? cloud_cirrusDepth(qc, cover, texel, t, wrap, u) : float2(0.0);
            float tf = mix(exp(-df.x / muc), exp(-df.y / muc), u.cirrusAlong.w);
            float tm = 1.0 - cover + cover * exp(-cloud_cirrusMeanDepth(u) / muc);
            float tc = -log(max(mix(tf, tm, far), 1e-6));
            for (int k = 0; k < 4; k++) {
                if (u.shadowLevels[k] < u.shellMid.y) { tauAbove[k] += tc; }
            }
        }
    }
    #undef CLOUD_RAY_AT
    out.write(tauAbove, gid);
    // The line's ground points (its lowest point where it passes over the
    // ground).
    float2 g = cloud_lineAt(pf0, sF, hBase, 0.0, u);
    float2 skyT = float2(cloud_skyColumn(cloud_figure(base + s * g.x, u), t, wrap, weather, u),
                         cloud_skyColumn(cloud_figure(base + s * g.y, u), t, wrap, weather, u));
    sky.write(float4(skyT, 0.0, 0.0), gid);
}

// ------------------------------------------- into R6's clouds layer ---

struct CloudSlotOut {
    float4 position [[position]];
};

vertex CloudSlotOut cloud_slot_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    CloudSlotOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

// The air between a camera inside it and a cloud result (A2's aerial
// perspective at its opacity-weighted mean distance, screen uv): its light
// dimmed by the air's transmittance, and the air's own light in front of it
// where it is opaque. Premultiplied and pre-exposed, as the result. One
// lookup for the parts together: each at its own distance cost 0.5-1 ms
// more at 3024 × 1964 for a difference seen only where the cirrus shows
// between clouds.
inline void cloud_haze(thread CloudResult &r, float2 uv, texture3d<float> froxels, sampler s,
                       constant AtmosphereUniforms &air, float exposure) {
    if (r.color.a <= 0.0 || r.mean > 1e29) { return; }
    float4 ap = atmo_aerialPerspective(froxels, s, uv, r.mean, air);
    r.color.rgb = r.color.rgb * ap.a + r.color.a * ap.rgb * exposure;
}

// The camera above the air: for a cloud at height h on the pixel's ray
// (muCamera its cosine from the camera's zenith, rCamera the camera's
// radius), the transmittance of the air above it, A2's own from it to space
// (A1's table: Rayleigh, aerosol and ozone, channel by channel), and of
// A2's in-scatter over the ground from space along the ray (cd/m², as the
// ground has it) the share of the air's mass above the cloud,
// e^(−h / 8 km). The light scattered per unit of extinction is not the
// same along the ray (the aerosol lies almost all below the clouds, the
// ozone above them only absorbs), so the cloud's share of the optical
// depth, (1 − T) / (1 − T_ground), gave a 2 km cloud 0.46-0.62 of the
// column's in-scatter where 0.62-0.76 lies above it (the #76 review's
// ports, one with A1's multiple scattering); the mass share is closer
// everywhere but forward toward a low Sun. Not the froxels: they reach
// 2,000 km along the ray (none of the air on the disc's outer part from
// 1,000 km up), and from orbit their slices, 40-125 km apart within the
// air, place a cloud's haze by distance, not height. (The mass share for
// the transmittance as well gave the clouds the aerosol below them and
// missed 22-71 % of the ozone above: 4-24 % too dark from LEO.)
inline void cloud_hazeFromSpace(thread CloudResult &r, float2 uv, float h, float muCamera, float rCamera,
                                texture2d<float> scatter, texture2d<float> trans,
                                sampler s, constant CloudUniforms &u, float exposure) {
    if (r.color.a <= 0.0) { return; }
    float rc = u.radii.x + max(h, 0.0), q = rCamera / rc;
    float mu = sqrt(max(1.0 - q * q * max(1.0 - muCamera * muCamera, 0.0), 0.0));
    float3 t = cloud_airTransmittance(h, mu, trans, s, u);
    float share = exp(-max(h, 0.0) / 8000.0);
    r.color.rgb = r.color.rgb * t + r.color.a * scatter.sample(s, uv, level(0)).rgb * share * exposure;
}

// Whether the cirrus lies in front of a part whose cloud the ray enters at
// `entry` (none: in front): by height, which the reprojection's nudges to a
// texel's entry cannot flip (by entry distance, the cirrus flipped behind a
// deck or in front of it, bright and dark lines along the checkerboard's
// rows from orbit). With the camera outside the shell (above 10 km) the
// cirrus is drawn where the ray first crosses it going down: in front of
// what it enters below the shell, and of what it enters above it on the way
// up again (beyond the ray's lowest point, past the shell's far crossing);
// behind a top above the shell on the way down. With the camera inside, the
// cirrus is where the ray leaves the shell going up: behind what it enters
// below the shell, in front of what it enters above. (The ray's origin and
// direction in figure coordinates, of and df.)
inline bool cloud_cirrusFirst(float entry, float3 of, float3 df, constant CloudUniforms &u) {
    if (entry >= 1e29) { return true; }
    float3 pe = of + df * entry;
    bool outside = u.shell.z > 0.0;
    bool below = cloud_height(pe, u) < u.shellMid.y;
    return below == outside || (outside && dot(pe, df) > 0.0);
}

// The parts in order of distance: the march's and the far layers' by the
// far weight wf, each with the cirrus in front of it or behind it by its own
// entry (cloud_cirrusFirst), then blended by wf. One order for the blend
// stepped where the parts disagreed: over towers above 10 km from orbit the
// march's tops are nearer than the far layers' 2 and 4.5 km shells, so the
// cirrus went behind a colour that was nearly all the far deck's until wf
// reached 1, then jumped in front of it. Where the parts agree this is the
// cirrus over (or under) the blend, cloud_over being linear in the farther
// part; it is continuous at wf 0 and 1.
inline CloudResult cloud_compose(CloudResult m, CloudResult farMid, CloudResult farLow, CloudResult cirrus, float wf,
                                 float3 of, float3 df, constant CloudUniforms &u) {
    CloudResult result = m;
    CloudResult far = farLow.front < farMid.front ? cloud_over(farLow, farMid) : cloud_over(farMid, farLow);
    if (wf > 0.0) {
        result.color = mix(m.color, far.color, wf);
        result.front = wf >= 1.0 ? far.front : min(m.front, far.front);
        // The mean of the two by their shares of the opacity (a texel the
        // march found clear has no mean of its own: switching to the far
        // layer's at a weight cut the far layer's share there, an edge).
        float am = m.color.a * (1.0 - wf), af = far.color.a * wf;
        result.mean = am + af > 0.0 ? (am * min(m.mean, 1e12) + af * min(far.mean, 1e12)) / (am + af) : 1e30;
        result.entry = wf >= 1.0 ? far.entry : min(m.entry, far.entry);
    }
    if (cirrus.color.a > 0.0) {
        CloudResult withM = cloud_cirrusFirst(m.entry, of, df, u) ? cloud_over(cirrus, m) : cloud_over(m, cirrus);
        if (wf <= 0.0) { return withM; }
        CloudResult withF = cloud_cirrusFirst(far.entry, of, df, u) ? cloud_over(cirrus, far) : cloud_over(far, cirrus);
        if (wf >= 1.0) { return withF; }
        result.color = mix(withM.color, withF.color, wf);
        result.front = min(withM.front, withF.front);
        float am = withM.color.a * (1.0 - wf), af = withF.color.a * wf;
        result.mean = am + af > 0.0 ? (am * min(withM.mean, 1e12) + af * min(withF.mean, 1e12)) / (am + af) : 1e30;
        result.entry = min(withM.entry, withF.entry);
    }
    return result;
}

// The linear depth (m) to the ground along the ray through frame pixel px,
// 1e30 where it meets none: for the slot's clip code over its footprint.
inline float cloud_groundDepth(float2 px, constant CloudUniforms &u, constant FrameUniforms &frame) {
    float3 vr = orbit_viewRay(px, frame);
    float3 w = normalize((frame.viewToWorld * float4(vr, 0.0)).xyz);
    float3 d = normalize((u.worldToBody * float4(w, 0.0)).xyz);
    float2 g = cloud_shell(u.cameraFigure.xyz, cloud_figureDir(d, u), u.shell.x);
    return g.x >= 0.0 ? g.x / length(vr) : 1e30;
}

// The frame's clouds at this texel of R6's targets: the march's (its
// target filtered when coarser: colour bilinear, depths the nearest of the
// four texels around), the far layers by their weight, and the cirrus, at
// R6's resolution, in order of distance; cut where the scene's depth (R6's
// test depth) lies in front of or within them: the optical depth before
// the scene, as a fraction of the way from the cloud's entry to twice its
// mean depth beyond it. Its front for R6's composite, where it has one, and
// its clip code (orbit_clipCode, LR0): cut where the scene cut it, else from
// its back estimate, or over its own ground from the nearest ground of the
// texel's upsample footprint (the clouds are never inside the ground, so a
// pixel there sees them whole). Clouds the scene hides wholly are written,
// with no light and a cut code, not discarded.
fragment EffectCloudOut cloud_slot_fragment(CloudSlotOut in [[stage_in]],
                                            constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]],
                                            constant EffectSlotUniforms &e [[buffer(ORBIT_EFFECT_BUFFER_SLOTS)]],
                                            constant CloudUniforms &u [[buffer(0)]],
                                            constant float4 &scale [[buffer(1)]],
                                            texture2d<float> clouds [[texture(0)]],
                                            texture2d<float> depths [[texture(1)]],
                                            texture3d<float> shape [[texture(2)]],
                                            texture3d<float> detail [[texture(3)]],
                                            texture2d<float> curl [[texture(4)]],
                                            texture2d<float> weatherA [[texture(5)]],
                                            texture2d<float> weatherB [[texture(6)]],
                                            texture3d<float> slab [[texture(7)]],
                                            texture2d<float> trans [[texture(8)]],
                                            texture2d<float> irr [[texture(9)]],
                                            texture2d<float> halfResDepth [[texture(ORBIT_EFFECT_TEXTURE_HALFRES_DEPTH)]],
                                            texture3d<float> froxels [[texture(ORBIT_TEXTURE_AERIAL_PERSPECTIVE)]],
                                            constant AtmosphereUniforms &air [[buffer(ORBIT_BUFFER_ATMOSPHERE)]],
                                            texture2d<float> spaceScatter [[texture(10)]],
                                            texture2d<float> spaceTransmittance [[texture(11)]],
                                            sampler wrap [[sampler(0)]],
                                            sampler weather [[sampler(1)]],
                                            sampler linear [[sampler(ORBIT_SAMPLER_LINEAR_CLAMP)]]) {
    uint2 texel = uint2(in.position.xy);
    float4 c, z;
    if (scale.x > 0.5) {
        uint2 t = min(texel, uint2(clouds.get_width(), clouds.get_height()) - 1u);
        c = clouds.read(t);
        z = depths.read(t);
    } else {
        float2 uv = in.position.xy * e.target.zw;
        c = clouds.sample(linear, uv);
        float4 fronts = depths.gather(linear, uv, int2(0), component::x);
        float4 means = depths.gather(linear, uv, int2(0), component::y);
        float4 entries = depths.gather(linear, uv, int2(0), component::z);
        z = float4(min(min(fronts.x, fronts.y), min(fronts.z, fronts.w)),
                   min(min(means.x, means.y), min(means.z, means.w)),
                   min(min(entries.x, entries.y), min(entries.z, entries.w)), 0.0);
    }
    // The march's, in metres along the ray.
    CloudRay ray = cloud_ray(in.position.xy * e.scale.x, u, frame);
    float k = ray.depthPerMetre;
    CloudResult result = {c, cloud_decodeDepth(z.x) / k, cloud_decodeDepth(z.y) / k, cloud_decodeDepth(z.z) / k};
    CloudTextures t = {shape, detail, curl, weatherA, weatherB};
    // The air in front. Inside the air, A2's froxels at the clouds' combined
    // mean distance (below); above it (A2's haze from space bound, as the
    // ground has it), each part through the air above its height. The two
    // blend over the 40 km above the air's top, where the froxels still hold
    // the whole air, so a climb or an entry does not step there (the
    // froxels' transmittance is grey and slice-interpolated, the other each
    // channel's own). None without air.
    float2 screen = in.position.xy * e.target.zw;
    float exposure = frame.exposure.x;
    bool froxelsOn = air.aerialPerspective.x >= 1.0;
    float airTop = air.radii.y - air.radii.x;
    float wSpace = scale.y < 0.5 ? 0.0 : (froxelsOn ? cloud_smoothstep(airTop, airTop + 40000.0, air.radii.z) : 1.0);
    CloudResult none = {float4(0.0), 1e30, 1e30, 1e30};
    CloudResult farMid = none, farLow = none;
    float wf = 0.0;
    if (ray.valid && ray.wFar > 0.0) {
        farMid = cloud_farLayer(ray.of, ray.df, ray.d, u.shellMid.x, u.shellMid.w, 1, t, slab, trans, irr, wrap, linear,
                                weather, u);
        farLow = cloud_farLayer(ray.of, ray.df, ray.d, u.shell.w, u.shellMid.z, 0, t, slab, trans, irr, wrap, linear,
                                weather, u);
        wf = ray.wFar;
    }
    CloudResult cirrus = cloud_cirrus(ray.of, ray.df, ray.d, u.footprint.x * e.scale.x * 0.5, t, trans, irr, wrap,
                                      linear, weather, u);
    CloudResult march = result;
    result = cloud_compose(march, farMid, farLow, cirrus, wf, ray.of, ray.df, u);
    if (froxelsOn && wSpace < 1.0) { cloud_haze(result, screen, froxels, linear, air, exposure); }
    if (wSpace > 0.0) {
        float3 upCamera = normalize(float3(ray.of.x, ray.of.y, ray.of.z * u.cameraFigure.w));
        float muCamera = dot(ray.d, upCamera), rCamera = u.radii.x + u.radii.y;
        cloud_hazeFromSpace(march, screen, u.shellMid.z, muCamera, rCamera, spaceScatter, trans,
                            linear, u, exposure);
        cloud_hazeFromSpace(farMid, screen, u.shellMid.w, muCamera, rCamera, spaceScatter, trans,
                            linear, u, exposure);
        cloud_hazeFromSpace(farLow, screen, u.shellMid.z, muCamera, rCamera, spaceScatter, trans,
                            linear, u, exposure);
        cloud_hazeFromSpace(cirrus, screen, u.shellMid.y, muCamera, rCamera, spaceScatter, trans,
                            linear, u, exposure);
        result.color = mix(result.color, cloud_compose(march, farMid, farLow, cirrus, wf, ray.of, ray.df, u).color, wSpace);
    }
    c = result.color;
    if (orbit_isNotFinite(c.rgb) || orbit_isNotFinite(c.a)) { c = float4(0.0); }
    c = float4(min(c.rgb, float3(6e4)), clamp(c.a, 0.0, 1.0));
    if (c.a <= 0.0 && max(c.r, max(c.g, c.b)) <= 0.0) { discard_fragment(); }
    // Linear depths, as R6's.
    float front = result.front * k, mean = result.mean * k, entry = min(result.entry, result.front) * k;
    float scene = orbit_effectSceneDistance(texel, halfResDepth, frame);
    float back = entry + 2.0 * max(mean - entry, 0.0);
    if (scene <= entry) {
        EffectCloudOut hidden;
        hidden.color = float4(0.0);
        hidden.front = float4(ORBIT_EFFECT_NO_FRONT);
        hidden.clip = float4(0.0);
        return hidden;
    }
    // The ground under the clouds is never inside them: where the scene is
    // this texel's ground (its ray's ground hit, within the spread of depths
    // a half-resolution texel has at that angle), no cut. A deck within a
    // kilometre or two of the ground had its back estimate past the ground,
    // and the cut flickered along the depths' contours (rings of dashes from
    // orbit).
    bool ground = false;
    float spread = 1.0;
    if (ray.ground < 1e29) {
        float3 pg = cloud_figure(ray.d * ray.ground, u);
        float muG = abs(dot(ray.d, normalize(float3(pg.x, pg.y, pg.z * u.cameraFigure.w))));
        spread = 1.0 - 2.0 * u.footprint.x / max(muG, 0.01) - 1e-3;
        ground = scene >= ray.ground * k * spread;
    }
    float clip = 0.0;
    if (!(scene < back && !ground)) {
        float endsAt = back;
        if (ground) {
            // The footprint's nearest ground, from its four corner rays.
            float2 centre = in.position.xy * e.scale.x;
            float r = e.scale.x > 1.5 ? 1.5 : 0.5, nearest = 1e30;
            for (int i = 0; i < 4; i++) {
                float2 corner = centre + float2((i & 1) != 0 ? r : -r, (i & 2) != 0 ? r : -r);
                nearest = min(nearest, cloud_groundDepth(corner, u, frame));
            }
            endsAt = min(back, nearest * spread);
        }
        clip = orbit_clipCode(endsAt, scene);
    }
    if (scene < back && !ground) {
        float f = (scene - entry) / max(back - entry, 1e-3);
        float a = clamp(c.a, 0.0, 0.9999);
        float cut = 1.0 - pow(1.0 - a, f);
        c.rgb *= a > 1e-5 ? cut / a : f;
        c.a = cut;
    }
    EffectCloudOut o;
    o.color = c;
    o.front = float4(front < 1e20 && front < scene ? orbit_frontCode(front) : ORBIT_EFFECT_NO_FRONT);
    o.clip = float4(clip);
    return o;
}

// ------------------------------------------------ R3's probe faces ---

struct CloudProbeView {
    float4x4 viewToWorld;     // the face's view basis (columns: right, up, -forward), tan(fov/2) = 1
    float4 params;            // x: 1 / pre-exposure (the cloud uniforms' Sun is pre-exposed), y: haze steps, z: face size,
                              // w: 1 with A2's profile bound (the haze marched)
    float4 sunWorld;          // xyz: unit, to the Sun (world), w: its angular radius (rad)
    float4 solar;             // rgb: the Sun's illuminance above the air (lux)
};

// R3's probe entry point: the far layers (low and mid, CloudPass's regime
// for the whole Earth) along one face texel's ray from the probe's centre
// (u.cameraFigure and the shells' constants, which CloudPass.encodeProbe
// sets for it), in cd/m2,
// premultiplied over what the face holds (the ground or the sky): the air
// between them and the probe marched (A2's optics), so the face becomes
// (1 - a) face + T cloud + a in-scatter, the haze in front of the cloud
// left whole. No cirrus, no march: the probe wants the clouds' light, not
// their detail.
fragment float4 cloud_probe_fragment(CloudSlotOut in [[stage_in]],
                                     constant CloudUniforms &u [[buffer(0)]],
                                     constant CloudProbeView &v [[buffer(1)]],
                                     constant AtmosphereUniforms &air [[buffer(ORBIT_BUFFER_ATMOSPHERE)]],
                                     texture3d<float> shape [[texture(2)]],
                                     texture3d<float> detail [[texture(3)]],
                                     texture2d<float> curl [[texture(4)]],
                                     texture2d<float> weatherA [[texture(5)]],
                                     texture2d<float> weatherB [[texture(6)]],
                                     texture3d<float> slab [[texture(7)]],
                                     texture2d<float> trans [[texture(8)]],
                                     texture2d<float> irr [[texture(9)]],
                                     texture2d<float> profile [[texture(10)]],
                                     texture2d<float> transmittance [[texture(ORBIT_TEXTURE_TRANSMITTANCE_LUT)]],
                                     texture2d<float> multiple [[texture(ORBIT_TEXTURE_MULTI_SCATTERING_LUT)]],
                                     sampler wrap [[sampler(0)]],
                                     sampler weather [[sampler(1)]],
                                     sampler linear [[sampler(ORBIT_SAMPLER_LINEAR_CLAMP)]]) {
    float size = v.params.z;
    float2 ndc = float2(2.0 * in.position.x / size - 1.0, 1.0 - 2.0 * in.position.y / size);
    float3 w = normalize((v.viewToWorld * float4(ndc, -1.0, 0.0)).xyz);
    float3 d = normalize((u.worldToBody * float4(w, 0.0)).xyz);
    float3 of = u.cameraFigure.xyz, df = cloud_figureDir(d, u);
    CloudTextures t = {shape, detail, curl, weatherA, weatherB};
    CloudResult farMid = cloud_farLayer(of, df, d, u.shellMid.x, u.shellMid.w, 1, t, slab, trans, irr, wrap, linear,
                                        weather, u);
    CloudResult farLow = cloud_farLayer(of, df, d, u.shell.w, u.shellMid.z, 0, t, slab, trans, irr, wrap, linear,
                                        weather, u);
    CloudResult far = farLow.front < farMid.front ? cloud_over(farLow, farMid) : cloud_over(farMid, farLow);
    float4 c = far.color;
    if (!(c.a > 0.0) || orbit_isNotFinite(c.rgb) || orbit_isNotFinite(c.a)) { discard_fragment(); }
    c.rgb *= v.params.x;
    c.a = clamp(c.a, 0.0, 1.0);
    if (air.radii.w > 0.5 && v.params.w > 0.5 && far.front < 1e29) {
        float scale = length(df);
        float3 dF = df / scale;
        float3 sunF = normalize(u.sun.xyz * float3(1.0, 1.0, u.cameraFigure.w));
        float3 seg = atmo_airSegment(of, dF, air.radii.x, air.radii.y);
        float end = min(seg.y, far.front * scale);
        if (end > seg.x) {
            AtmoMarch m = atmo_march(of, dF, seg.x, end, int(v.params.y), sunF, dot(w, v.sunWorld.xyz), v.sunWorld.w,
                                     air, transmittance, multiple, profile, linear);
            c.rgb = c.rgb * m.transmittance + c.a * m.radiance * v.solar.rgb;
        }
    }
    return float4(orbit_isNotFinite(c.rgb) ? float3(0.0) : clamp(c.rgb, 0.0, 60000.0), c.a);
}
"""#

extension ShaderModule {
    public static let cloud = ShaderModule(name: "Cloud", headers: [.effectSlots, .atmosphereCommon],
                                           source: cloudShaderSource)
}

// What other tracks read from the clouds (C2's contract): the Sun's light
// through the clouds at a point, for the ground (the planet pass), the
// vessels (R2, R4) and the plumes (P2). A module adds `.cloudShadow` to its headers and
// samples the reserved slot 24 with AtmosphereUniforms' cloud members, which
// CloudPass fills in P0.
let cloudShadowHeaderSource = #"""
// ------------------------------------------------------- cloud shadow ---

// The optical depth along the Sun through the clouds above camera-relative
// world point p (x), from the cloud shadow map (texture 24: the optical
// depth above 0, 2, 6 and 10 km, CloudPass.shadowLevels, cirrus included
// below 10 km) at p's place and height, AtmosphereUniforms.cloudShadowMatrix
// taking p to (u, v, height above the ground, 1); and the map's weight
// there (y): 1 inside, fading to 0 over its outer tenth, 0 where the clouds
// are not drawn or p is off the map (from orbit the ground beyond it: the far
// layer's own cover hides it there).
inline float2 orbit_cloudShadowDepth(float3 p, constant AtmosphereUniforms &a, texture2d<float> map, sampler s) {
    if (a.cloudLayer.w < 0.5) { return float2(0.0); }
    float4 m = a.cloudShadowMatrix * float4(p, 1.0);
    if (any(m.xy < 0.0) || any(m.xy > 1.0)) { return float2(0.0); }
    float4 tau = map.sample(s, m.xy, level(0.0));
    float h = m.z;
    float t = h < 2000.0 ? mix(tau.x, tau.y, max(h, 0.0) / 2000.0)
            : h < 6000.0 ? mix(tau.y, tau.z, (h - 2000.0) / 4000.0)
            : h < 10000.0 ? mix(tau.z, tau.w, (h - 6000.0) / 4000.0)
            : mix(tau.w, 0.0, clamp((h - 10000.0) / 2500.0, 0.0, 1.0));
    float2 edge = min(m.xy, 1.0 - m.xy);
    return float2(t, clamp(min(edge.x, edge.y) * 10.0, 0.0, 1.0));
}

// The Sun's direct beam through the clouds at p, e^(-tau): for what is lit by
// the Sun as a light (the vessels, the plumes), the clouds' own light
// reaching them through R3's probe.
inline float orbit_cloudSunTransmittance(float3 p, constant AtmosphereUniforms &a, texture2d<float> map, sampler s) {
    float2 d = orbit_cloudShadowDepth(p, a, map, s);
    return mix(1.0, exp(-d.x), d.y);
}

// The light reaching a Lambertian ground through the clouds at p, per unit
// of the clear sky's, the Sun at cosine mu0 there (signed, the ellipsoid's
// up): x the Sun's, y the sky's. The Sun's: its direct beam and what the
// clouds on its line pass on diffusely, a conservative slab's two-stream
// transmittance, 2 / (2 + (1 - g) tau) for its vertical optical depth tau,
// g 0.85 (Bohren 1987; CloudOptics.slabTransmittance,
// CloudLayerModel.waterAsymmetry). The map holds the depth along the Sun's
// ray, curved over the Earth: its vertical depth is that times the ray's
// slope at the clouds (2 km), sqrt(mu0² + 2 h / R). Under thick cloud
// (tau 20) 0.4 of the Sun, not e^-20; thin cirrus (tau 0.4) dims it by 3 %.
// The sky's: the cover overhead (cloud_skyColumn, `skyMap` at p's texel:
// its line's rising ground point with the Sun up, its falling one with the
// Sun under the horizon), not the clouds on the Sun's line, which lie
// kilometres off at a low Sun and hundreds at the terminator.
inline float2 orbit_cloudGroundTransmittance(float3 p, float mu0, constant AtmosphereUniforms &a, texture2d<float> map,
                                             texture2d<float> skyMap, sampler s) {
    float2 d = orbit_cloudShadowDepth(p, a, map, s);
    if (d.y <= 0.0) { return float2(1.0); }
    float slope = sqrt(mu0 * mu0 + 2.0 * 2000.0 / 6.371e6);
    float2 sky = skyMap.sample(s, (a.cloudShadowMatrix * float4(p, 1.0)).xy, level(0.0)).xy;
    return mix(float2(1.0), float2(2.0 / (2.0 + 0.15 * d.x * slope), mu0 >= 0.0 ? sky.x : sky.y), d.y);
}
"""#

extension ShaderHeader {
    /// The clouds' shadow for other modules (`orbit_cloudSunTransmittance`).
    public static let cloudShadow = ShaderHeader(name: "CloudShadow", source: cloudShadowHeaderSource)
}
