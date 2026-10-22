// Exhaust plumes as additive impostors (track P2 owns this module and
// replaces it with ray-marched plumes).
let plumeShaderSource = #"""
// ------------------------------------------------------------------ plumes ---

struct PlumeVertex {
    float4 position;   // camera-relative world position, w = 1
    float4 color;      // rgb: colour times intensity
    float4 shape;      // x: across (-1...1), y: along (0 exit ... 1 tail), z: dark core, w: 1 = glow disc
};

struct PlumeOut {
    float4 position [[position]];
    float4 color;
    float4 shape;
};

vertex PlumeOut plume_vertex(uint vid [[vertex_id]],
                             const device PlumeVertex *verts [[buffer(0)]],
                             constant PointUniforms &u [[buffer(1)]]) {
    PlumeVertex v = verts[vid];
    PlumeOut o;
    o.position = u.viewProjection * v.position;
    o.color = v.color;
    o.shape = v.shape;
    return o;
}

// R1's bridge until P2's plumes: today's intensities are relative to a white
// Lambert surface facing the Sun, so they are scaled by E⊙/π (cd/m²) and the
// frame's pre-exposure.
static float plume_legacyScale(constant FrameUniforms &frame) {
    return frame.exposure.x * frame.sunIlluminance.w / M_PI_F;
}

// Additive: a cone seen side-on (dense on its axis, fading to the tail, with
// a hot line near the exit and, for kerosene, a dark fuel-rich core just
// below it), and a soft disc over the exit that carries the plume end-on.
fragment float4 plume_fragment(PlumeOut in [[stage_in]], constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]]) {
    float a;
    if (in.shape.w < 0.5) {
        float x2 = in.shape.x * in.shape.x, y = clamp(in.shape.y, 0.0, 1.0);
        float across = pow(max(1.0 - x2, 0.0), 1.5);
        float along = smoothstep(0.0, 0.03, y) * pow(1.0 - y, 1.6);
        float core = 1.0 - in.shape.z * (1.0 - smoothstep(0.03, 0.2, y)) * (1.0 - x2);
        float hot = 1.0 + 0.8 * exp(-6.0 * y) * pow(max(1.0 - x2, 0.0), 6.0);
        a = across * along * core * hot;
    } else {
        float r2 = dot(in.shape.xy, in.shape.xy);
        a = pow(max(1.0 - r2, 0.0), 2.0);
    }
    return float4(min(in.color.rgb * (a * plume_legacyScale(frame)), 60000.0), 0.0);   // below half float's overflow
}
"""#

extension ShaderModule {
    public static let plume = ShaderModule(name: "Plume", source: plumeShaderSource)
}
