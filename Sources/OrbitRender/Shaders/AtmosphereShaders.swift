// The atmosphere (track A2 owns this module): the sky-view LUT and the
// aerial-perspective froxels (P0, compute), and the P2 composite, which
// draws the sky over everything behind the air (the stars, the Sun's disc,
// far bodies): from inside the atmosphere from the sky-view LUT, from space
// by a march along each pixel's ray through the shell in the planet's
// figure coordinates, with the planet's shadow in the air. The same sky is
// R3's probe entry point. AtmosphereCommon has the optics.
let atmosphereShaderSource = #"""
// -------------------------------------------------------------- atmosphere ---

struct AtmospherePassUniforms {
    float4x4 worldToFigure;   // world directions to figure coordinates (body rotation, z times a/b): normalise after
    float4 camera;            // xyz: the camera from the planet's centre, figure coordinates (m), w: its radius (m)
    float4 sun;               // xyz: unit toward the Sun, figure coordinates, w: its angular radius (rad)
    float4 up;                // xyz: the camera's zenith (figure, unit), w: the Sun's zenith cosine there
    float4 sunAzimuth;        // xyz: horizontal unit toward the Sun's azimuth (figure), w: 1 inside the atmosphere
    float4 sunWorld;          // xyz: unit toward the Sun (world), for the phase functions
    float4 solar;             // rgb: E⊙ times the Sun's colour at unit luminance (lux): tables to cd/m²
    float4 steps;             // x: sky-view march, y: limb march, z: march to the ground, w: per froxel slice
};

struct AtmosphereView {
    float4x4 viewToWorld;     // rotation only
    float4 projection;        // x: tan(fovX/2), y: tan(fovY/2), z: the composite's depth (reversed-Z), w: pre-exposure
    float4 viewport;          // xy: size (px), zw: 1 / size
};

// ------------------------------------------------------- P0: the sky view ---

kernel void atmosphere_skyView(texture2d<float, access::write> out [[texture(0)]],
                               constant AtmospherePassUniforms &p [[buffer(0)]],
                               constant AtmosphereUniforms &a [[buffer(ORBIT_BUFFER_ATMOSPHERE)]],
                               texture2d<float> transmittance [[texture(ORBIT_TEXTURE_TRANSMITTANCE_LUT)]],
                               texture2d<float> multiple [[texture(ORBIT_TEXTURE_MULTI_SCATTERING_LUT)]],
                               texture2d<float> profile [[texture(1)]],
                               sampler s [[sampler(ORBIT_SAMPLER_LINEAR_CLAMP)]],
                               uint2 gid [[thread_position_in_grid]]) {
    float w = float(out.get_width()), h = float(out.get_height());
    if (float(gid.x) >= w || float(gid.y) >= h) { return; }
    float rb = a.radii.x, rt = a.radii.y, r = max(p.camera.w, rb);
    float x = atmo_unit((float(gid.x) + 0.5) / w, w), y = atmo_unit((float(gid.y) + 0.5) / h, h);
    float vHorizon = sqrt(max((r - rb) * (r + rb), 0.0));
    float beta = acos(clamp(vHorizon / r, 0.0, 1.0));
    float zh = M_PI_F - beta;
    float c = y < 0.5 ? 1.0 - 2.0 * y : 2.0 * y - 1.0;
    float zenith = y < 0.5 ? zh * (1.0 - c * c) : zh + beta * c * c;
    float cosAz = 1.0 - 2.0 * x * x, sinAz = sqrt(max(1.0 - cosAz * cosAz, 0.0));
    float muV = cos(zenith), sinV = sin(zenith);
    // The camera's frame: z up, x toward the Sun's azimuth.
    float3 d = float3(sinV * cosAz, sinV * sinAz, muV);
    float muS = p.up.w;
    float3 sun = float3(sqrt(max(1.0 - muS * muS, 0.0)), 0.0, muS);
    float3 o = float3(0.0, 0.0, r);
    float3 seg = atmo_airSegment(o, d, rb, rt);
    AtmoMarch m = atmo_march(o, d, seg.x, seg.y, int(p.steps.x), sun, dot(d, sun), p.sun.w, a, transmittance,
                             multiple, profile, s);
    out.write(float4(m.radiance * p.solar.rgb, 1.0), gid);
}

// ------------------------------------------------- P0: aerial perspective ---

