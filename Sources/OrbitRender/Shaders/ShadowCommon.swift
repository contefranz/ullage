// The Sun's shadow on a receiver, from the shadow maps (R4) and, later, the
// cloud shadow (C2). A header for every module with shadow receivers (track
// R4 owns this file); `ShadowFitting` (OrbitScene) is its Swift reference.
let shadowCommonSource = #"""
// --------------------------------------------------------------- shadow ---
//
// THE API, for R2's vessel and site shading and E2's planet surface:
//
//   float orbit_sunShadow(float3 position, float3 normal, constant LightingUniforms &lighting,
//                         depth2d_array<float> atlas, sampler compare);
//   float orbit_groundShadow(float3 position, float3 normal, constant LightingUniforms &lighting,
//                            depth2d_array<float> atlas, sampler compare);
//
//   position  the receiver, camera-relative world (m): where the vertex
//             function placed it (model * position), not the view space.
//   normal    unit shading normal (world) of the side being drawn: reversed
//             on the back of a two-sided shape, as the shading uses it.
//   returns   the Sun's visible share, 0 in umbra to 1 lit, from vessels and
//             sites. Multiply the Sun's direct light by it and nothing else.
//             A face turned from the Sun gets 0. The Earth's shadow stays
//             the vessel's sunlit fraction, clouds' C2's cloud shadow.
//   bindings  lighting at ORBIT_BUFFER_LIGHTING, the atlas at
//             ORBIT_TEXTURE_SHADOW_ATLAS, compare at
//             ORBIT_SAMPLER_SHADOW_COMPARE: the frame graph binds all three
//             on every render encoder it opens (FrameContext.bindShared).
//             With no maps (none fitted, or ShadowSettings.enabled false)
//             both return 1 at once.
//
//   orbit_groundShadow is the planet's entry point (planet_fragment's hit
//   point d * t and its normal); today it is orbit_sunShadow. Off the maps'
//   footprints, the whole planet but the ground about the vessels and the
//   pad, it costs a matrix product per map.
//
// R2's mesh_fragment, for example, with the camera-relative world position
// carried from its vertex function:
//
//   fragment float4 mesh_fragment(MeshOut in [[stage_in]], bool front [[front_facing]],
//                                 constant MeshUniforms &u [[buffer(1)]],
//                                 constant LightingUniforms &lighting [[buffer(ORBIT_BUFFER_LIGHTING)]],
//                                 depth2d_array<float> shadowAtlas [[texture(ORBIT_TEXTURE_SHADOW_ATLAS)]],
//                                 sampler shadowCompare [[sampler(ORBIT_SAMPLER_SHADOW_COMPARE)]]) {
//       float3 n = normalize(in.normal);
//       if (!front) { n = -n; }
//       float sun = u.light.x * max(dot(n, u.sunDir.xyz), 0.0)
//                 * orbit_sunShadow(in.world, n, lighting, shadowAtlas, shadowCompare);
//
// THE MAPS (LightingUniforms, filled by ShadowPass in P0):
//   shadowMatrices[i]  camera-relative world -> map i's clip space: x, y in
//                      -1...1 across its footprint, z 1 at its Sun side to 0
//                      at its far side (reversed, as the scene's depth).
//   shadowMaps[i]      x: atlas layer, y: texel (m), z: depth range (m),
//                      w: 1 in use.
//   shadowParams       x: maps in use, y: filter taps (9 or fewer: a fixed
//                      3x3 PCF), z: normal offset (texels), w: slope bias
//                      (texels per unit tangent of the incidence).
// Maps come in the order receivers try them: the detail map, the camera
// target's cluster, then other clusters and sites. A receiver takes the
// first whose footprint holds it with room for the filter, and blends into
// the next one holding it over the last 10% of the footprint. Every map's
// depth covers every caster it draws, so a receiver anywhere in its
// footprint's column, however far behind, is served right.
//
// THE FILTER is PCSS (Fernando 2005) with the Sun's 0.533° disc:
// - a blocker search: the receiver's own texel, then taps spaced
//   logarithmically out to the widest penumbra a caster at the map's Sun
//   side could throw here (`orbit_shadowSearch`), dense near the receiver
//   so a thin caster close by (a truss member, a swing arm) is found;
// - then Vogel taps (`orbit_shadowVogel`) over a disc the penumbra's half
//   width across, tan(alpha) * delta-d for the blockers' mean depth, each a
//   hardware 2x2 compare.
// The taps turn per map texel (fixed to the casters, so the grain never
// crawls), and each compares with the receiver's own plane at the tap
// (receiver-plane depth bias), so a slope does not shadow itself. While a
// coarser map also holds the receiver, a penumbra wider than
// ORBIT_SHADOW_MAX_FILTER texels, or a search wider than
// ORBIT_SHADOW_MAX_SEARCH, is left to that map.

