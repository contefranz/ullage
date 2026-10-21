// Display-space overlays: the orbit line (and, for now, the parachute risers)
// and the markers' sprites (the render foundation's module).
let overlayShaderSource = #"""
// ------------------------------------------------------------------- lines ---

struct LineVertex {
    float4 position;   // camera-relative world position, w = 1
    float4 color;
};

struct LineOut {
    float4 position [[position]];
    float4 color;
};

vertex LineOut line_vertex(uint vid [[vertex_id]],
                           const device LineVertex *verts [[buffer(0)]],
                           constant PointUniforms &u [[buffer(1)]]) {
    LineOut o;
    o.position = u.viewProjection * verts[vid].position;
    o.color = verts[vid].color;
    return o;
}

fragment float4 line_fragment(LineOut in [[stage_in]]) {
    return in.color;
}

// ----------------------------------------------------------------- sprites ---

struct SpriteVertex {
    float4 position;   // anchor, camera-relative world, w = 1
    float4 offset;     // xy: pixels from the anchor (y up), zw: atlas uv
    float4 color;      // tint, premultiplied
};

struct SpriteUniforms {
    float4x4 viewProjection;
    float4 params;                 // xy: pixels -> NDC (2 / drawable size)
};

struct SpriteOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
};

vertex SpriteOut sprite_vertex(uint vid [[vertex_id]],
                               const device SpriteVertex *verts [[buffer(0)]],
                               constant SpriteUniforms &u [[buffer(1)]]) {
    SpriteVertex v = verts[vid];
    float4 clip = u.viewProjection * v.position;
    clip.xy += v.offset.xy * u.params.xy * clip.w;   // a fixed size in pixels, at the anchor's depth
    SpriteOut o;
    o.position = clip;
    o.uv = v.offset.zw;
    o.color = v.color;
    return o;
}

fragment float4 sprite_fragment(SpriteOut in [[stage_in]],
                                texture2d<float> atlas [[texture(0)]],
                                sampler smp [[sampler(0)]]) {
    return atlas.sample(smp, in.uv) * in.color;
}
"""#

extension ShaderModule {
    public static let overlay = ShaderModule(name: "Overlay", source: overlayShaderSource)
}
