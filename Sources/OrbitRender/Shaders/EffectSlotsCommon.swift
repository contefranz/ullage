// The effect slots' contract (track R6 owns this header): what a module
// that draws into the half-resolution targets includes after ShaderCommon.
// C2's clouds, P2's plumes and P3's smoke add `.effectSlots` to their
// module's headers. It mirrors OrbitScene's EffectSlots, line for line.
//
// In the half-resolution encoder (HalfResTransparentPass) R6 binds:
//  * buffer 27 (vertex and fragment): EffectSlotUniforms;
//  * fragment texture 18: the half-resolution scene depth (rg32Float,
//    reversed-Z; x the test depth, y the quad's other extreme);
//  * the depth attachment: the farthest depth of each texel's upsample
//    footprint (depth32Float, EffectSlots.footprintFarthest), for a
//    read-only greater-equal test (HalfResSlots.depthTest);
//  * R1's blue noise at texture 26 (ORBIT_TEXTURE_BLUE_NOISE), with every
//    render encoder's shared bindings, for orbit_effectJitter.
// An effect uses buffers 0-26 and textures 0-17 for its own.
//
// The reconstruction (LR0): the composite reads a texel at a neighbouring
// pixel of another depth only where its effects ended nearer than both
// scene depths. A volume says where in its back code (the fronts' a,
// max-blended: orbit_backCode), the clouds and OIT in their clip codes (the
// clip attachment, min-blended: orbit_clipCode). A writer that reports
// them lists its layers in HalfResEffect.reconstructedLayers.
let effectSlotsCommonSource = #"""
// ------------------------------------------------------- effect slots ---

#define ORBIT_EFFECT_BUFFER_SLOTS 27            // EffectSlotUniforms
#define ORBIT_EFFECT_TEXTURE_HALFRES_DEPTH 18   // texture2d<float>, rg32Float: x test depth, y other extreme
// The half-resolution pass's colour attachments.
#define ORBIT_EFFECT_CLOUDS 0                   // rgba16Float, premultiplied over: C2
#define ORBIT_EFFECT_VOLUMES 1                  // rgba16Float, premultiplied over: P2
#define ORBIT_EFFECT_OIT_ACCUMULATION 2         // rgba16Float, added: P3
#define ORBIT_EFFECT_OIT_REVEALAGE 3            // r16Float, multiplied by 1 - src: P3
#define ORBIT_EFFECT_FRONT 4                    // rgba16Float, min: r clouds, g volumes, b OIT (front codes); max: a the volumes' back
#define ORBIT_EFFECT_CLIPS 5                    // rg8Unorm, min: r clouds, g OIT (clip codes)
#define ORBIT_EFFECT_NO_FRONT 65504.0           // a front channel's clear value: nothing in front of infinity
#define ORBIT_EFFECT_NO_BACK -65504.0           // the back channel's clear value: no volume, nothing to cut
#define ORBIT_EFFECT_BACK_MARGIN 0.03125        // added to a back's log2, against half's rounding (EffectSlots.backMargin)
#define ORBIT_EFFECT_CLIP_STEPS 16.0            // clip-code steps to an octave over the first 12 octaves (codes 1-192)
#define ORBIT_EFFECT_CLIP_FINE 192.0            // the last fine code; beyond it 2 octaves a step
#define ORBIT_EFFECT_CLIP_EMPTY 255.0           // the clip codes' clear value: nothing drawn, ended everywhere

struct EffectSlotUniforms {
    float4 target;      // xy: the targets' size (texels), zw: 1 / size
    float4 scale;       // x: frame pixels per texel (2 half, 1 full), y: 1 / x, z: log2(1 + upsample tolerance), w: layers drawn (1 clouds, 2 volumes, 4 OIT)
    float4 oit;         // x: reference depth (m), y: weight exponent, z: least depth factor, w: largest
    float4 front;       // x: front opacity, y: most a fragment adds to an accumulation channel, z: front radiance (pre-exposed)
    float4 reconstruction; // x: layers whose writers all report their ends (1 clouds, 2 volumes, 4 OIT), y: the jitter's rotation this frame
};

