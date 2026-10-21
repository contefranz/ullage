// The Sun's shadow on a receiver, from the shadow maps (R4) and, later, the
// cloud shadow (C2). A header for every module with shadow receivers (track R4 owns this file).
let shadowCommonSource = #"""
// --------------------------------------------------------------- shadow ---

// The Sun's visible share at a camera-relative `position` with normal
// `normal` (world): 1 lit, 0 shadowed. A stub until R4 fills it.
static inline float orbit_sunShadow(float3 position, float3 normal, constant LightingUniforms &lighting,
                                    depth2d_array<float> atlas, sampler compare) {
    return 1.0;
}
"""#

extension ShaderHeader {
    public static let shadowCommon = ShaderHeader(name: "ShadowCommon", source: shadowCommonSource)
}