// Each froxel marches its pixel's ray from the camera to its slice's
// distance far·((i + 1)/n)^k on its own (in parallel: a column marched
// slice by slice is too few threads to fill the GPU): in-scattered
// luminance (cd/m²) in rgb and the transmittance's mean in a. The volume is
// rgba32Float: toward a low Sun the light passes 1e5 cd/m².
kernel void atmosphere_froxels(texture3d<float, access::write> out [[texture(0)]],
                               constant AtmospherePassUniforms &p [[buffer(0)]],
                               constant AtmosphereView &view [[buffer(1)]],
                               constant AtmosphereUniforms &a [[buffer(ORBIT_BUFFER_ATMOSPHERE)]],
                               texture2d<float> transmittance [[texture(ORBIT_TEXTURE_TRANSMITTANCE_LUT)]],
                               texture2d<float> multiple [[texture(ORBIT_TEXTURE_MULTI_SCATTERING_LUT)]],
                               texture2d<float> profile [[texture(1)]],
                               sampler s [[sampler(ORBIT_SAMPLER_LINEAR_CLAMP)]],
                               uint3 gid [[thread_position_in_grid]]) {
    uint W = out.get_width(), H = out.get_height(), N = out.get_depth();
    if (gid.x >= W || gid.y >= H || gid.z >= N) { return; }
    float2 uv = (float2(gid.xy) + 0.5) / float2(W, H);
    float3 dView = float3((2.0 * uv.x - 1.0) * view.projection.x, (1.0 - 2.0 * uv.y) * view.projection.y, -1.0);
    float3 dW = normalize((view.viewToWorld * float4(dView, 0.0)).xyz);
    float3 dF = normalize((p.worldToFigure * float4(dW, 0.0)).xyz);
    float3 seg = atmo_airSegment(p.camera.xyz, dF, a.radii.x, a.radii.y);
    float d = a.aerialPerspective.y * pow(float(gid.z + 1) / float(N), a.aerialPerspective.z);
    AtmoMarch m = atmo_march(p.camera.xyz, dF, seg.x, min(d, seg.y), int(p.steps.w), p.sun.xyz,
                             dot(dW, p.sunWorld.xyz), p.sun.w, a, transmittance, multiple, profile, s);
    out.write(float4(m.radiance * p.solar.rgb, dot(m.transmittance, float3(1.0 / 3.0))), gid);
}

// ------------------------------------------------- P0: the ground from space ---

// From above the air, the haze over the ground for every pixel's ray, at a
// reduced resolution the planet shader samples (the march per pixel costs
// too much when the Earth fills the frame): in-scattered luminance (cd/m²)
// and the transmittance, to where the ray meets the ground, or for a ray
// that misses it to its closest approach to the planet, so the values run on
// smoothly across the silhouette. The haze is rgba32Float: at the silhouette
// under a Sun a few degrees above the limb it passes 65,504 cd/m².
kernel void atmosphere_spaceGround(texture2d<float, access::write> scatter [[texture(0)]],
                                   texture2d<float, access::write> transmitted [[texture(2)]],
                                   constant AtmospherePassUniforms &p [[buffer(0)]],
                                   constant AtmosphereView &view [[buffer(1)]],
                                   constant AtmosphereUniforms &a [[buffer(ORBIT_BUFFER_ATMOSPHERE)]],
                                   texture2d<float> transmittance [[texture(ORBIT_TEXTURE_TRANSMITTANCE_LUT)]],
                                   texture2d<float> multiple [[texture(ORBIT_TEXTURE_MULTI_SCATTERING_LUT)]],
                                   texture2d<float> profile [[texture(1)]],
                                   sampler s [[sampler(ORBIT_SAMPLER_LINEAR_CLAMP)]],
                                   uint2 gid [[thread_position_in_grid]]) {
    uint W = scatter.get_width(), H = scatter.get_height();
    if (gid.x >= W || gid.y >= H) { return; }
    float2 uv = (float2(gid) + 0.5) / float2(W, H);
    float3 dView = float3((2.0 * uv.x - 1.0) * view.projection.x, (1.0 - 2.0 * uv.y) * view.projection.y, -1.0);
    float3 dW = normalize((view.viewToWorld * float4(dView, 0.0)).xyz);
    float3 dF = normalize((p.worldToFigure * float4(dW, 0.0)).xyz);
    float3 o = p.camera.xyz;
    float3 seg = atmo_airSegment(o, dF, a.radii.x, a.radii.y);
    float end = seg.z > 0.5 ? seg.y : min(seg.y, max(-dot(o, dF), seg.x));
    AtmoMarch m = atmo_march(o, dF, seg.x, end, int(p.steps.z), p.sun.xyz, dot(dW, p.sunWorld.xyz), p.sun.w, a,
                             transmittance, multiple, profile, s);
    scatter.write(float4(m.radiance * p.solar.rgb, 1.0), gid);
    transmitted.write(float4(m.transmittance, 1.0), gid);
}

// ------------------------------------------------------ P2: the composite ---

struct AtmosphereSky {
    float3 radiance;          // cd/m², not pre-exposed
    float3 transmittance;     // of what lies behind the air along the ray
};