// The view ray through point p of the effect targets (texel centres at
// +0.5), in view axes with z = -1, as orbit_viewRay: a point s along it is s
// metres deep (linear depth).
inline float3 orbit_effectViewRay(float2 p, constant EffectSlotUniforms &e, constant FrameUniforms &f) {
    return orbit_viewRay(p * e.scale.x, f);
}

// The most any channel of radiance an effect writes may hold, pre-exposed:
// rgba16Float's largest finite value is 65504, and the scene clamps its light
// here too (R1's rule), so nothing becomes infinite on the way to post.
#define ORBIT_EFFECT_MAX_RADIANCE 6.0e4

inline float3 orbit_effectRadiance(float3 c) {
    return min(c, float3(ORBIT_EFFECT_MAX_RADIANCE));
}

// Linear depths past this are the sky (fast math assumes no infinities).
#define ORBIT_EFFECT_SKY_DISTANCE 1e30

// The scene's linear depth (m) the texel's effects end at: the test depth,
// ORBIT_EFFECT_SKY_DISTANCE on the sky.
inline float orbit_effectSceneDistance(uint2 texel, texture2d<float> halfResDepth, constant FrameUniforms &f) {
    float d = halfResDepth.read(texel).x;
    return d > 0.0 ? orbit_linearDepth(d, f.camera.x) : ORBIT_EFFECT_SKY_DISTANCE;
}

// A front depth as the front channels store it: log2 of the linear depth (m).
inline float orbit_frontCode(float linearDepth) {
    return min(log2(max(linearDepth, 1.0 / 16384.0)), ORBIT_EFFECT_NO_FRONT);
}

// Whether an item's contribution so far (its coverage 1 - T and its
// premultiplied, pre-exposed radiance) has become visible: its front is
// here (EffectSlots.frontReached). A volume tests it as it marches front to
// back and reports the first depth where it holds.
inline bool orbit_frontReached(float coverage, float3 radiance, constant EffectSlotUniforms &e) {
    return coverage >= e.front.x || max(radiance.r, max(radiance.g, radiance.b)) >= e.front.z;
}

// A march's jitter in [0, 1) at texel t (EffectSlots.jitter): R1's
// blue-noise tile there (texture 26), its values rotated by the golden ratio
// each frame, so a texel's jitter runs through a low-discrepancy sequence
// over frames while each frame's pattern stays blue. `salt` shifts the tile,
// for a second, independent use in one effect.
inline float orbit_effectJitter(uint2 texel, uint salt, constant EffectSlotUniforms &e, texture2d<float> blueNoise) {
    uint n = blueNoise.get_width();
    uint2 p = (texel + uint2(salt * 37u, salt * 61u)) % n;
    return fract(blueNoise.read(p).r + e.reconstruction.y);
}

// A volume's back code (EffectSlots.backCode), for the fronts' a channel:
// log2 of the linear depth where its last visible step ended, plus the
// margin; ORBIT_EFFECT_NO_FRONT where the scene cut it (`cut`: its proxy
// went on behind the texel's scene, or lay wholly behind it);
// ORBIT_EFFECT_NO_BACK with nothing visible (lastVisible <= 0).
inline float orbit_backCode(float lastVisible, bool cut) {
    if (cut) { return ORBIT_EFFECT_NO_FRONT; }
    if (lastVisible <= 0.0) { return ORBIT_EFFECT_NO_BACK; }
    return min(log2(max(lastVisible, 1.0 / 16384.0)) + ORBIT_EFFECT_BACK_MARGIN, ORBIT_EFFECT_NO_FRONT - 1.0);
}

