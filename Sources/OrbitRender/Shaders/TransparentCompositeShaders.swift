// The effect slots' composite (track R6 owns this module): the
// half-resolution layers upsampled to the frame by depth
// (EffectSlots.upsampleWeights), ordered by their fronts and blended over
// the scene in one premultiplied colour; and the slots' debug views.
let transparentCompositeShaderSource = #"""
// --------------------------------------------------- effect composite ---

struct EffectFullscreenOut {
    float4 position [[position]];
};

vertex EffectFullscreenOut effect_composite_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    EffectFullscreenOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

// The layers at one pixel: premultiplied colours and front codes, in the
// tie order clouds, volumes, OIT.
struct EffectLayers {
    float4 color[3];
    float front[3];
};

// The maths' texel order, (0,0), (1,0), (0,1), (1,1), from a gather's
// (x: (u0,v1), y: (u1,v1), z: (u1,v0), w: (u0,v0)).
inline float4 effect_gatherOrder(float4 g) {
    return float4(g.w, g.z, g.x, g.y);
}

inline float4 effect_resolveOIT(float4 accumulation, float revealage) {
    float coverage = 1.0 - clamp(revealage, 0.0, 1.0);
    return float4(accumulation.rgb * (coverage / clamp(accumulation.a, 1e-5, 5e4)), coverage);
}

// The drawn layers (`used`: 1 clouds, 2 volumes, 4 OIT) at texel t.
inline EffectLayers effect_readLayers(uint2 t, uint used, texture2d<float> clouds, texture2d<float> volumes,
                                      texture2d<float> accumulation, texture2d<float> revealage) {
    EffectLayers l;
    l.color[0] = (used & 1u) != 0u ? clouds.read(t) : float4(0.0);
    l.color[1] = (used & 2u) != 0u ? volumes.read(t) : float4(0.0);
    l.color[2] = (used & 4u) != 0u ? effect_resolveOIT(accumulation.read(t), revealage.read(t).r) : float4(0.0);
    return l;
}

// The drawn layers filtered bilinearly at uv (normalised): the sampler's
// weights are the maths' exactly, a pixel sitting a quarter texel from the
// four centres. The OIT pair is filtered, then resolved.
inline EffectLayers effect_sampleLayers(float2 uv, uint used, sampler s, texture2d<float> clouds,
                                        texture2d<float> volumes, texture2d<float> accumulation,
                                        texture2d<float> revealage) {
    EffectLayers l;
    l.color[0] = (used & 1u) != 0u ? clouds.sample(s, uv) : float4(0.0);
    l.color[1] = (used & 2u) != 0u ? volumes.sample(s, uv) : float4(0.0);
    l.color[2] = (used & 4u) != 0u ? effect_resolveOIT(accumulation.sample(s, uv), revealage.sample(s, uv).r)
                                   : float4(0.0);
    return l;
}

// The layers over one another, farthest front first; equal fronts keep the
// tie order, the later over the earlier.
inline float4 effect_compositeLayers(EffectLayers l) {
    int order[3] = {0, 1, 2};
    for (int i = 1; i < 3; i++) {
        for (int j = i; j > 0 && l.front[order[j]] > l.front[order[j - 1]]; j--) {
            int t = order[j];
            order[j] = order[j - 1];
            order[j - 1] = t;
        }
    }
    float4 result = float4(0.0);
    for (int k = 0; k < 3; k++) {
        float4 c = l.color[order[k]];
        result = c + (1.0 - c.a) * result;
    }
    return result;
}

