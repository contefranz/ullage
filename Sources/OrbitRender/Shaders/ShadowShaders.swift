// Shadow maps: the casters' depth-only vertex function, and the sun-shadow
// debug view (track R4 owns this module).
let shadowShaderSource = #"""
// ------------------------------------------------------------ shadow ---

// Casters, drawn into a layer of the atlas with depth clamped (pancaked):
// positions only, from any vertex layout that starts with a float4 position
// (the shadow pass's own position buffers, MeshVertex, VertexV2), `stride`
// float4s apart.
struct ShadowCasterOut {
    float4 position [[position]];
};

vertex ShadowCasterOut shadow_caster_vertex(uint vid [[vertex_id]],
                                            const device float4 *verts [[buffer(0)]],
                                            constant float4x4 &clip [[buffer(1)]],   // the mesh's frame -> the map's clip space
                                            constant uint &stride [[buffer(2)]]) {
    ShadowCasterOut o;
    o.position = clip * float4(verts[vid * stride].xyz, 1.0);
    return o;
}

// ---------------------------------------------------- sun-shadow view ---
//
// DebugView.sunShadow: the Sun's visible share from the maps on every
// surface, grey from 12% (umbra) to white (lit) as displayed, a little
// darker as the Sun grazes the face, tinted by the map that served it
// (ShadowDebugUniforms); a face turned from the Sun dark blue; a surface no
// map holds pale red. The planet and the vessels come from the resolved
// scene depth; the sites, which P1 does not draw yet, are drawn here.

struct ShadowDebugUniforms {
    float4 tint[ORBIT_MAX_SHADOW_MAPS];   // rgb: per map
};

struct ShadowDebugOut {
    float4 color [[color(0)]];
    float depth [[depth(any)]];
};

struct ShadowFullscreenOut {
    float4 position [[position]];
};

vertex ShadowFullscreenOut shadow_debug_fullscreen(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    ShadowFullscreenOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

// Display values (the target is sRGB): grey runs evenly with the share,
// shaded a little by the Sun's incidence (`cosI`) so that faces read.
static float3 shadow_debugColor(float2 s, float cosI, constant ShadowDebugUniforms &u) {
    float3 c;
    if (s.y < -1.5) {
        c = float3(0.22, 0.24, 0.42);
    } else {
        float3 tint = s.y < -0.5 ? float3(1.0, 0.8, 0.8) : u.tint[int(s.y + 0.5)].rgb;
        c = (0.12 + 0.88 * s.x) * (0.7 + 0.3 * saturate(cosI)) * tint;
    }
    return pow(c, 2.2);
}

// The Sun's incidence on a normal, from the first map's axes (1 without maps).
static float shadow_debugIncidence(float3 n, constant LightingUniforms &l) {
    return l.shadowParams.x > 0.5 ? dot(n, orbit_shadowAxes(l, 0)[2]) : 1.0;
}

// The camera-relative world position of pixel p with reversed-Z depth d.
static float3 shadow_worldPosition(float2 p, float d, constant FrameUniforms &f) {
    float3 view = orbit_viewRay(p, f) * orbit_linearDepth(d, f.camera.x);
    return (f.viewToWorld * float4(view, 0.0)).xyz;
}

fragment ShadowDebugOut shadow_debug_deferred(ShadowFullscreenOut in [[stage_in]],
                                              constant ShadowDebugUniforms &u [[buffer(0)]],
                                              constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]],
                                              constant LightingUniforms &lighting [[buffer(ORBIT_BUFFER_LIGHTING)]],
                                              depth2d<float> depth [[texture(0)]],
                                              depth2d_array<float> atlas [[texture(ORBIT_TEXTURE_SHADOW_ATLAS)]],
                                              sampler compare [[sampler(ORBIT_SAMPLER_SHADOW_COMPARE)]]) {
    int2 xy = int2(in.position.xy);
    int2 size = int2(depth.get_width(), depth.get_height());
    float d = depth.read(uint2(xy));
    ShadowDebugOut o;
    o.depth = d;
    if (d <= 0.0) {                                  // the sky
        o.color = float4(0.0, 0.0, 0.0, 1.0);
        return o;
    }
    float3 c = shadow_worldPosition(float2(xy) + 0.5, d, frame);
    // The normal from the neighbours on the side nearer in depth, each way,
    // so silhouettes do not bend it.
    float3 dx = float3(0.0), dy = float3(0.0);
    float best = INFINITY;
    for (int s = -1; s <= 1; s += 2) {
        int2 q = clamp(xy + int2(s, 0), int2(0), size - 1);
        float dq = depth.read(uint2(q));
        if (dq > 0.0 && abs(dq - d) < best) {
            best = abs(dq - d);
            dx = (shadow_worldPosition(float2(q) + 0.5, dq, frame) - c) * float(s);
        }
    }
    best = INFINITY;
    for (int s = -1; s <= 1; s += 2) {
        int2 q = clamp(xy + int2(0, s), int2(0), size - 1);
        float dq = depth.read(uint2(q));
        if (dq > 0.0 && abs(dq - d) < best) {
            best = abs(dq - d);
            dy = (shadow_worldPosition(float2(q) + 0.5, dq, frame) - c) * float(s);
        }
    }
    float3 n = cross(dy, dx);
    n = length(n) > 0.0 ? normalize(n) : -normalize(c);
    if (dot(n, c) > 0.0) { n = -n; }                // towards the camera
    float2 s = orbit_sunShadowAndMap(c, n, lighting, atlas, compare);
    o.color = float4(shadow_debugColor(s, shadow_debugIncidence(n, lighting), u), 1.0);
    return o;
}

// The sites: their meshes (MeshVertex, `stride` float4s apart) shaded with
// their own normals.
struct ShadowSiteUniforms {
    float4x4 viewProjection;               // camera-relative world -> clip
    float4x4 model;                        // the element's frame -> camera-relative world
};

struct ShadowSiteOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
};

vertex ShadowSiteOut shadow_debug_site_vertex(uint vid [[vertex_id]],
                                              const device float4 *verts [[buffer(0)]],
                                              constant ShadowSiteUniforms &u [[buffer(1)]],
                                              constant uint &stride [[buffer(2)]]) {
    float4 p = u.model * float4(verts[vid * stride].xyz, 1.0);
    ShadowSiteOut o;
    o.position = u.viewProjection * p;
    o.world = p.xyz;
    o.normal = (u.model * float4(verts[vid * stride + 1].xyz, 0.0)).xyz;
    return o;
}

fragment float4 shadow_debug_site(ShadowSiteOut in [[stage_in]], bool front [[front_facing]],
                                  constant ShadowDebugUniforms &u [[buffer(0)]],
                                  constant LightingUniforms &lighting [[buffer(ORBIT_BUFFER_LIGHTING)]],
                                  depth2d_array<float> atlas [[texture(ORBIT_TEXTURE_SHADOW_ATLAS)]],
                                  sampler compare [[sampler(ORBIT_SAMPLER_SHADOW_COMPARE)]]) {
    float3 n = normalize(in.normal);
    if (!front) { n = -n; }
    return float4(shadow_debugColor(orbit_sunShadowAndMap(in.world, n, lighting, atlas, compare),
                                    shadow_debugIncidence(n, lighting), u), 1.0);
}
"""#

extension ShaderModule {
    public static let shadow = ShaderModule(name: "Shadow", headers: [.shadowCommon], source: shadowShaderSource)
}