// The sky along a world direction from the camera.
inline AtmosphereSky atmosphere_sky(float3 dW, constant AtmospherePassUniforms &p, constant AtmosphereUniforms &a,
                                    texture2d<float> transmittance, texture2d<float> multiple,
                                    texture2d<float> skyView, texture2d<float> profile, sampler s) {
    AtmosphereSky sky;
    float3 dF = normalize((p.worldToFigure * float4(dW, 0.0)).xyz);
    float rb = a.radii.x, rt = a.radii.y;
    if (p.sunAzimuth.w > 0.5) {
        float r = max(p.camera.w, rb);
        float mu = clamp(dot(dF, p.up.xyz), -1.0, 1.0);
        float3 h = dF - p.up.xyz * mu;
        float hl = length(h);
        float cosAz = hl > 1e-6 ? clamp(dot(h / hl, p.sunAzimuth.xyz), -1.0, 1.0) : 1.0;
        float2 size = float2(skyView.get_width(), skyView.get_height());
        sky.radiance = skyView.sample(s, atmo_skyViewUV(r, rb, mu, cosAz, size), level(0)).rgb;
        sky.transmittance = atmo_transmittanceToTop(transmittance, s, r, mu, rb, rt);
    } else {
        float3 seg = atmo_airSegment(p.camera.xyz, dF, rb, rt);
        int steps = int(seg.z > 0.5 ? p.steps.z : p.steps.y);
        AtmoMarch m = atmo_march(p.camera.xyz, dF, seg.x, seg.y, steps, p.sun.xyz, dot(dW, p.sunWorld.xyz), p.sun.w,
                                 a, transmittance, multiple, profile, s);
        sky.radiance = m.radiance * p.solar.rgb;
        sky.transmittance = m.transmittance;
    }
    return sky;
}

struct AtmosphereOut {
    float4 position [[position]];
};

// A full-screen triangle at `projection.z`: just beyond the far side of the
// atmosphere's shell, so that (reversed-Z, greater-equal, no depth write) it
// covers what lies behind all the air and leaves the planet and what is in
// front of it to their own shaders.
vertex AtmosphereOut atmosphere_vertex(uint vid [[vertex_id]], constant AtmosphereView &view [[buffer(1)]]) {
    float2 q = float2(float((vid << 1) & 2), float(vid & 2));
    AtmosphereOut o;
    o.position = float4(q * 2.0 - 1.0, view.projection.z, 1.0);
    return o;
}

// Dual-source blending: the scene becomes radiance + transmittance × scene.
struct AtmosphereBlend {
    float4 radiance [[color(0), index(0)]];
    float4 transmittance [[color(0), index(1)]];
};

fragment AtmosphereBlend atmosphere_fragment(AtmosphereOut in [[stage_in]],
                                             constant AtmospherePassUniforms &p [[buffer(0)]],
                                             constant AtmosphereView &view [[buffer(1)]],
                                             constant AtmosphereUniforms &a [[buffer(ORBIT_BUFFER_ATMOSPHERE)]],
                                             texture2d<float> transmittance [[texture(ORBIT_TEXTURE_TRANSMITTANCE_LUT)]],
                                             texture2d<float> multiple [[texture(ORBIT_TEXTURE_MULTI_SCATTERING_LUT)]],
                                             texture2d<float> skyView [[texture(ORBIT_TEXTURE_SKY_VIEW_LUT)]],
                                             texture2d<float> profile [[texture(1)]],
                                             sampler s [[sampler(ORBIT_SAMPLER_LINEAR_CLAMP)]]) {
    float2 ndc = float2(2.0 * in.position.x * view.viewport.z - 1.0, 1.0 - 2.0 * in.position.y * view.viewport.w);
    float3 dView = float3(ndc.x * view.projection.x, ndc.y * view.projection.y, -1.0);
    float3 dW = normalize((view.viewToWorld * float4(dView, 0.0)).xyz);
    AtmosphereSky sky = atmosphere_sky(dW, p, a, transmittance, multiple, skyView, profile, s);
    AtmosphereBlend o;
    float3 l = sky.radiance * view.projection.w;
    // Half float's overflow; a NaN counts as no light.
    o.radiance = float4(orbit_isNotFinite(l) ? float3(0.0) : min(max(l, 0.0), 60000.0), 0.0);
    o.transmittance = float4(orbit_isNotFinite(sky.transmittance) ? float3(1.0) : clamp(sky.transmittance, 0.0, 1.0),
                             1.0);
    return o;
}
"""#

extension ShaderModule {
    public static let atmosphere = ShaderModule(name: "Atmosphere", headers: [.atmosphereCommon],
                                                source: atmosphereShaderSource)
}