// A clouds or OIT clip code (EffectSlots.clipCode), as the rg8Unorm
// attachment stores it (code / 255): 0 where the effect is cut at this
// texel's scene (`endsAt`, the linear depth from which no scene cuts it,
// beyond `sceneDistance`); else the octaves `endsAt` lies in front of the
// scene, in sixteenths over the first 12 (codes 1-192), in twos beyond,
// rounded down, at most 254.
inline float orbit_clipCode(float endsAt, float sceneDistance) {
    if (!(endsAt <= sceneDistance)) { return 0.0; }
    float octaves = log2(max(sceneDistance, 1e-30) / max(endsAt, 1e-30));
    float code = octaves < ORBIT_EFFECT_CLIP_FINE / ORBIT_EFFECT_CLIP_STEPS ? 1.0 + floor(octaves * ORBIT_EFFECT_CLIP_STEPS)
        : ORBIT_EFFECT_CLIP_FINE + 1.0 + floor(0.5 * (octaves - ORBIT_EFFECT_CLIP_FINE / ORBIT_EFFECT_CLIP_STEPS));
    return min(code, ORBIT_EFFECT_CLIP_EMPTY - 1.0) / 255.0;
}

// McGuire and Bavoil's weight on depth relative to the frame's reference.
inline float orbit_oitWeight(float alpha, float linearDepth, constant EffectSlotUniforms &e) {
    float f = pow(max(linearDepth, 1e-6) / max(e.oit.x, 1e-6), -e.oit.y);
    return alpha * clamp(f, e.oit.z, e.oit.w);
}

// What a clouds effect writes: premultiplied radiance (pre-exposed) and
// 1 - T in a; its front code in every channel (the pipeline keeps r), at the
// first depth where orbit_frontReached holds, or ORBIT_EFFECT_NO_FRONT; its
// clip code (orbit_clipCode) in every channel (the pipeline keeps r).
struct EffectCloudOut {
    float4 color [[color(ORBIT_EFFECT_CLOUDS)]];
    float4 front [[color(ORBIT_EFFECT_FRONT)]];
    float4 clip [[color(ORBIT_EFFECT_CLIPS)]];
};

// What a volume effect writes (plumes): as clouds, the front kept in g, and
// its back code (orbit_backCode) in a.
struct EffectVolumeOut {
    float4 color [[color(ORBIT_EFFECT_VOLUMES)]];
    float4 front [[color(ORBIT_EFFECT_FRONT)]];
};

// What an OIT fragment writes (smoke): the accumulation, its opacity for the
// revealage, its front (kept in b), its clip code (kept in g).
struct EffectOITOut {
    float4 accumulation [[color(ORBIT_EFFECT_OIT_ACCUMULATION)]];
    float revealage [[color(ORBIT_EFFECT_OIT_REVEALAGE)]];
    float4 front [[color(ORBIT_EFFECT_FRONT)]];
    float4 clip [[color(ORBIT_EFFECT_CLIPS)]];
};

// An OIT fragment of premultiplied colour (pre-exposed) at a linear depth;
// its front if it is visible on its own (orbit_frontReached); its clip code
// (orbit_clipCode of where its soft fade into the scene would start,
// against the texel's scene). A fragment the texel's scene fades out
// entirely is still written, with no light and a clip code of 0.
inline EffectOITOut orbit_oitOutput(float4 premultiplied, float linearDepth, float clip, constant EffectSlotUniforms &e) {
    premultiplied.rgb = orbit_effectRadiance(premultiplied.rgb);
    float w = orbit_oitWeight(premultiplied.a, linearDepth, e);
    EffectOITOut o;
    o.accumulation = float4(min(premultiplied.rgb * w, e.front.y), premultiplied.a * w);
    o.revealage = premultiplied.a;
    o.front = float4(orbit_frontReached(premultiplied.a, premultiplied.rgb, e) ? orbit_frontCode(linearDepth)
                                                                              : ORBIT_EFFECT_NO_FRONT);
    o.clip = float4(clip);
    return o;
}
"""#

extension ShaderHeader {
    /// The effect slots' contract, for modules that draw into R6's targets.
    public static let effectSlots = ShaderHeader(name: "EffectSlotsCommon", source: effectSlotsCommonSource)
}
