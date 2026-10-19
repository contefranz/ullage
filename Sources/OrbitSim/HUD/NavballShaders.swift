// The navball's Metal shader source, compiled at runtime with
// `makeLibrary(source:)` as the scene's is (Shaders.swift), but kept apart so
// the two renderers share nothing.
//
// The ball is drawn in a square viewport, NDC x right and y up. Its face is
// the unit ball seen along the pilot's +x (the nose), orthographically: the
// screen point (u, v) inside the radius is the body direction (sqrt(1 - u² -
// v²), u, -v), right being +y and up the head (-z), as `Navball.project`.
// Every uniform member is float4 / float4x4 so Swift and MSL layouts match.

let navballShaderSource = #"""
#include <metal_stdlib>
using namespace metal;

struct BallUniforms {
    float4x4 bodyToNED;   // columns 0-2: pilot axes -> north-east-down
    float4 geometry;      // x: ball radius (NDC), y: bezel outer radius (NDC)
};

struct BallOut {
    float4 position [[position]];
    float2 ndc;
};

vertex BallOut navball_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    BallOut o;
    o.ndc = p * 2.0 - 1.0;
    o.position = float4(o.ndc, 0.0, 1.0);
    return o;
}

// The art's equirectangular map: azimuth 0 (north) at u = 0 increasing
// east, elevation +90 at v = 0. Gradients from whichever of two seams is
// farther away (Tarini), so the mip level does not jump at north.
static float4 sampleBall(texture2d<float> tex, sampler smp, float az, float el) {
    float v = 0.5 - el / M_PI_F;
    float u1 = fract(az / (2.0 * M_PI_F));
    float u2 = fract(az / (2.0 * M_PI_F) + 0.5);
    bool first = fwidth(u1) <= fwidth(u2) + 1e-6;
    float2 gx = float2(first ? dfdx(u1) : dfdx(u2), dfdx(v));
    float2 gy = float2(first ? dfdy(u1) : dfdy(u2), dfdy(v));
    return tex.sample(smp, float2(u1, v), gradient2d(gx, gy));
}

fragment float4 navball_fragment(BallOut in [[stage_in]],
                                 constant BallUniforms &u [[buffer(0)]],
                                 texture2d<float> art [[texture(0)]],
                                 sampler smp [[sampler(0)]]) {
    float R = u.geometry.x, B = u.geometry.y;
    float r = length(in.ndc);
    float px = max(fwidth(r), 1e-5);
    if (r > B + px) { discard_fragment(); }

    // The bezel: a dark ring with a lighter lip on each edge.
    float4 bezel = float4(0.035, 0.04, 0.045, 0.92);
    float lip = max(1.0 - abs(r - R) / (1.5 * px), 0.0) * 0.6 + max(1.0 - abs(r - B) / (1.5 * px), 0.0) * 0.35;
    bezel.rgb += lip * float3(0.55, 0.58, 0.6);
    bezel.a *= clamp((B - r) / px + 0.5, 0.0, 1.0);
    float4 ring = float4(bezel.rgb * bezel.a, bezel.a);   // premultiplied

    if (r >= R) { return ring; }

    float2 uv = in.ndc / R;
    float s2 = min(dot(uv, uv), 1.0);
    float3 pBody = float3(sqrt(1.0 - s2), uv.x, -uv.y);
    float3 pNED = (u.bodyToNED * float4(pBody, 0.0)).xyz;
    float el = asin(clamp(-pNED.z, -1.0, 1.0));
    float az = atan2(pNED.y, pNED.x);
    float4 c = sampleBall(art, smp, az, el);

    // Lit from the viewer, darker towards the limb, a soft highlight at the
    // upper left.
    float3 n = float3(uv.x, uv.y, pBody.x);
    float shade = 0.45 + 0.55 * pow(max(pBody.x, 0.0), 0.6);
    float spec = pow(max(dot(n, normalize(float3(-0.45, 0.55, 1.0))), 0.0), 30.0) * 0.22;
    float3 rgb = c.rgb * shade + spec;
    // Anti-aliased limb against the bezel.
    float inside = clamp((R - r) / px, 0.0, 1.0);
    return mix(ring, float4(rgb, 1.0), inside);
}

// ------------------------------------------------------------- markers ---

struct MarkerInstance {
    float4 place;   // xy: centre (NDC), z: half-size (NDC), w: rotation (rad)
    float4 cell;    // xy: atlas cell origin (uv), zw: cell size (uv)
    float4 tint;    // rgb multiplies the glyph, a its opacity
};

struct MarkerOut {
    float4 position [[position]];
    float2 uv;
    float4 tint;
};

vertex MarkerOut marker_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                               constant MarkerInstance *instances [[buffer(0)]]) {
    const float2 corners[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1),
                                float2(-1, 1), float2(1, -1), float2(1, 1) };
    MarkerInstance m = instances[iid];
    float2 c = corners[vid];
    float cs = cos(m.place.w), sn = sin(m.place.w);
    float2 p = m.place.xy + float2(c.x * cs - c.y * sn, c.x * sn + c.y * cs) * m.place.z;
    MarkerOut o;
    o.position = float4(p, 0.0, 1.0);
    // Texture v grows downwards: the cell's top row is the glyph's top.
    o.uv = m.cell.xy + float2(c.x * 0.5 + 0.5, 0.5 - c.y * 0.5) * m.cell.zw;
    o.tint = m.tint;
    return o;
}

fragment float4 marker_fragment(MarkerOut in [[stage_in]],
                                texture2d<float> atlas [[texture(0)]],
                                sampler smp [[sampler(0)]]) {
    float4 g = atlas.sample(smp, in.uv);   // premultiplied
    return float4(g.rgb * in.tint.rgb, g.a) * in.tint.a;
}
"""#
