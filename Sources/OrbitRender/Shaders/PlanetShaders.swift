// The planets, ray-traced on a full-screen triangle (track E2 owns this
// module, with the atmosphere's composite handed to A2).
let planetShaderSource = #"""
// ---------------------------------------------------------------- planets ---

// The planet is an ellipsoid of revolution about its body z axis (radii a,
// a, b). In body axes stretched by s = a/b along z it is the sphere of
// radius a, and a ray stays a ray with the same parameter t: the
// intersection is a sphere's, in those "figure" coordinates.
struct PlanetUniforms {
    float4x4 viewToWorld;     // rotation only
    float4x4 worldToBody;     // rotation only
    float4 centerRadius;      // xyz: planet centre relative to camera (world), w: equatorial radius a (m)
    float4 params;            // x: camera height above the surface (m), y: tan(fovX/2), z: tan(fovY/2), w: near plane (m)
    float4 sunDir;            // xyz: unit vector planet -> Sun (world), w: 1 if this body is the Sun
    float4 baseColor;         // rgb: base albedo (linear), w: 1 if a texture is bound
    float4 atmosphere;        // rgb: sky colour (linear), w: visual scale height (m), 0 = none
    float4 options;           // x: draw lat/lon grid, y: ambient light
    float4 origin;            // xyz: camera relative to the centre in figure coordinates, w: |xyz|^2 - a^2 (CPU, double)
    float4 figure;            // x: s = a/b
};

struct FullscreenOut {
    float4 position [[position]];
    float2 ndc;
};

vertex FullscreenOut planet_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    FullscreenOut o;
    o.ndc = p * 2.0 - 1.0;
    o.position = float4(o.ndc, 0.0, 1.0);
    return o;
}

struct DepthColorOut {
    float4 color [[color(0)]];
    float depth [[depth(any)]];
};

// R1's bridge until A2 and E2 make this pass photometric: today's colours
// are light relative to a white Lambert surface facing the Sun, so they are
// scaled by E⊙/π (cd/m²) and the frame's pre-exposure; the ambient floor
// (options.y) instead stays as it was on screen, a night floor relative to
// the exposure (as R3's will be), so the night side stays dark under any
// exposure rather than lit like a room.
// The scene's colour is half float: light is clamped below its overflow.
#define PLANET_FP16_MAX 60000.0
static float planet_legacyScale(constant FrameUniforms &frame) {
    return frame.exposure.x * frame.sunIlluminance.w / M_PI_F;
}

// Longitude-seam-free texture lookup (Tarini's method).
static float4 sampleEquirect(texture2d<float> tex, sampler smp, float lon, float lat) {
    float v = 0.5 - lat / M_PI_F;
    float u1 = fract(lon / (2.0 * M_PI_F) + 0.5);
    float u2 = fract(lon / (2.0 * M_PI_F)) ;
    float u = fwidth(u1) <= fwidth(u2) + 1e-6 ? u1 : fract(u2 + 0.5);
    float2 g1 = float2(fwidth(u1) <= fwidth(u2) + 1e-6 ? dfdx(u1) : dfdx(u2), dfdx(v));
    float2 g2 = float2(fwidth(u1) <= fwidth(u2) + 1e-6 ? dfdy(u1) : dfdy(u2), dfdy(v));
    return tex.sample(smp, float2(u, v), gradient2d(g1, g2));
}

