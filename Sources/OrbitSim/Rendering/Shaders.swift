// Metal shader source, compiled at runtime with `makeLibrary(source:)` so the
// package builds with plain SwiftPM (no .metal build step).
//
// Conventions shared with the Swift side:
//  * "world" = ICRF axes, origin at the camera (camera-relative, float).
//  * Reversed-Z infinite projection: depth = near / -z_view, cleared to 0,
//    compare function greaterEqual.
//  * Every uniform member is float4 / float4x4 so Swift and MSL layouts match.

let shaderSource = #"""
#include <metal_stdlib>
using namespace metal;

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
                                       sampler smp [[sampler(0)]]) {
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
        o.color = float4(u.atmosphere.rgb * a, 0.85 * a);
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
        color = u.baseColor.rgb * 4.0;
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
        color = albedo * (diffuse + u.options.y);
        if (H > 0.0) {
            float density = exp(-max(alt, 0.0) / H);
            float haze = 1.0 - exp(-t * density / (12.0 * H));
            float day = smoothstep(-0.2, 0.3, dot(n, sun));
            color = mix(color, u.atmosphere.rgb * day, clamp(haze, 0.0, 0.85));
        }
    }
    float3 hitView = dView * t;
    o.color = float4(color, 1.0);
    o.depth = clamp(u.params.w / max(-hitView.z, 1e-6), 0.0, 1.0);
    return o;
}

// ------------------------------------------------------------------ meshes ---

struct MeshVertex {
    float4 position;   // xyz (vessel construction frame, m), w = 1
    float4 normal;     // xyz
    float4 color;      // rgb linear, w: emissive role (0 none, 1 heat shield)
};

struct MeshUniforms {
    float4x4 modelViewProjection;
    float4x4 model;                // construction frame -> camera-relative world
    float4x4 normalMatrix;         // normals -> world (rotation, inverse scale)
    float4 sunDir;                 // xyz: unit vector to the Sun (world)
    float4 light;                  // x: sunlit fraction, y: ambient floor, z: earthshine, full disc
    float4 earthDir;               // xyz: unit vector to the reference body (world), w: its lit share
    float4 earthColor;             // rgb: earthshine colour
    float4 glow;                   // rgb: heat-shield glow, added
    float4 flowDir;                // xyz: unit velocity through the air (world), zero in vacuum
};

struct MeshOut {
    float4 position [[position]];
    float3 normal;
    float4 color;
};

vertex MeshOut mesh_vertex(uint vid [[vertex_id]],
                           const device MeshVertex *verts [[buffer(0)]],
                           constant MeshUniforms &u [[buffer(1)]]) {
    MeshVertex v = verts[vid];
    MeshOut o;
    o.position = u.modelViewProjection * v.position;
    o.normal = (u.normalMatrix * float4(v.normal.xyz, 0.0)).xyz;
    o.color = v.color;
    return o;
}

// Lambert from the Sun (times the sunlit fraction) and from the lit part of
// the reference body below, plus an ambient floor. Back faces are only drawn
// for open shapes (closed ones are culled) and are lit as their inside, with
// the normal reversed. Heat-shield vertices add the glow, strongest where the
// surface faces the oncoming air.
fragment float4 mesh_fragment(MeshOut in [[stage_in]], bool front [[front_facing]],
                              constant MeshUniforms &u [[buffer(1)]]) {
    float3 n = normalize(in.normal);
    if (!front) { n = -n; }
    float sun = u.light.x * max(dot(n, u.sunDir.xyz), 0.0);
    float3 earth = u.earthColor.rgb * (u.light.z * u.earthDir.w * max(dot(n, u.earthDir.xyz), 0.0));
    float3 c = in.color.rgb * (float3(sun) + earth + u.light.y);
    if (in.color.w > 0.5 && in.color.w < 1.5) {
        float facing = max(dot(n, u.flowDir.xyz), 0.0);
        c += u.glow.rgb * (0.2 + 0.8 * facing);
    }
    return float4(c, 1.0);
}

// ------------------------------------------------------------------ points ---

struct PointVertex {
    float4 position;   // xyz: direction or camera-relative position (world), w: 0 = direction, 1 = point
    float4 color;      // rgb, a = brightness
    float4 size;       // x: point size in pixels
};

struct PointUniforms {
    float4x4 viewProjection;       // rotation-only view * projection
    float4 params;                 // x: point-size scale
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

// Additive: a cone seen side-on (dense on its axis, fading to the tail, with
// a hot line near the exit and, for kerosene, a dark fuel-rich core just
// below it), and a soft disc over the exit that carries the plume end-on.
fragment float4 plume_fragment(PlumeOut in [[stage_in]]) {
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
    return float4(in.color.rgb * a, 0.0);
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