// The upsample (EffectSlots.upsampleWeights) and the composite
// (EffectSlots.compositePixel), blended premultiplied over the scene:
// rgb + (1 - a) * scene. The pixel's depth comes from the downsample's copy,
// texture 5 (`.halfResPixelDepths`).
// - At full resolution, the pixel's own texel.
// - At half resolution, the four test depths in one gather. Where they are
//   all within the tolerance of the pixel's depth, the layers are filtered
//   bilinearly, one sample each, and the fronts are the least of the four.
//   Elsewhere the texel nearest in depth is read alone.
// - The fronts are read only where two layers or more have anything.
// - A pixel no layer covers is discarded; a NaN or an infinity from an
//   effect stays out of the frame.
fragment float4 effect_composite_fragment(EffectFullscreenOut in [[stage_in]],
                                          constant EffectSlotUniforms &e [[buffer(ORBIT_EFFECT_BUFFER_SLOTS)]],
                                          sampler linear [[sampler(ORBIT_SAMPLER_LINEAR_CLAMP)]],
                                          texture2d<float> halfResDepth [[texture(ORBIT_EFFECT_TEXTURE_HALFRES_DEPTH)]],
                                          texture2d<float> clouds [[texture(0)]],
                                          texture2d<float> volumes [[texture(1)]],
                                          texture2d<float> accumulation [[texture(2)]],
                                          texture2d<float> revealage [[texture(3)]],
                                          texture2d<float> fronts [[texture(4)]],
                                          texture2d<float> pixelDepths [[texture(5)]]) {
    uint2 px = uint2(in.position.xy);
    uint used = uint(e.scale.w + 0.5);
    uint2 last = uint2(e.target.xy) - 1u;
    EffectLayers l;
    // The texel the fronts come from; none: the least of the four around uv.
    int2 single = int2(min(px, last));
    float2 uv = (float2(px) + 0.5) * e.scale.y * e.target.zw;
    if (e.scale.x > 1.5) {
        float2 t = (float2(px) + 0.5) * e.scale.y - 0.5;
        float2 cell = floor(t), fr = t - cell;
        float4 bilinear = float4((1.0 - fr.x) * (1.0 - fr.y), fr.x * (1.0 - fr.y), (1.0 - fr.x) * fr.y, fr.x * fr.y);
        float4 depths = effect_gatherOrder(halfResDepth.gather(linear, uv));
        // The pixel's own depth, from the downsample's copy (the scene's is
        // this encoder's resolve target).
        float depth = pixelDepths.read(px / 2u)[(px.x & 1u) + 2u * (px.y & 1u)];
        float4 apart = abs(log2(max(depths, float4(1e-30))) - log2(max(depth, 1e-30)));
        if (all(apart <= e.scale.z)) {
            single = int2(-1);
            l = effect_sampleLayers(uv, used, linear, clouds, volumes, accumulation, revealage);
        } else {
            int best = 0;
            for (int i = 1; i < 4; i++) {
                if (apart[i] < apart[best] || (apart[i] == apart[best] && bilinear[i] > bilinear[best])) { best = i; }
            }
            int2 offsets[4] = {int2(0, 0), int2(1, 0), int2(0, 1), int2(1, 1)};
            single = clamp(int2(cell) + offsets[best], int2(0), int2(last));
            l = effect_readLayers(uint2(single), used, clouds, volumes, accumulation, revealage);
        }
    } else {
        l = effect_readLayers(uint2(single), used, clouds, volumes, accumulation, revealage);
    }
    int drawn = 0;
    for (int k = 0; k < 3; k++) { drawn += any(l.color[k] != 0.0) ? 1 : 0; }
    if (drawn == 0) { discard_fragment(); }
    for (int k = 0; k < 3; k++) { l.front[k] = ORBIT_EFFECT_NO_FRONT; }
    if (drawn > 1) {
        if (single.x >= 0) {
            float4 f = fronts.read(uint2(single));
            l.front[0] = f.r;
            l.front[1] = f.g;
            l.front[2] = f.b;
        } else {
            float4 r = fronts.gather(linear, uv, int2(0), component::x);
            float4 g = fronts.gather(linear, uv, int2(0), component::y);
            float4 b = fronts.gather(linear, uv, int2(0), component::z);
            l.front[0] = min(min(r.x, r.y), min(r.z, r.w));
            l.front[1] = min(min(g.x, g.y), min(g.z, g.w));
            l.front[2] = min(min(b.x, b.y), min(b.z, b.w));
        }
    }
    float4 c = effect_compositeLayers(l);
    if (orbit_isNotFinite(c.rgb) || orbit_isNotFinite(c.a)) { return float4(0.0); }
    return float4(c.rgb, clamp(c.a, 0.0, 1.0));
}

