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
    float4 extinction;        // x: low, y: mid, z: cirrus in-cloud extinction (1/m), w: density scale
    float4 layers;            // x: mid base, y: mid top, z: cirrus base, w: cirrus top (m)
    float4 march;             // x: steps, y: light samples, z: light distance (m), w: near reach (m)
    float4 mie;               // x: g HG, y: g Draine, z: Draine alpha, w: Draine weight
    float4 lighting;          // x: two-stream backscatter b, y: least Sun cosine, z: detail, w: cirrus g
    float4 regime;            // x: near weight, y: orbit, z: far, w: in-cloud density factor for the far layer
    float4 footprint;         // x: pixel angle (rad), y: far blend start (m), z: far blend end (m), w: global coverage modulation
    float4 checker;           // xy: this frame's checkerboard texel, z: 1 marching one texel in four, w: frame index
    float4 lookDev;           // x: 1 a uniform homogeneous layer, y: its cover, z: its optical depth, w: 1 force far, 2 force march
    float4 target;            // xy: the march target's size, zw: frame pixels per texel
    float4 lut;               // x: LUT depths, y: cosines, z: least depth, w: ln(most / least)
    float4 lut2;              // x: least cosine, y: 1 with a field, z: shadow altitudes 0, w: unused
    float4 shadow;            // x: extent (m), y: texels, z: 1 drawn, w: steps
    float4 shadowCenter;      // xyz: the map's centre minus the camera, body axes (m)
    float4 shadowU;           // xyz: the map's u axis (body)
    float4 shadowV;           // xyz: v axis
    float4 shadowLevels;      // the altitudes (m) the map's channels hold the optical depth above
    float4 coverage[9];       // the coverage thresholds θ(c) at c = 0, 1/32 ... 1, four to an entry
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