#define ORBIT_SHADOW_TAN_SUN 0.0046507          // tan of the Sun's mean angular radius (ShadowFitting.sunAngularRadius)
#define ORBIT_SHADOW_MAX_FILTER 24.0            // texels (ShadowFitting.maxFilterRadius)
#define ORBIT_SHADOW_MAX_SEARCH 96.0            // texels (ShadowFitting.maxSearchRadius)
#define ORBIT_SHADOW_BAND 0.1                   // ShadowFitting.blendBand
#define ORBIT_SHADOW_SEARCH_TAPS 16
#define ORBIT_SHADOW_MAX_SLOPE 8.0              // the incidence's tangent, at most
#define ORBIT_SHADOW_DEPTH_ULP (1.0 / 65535.0)  // depth16Unorm

// Map i's clip position of p.
inline float3 orbit_shadowClip(constant LightingUniforms &l, int i, float3 p) {
    return (l.shadowMatrices[i] * float4(p, 1.0)).xyz;
}

// Map i's right, up and to-the-Sun axes (world): its matrix's rows.
inline float3x3 orbit_shadowAxes(constant LightingUniforms &l, int i) {
    float4x4 m = l.shadowMatrices[i];
    return float3x3(normalize(float3(m[0][0], m[1][0], m[2][0])), normalize(float3(m[0][1], m[1][1], m[2][1])),
                    normalize(float3(m[0][2], m[1][2], m[2][2])));
}

// The half width of a map's usable footprint in clip units: the filter's
// room is left at its edge (ShadowFitting.usableEdge).
inline float orbit_shadowEdge(float size) {
    return 1.0 - 2.0 * (ORBIT_SHADOW_MAX_FILTER + 2.0) / size;
}

// Tap k of n in the unit disc (Vogel 2007; ShadowFitting.vogel): equal-area
// rings turned by the golden angle, so the taps weigh the disc uniformly.
inline float2 orbit_shadowVogel(int k, int n, float rotation) {
    float r = sqrt((float(k) + 0.5) / float(n));
    float a = float(k) * 2.39996323 + rotation;
    return r * float2(cos(a), sin(a));
}

// Blocker-search tap k of n (k >= 1; tap 0 is the receiver's texel), out
// to `radius` texels: radii spaced logarithmically from a texel, turned by
// the golden angle (ShadowFitting.searchTap).
inline float2 orbit_shadowSearch(int k, int n, float radius, float rotation) {
    float r = pow(max(radius, 1.0), float(k) / float(n - 1));
    float a = float(k) * 2.39996323 + rotation;
    return r * float2(cos(a), sin(a));
}

// Interleaved gradient noise (Jimenez 2014) of a map texel, 0...1.
inline float orbit_shadowNoise(float2 texel) {
    return fract(52.9829189 * fract(dot(floor(texel), float2(0.06711056, 0.00583715))));
}

