// Stars, the Sun's disc, and the bodies and vessels too small to draw, as
// photometric point sources (track R1 owns this module). Every value is
// luminance (cd/m²) times the frame's pre-exposure.
let starShaderSource = #"""
// ------------------------------------------------------------------ points ---

#define STAR_FP16_MAX 60000.0

struct StarPoint {
    float4 position;     // xyz: direction or camera-relative position (world), w: 0 = direction, 1 = point
    float4 illuminance;  // rgb: illuminance at the camera (lux, linear Rec. 709)
};

struct StarUniforms {
    float4x4 viewProjection;
    float4x4 view;       // world -> view, rotation only
    float4 viewport;     // xy: size (px)
    float4 params;       // x: pixel solid angle on the axis (sr), y: tent radius (px), z: pre-exposure
};

struct StarOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float2 centre [[flat]];       // px
    float3 peak [[flat]];         // pre-exposed luminance with all the light in one pixel
};

// A point source spread over a tent of radius r pixels in x and y, whose
// samples at pixel centres sum to 1 wherever it falls (a partition of
// unity for whole r), so a star's light in the image is its illuminance
// whatever its sub-pixel position; the sprite covers every pixel it lights.
vertex StarOut star_vertex(uint vid [[vertex_id]],
                           const device StarPoint *pts [[buffer(0)]],
                           constant StarUniforms &u [[buffer(1)]]) {
    StarPoint p = pts[vid];
    StarOut o;
    float4 clip = u.viewProjection * float4(p.position.xyz, 1.0);
    if (p.position.w < 0.5) { clip.z = 0.0; }          // directions sit at infinity
    o.position = clip;
    float r = u.params.y;
    o.pointSize = 2.0 * r + 2.0;
    float2 ndc = clip.xy / max(clip.w, 1e-30);
    o.centre = float2((ndc.x + 1.0) * 0.5 * u.viewport.x, (1.0 - ndc.y) * 0.5 * u.viewport.y);
    // A pixel's solid angle falls as cos³ off the axis.
    float3 v = (u.view * float4(p.position.xyz, 0.0)).xyz;
    float c = max(-v.z / max(length(v), 1e-30), 1e-3);
    o.peak = p.illuminance.rgb * u.params.z / (u.params.x * c * c * c);
    if (clip.w <= 0.0) { o.pointSize = 0.0; o.position = float4(2.0, 2.0, 0.0, 1.0); }
    return o;
}

fragment float4 star_fragment(StarOut in [[stage_in]], constant StarUniforms &u [[buffer(1)]]) {
    float r = u.params.y;
    float2 d = abs(in.position.xy - in.centre);
    float2 w = max(1.0 - d / r, 0.0) / r;
    return float4(min(in.peak * (w.x * w.y), STAR_FP16_MAX), 0.0);
}

// ------------------------------------------------------------- the Sun ---

struct SunUniforms {
    float4 direction;    // xyz: unit, camera -> Sun (world), w: angular radius (rad)
    float4 light;        // rgb: luminance at the disc's centre times the pre-exposure, w: limb darkening u
    float4 quad;         // x: tan of the quad's half-angle, y: pixels per radian
    float4x4 viewProjection;
};

struct SunOut {
    float4 position [[position]];
};

// A square around the Sun at infinity, wide enough for its edge's smoothing.
vertex SunOut sun_vertex(uint vid [[vertex_id]], constant SunUniforms &u [[buffer(1)]]) {
    float3 d = u.direction.xyz;
    float3 a = normalize(cross(abs(d.z) < 0.9 ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0), d));
    float3 b = cross(d, a);
    const float2 corners[6] = { float2(-1, -1), float2(1, -1), float2(1, 1), float2(-1, -1), float2(1, 1), float2(-1, 1) };
    float2 c = corners[vid] * u.quad.x;
    float4 clip = u.viewProjection * float4(d + a * c.x + b * c.y, 1.0);
    clip.z = 0.0;
    SunOut o;
    o.position = clip;
    return o;
}

// The disc, limb-darkened (1 - u(1 - μ)), its edge smoothed over a pixel.
fragment float4 sun_fragment(SunOut in [[stage_in]], constant SunUniforms &u [[buffer(1)]],
                             constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]]) {
    float3 ray = normalize((frame.viewToWorld * float4(orbit_viewRay(in.position.xy, frame), 0.0)).xyz);
    float theta = acos(clamp(dot(ray, u.direction.xyz), -1.0, 1.0));
    float alpha = u.direction.w;
    float cover = clamp((alpha - theta) * u.quad.y + 0.5, 0.0, 1.0);
    if (cover <= 0.0) { discard_fragment(); }
    float s = min(theta / alpha, 1.0);
    float mu = sqrt(max(1.0 - s * s, 0.0));
    float limb = 1.0 - u.light.w * (1.0 - mu);
    return float4(min(u.light.rgb * (limb * cover), STAR_FP16_MAX), 0.0);
}
"""#

extension ShaderModule {
    public static let star = ShaderModule(name: "Star", source: starShaderSource)
}
