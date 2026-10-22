// The effect slots' contract (track R6 owns this header): what a module
// that draws into the half-resolution targets includes after ShaderCommon.
// C2's clouds, P2's plumes and P3's smoke add `.effectSlots` to their
// module's headers. It mirrors OrbitScene's EffectSlots, line for line.
//
// In the half-resolution encoder (HalfResTransparentPass) R6 binds:
//  * buffer 27 (vertex and fragment): EffectSlotUniforms;
//  * fragment texture 18: the half-resolution scene depth (rg32Float,
//    reversed-Z; x the test depth, y the quad's other extreme);
//  * the depth attachment: the test depth (depth32Float), for a
//    read-only greater-equal test (HalfResSlots.depthTest).
// An effect uses buffers 0-26 and textures 0-17 for its own.
let effectSlotsCommonSource = #"""
// ------------------------------------------------------- effect slots ---

#define ORBIT_EFFECT_BUFFER_SLOTS 27            // EffectSlotUniforms
#define ORBIT_EFFECT_TEXTURE_HALFRES_DEPTH 18   // texture2d<float>, rg32Float: x test depth, y other extreme
// The half-resolution pass's colour attachments.
#define ORBIT_EFFECT_CLOUDS 0                   // rgba16Float, premultiplied over: C2
#define ORBIT_EFFECT_VOLUMES 1                  // rgba16Float, premultiplied over: P2
#define ORBIT_EFFECT_OIT_ACCUMULATION 2         // rgba16Float, added: P3
#define ORBIT_EFFECT_OIT_REVEALAGE 3            // r16Float, multiplied by 1 - src: P3
#define ORBIT_EFFECT_FRONT 4                    // rgba16Float, min: r clouds, g volumes, b OIT (front codes)
#define ORBIT_EFFECT_NO_FRONT 65504.0           // a front channel's clear value: nothing in front of infinity

struct EffectSlotUniforms {
    float4 target;      // xy: the targets' size (texels), zw: 1 / size
    float4 scale;       // x: frame pixels per texel (2 half, 1 full), y: 1 / x, z: log2(1 + upsample tolerance), w: layers drawn (1 clouds, 2 volumes, 4 OIT)
    float4 oit;         // x: reference depth (m), y: weight exponent, z: least depth factor, w: largest
    float4 front;       // x: front opacity, y: most a fragment adds to an accumulation channel
};

// The view ray through point p of the effect targets (texel centres at
// +0.5), in view axes with z = -1, as orbit_viewRay: a point s along it is s
// metres deep (linear depth).
inline float3 orbit_effectViewRay(float2 p, constant EffectSlotUniforms &e, constant FrameUniforms &f) {
    return orbit_viewRay(p * e.scale.x, f);
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

// McGuire and Bavoil's weight on depth relative to the frame's reference.
inline float orbit_oitWeight(float alpha, float linearDepth, constant EffectSlotUniforms &e) {
    float f = pow(max(linearDepth, 1e-6) / max(e.oit.x, 1e-6), -e.oit.y);
    return alpha * clamp(f, e.oit.z, e.oit.w);
}

// What a clouds effect writes: premultiplied radiance (pre-exposed) and
// 1 - T in a; its front code in every channel (the pipeline keeps r).
struct EffectCloudOut {
    float4 color [[color(ORBIT_EFFECT_CLOUDS)]];
    float4 front [[color(ORBIT_EFFECT_FRONT)]];
};

// What a volume effect writes (plumes): as clouds, the front kept in g.
struct EffectVolumeOut {
    float4 color [[color(ORBIT_EFFECT_VOLUMES)]];
    float4 front [[color(ORBIT_EFFECT_FRONT)]];
};

// What an OIT fragment writes (smoke): the accumulation, its opacity for the
// revealage, its front (kept in b).
struct EffectOITOut {
    float4 accumulation [[color(ORBIT_EFFECT_OIT_ACCUMULATION)]];
    float revealage [[color(ORBIT_EFFECT_OIT_REVEALAGE)]];
    float4 front [[color(ORBIT_EFFECT_FRONT)]];
};

// An OIT fragment of premultiplied colour (pre-exposed) at a linear depth.
inline EffectOITOut orbit_oitOutput(float4 premultiplied, float linearDepth, constant EffectSlotUniforms &e) {
    float w = orbit_oitWeight(premultiplied.a, linearDepth, e);
    EffectOITOut o;
    o.accumulation = float4(min(premultiplied.rgb * w, e.front.y), premultiplied.a * w);
    o.revealage = premultiplied.a;
    o.front = float4(premultiplied.a >= e.front.x ? orbit_frontCode(linearDepth) : ORBIT_EFFECT_NO_FRONT);
    return o;
}
"""#

extension ShaderHeader {
    /// The effect slots' contract, for modules that draw into R6's targets.
    public static let effectSlots = ShaderHeader(name: "EffectSlotsCommon", source: effectSlotsCommonSource)
}
