// Debug views: arbitrary output variables drawn over the output from the
// resolved scene (the render foundation's module).
let debugShaderSource = #"""
// --------------------------------------------------------------- debug ---

struct DebugOut {
    float4 position [[position]];
};

vertex DebugOut debug_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    DebugOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

// A perceptual ramp, dark blue through green and yellow to white.
static float3 debug_ramp(float t) {
    t = clamp(t, 0.0, 1.0);
    float3 a = float3(0.05, 0.03, 0.30), b = float3(0.10, 0.55, 0.55), c = float3(0.95, 0.85, 0.20);
    return t < 0.5 ? mix(a, b, t * 2.0) : (t < 0.85 ? mix(b, c, (t - 0.5) / 0.35) : mix(c, float3(1.0), (t - 0.85) / 0.15));
}

// The camera-relative view-space position of pixel p (centre at +0.5) with
// reversed-Z depth d.
static float3 debug_viewPosition(float2 p, float d, constant FrameUniforms &f) {
    return orbit_viewRay(p, f) * orbit_linearDepth(d, f.camera.x);
}

// params.x: the view (1 depth, 2 normals, 3 luminance).
fragment float4 debug_fragment(DebugOut in [[stage_in]],
                               constant float4 &params [[buffer(0)]],
                               constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]],
                               texture2d<float> color [[texture(0)]],
                               depth2d<float> depth [[texture(1)]]) {
    uint2 xy = uint2(in.position.xy);
    uint2 size = uint2(depth.get_width(), depth.get_height());
    int view = int(params.x + 0.5);
    if (view == 3) {
        float3 c = color.read(xy).rgb;                          // linear: the texture is sRGB
        float y = dot(c, float3(0.2126, 0.7152, 0.0722));
        float stops = clamp(log2(max(y, 1e-6)) + 8.0, 0.0, 8.0);  // 2^-8 ... 1
        float band = floor(stops) / 8.0;
        return float4(debug_ramp(band), 1.0);
    }
    float d = depth.read(xy);
    if (d <= 0.0) { return float4(0.0, 0.0, 0.0, 1.0); }        // the sky, at infinity
    if (view == 1) {
        float range = log10(orbit_linearDepth(d, frame.camera.x) / frame.camera.x) / 9.6;   // 0.25 m ... 1e9 m
        return float4(debug_ramp(1.0 - range), 1.0);
    }
    float2 p = float2(xy) + 0.5;
    uint2 xr = uint2(min(xy.x + 1, size.x - 1), xy.y), yd = uint2(xy.x, min(xy.y + 1, size.y - 1));
    float3 c0 = debug_viewPosition(p, d, frame);
    float3 cx = debug_viewPosition(float2(xr) + 0.5, max(depth.read(xr), 1e-30), frame);
    float3 cy = debug_viewPosition(float2(yd) + 0.5, max(depth.read(yd), 1e-30), frame);
    float3 n = normalize(cross(cy - c0, cx - c0));
    float3 world = (frame.viewToWorld * float4(n, 0.0)).xyz;
    return float4(0.5 + 0.5 * world, 1.0);
}
"""#

extension ShaderModule {
    public static let debug = ShaderModule(name: "Debug", source: debugShaderSource)
}