// CloudWeatherMap.texel at grid point gid: the three covers and the low
// layer's base (A), its top (B.x).
kernel void cloud_weather(texture2d<uint, access::read> first [[texture(0)]],
                          texture2d<uint, access::read> second [[texture(1)]],
                          texture2d<float, access::write> outA [[texture(2)]],
                          texture2d<float, access::write> outB [[texture(3)]],
                          constant float4 *climate [[buffer(0)]],
                          constant CloudWeatherParams &p [[buffer(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
    uint w = outA.get_width(), hgt = outA.get_height();
    if (gid.x >= w || gid.y >= hgt) { return; }
    float4 c = climate[gid.y];
    float low = c.x, mid = c.y, high = c.z;
    float base = -1.0;
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
            float x = 1.0 - p.snapshots.z;
            float3 f = clamp(v.xyz, 0.0, 1.0);
            low = f.x + x * (c.x - f.x);
            mid = f.y + x * (c.y - f.y);
            high = f.z + x * (c.z - f.z);
            if (x < 0.5 && known.w) { base = v.w; }
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
    float lowBase = p.layerModel.x;
    if (base >= 0.0 && base < p.layerModel.y) { lowBase = max(base, 0.0); }
    float lowTop = convective ? p.layerModel.w : lowBase + p.layerModel.z;
    outA.write(float4(low, mid, high, lowBase), gid);
    outB.write(float4(lowTop, 0.0, 0.0, 0.0), gid);
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

// The coverage threshold θ(c): the shape value above which a fraction c of
// the sky is cloud (CloudCoverage), linear between its 33 entries.
inline float cloud_threshold(float cover, constant CloudUniforms &u) {
    float x = clamp(cover, 0.0, 1.0) * 32.0;
    int i = min(int(x), 31);
    float a = u.coverage[i / 4][i % 4], b = u.coverage[(i + 1) / 4][(i + 1) % 4];
    return mix(a, b, x - float(i));
}

inline float cloud_profileLow(float h) {
    return clamp(cloud_remap(h, 0.0, 0.08, 0.0, 1.0), 0.0, 1.0) * clamp(cloud_remap(h, 0.4, 1.0, 1.0, 0.0), 0.0, 1.0);
}

inline float cloud_profileMid(float h) {
    return clamp(cloud_remap(h, 0.0, 0.2, 0.0, 1.0), 0.0, 1.0) * clamp(cloud_remap(h, 0.55, 1.0, 1.0, 0.0), 0.0, 1.0);
}

// One layer's density in [0, 1]: Schneider's low-frequency shape (the
// Perlin-Worley dilated by the Worley fBm), shaped by the height profile,
// cut at the coverage threshold, then eroded by the detail (wispy below,
// billowy above).
inline float cloud_layerDensity(float4 shape, float cover, float profile, float detailValue, float detailAmount,
                                float h01, constant CloudUniforms &u) {
    float fbm = shape.g * 0.625 + shape.b * 0.25 + shape.a * 0.125;
    float base = clamp(cloud_remap(shape.r, fbm - 1.0, 1.0, 0.0, 1.0), 0.0, 1.0) * profile;
    float theta = cloud_threshold(cover, u);
    float d = clamp(cloud_remap(base, theta, 1.0, 0.0, 1.0), 0.0, 1.0);
    if (d <= 0.0 || detailAmount <= 0.0) { return d; }
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

// The cloud at camera-relative body point q. `detailAmount` fades the
// erosion with distance; `cheap` leaves it and the curl out (the light
// march, the shadow map).
inline CloudSample cloud_sample(float3 q, float detailAmount, bool cheap, thread const CloudTextures &t,
                                sampler wrap, sampler weather, constant CloudUniforms &u) {
    CloudSample s = {0.0, 0.0, 0.0, -1.0};
    float3 pf = cloud_figure(q, u);
    float h = cloud_height(pf, u);
    if (h < 0.0 || h > u.radii.z) { return s; }
    float2 uv = cloud_weatherUV(pf, u);
    float4 wa, wb;
    if (u.lookDev.x > 0.5) {
        wa = float4(u.lookDev.y, 0.0, 0.0, 1000.0);
        wb = float4(2500.0, 0.0, 0.0, 0.0);
    } else {
        wa = t.weatherA.sample(weather, uv, level(0.0));
        wb = t.weatherB.sample(weather, uv, level(0.0));
    }
    float lowBase = wa.w, lowTop = max(wb.x, lowBase + 100.0);
    bool inLow = h >= lowBase && h <= lowTop && wa.x > 0.002;
    bool inMid = h >= u.layers.x && h <= u.layers.y && wa.y > 0.002 && !inLow;
    if (!inLow && !inMid) { return s; }
    if (u.lookDev.x > 0.5) {
        // A homogeneous slab: the far LUT's own case.
        s.sigma = u.lookDev.z / (lowTop - lowBase);
        s.column = u.lookDev.z;
        s.h01 = (h - lowBase) / (lowTop - lowBase);
        s.layer = 0.0;
        return s;
    }
    float3 dir = normalize(float3(pf.x, pf.y, pf.z));
    // Large-scale structure: the shape volume's Perlin-Worley over 400 km
    // of the sphere, moving the cover up and down where it is partial.
    float g = t.shape.sample(wrap, dir * (u.radii.x / 400000.0), level(0.0)).r;
    if (inLow) {
        float h01 = (h - lowBase) / (lowTop - lowBase);
        float cover = clamp(wa.x + (g - 0.5) * u.footprint.w * 4.0 * wa.x * (1.0 - wa.x), 0.0, 1.0);
        float3 p = (u.noiseLow.xyz + q) / u.noiseLow.w;
        float lod = cheap ? 2.0 : 0.0;
        float4 shape = t.shape.sample(wrap, p, level(lod));
        float detailValue = 0.0;
        if (!cheap && detailAmount > 0.0) {
            float2 c = t.curl.sample(wrap, (u.noiseLow.xy + q.xy) / u.windHigh.w, level(0.0)).xy;
            float3 pd = (u.noiseLow.xyz + q + float3(c, 0.0) * 300.0 * (1.0 - h01)) / u.noiseHigh.w;
            float3 dv = t.detail.sample(wrap, pd, level(0.0)).rgb;
            detailValue = dv.r * 0.625 + dv.g * 0.25 + dv.b * 0.125;
        }
        float d = cloud_layerDensity(shape, cover, cloud_profileLow(h01), detailValue, cheap ? 0.0 : detailAmount, h01, u);
        s.sigma = d * u.extinction.x * u.extinction.w;
        s.column = s.sigma * (lowTop - lowBase);
        s.h01 = h01;
        s.layer = 0.0;
    } else {
        float h01 = (h - u.layers.x) / (u.layers.y - u.layers.x);
        float cover = clamp(wa.y + (g - 0.5) * u.footprint.w * 4.0 * wa.y * (1.0 - wa.y), 0.0, 1.0);
        float3 p = (u.noiseMid.xyz + q) / u.noiseMid.w;
        float4 shape = t.shape.sample(wrap, p * float3(1.0, 1.0, 1.0), level(cheap ? 2.0 : 0.0));
        float detailValue = 0.0;
        if (!cheap && detailAmount > 0.0) {
            float3 dv = t.detail.sample(wrap, (u.noiseMid.xyz + q) / (2.0 * u.noiseHigh.w), level(0.0)).rgb;
            detailValue = dv.r * 0.625 + dv.g * 0.25 + dv.b * 0.125;
        }
        float d = cloud_layerDensity(shape, cover, cloud_profileMid(h01), detailValue, cheap ? 0.0 : detailAmount, h01, u);
        s.sigma = d * u.extinction.y * u.extinction.w;
        s.column = s.sigma * (u.layers.y - u.layers.x);
        s.h01 = h01;
        s.layer = 1.0;
    }
    return s;
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

// The slab LUT (CloudSlabLUT) for layer l at optical depth tau, the Sun's
// cosine mu0 and the eye's mu: single scattering without phase, the Sun's
// diffuse light, the sky's, the transmittance.
inline float4 cloud_slabLUT(texture3d<float> lut, sampler s, int l, float tau, float mu0, float mu, constant CloudUniforms &u) {
    float depths = u.lut.x, cosines = u.lut.y;
    float thin = clamp(tau / u.lut.z, 0.0, 1.0);
    float k = log(max(tau, u.lut.z) / u.lut.z) / u.lut.w * (depths - 1.0);
    float x = clamp((mu - u.lut2.x) / (1.0 - u.lut2.x), 0.0, 1.0) * (cosines - 1.0);
    float y = clamp((mu0 - u.lut2.x) / (1.0 - u.lut2.x), 0.0, 1.0) * (cosines - 1.0);
    float z = float(l) * depths + clamp(k, 0.0, depths - 1.0);
    float3 uvw = (float3(x, y, z) + 0.5) / float3(cosines, cosines, 2.0 * depths);
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
                                  texture2d<float> irr, sampler linear, sampler weather, constant CloudUniforms &u) {
    CloudResult r = {float4(0.0), 1e30, 1e30, 1e30};
    float2 hit = cloud_shell(of, df, c);
    float th = hit.x >= 0.0 ? hit.x : hit.y;
    if (th < 0.0) { return r; }
    float3 pf = of + df * th;
    float3 up = normalize(float3(pf.x, pf.y, pf.z * u.cameraFigure.w));
    float mu = -dot(d, up);
    if (mu <= 0.0) { return r; }   // seen from below: the march's
    float mu0 = dot(u.sun.xyz, up);
    float4 wa, wb;
    if (u.lookDev.x > 0.5) {
        wa = float4(u.lookDev.y, 0.0, 0.0, 1000.0);
        wb = float4(2500.0, 0.0, 0.0, 0.0);
    } else {
        float2 uv = cloud_weatherUV(pf, u);
        wa = t.weatherA.sample(weather, uv, level(0.0));
        wb = t.weatherB.sample(weather, uv, level(0.0));
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
    float tau = u.lookDev.x > 0.5 ? u.lookDev.z : beta * u.extinction.w * thickness * u.regime.w;
    float4 v = cloud_slabLUT(lut, linear, layer, tau, mu0, mu, u);
    // The air above the layer's top, where its light comes from.
    float top = layer == 0 ? wb.x : u.layers.y;
    float3 sun = u.sunLight.rgb * cloud_sunTransmittance(top, mu0, trans, linear, u);
    float3 sky = u.sunLight.rgb * cloud_skyIrradiance(top, mu0, irr, linear, u);
    (void)href;
    float3 L = sun * (v.r * cloud_mie(dot(d, u.sun.xyz), u) + v.g) + sky * v.b;
    r.color = float4(L * cover, cover * (1.0 - v.a));
    r.front = th;
    r.entry = th;
    r.mean = th + 0.5 * thickness / mu;
    return r;
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
    if (th < 0.0) { return r; }
    float3 pf = of + df * th;
    float cover = t.weatherA.sample(weather, cloud_weatherUV(pf, u), level(0.0)).z;
    if (cover <= 0.002) { return r; }
    float3 up = normalize(float3(pf.x, pf.y, pf.z * u.cameraFigure.w));
    float mu = dot(-d, up), m = max(abs(mu), 0.03);
    float mu0 = dot(u.sun.xyz, up);
    float3 q = d * th;
    // Fibres: the Worley fBm stretched eight times along the streaks, warped by the curl.
    float3 a = u.windHigh.xyz;
    float3 p = u.noiseHigh.xyz + q;
    float along = dot(p, a);
    float3 across = p - a * along;
    float2 c = t.curl.sample(wrap, p.xy / u.windHigh.w, level(0.0)).xy;
    float3 pn = (across + a * (along * 0.125) + float3(c, 0.0) * 2000.0) / u.noiseLow.w;
    float footprint = th * pixelAngle / m;
    float lod = clamp(log2(max(footprint / 128.0, 1.0)), 0.0, 6.0);
    float4 s = t.shape.sample(wrap, pn, level(lod));
    float n = mix(s.b * 0.7 + s.a * 0.3, 0.5, cloud_smoothstep(u.footprint.y, u.footprint.z, footprint));
    float d01 = clamp(cloud_remap(n, cloud_threshold(cover, u), 1.0, 0.0, 1.0), 0.0, 1.0);
    // Far away the fibres average out: their mean density.
    d01 = mix(d01, 0.5, cloud_smoothstep(u.footprint.y, u.footprint.z, footprint));
    float coverEff = mix(1.0, cover, cloud_smoothstep(u.footprint.y, u.footprint.z, footprint));
    float tau = u.extinction.z * (u.layers.w - u.layers.z) * d01 * u.extinction.w;
    if (tau <= 1e-5) { return r; }
    float mu0c = max(mu0, u.lighting.y);
    float ct = dot(d, u.sun.xyz);
    float phase = cloud_hg(ct, u.lighting.w);
    float single;
    if (mu > 0.0) {
        float k = 1.0 / mu0c + 1.0 / m;
        single = (1.0 - exp(-tau * k)) / (m * k);
    } else {
        float k = 1.0 / m - 1.0 / mu0c;
        single = abs(k) < 1e-3 ? tau / m * exp(-tau / m) : (exp(-tau / mu0c) - exp(-tau / m)) / (m * k);
    }
    float b = (1.0 - u.lighting.w) * 0.5;
    float2 st = cloud_streams(mu > 0.0 ? 0.0 : tau, tau, b);
    float diffuse = mu > 0.0 ? mu0c * st.y / CLOUD_PI : mu0c * max(st.x - exp(-tau / mu0c), 0.0) / CLOUD_PI;
    float skyD = mu > 0.0 ? st.y / CLOUD_PI : st.x / CLOUD_PI;
    float h = u.shellMid.y;
    float3 sun = u.sunLight.rgb * cloud_sunTransmittance(h, mu0, trans, linear, u);
    float3 sky = u.sunLight.rgb * cloud_skyIrradiance(h, mu0, irr, linear, u);
    float3 L = sun * (phase * single + diffuse) + sky * skyD;
    float alpha = 1.0 - exp(-tau / m);
    r.color = float4(L * coverEff, alpha * coverEff);
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
    int lightSamples = int(u.march.y);
    float lightDistance = u.march.z;
    float tm = t0 + jitter * (near ? base * 0.05 : base);
    // In cloud; refining (fine steps after backing off at first contact).
    bool inCloud = false, refining = false;
    float fine = base;
    for (int i = 0; i < steps * 2 && tm < t1; i++) {
        float x = (tm - t0) / max(span, 1.0);
        float empty = near ? max(2.0 * x * span / float(steps), base * 0.05) : base;
        float3 q = d * tm;
        float detail = u.lighting.z * (1.0 - cloud_smoothstep(15000.0, 60000.0, tm));
        CloudSample c = cloud_sample(q, detail, false, t, wrap, weather, u);
        if (c.sigma <= 0.0) {
            if (inCloud) { inCloud = false; refining = false; }
            tm += refining ? fine : empty;
            continue;
        }
        if (!inCloud && !refining) {
            fine = clamp(0.4 / c.sigma, 1.0, empty);
            float back = min(0.5 * empty, tm - t0);
            if (back > fine) {
                refining = true;
                tm -= back;
                continue;
            }
        }
        inCloud = true;
        refining = false;
        float dt = clamp(0.4 / c.sigma, 1.0, empty);
        r.entry = min(r.entry, tm);
        float3 pf = cloud_figure(q, u);
        float h = cloud_height(pf, u);
        float3 up = normalize(float3(pf.x, pf.y, pf.z * u.cameraFigure.w));
        float mu0 = dot(u.sun.xyz, up);
        float muUp = -dot(d, up);
        // The light march towards the Sun.
        float tauSun = 0.0;
        for (int k = 0; k < lightSamples; k++) {
            float a0 = float(k) / float(lightSamples), a1 = float(k + 1) / float(lightSamples);
            float e0 = a0 * a0, e1 = a1 * a1;
            float sl = lightDistance * 0.5 * (e0 + e1);
            CloudSample l = cloud_sample(q + u.sun.xyz * sl, 0.0, true, t, wrap, weather, u);
            tauSun += l.sigma * lightDistance * (e1 - e0);
        }
        float tcol = min(c.column * (1.0 - c.h01), tauSun * max(mu0, u.lighting.y));
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

// The march target's texel gid: the cirrus, the far layers or the march
// (blended by the pixel's footprint on the layers), composited in order of
// distance. Color: premultiplied radiance, pre-exposed, and 1 - T; depth:
// the front, the opacity-weighted mean and the entry, as linear (view-axis)
// depths (m).
kernel void cloud_march_kernel(texture2d<float, access::write> outColor [[texture(0)]],
                               texture2d<float, access::write> outDepth [[texture(1)]],
                               texture3d<float> shape [[texture(2)]],
                               texture3d<float> detail [[texture(3)]],
                               texture2d<float> curl [[texture(4)]],
                               texture2d<float> weatherA [[texture(5)]],
                               texture2d<float> weatherB [[texture(6)]],
                               texture3d<float> slab [[texture(7)]],
                               texture2d<float> trans [[texture(8)]],
                               texture2d<float> irr [[texture(9)]],
                               sampler wrap [[sampler(0)]],
                               sampler weather [[sampler(1)]],
                               sampler linear [[sampler(ORBIT_SAMPLER_LINEAR_CLAMP)]],
                               constant CloudUniforms &u [[buffer(0)]],
                               constant EffectSlotUniforms &e [[buffer(1)]],
                               constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]],
                               uint2 tid [[thread_position_in_grid]]) {
    // One texel in each 2x2 block when reprojecting, every texel otherwise.
    uint2 gid = u.checker.z > 0.5 ? tid * 2u + uint2(u.checker.xy) : tid;
    if (gid.x >= uint(u.target.x) || gid.y >= uint(u.target.y)) { return; }
    CloudTextures t = {shape, detail, curl, weatherA, weatherB};
    float2 px = (float2(gid) + 0.5) * u.target.zw;
    float3 vr = orbit_viewRay(px, frame);
    float3 w = normalize((frame.viewToWorld * float4(vr, 0.0)).xyz);
    float3 d = normalize((u.worldToBody * float4(w, 0.0)).xyz);
    // Linear depth (along the view axis) per metre along the ray.
    float depthPerMetre = 1.0 / length(vr);
    float pixelAngle = u.footprint.x;
    float3 of = u.cameraFigure.xyz, df = cloud_figureDir(d, u);

    CloudResult result = {float4(0.0), 1e30, 1e30, 1e30};
    // The ray's stretch in the clouds' shell, to the ground.
    float2 top = cloud_shell(of, df, u.shell.y);
    float2 ground = cloud_shell(of, df, u.shell.x);
    float tGround = ground.x >= 0.0 ? ground.x : 1e30;
    bool inside = u.radii.y <= u.radii.z;
    float t0 = inside ? 0.0 : top.x, t1 = min(inside ? (top.y >= 0.0 ? top.y : top.x) : top.y, tGround);
    if (top.x < 0.0 && top.y < 0.0) { t1 = -1.0; }
    if (inside) { t1 = min(t1, u.march.w); }
    if (t1 > t0 && t0 >= 0.0) {
        // The far layers and the march, blended by the footprint where
        // the ray meets the low layer.
        CloudResult farLow = {float4(0.0), 1e30, 1e30, 1e30}, farMid = farLow;
        float2 hitLow = cloud_shell(of, df, u.shell.w);
        float tl = hitLow.x >= 0.0 ? hitLow.x : max(t0, 0.0);
        float muL = 1.0;
        {
            float3 pf = of + df * tl;
            float3 up = normalize(float3(pf.x, pf.y, pf.z * u.cameraFigure.w));
            muL = max(-dot(d, up), 0.02);
        }
        float footprint = tl * pixelAngle / muL;
        float wFar = max(u.regime.z, inside ? 0.0 : cloud_smoothstep(u.footprint.y, u.footprint.z, footprint));
        if (u.lookDev.w > 1.5) { wFar = 0.0; }
        if (u.lookDev.w > 0.5 && u.lookDev.w < 1.5) { wFar = 1.0; }
        CloudResult far = {float4(0.0), 1e30, 1e30, 1e30};
        if (wFar > 0.0) {
            farMid = cloud_farLayer(of, df, d, u.shellMid.x, u.shellMid.w, 1, t, slab, trans, irr, linear, weather, u);
            farLow = cloud_farLayer(of, df, d, u.shell.w, u.shellMid.z, 0, t, slab, trans, irr, linear, weather, u);
            far = cloud_over(farMid, farLow);
        }
        CloudResult marched = {float4(0.0), 1e30, 1e30, 1e30};
        if (wFar < 1.0) {
            float jitter = cloud_noise(float2(gid), u.checker.w);
            marched = cloud_march(d, t0, t1, inside, jitter, t, trans, irr, wrap, linear, weather, u, e);
        }
        result.color = mix(marched.color, far.color, wFar);
        result.front = wFar >= 1.0 ? far.front : (wFar <= 0.0 ? marched.front : min(marched.front, far.front));
        result.mean = wFar >= 0.5 ? far.mean : marched.mean;
        result.entry = wFar >= 1.0 ? far.entry : (wFar <= 0.0 ? marched.entry : min(marched.entry, far.entry));
    }
    CloudResult cirrus = cloud_cirrus(of, df, d, pixelAngle, t, trans, irr, wrap, linear, weather, u);
    // Order by distance: the cirrus over the lower layers seen from below
    // or from above.
    if (cirrus.color.a > 0.0) {
        bool cirrusNearer = cirrus.entry < result.entry;
        result = cirrusNearer ? cloud_over(cirrus, result) : cloud_over(result, cirrus);
    }
    float4 c = result.color;
    if (orbit_isNotFinite(c.rgb) || orbit_isNotFinite(c.a)) { c = float4(0.0); }
    outColor.write(float4(min(c.rgb, float3(6e4)), clamp(c.a, 0.0, 1.0)), gid);
    // Linear (view-axis) depths, as R6's fronts are.
    outDepth.write(float4(result.front, result.mean, result.entry, 0.0) * depthPerMetre, gid);
}

// ------------------------------------------------- the temporal resolve ---

struct CloudResolveUniforms {
    float4x4 reprojection;   // camera-relative world now -> last frame's clip
    float4 target;           // xy: size, zw: frame pixels per texel
    float4 checker;          // xy: this frame's texel, z: 1 reprojecting, w: 1 history valid
};

// Every texel: marched this frame, or last frame's at the same body-fixed
// point (its colour filtered, its depths the nearest texel's), the colour
// clamped to the box of this frame's marched neighbours. Without history the
// nearest marched neighbour stands in.
kernel void cloud_resolve(texture2d<float, access::read> fresh [[texture(0)]],
                          texture2d<float, access::read> freshDepth [[texture(1)]],
                          texture2d<float> history [[texture(2)]],
                          texture2d<float, access::read> historyDepth [[texture(3)]],
                          texture2d<float, access::write> outColor [[texture(4)]],
                          texture2d<float, access::write> outDepth [[texture(5)]],
                          sampler linear [[sampler(ORBIT_SAMPLER_LINEAR_CLAMP)]],
                          constant CloudResolveUniforms &r [[buffer(0)]],
                          constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]],
                          uint2 gid [[thread_position_in_grid]]) {
    uint2 size = uint2(r.target.xy);
    if (gid.x >= size.x || gid.y >= size.y) { return; }
    bool marched = r.checker.z < 0.5 || all((gid & 1u) == uint2(r.checker.xy));
    if (marched) {
        outColor.write(fresh.read(gid), gid);
        outDepth.write(freshDepth.read(gid), gid);
        return;
    }
    // This frame's marched texels around it: one in each 2x2 block.
    uint2 base = (gid & ~1u) + uint2(r.checker.xy);
    float4 lo = float4(1e30), hi = float4(-1e30), nearest = float4(0.0), nearestDepth = float4(1e30);
    float best = 1e30;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            int2 p = int2(base) + int2(x, y) * 2;
            if (p.x < 0 || p.y < 0 || p.x >= int(size.x) || p.y >= int(size.y)) { continue; }
            float4 c = fresh.read(uint2(p));
            lo = min(lo, c);
            hi = max(hi, c);
            float dd = length(float2(p) - float2(gid));
            if (dd < best) { best = dd; nearest = c; nearestDepth = freshDepth.read(uint2(p)); }
        }
    }
    if (r.checker.w < 0.5) {
        outColor.write(nearest, gid);
        outDepth.write(nearestDepth, gid);
        return;
    }
    // The point at the cloud's mean depth along this texel's ray, in last
    // frame's view (a direction where there is no cloud).
    float2 px = (float2(gid) + 0.5) * r.target.zw;
    float3 w = (frame.viewToWorld * float4(orbit_viewRay(px, frame), 0.0)).xyz;
    float z = nearestDepth.y;
    float4 clip = z > 0.0 && z < 1e12 ? r.reprojection * float4(w * z, 1.0) : r.reprojection * float4(w, 0.0);
    float2 uv = float2(-1.0);
    if (clip.w > 0.0) {
        float2 ndc = clip.xy / clip.w;
        uv = float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
    }
    if (any(uv < 0.0) || any(uv > 1.0)) {
        outColor.write(nearest, gid);
        outDepth.write(nearestDepth, gid);
        return;
    }
    float4 h = history.sample(linear, uv);
    uint2 ht = min(uint2(uv * r.target.xy), size - 1u);
    float4 hd = historyDepth.read(ht);
    float4 margin = (hi - lo) * 0.1;
    outColor.write(clamp(h, lo - margin, hi + margin), gid);
    outDepth.write(float4(min(hd.x, nearestDepth.x), hd.y, min(hd.z, nearestDepth.z), 0.0), gid);
}

// ------------------------------------------------ the cloud shadow map ---

// Texel gid's Sun ray through the shell: the optical depth above each of
// the four altitudes in u.shadowLevels.
kernel void cloud_shadow(texture2d<float, access::write> out [[texture(0)]],
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
    // From the shell's top towards the Sun's opposite, down to the ground.
    float3 of = cloud_figure(base, u), df = cloud_figureDir(-s, u);
    float cTop = dot(of, of) - pow(u.radii.x + u.radii.z, 2.0);
    // Back up the ray to above the shell: start where it enters the top.
    float2 enter = cloud_shell(of, -df, cTop);
    float back = enter.x >= 0.0 ? enter.x : (enter.y >= 0.0 ? enter.y : 0.0);
    float3 o = base + s * back;
    float3 of2 = cloud_figure(o, u);
    float2 g = cloud_shell(of2, df, dot(of2, of2) - u.radii.x * u.radii.x);
    float tEnd = g.x >= 0.0 ? g.x : 2.0 * back;
    int steps = int(u.shadow.w);
    float4 tauAbove = float4(0.0);
    float dt = tEnd / float(steps);
    for (int i = 0; i < steps; i++) {
        float tm = (float(i) + 0.5) * dt;
        float3 q = o - s * tm;
        CloudSample c = cloud_sample(q, 0.0, true, t, wrap, weather, u);
        float h = cloud_height(cloud_figure(q, u), u);
        float add = c.sigma * dt;
        for (int k = 0; k < 4; k++) {
            if (h >= u.shadowLevels[k]) { tauAbove[k] += add; }
        }
    }
    out.write(tauAbove, gid);
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

// The resolved clouds at this texel, cut where the scene's depth (R6's
// test depth) lies in front of or within them: the optical depth before the
// scene, as a fraction of the way from the cloud's entry to twice its mean
// depth beyond it. Its front for R6's composite, where it has one.
fragment EffectCloudOut cloud_slot_fragment(CloudSlotOut in [[stage_in]],
                                            constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]],
                                            constant EffectSlotUniforms &e [[buffer(ORBIT_EFFECT_BUFFER_SLOTS)]],
                                            constant float4 &scale [[buffer(0)]],
                                            texture2d<float> clouds [[texture(0)]],
                                            texture2d<float> depths [[texture(1)]],
                                            texture2d<float> halfResDepth [[texture(ORBIT_EFFECT_TEXTURE_HALFRES_DEPTH)]],
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
        uint2 t = min(uint2(uv * float2(depths.get_width(), depths.get_height())),
                      uint2(depths.get_width(), depths.get_height()) - 1u);
        z = depths.read(t);
    }
    if (c.a <= 0.0 && max(c.r, max(c.g, c.b)) <= 0.0) { discard_fragment(); }
    float scene = orbit_effectSceneDistance(texel, halfResDepth, frame);
    float entry = min(z.z, z.x), back = entry + 2.0 * max(z.y - entry, 0.0);
    if (scene <= entry) { discard_fragment(); }
    if (scene < back) {
        float f = (scene - entry) / max(back - entry, 1e-3);
        float a = clamp(c.a, 0.0, 0.9999);
        float cut = 1.0 - pow(1.0 - a, f);
        c.rgb *= a > 1e-5 ? cut / a : f;
        c.a = cut;
    }
    EffectCloudOut o;
    o.color = float4(c.rgb, clamp(c.a, 0.0, 1.0));
    bool front = z.x < 1e20 && z.x < scene;
    o.front = float4(front ? orbit_frontCode(z.x) : ORBIT_EFFECT_NO_FRONT);
    return o;
}
"""#

extension ShaderModule {
    public static let cloud = ShaderModule(name: "Cloud", headers: [.effectSlots], source: cloudShaderSource)
}