fragment DepthColorOut planet_fragment(FullscreenOut in [[stage_in]],
                                       constant PlanetUniforms &u [[buffer(0)]],
                                       texture2d<float> tex [[texture(0)]],
                                       sampler smp [[sampler(0)]],
                                       constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]]) {
    float3 dView = normalize(float3(in.ndc.x * u.params.y, in.ndc.y * u.params.z, -1.0));
    float3 d = (u.viewToWorld * float4(dView, 0.0)).xyz;
    float3 oc = -u.centerRadius.xyz;            // camera relative to planet centre (world)
    float R = u.centerRadius.w;
    float alt = u.params.x;
    float s = u.figure.x;
    // The ray in figure coordinates: |ro + t df|^2 = R^2.
    float3 ro = u.origin.xyz;
    float3 df = (u.worldToBody * float4(d, 0.0)).xyz * float3(1.0, 1.0, s);
    float A = dot(df, df);
    float b = dot(ro, df);
    float c = u.origin.w;                       // |o|^2 - R^2, from the precise CPU position
    float disc = b * b - A * c;
    bool hit = disc >= 0.0 && (b < 0.0 || c < 0.0);

    float3 sun = u.sunDir.xyz;
    float H = u.atmosphere.w;
    DepthColorOut o;

    if (!hit) {
        if (H <= 0.0) { discard_fragment(); }
        // Height of the ray's closest approach to the figure (stable form).
        float hca = b >= 0.0 ? alt : (-disc / A) / (sqrt(max(R * R - disc / A, 0.0)) + R);
        float density = exp(-max(hca, 0.0) / H);
        if (density < 1e-3) { discard_fragment(); }
        float tca = max(-b / A, 0.0);
        float3 q = normalize(oc + d * tca);
        float day = smoothstep(-0.25, 0.25, dot(q, sun));
        float a = clamp(density * 1.2, 0.0, 1.0) * day;
        // Premultiplied output; at most 85% opaque so the Sun still shows through.
        o.color = float4(min(u.atmosphere.rgb * (a * planet_legacyScale(frame)), PLANET_FP16_MAX), 0.85 * a);
        // Depth of the ray's closest approach, so the sky covers bodies drawn
        // earlier (bodies are drawn farthest first).
        o.depth = clamp(u.params.w / (max(tca, R) * -dView.z), 0.0, 1.0);
        return o;
    }

    float t = c / (-b + sqrt(disc));             // near intersection, stable near the surface
    if (c < 0.0) { t = (-b + sqrt(disc)) / A; }  // camera inside the figure (should not happen)
    float3 p = ro + df * t;                      // hit point, figure coordinates
    // The normal: the gradient of x^2 + y^2 + (z s)^2 in body axes; its
    // latitude is the geodetic one, as the maps are drawn.
    float3 nb = normalize(float3(p.xy, p.z * s));
    float3 n = (transpose(u.worldToBody) * float4(nb, 0.0)).xyz;

    float3 color;
    if (u.sunDir.w > 0.5) {
        color = u.baseColor.rgb * 4.0 * planet_legacyScale(frame);
    } else {
        float lat = asin(clamp(nb.z, -1.0, 1.0));
        float lon = atan2(nb.y, nb.x);
        float3 albedo = u.baseColor.rgb;
        if (u.baseColor.w > 0.5) {
            albedo = sampleEquirect(tex, smp, lon, lat).rgb;
        }
        if (u.options.x > 0.5) {
            float gridStep = M_PI_F / 12.0;      // 15 degree grid
            float2 g = float2(lon, lat) / gridStep;
            float2 w = fwidth(g);
            float2 f = abs(fract(g + 0.5) - 0.5) / max(w, float2(1e-5));
            float gridLine = 1.0 - clamp(min(f.x, f.y), 0.0, 1.0);
            albedo = mix(albedo, float3(0.9, 0.9, 0.9), gridLine * 0.35);
        }
        float diffuse = max(dot(n, sun), 0.0);
        float3 lit = albedo * diffuse, night = albedo * u.options.y;
        if (H > 0.0) {
            float density = exp(-max(alt, 0.0) / H);
            float haze = clamp(1.0 - exp(-t * density / (12.0 * H)), 0.0, 0.85);
            float day = smoothstep(-0.2, 0.3, dot(n, sun));
            lit = mix(lit, u.atmosphere.rgb * day, haze);
            night *= 1.0 - haze;
        }
        color = lit * planet_legacyScale(frame) + night;
    }
    float3 hitView = dView * t;
    o.color = float4(min(color, PLANET_FP16_MAX), 1.0);
    o.depth = clamp(u.params.w / max(-hitView.z, 1e-6), 0.0, 1.0);
    return o;
}
"""#

extension ShaderModule {
    public static let planet = ShaderModule(name: "Planet", headers: [.shadowCommon], source: planetShaderSource)
}
