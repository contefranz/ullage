// The effect slots' composite (track R6 owns this module): the
// half-resolution layers reconstructed at full resolution by depth and by
// where their effects ended (EffectSlots.upsampleWeights, LR0), ordered by
// their fronts and blended over the scene in one premultiplied colour; and
// the slots' debug views.
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

// A layer's channel as the composite takes it (EffectSlots.layerChannel):
// each item is held below 6e4, but a layer sums them in rgba16Float, which
// can reach +inf. As in R1's post, light past half's range saturates (here
// at ORBIT_EFFECT_MAX_RADIANCE), and NaN and -inf are no light, so an
// overflowing layer shows saturated, not a hole.
inline float effect_layerChannel(float x) {
    uint b = as_type<uint>(x);
    if ((b & 0x7f800000u) == 0x7f800000u) { return (b & 0x807fffffu) == 0u ? ORBIT_EFFECT_MAX_RADIANCE : 0.0; }
    return clamp(x, 0.0, ORBIT_EFFECT_MAX_RADIANCE);
}

// Premultiplied colour, its coverage within 0...1.
inline float4 effect_layer(float4 c) {
    return float4(effect_layerChannel(c.r), effect_layerChannel(c.g), effect_layerChannel(c.b),
                  min(effect_layerChannel(c.a), 1.0));
}

// The OIT pair resolved; a revealage that is not a number reveals everything.
inline float4 effect_resolveOIT(float4 accumulation, float revealage) {
    float reveal = orbit_isNotFinite(revealage) ? 1.0 : clamp(revealage, 0.0, 1.0);
    float coverage = 1.0 - reveal;
    float4 a = float4(effect_layerChannel(accumulation.r), effect_layerChannel(accumulation.g),
                      effect_layerChannel(accumulation.b), effect_layerChannel(accumulation.a));
    return effect_layer(float4(a.rgb * (coverage / clamp(a.a, 1e-5, 5e4)), coverage));
}

