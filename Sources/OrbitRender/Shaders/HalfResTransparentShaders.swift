// The effect slots' depth downsample (track R6 owns this module): the scene
// depth to the half-resolution test depth, a checkerboard of each quad's
// nearest and farthest (EffectSlots.halfResDepth).
let halfResTransparentShaderSource = #"""
// ---------------------------------------------------- half-res depth ---

struct EffectFullscreenOut {
    float4 position [[position]];
};

vertex EffectFullscreenOut effect_fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    EffectFullscreenOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

struct EffectDepthOut {
    float4 depths [[color(0)]];        // x: test depth, y: the quad's other extreme
    float depth [[depth(any)]];        // the test depth, for the effects' depth test
};

// Each texel reads the frame pixels it covers (scale × scale, fewer at the
// edge): the nearest on even texels ((x + y) even), the farthest on odd.
fragment EffectDepthOut effect_depth_fragment(EffectFullscreenOut in [[stage_in]],
                                              constant EffectSlotUniforms &e [[buffer(ORBIT_EFFECT_BUFFER_SLOTS)]],
                                              depth2d<float> scene [[texture(0)]]) {
    uint2 t = uint2(in.position.xy);
    uint s = uint(e.scale.x + 0.5);
    uint2 size = uint2(scene.get_width(), scene.get_height());
    float nearest = 0.0, farthest = 1.0e30;
    for (uint dy = 0; dy < s; dy++) {
        for (uint dx = 0; dx < s; dx++) {
            uint2 p = t * s + uint2(dx, dy);
            if (p.x < size.x && p.y < size.y) {
                float d = scene.read(p);
                nearest = max(nearest, d);
                farthest = min(farthest, d);
            }
        }
    }
    farthest = min(farthest, nearest);
    bool even = ((t.x + t.y) & 1u) == 0u;
    EffectDepthOut o;
    o.depths = float4(even ? nearest : farthest, even ? farthest : nearest, 0.0, 0.0);
    o.depth = o.depths.x;
    return o;
}
"""#

extension ShaderModule {
    public static let halfResTransparent = ShaderModule(name: "HalfResTransparent", headers: [.effectSlots],
                                                        source: halfResTransparentShaderSource)
}
