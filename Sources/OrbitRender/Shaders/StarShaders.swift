// Stars, and the bodies and vessels too small to draw, as points (track R1
// owns this module).
let starShaderSource = #"""
// ------------------------------------------------------------------ points ---

struct PointVertex {
    float4 position;   // xyz: direction or camera-relative position (world), w: 0 = direction, 1 = point
    float4 color;      // rgb, a = brightness
    float4 size;       // x: point size in pixels
};

struct PointOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float4 color;
};

vertex PointOut point_vertex(uint vid [[vertex_id]],
                             const device PointVertex *pts [[buffer(0)]],
                             constant PointUniforms &u [[buffer(1)]]) {
    PointVertex p = pts[vid];
    PointOut o;
    float4 clip = u.viewProjection * float4(p.position.xyz, 1.0);
    if (p.position.w < 0.5) {
        clip.z = 0.0;                // directions sit at infinity
    }
    o.position = clip;
    o.pointSize = p.size.x * u.params.x;
    o.color = p.color;
    return o;
}

fragment float4 point_fragment(PointOut in [[stage_in]], float2 pc [[point_coord]]) {
    float r = length(pc - 0.5) * 2.0;
    float a = clamp(1.0 - r, 0.0, 1.0);
    a = a * a;
    return float4(in.color.rgb, in.color.a * a);
}
"""#

extension ShaderModule {
    public static let star = ShaderModule(name: "Star", source: starShaderSource)
}