// The drawn layers (`used`: 1 clouds, 2 volumes, 4 OIT) at texel t.
inline EffectLayers effect_readLayers(uint2 t, uint used, texture2d<float> clouds, texture2d<float> volumes,
                                      texture2d<float> accumulation, texture2d<float> revealage) {
    EffectLayers l;
    l.color[0] = (used & 1u) != 0u ? effect_layer(clouds.read(t)) : float4(0.0);
    l.color[1] = (used & 2u) != 0u ? effect_layer(volumes.read(t)) : float4(0.0);
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
    l.color[0] = (used & 1u) != 0u ? effect_layer(clouds.sample(s, uv)) : float4(0.0);
    l.color[1] = (used & 2u) != 0u ? effect_layer(volumes.sample(s, uv)) : float4(0.0);
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

// The drawn layers at the four texels around a pixel, mixed with weights w
// (EffectSlots.compositePixel): colours summed, the OIT pair summed then
// resolved. The texels in the maths' order, from cell (the lower-left).
inline EffectLayers effect_mixLayers(int2 cell, int2 last, float4 w, uint used, texture2d<float> clouds,
                                     texture2d<float> volumes, texture2d<float> accumulation,
                                     texture2d<float> revealage) {
    int2 offsets[4] = {int2(0, 0), int2(1, 0), int2(0, 1), int2(1, 1)};
    float4 c0 = float4(0.0), c1 = float4(0.0), acc = float4(0.0);
    float rev = 0.0;
    for (int i = 0; i < 4; i++) {
        if (w[i] <= 0.0) { continue; }
        uint2 t = uint2(clamp(cell + offsets[i], int2(0), last));
        if ((used & 1u) != 0u) { c0 += w[i] * clouds.read(t); }
        if ((used & 2u) != 0u) { c1 += w[i] * volumes.read(t); }
        if ((used & 4u) != 0u) {
            acc += w[i] * accumulation.read(t);
            rev += w[i] * revealage.read(t).r;
        }
    }
    EffectLayers l;
    l.color[0] = (used & 1u) != 0u ? effect_layer(c0) : float4(0.0);
    l.color[1] = (used & 2u) != 0u ? effect_layer(c1) : float4(0.0);
    l.color[2] = (used & 4u) != 0u ? effect_resolveOIT(acc, rev) : float4(0.0);
    return l;
}

// Whether a clip code (EffectSlots.clipEnded) lets a pixel of log2 linear
// depth pixelLog use a texel of log2 linear test depth texelLog (the sky at
// ORBIT_EFFECT_SKY_DISTANCE for both): ended in front of both.
inline bool effect_clipEnded(float code, float texelLog, float pixelLog) {
    float b = round(code * 255.0);
    if (b >= ORBIT_EFFECT_CLIP_EMPTY) { return true; }
    if (b < 0.5) { return false; }
    float octaves = b <= ORBIT_EFFECT_CLIP_FINE ? (b - 1.0) / ORBIT_EFFECT_CLIP_STEPS
                                                : ORBIT_EFFECT_CLIP_FINE / ORBIT_EFFECT_CLIP_STEPS + 2.0 * (b - ORBIT_EFFECT_CLIP_FINE - 1.0);
    return texelLog - pixelLog <= octaves;
}

// How a pixel reads the half-resolution texels (EffectSlots.reconstruction).
// kind: 0 its own texel (full resolution), 1 bilinear, 2 renormalised, 3 the
// nearest in depth. uv: the bilinear sample's; cell: the lower-left texel of
// the four; w: the renormalised weights; single: the texel read alone.
struct EffectReconstruction {
    int kind;
    float2 uv;
    int2 cell;
    float4 w;
    int2 single;
};

// The reconstruction at pixel px (EffectSlots.upsampleWeights). At half
// resolution, of the four texels around the pixel, one matches when its
// test depth is within the tolerance of the pixel's, or when every layer
// drawn at it ended nearer than both scene depths: the volumes' back (the
// fronts' a) in front of the pixel's scene, the clouds' and OIT's clip
// codes met. A layer not reconstructed this frame
// (EffectSlotUniforms.reconstruction.x) never ends. All four matching:
// bilinear; some: Kopf et al.'s joint bilateral weights, the bilinear ones
// renormalised over them; none: the texel nearest in depth.
inline EffectReconstruction effect_reconstruct(uint2 px, constant EffectSlotUniforms &e, constant FrameUniforms &frame,
                                               sampler linear, texture2d<float> halfResDepth, texture2d<float> fronts,
                                               texture2d<float> pixelDepths, texture2d<float> clips) {
    uint used = uint(e.scale.w + 0.5);
    uint reconstructed = uint(e.reconstruction.x + 0.5) & used;
    int2 last = int2(e.target.xy) - 1;
    EffectReconstruction r;
    r.uv = (float2(px) + 0.5) * e.scale.y * e.target.zw;
    r.single = min(int2(px), last);
    r.cell = int2(0);
    r.w = float4(0.0);
    if (e.scale.x <= 1.5) {
        r.kind = 0;
        return r;
    }
    float2 t = (float2(px) + 0.5) * e.scale.y - 0.5;
    float2 fc = floor(t), fr = t - fc;
    r.cell = int2(fc);
    float4 bilinear = float4((1.0 - fr.x) * (1.0 - fr.y), fr.x * (1.0 - fr.y), (1.0 - fr.x) * fr.y, fr.x * fr.y);
    float4 depths = effect_gatherOrder(halfResDepth.gather(linear, r.uv));
    // The pixel's own depth, from the downsample's copy (the scene's is the
    // composite's resolve target).
    float depth = pixelDepths.read(px / 2u)[(px.x & 1u) + 2u * (px.y & 1u)];
    float lz = log2(max(depth, 1e-30));
    float4 lt = log2(max(depths, float4(1e-30)));
    float4 apart = abs(lt - lz);
    bool4 match = apart <= e.scale.z;
    if (!all(match)) {
        bool4 ended = bool4((used & ~reconstructed) == 0u);
        // Linear depths in log2, the sky at ORBIT_EFFECT_SKY_DISTANCE.
        float nearLog = log2(frame.camera.x), skyLog = log2(ORBIT_EFFECT_SKY_DISTANCE);
        float pixelLog = depth > 0.0 ? nearLog - lz : skyLog;
        if ((reconstructed & 2u) != 0u) {
            float4 backs = effect_gatherOrder(fronts.gather(linear, r.uv, int2(0), component::w));
            ended = ended && (backs < float4(pixelLog));
        }
        if ((reconstructed & 5u) != 0u) {
            float4 cr = effect_gatherOrder(clips.gather(linear, r.uv, int2(0), component::x));
            float4 cg = effect_gatherOrder(clips.gather(linear, r.uv, int2(0), component::y));
            for (int i = 0; i < 4; i++) {
                float texelLog = depths[i] > 0.0 ? nearLog - lt[i] : skyLog;
                if ((reconstructed & 1u) != 0u) { ended[i] = ended[i] && effect_clipEnded(cr[i], texelLog, pixelLog); }
                if ((reconstructed & 4u) != 0u) { ended[i] = ended[i] && effect_clipEnded(cg[i], texelLog, pixelLog); }
            }
        }
        match = match || ended;
    }
    if (all(match)) {
        r.kind = 1;
    } else if (any(match)) {
        r.kind = 2;
        r.w = select(float4(0.0), bilinear, match);
        r.w /= max(r.w.x + r.w.y + r.w.z + r.w.w, 1e-12);
    } else {
        r.kind = 3;
        int best = 0;
        for (int i = 1; i < 4; i++) {
            if (apart[i] < apart[best] || (apart[i] == apart[best] && bilinear[i] > bilinear[best])) { best = i; }
        }
        int2 offsets[4] = {int2(0, 0), int2(1, 0), int2(0, 1), int2(1, 1)};
        r.single = clamp(r.cell + offsets[best], int2(0), last);
    }
    return r;
}

// The reconstruction (effect_reconstruct) and the composite
// (EffectSlots.compositePixel), blended premultiplied over the scene:
// rgb + (1 - a) * scene.
// - Bilinear: the layers filtered, one sample each, the fronts the least
//   of the four.
// - Renormalised: the four texels read and mixed, the fronts the least of
//   those that weigh.
// - The nearest, or full resolution: one texel.
// - The fronts are read only where two layers or more have anything.
// - A pixel no layer covers is discarded; a NaN or an infinity from an
//   effect stays out of the frame.
fragment float4 effect_composite_fragment(EffectFullscreenOut in [[stage_in]],
                                          constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]],
                                          constant EffectSlotUniforms &e [[buffer(ORBIT_EFFECT_BUFFER_SLOTS)]],
                                          sampler linear [[sampler(ORBIT_SAMPLER_LINEAR_CLAMP)]],
                                          texture2d<float> halfResDepth [[texture(ORBIT_EFFECT_TEXTURE_HALFRES_DEPTH)]],
                                          texture2d<float> clouds [[texture(0)]],
                                          texture2d<float> volumes [[texture(1)]],
                                          texture2d<float> accumulation [[texture(2)]],
                                          texture2d<float> revealage [[texture(3)]],
                                          texture2d<float> fronts [[texture(4)]],
                                          texture2d<float> pixelDepths [[texture(5)]],
                                          texture2d<float> clips [[texture(6)]]) {
    uint2 px = uint2(in.position.xy);
    uint used = uint(e.scale.w + 0.5);
    EffectReconstruction r = effect_reconstruct(px, e, frame, linear, halfResDepth, fronts, pixelDepths, clips);
    EffectLayers l;
    if (r.kind == 1) {
        l = effect_sampleLayers(r.uv, used, linear, clouds, volumes, accumulation, revealage);
    } else if (r.kind == 2) {
        l = effect_mixLayers(r.cell, int2(e.target.xy) - 1, r.w, used, clouds, volumes, accumulation, revealage);
    } else {
        l = effect_readLayers(uint2(r.single), used, clouds, volumes, accumulation, revealage);
    }
    int drawn = 0;
    for (int k = 0; k < 3; k++) { drawn += any(l.color[k] != 0.0) ? 1 : 0; }
    if (drawn == 0) { discard_fragment(); }
    for (int k = 0; k < 3; k++) { l.front[k] = ORBIT_EFFECT_NO_FRONT; }
    if (drawn > 1) {
        if (r.kind == 0 || r.kind == 3) {
            float4 f = fronts.read(uint2(r.single));
            l.front[0] = f.r;
            l.front[1] = f.g;
            l.front[2] = f.b;
        } else {
            float4 fr = effect_gatherOrder(fronts.gather(linear, r.uv, int2(0), component::x));
            float4 fg = effect_gatherOrder(fronts.gather(linear, r.uv, int2(0), component::y));
            float4 fb = effect_gatherOrder(fronts.gather(linear, r.uv, int2(0), component::z));
            if (r.kind == 2) {
                // Only the texels that weigh.
                float4 none = float4(ORBIT_EFFECT_NO_FRONT);
                fr = select(none, fr, r.w > 0.0);
                fg = select(none, fg, r.w > 0.0);
                fb = select(none, fb, r.w > 0.0);
            }
            l.front[0] = min(min(fr.x, fr.y), min(fr.z, fr.w));
            l.front[1] = min(min(fg.x, fg.y), min(fg.z, fg.w));
            l.front[2] = min(min(fb.x, fb.y), min(fb.z, fb.w));
        }
    }
    float4 c = effect_compositeLayers(l);
    if (orbit_isNotFinite(c.rgb) || orbit_isNotFinite(c.a)) { return float4(0.0); }
    return float4(orbit_effectRadiance(c.rgb), clamp(c.a, 0.0, 1.0));
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
// its layer (clouds grey, volumes orange, OIT cyan), 4 the reconstruction
// where an effect covers the pixel: bilinear grey (green where the texels'
// depths differ, the writers' ends making it so), renormalised yellow, the
// nearest red; its brightness the layers' coverage.
fragment float4 effect_debug_fragment(EffectFullscreenOut in [[stage_in]],
                                      constant float4 &params [[buffer(0)]],
                                      constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]],
                                      constant EffectSlotUniforms &e [[buffer(ORBIT_EFFECT_BUFFER_SLOTS)]],
                                      texture2d<float> halfResDepth [[texture(ORBIT_EFFECT_TEXTURE_HALFRES_DEPTH)]],
                                      texture2d<float> clouds [[texture(0)]],
                                      texture2d<float> volumes [[texture(1)]],
                                      texture2d<float> revealage [[texture(3)]],
                                      texture2d<float> fronts [[texture(4)]],
                                      texture2d<float> pixelDepths [[texture(5)]],
                                      texture2d<float> clips [[texture(6)]],
                                      sampler linear [[sampler(ORBIT_SAMPLER_LINEAR_CLAMP)]]) {
    uint2 t = min(uint2(in.position.xy * e.scale.y), uint2(e.target.xy) - 1u);
    int view = int(params.x + 0.5);
    uint used = uint(e.scale.w + 0.5);
    if (view == 4) {
        uint2 px = uint2(in.position.xy);
        EffectReconstruction r = effect_reconstruct(px, e, frame, linear, halfResDepth, fronts, pixelDepths, clips);
        float coverage = max(max((used & 1u) != 0u ? clouds.read(t).a : 0.0, (used & 2u) != 0u ? volumes.read(t).a : 0.0),
                             (used & 4u) != 0u ? 1.0 - revealage.read(t).r : 0.0);
        if (coverage <= 0.0) { return float4(0.0, 0.0, 0.0, 1.0); }
        float3 c = float3(0.6);
        if (r.kind == 1) {
            float4 d = effect_gatherOrder(halfResDepth.gather(linear, r.uv));
            float lz = log2(max(pixelDepths.read(px / 2u)[(px.x & 1u) + 2u * (px.y & 1u)], 1e-30));
            if (any(abs(log2(max(d, float4(1e-30))) - lz) > e.scale.z)) { c = float3(0.2, 0.9, 0.3); }
        } else if (r.kind == 2) {
            c = float3(1.0, 0.85, 0.1);
        } else if (r.kind == 3) {
            c = float3(1.0, 0.15, 0.1);
        }
        return float4(c * (0.25 + 0.75 * clamp(coverage, 0.0, 1.0)), 1.0);
    }
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