// ----------------------------------------------------- slot debug views ---

// A perceptual ramp, dark blue through green and yellow to white (as the
// render foundation's debug views).
inline float3 effect_debugRamp(float t) {
    t = clamp(t, 0.0, 1.0);
    float3 a = float3(0.05, 0.03, 0.30), b = float3(0.10, 0.55, 0.55), c = float3(0.95, 0.85, 0.20);
    return t < 0.5 ? mix(a, b, t * 2.0) : (t < 0.85 ? mix(b, c, (t - 0.5) / 0.35) : mix(c, float3(1.0), (t - 0.85) / 0.15));
}

// The depth ramp of F9's depth view: 0.25 m white ... 1e9 m dark blue.
inline float3 effect_depthColor(float linearDepth, float near) {
    return effect_debugRamp(1.0 - log10(max(linearDepth, near) / near) / 9.6);
}

// params.x: 1 the half-resolution test depth (magenta where a texel's quad
// spans an edge, so the checkerboard shows), 2 each layer's coverage (red
// clouds, green volumes, blue OIT), 3 the nearest front's depth, tinted by
// its layer (clouds grey, volumes orange, OIT cyan).
fragment float4 effect_debug_fragment(EffectFullscreenOut in [[stage_in]],
                                      constant float4 &params [[buffer(0)]],
                                      constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]],
                                      constant EffectSlotUniforms &e [[buffer(ORBIT_EFFECT_BUFFER_SLOTS)]],
                                      texture2d<float> halfResDepth [[texture(ORBIT_EFFECT_TEXTURE_HALFRES_DEPTH)]],
                                      texture2d<float> clouds [[texture(0)]],
                                      texture2d<float> volumes [[texture(1)]],
                                      texture2d<float> revealage [[texture(3)]],
                                      texture2d<float> fronts [[texture(4)]]) {
    uint2 t = min(uint2(in.position.xy * e.scale.y), uint2(e.target.xy) - 1u);
    int view = int(params.x + 0.5);
    uint used = uint(e.scale.w + 0.5);
    if (view == 1) {
        float2 d = halfResDepth.read(t).xy;
        if (d.x <= 0.0 && d.y <= 0.0) { return float4(0.0, 0.0, 0.0, 1.0); }
        float3 c = d.x > 0.0 ? effect_depthColor(orbit_linearDepth(d.x, frame.camera.x), frame.camera.x) : float3(0.0);
        bool edge = abs(log2(max(d.x, 1e-30)) - log2(max(d.y, 1e-30))) > e.scale.z;
        return float4(edge ? mix(c, float3(1.0, 0.0, 1.0), 0.6) : c, 1.0);
    }
    if (view == 2) {
        float3 c = float3((used & 1u) != 0u ? clouds.read(t).a : 0.0,
                          (used & 2u) != 0u ? volumes.read(t).a : 0.0,
                          (used & 4u) != 0u ? 1.0 - revealage.read(t).r : 0.0);
        return float4(c, 1.0);
    }
    float4 f = fronts.read(t);
    float code[3] = {(used & 1u) != 0u ? f.r : ORBIT_EFFECT_NO_FRONT, (used & 2u) != 0u ? f.g : ORBIT_EFFECT_NO_FRONT,
                     (used & 4u) != 0u ? f.b : ORBIT_EFFECT_NO_FRONT};
    int nearest = code[1] < code[0] ? 1 : 0;
    nearest = code[2] < code[nearest] ? 2 : nearest;
    if (code[nearest] >= ORBIT_EFFECT_NO_FRONT) { return float4(0.0, 0.0, 0.0, 1.0); }
    float3 tint[3] = {float3(0.8), float3(1.0, 0.6, 0.25), float3(0.3, 0.9, 1.0)};
    return float4(effect_depthColor(exp2(code[nearest]), frame.camera.x) * tint[nearest], 1.0);
}
"""#

extension ShaderModule {
    public static let transparentComposite = ShaderModule(name: "TransparentComposite", headers: [.effectSlots],
                                                          source: transparentCompositeShaderSource)
}