// The Sun's visible share at p from map i alone; -1 when a coarser map
// (`coarser`) should serve p instead: its penumbra is wider than the
// filter's limit here.
inline float orbit_shadowFromMap(constant LightingUniforms &l, int i, float3 p, float3 n, bool coarser,
                                 depth2d_array<float> atlas, sampler compare) {
    float4 info = l.shadowMaps[i];
    uint layer = uint(info.x + 0.5);
    float texel = info.y, range = info.z, size = float(atlas.get_width());
    float3x3 axes = orbit_shadowAxes(l, i);
    float3 nl = float3(dot(n, axes[0]), dot(n, axes[1]), dot(n, axes[2]));   // the normal in the map's axes
    float cosI = max(nl.z, 1e-3), sinI = sqrt(saturate(1.0 - cosI * cosI));
    float tanI = min(sinI / cosI, ORBIT_SHADOW_MAX_SLOPE);
    float3 c = orbit_shadowClip(l, i, p + n * (l.shadowParams.z * texel * sinI));
    // The receiver, a texel and more on a slope towards the Sun, in depth.
    float z = c.z + (1.0 + l.shadowParams.w * tanI) * texel / range + 1.5 * ORBIT_SHADOW_DEPTH_ULP;
    // Its plane's depth per texel along the map's s (right) and t (down).
    float2 g = -nl.xy / cosI;
    float2 slope = clamp(float2(g.x, -g.y), -ORBIT_SHADOW_MAX_SLOPE, ORBIT_SHADOW_MAX_SLOPE) * texel / range;
    float2 st = float2(0.5 + 0.5 * c.x, 0.5 - 0.5 * c.y) * size;
    float rotation = 6.2831853 * orbit_shadowNoise(st);
    int taps = int(l.shadowParams.y + 0.5);

    if (taps <= 9) {
        float lit = 0.0;
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                float2 o = float2(x, y);
                lit += atlas.sample_compare(compare, (st + o) / size, layer, saturate(z + dot(slope, o)));
            }
        }
        return lit / 9.0;
    }

    // Blockers: texels nearer the Sun than the receiver's plane, within the
    // widest penumbra a caster at the map's Sun side would throw here, and
    // 30% beyond, where the sparse outer taps would miss a penumbra's edge.
    float reach = max(1.3 * ORBIT_SHADOW_TAN_SUN * (1.0 - z) * range / texel, 1.0);
    float search = coarser ? min(reach, ORBIT_SHADOW_MAX_SEARCH) : reach;
    float sum = 0.0, count = 0.0;
    for (int k = 0; k < ORBIT_SHADOW_SEARCH_TAPS; k++) {
        float2 o = k == 0 ? float2(0.0) : orbit_shadowSearch(k, ORBIT_SHADOW_SEARCH_TAPS, search, rotation);
        float2 t = floor(st + o);
        if (any(t < 0.0) || any(t >= size)) { continue; }
        float d = atlas.read(uint2(t), layer);
        if (d > max(z + dot(slope, o), ORBIT_SHADOW_DEPTH_ULP)) {
            sum += d;
            count += 1.0;
        }
    }
    if (count == 0.0) { return coarser && reach > search ? -1.0 : 1.0; }

    float radius = ORBIT_SHADOW_TAN_SUN * (sum / count - z) * range / texel;
    if (coarser && radius > ORBIT_SHADOW_MAX_FILTER) { return -1.0; }
    float lit = 0.0;
    for (int k = 0; k < taps; k++) {
        float2 o = orbit_shadowVogel(k, taps, rotation) * radius;
        lit += atlas.sample_compare(compare, (st + o) / size, layer, saturate(z + dot(slope, o)));
    }
    return lit / float(taps);
}

// The Sun's visible share at p (x) and the map that gave it (y): its index,
// -1 when no map holds p (lit), -2 when the face is turned from the Sun.
inline float2 orbit_sunShadowAndMap(float3 p, float3 n, constant LightingUniforms &l,
                                    depth2d_array<float> atlas, sampler compare) {
    int count = min(int(l.shadowParams.x + 0.5), ORBIT_MAX_SHADOW_MAPS);
    if (count <= 0) { return float2(1.0, -1.0); }
    float edge = orbit_shadowEdge(float(atlas.get_width()));
    bool holds[ORBIT_MAX_SHADOW_MAPS], any = false;
    float band[ORBIT_MAX_SHADOW_MAPS];
    for (int i = 0; i < count; i++) {
        float3 c = orbit_shadowClip(l, i, p);
        float e = max(abs(c.x), abs(c.y)) / edge;
        holds[i] = e < 1.0;
        any = any || holds[i];
        band[i] = saturate((e - (1.0 - ORBIT_SHADOW_BAND)) / ORBIT_SHADOW_BAND);
    }
    if (!any) { return float2(1.0, -1.0); }
    if (dot(n, orbit_shadowAxes(l, 0)[2]) <= 0.0) { return float2(0.0, -2.0); }
    for (int i = 0; i < count; i++) {
        if (!holds[i]) { continue; }
        int next = -1;
        for (int j = i + 1; j < count && next < 0; j++) {
            if (holds[j]) { next = j; }
        }
        float v = orbit_shadowFromMap(l, i, p, n, next >= 0, atlas, compare);
        if (v < 0.0) { continue; }
        if (next >= 0 && band[i] > 0.0) {
            bool further = false;
            for (int j = next + 1; j < count; j++) { further = further || holds[j]; }
            float w = orbit_shadowFromMap(l, next, p, n, further, atlas, compare);
            if (w >= 0.0) { v = mix(v, w, band[i]); }
        }
        return float2(v, float(i));
    }
    return float2(1.0, -1.0);
}

// The Sun's visible share at a camera-relative position with a unit normal
// (world): 1 lit, 0 shadowed. See the API above.
inline float orbit_sunShadow(float3 position, float3 normal, constant LightingUniforms &lighting,
                             depth2d_array<float> atlas, sampler compare) {
    return orbit_sunShadowAndMap(position, normal, lighting, atlas, compare).x;
}

// The same on the planet's surface (E2): see the API above.
inline float orbit_groundShadow(float3 position, float3 normal, constant LightingUniforms &lighting,
                                depth2d_array<float> atlas, sampler compare) {
    return orbit_sunShadow(position, normal, lighting, atlas, compare);
}
"""#

extension ShaderHeader {
    public static let shadowCommon = ShaderHeader(name: "ShadowCommon", source: shadowCommonSource)
}
