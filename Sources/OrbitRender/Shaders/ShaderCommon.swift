// Metal shader source, compiled at runtime with `makeLibrary(source:)` so the
// package builds with plain SwiftPM (no .metal build step). Every module is
// its own library: this header, the module's headers, then its source.
//
// Conventions shared with the Swift side:
//  * "world" = ICRF axes, origin at the camera (camera-relative, float).
//  * Reversed-Z infinite projection: depth = near / -z_view, cleared to 0,
//    compare function greaterEqual. Linear depth is near / depth.
//  * Every uniform member is float4 / float4x4 (or a fixed array of them) so
//    Swift and MSL layouts match (FrameUniforms.swift mirrors these).
//  * The binding table below is fixed in every module and stage; buffers
//    0-27, textures 0-18 and samplers 0-13 are each pass's own.

let shaderCommonSource = #"""
#include <metal_stdlib>
using namespace metal;

// ------------------------------------------------------------ bindings ---

#define ORBIT_BUFFER_ATMOSPHERE 28            // AtmosphereUniforms (A2, C2)
#define ORBIT_BUFFER_LIGHTING 29              // LightingUniforms (R3, R4, P2)
#define ORBIT_BUFFER_FRAME 30                 // FrameUniforms
#define ORBIT_TEXTURE_SCENE_DEPTH 19          // depth2d<float>: the resolved scene depth, after P1
#define ORBIT_TEXTURE_ENV_SPECULAR 20         // texturecube<float>: GGX-prefiltered radiance mips (R3)
#define ORBIT_TEXTURE_ENV_IRRADIANCE 21       // texturecube<float>: irradiance, 16² (R3)
#define ORBIT_TEXTURE_DFG_LUT 22              // texture2d<float>: split-sum DFG (R2)
#define ORBIT_TEXTURE_SHADOW_ATLAS 23         // depth2d_array<float>: sun shadow maps (R4)
#define ORBIT_TEXTURE_CLOUD_SHADOW 24         // texture2d<float>: cloud shadow (C2)
#define ORBIT_TEXTURE_TRANSMITTANCE_LUT 25    // texture2d<float>: atmospheric transmittance (A2)
#define ORBIT_TEXTURE_BLUE_NOISE 26           // texture2d<float> (R1)
#define ORBIT_TEXTURE_TONE_LUT 27             // texture3d<float>: 33³ tone curve over log2 input (R1)
#define ORBIT_TEXTURE_MULTI_SCATTERING_LUT 28 // texture2d<float> (A2)
#define ORBIT_TEXTURE_SKY_VIEW_LUT 29         // texture2d<float> (A2)
#define ORBIT_TEXTURE_AERIAL_PERSPECTIVE 30   // texture3d<float>: froxels (A2)
#define ORBIT_SAMPLER_LINEAR_CLAMP 14
#define ORBIT_SAMPLER_SHADOW_COMPARE 15       // compare greaterEqual (reversed-Z)
#define ORBIT_MAX_LOCAL_LIGHTS 8
#define ORBIT_MAX_SHADOW_MAPS 4

// ------------------------------------------------------ shared uniforms ---

struct FrameUniforms {
    float4x4 viewProjection;          // camera-relative world -> clip (rotation-only view)
    float4x4 view;                    // world -> view, rotation only
    float4x4 projection;              // reversed-Z, infinite far plane
    float4x4 viewToWorld;             // rotation only
    float4x4 previousViewProjection;  // last frame's, for reprojection
    float4 viewport;                  // xy: size (px), zw: 1 / size
    float4 camera;                    // x: near (m), y: tan(fovY/2), z: aspect, w: render scale
    float4 time;                      // x: wall s mod 3600, y: wall dt, z: scene sim s mod 86400, w: sim dt
    float4 frame;                     // x: frame index, y: warp, z: 1 paused, w: 1 temporal reset
    float4 exposure;                  // x: pre-exposure, y: EV100, z: pre-exposure ratio to last frame, w: compensation (R1)
    float4 sunDirection;              // xyz: unit, camera -> Sun (world), w: angular radius (rad)
    float4 sunIlluminance;            // rgb: lux at the camera above the air (linear Rec. 709), w: total lux
    float4 noiseOrigin;               // xyz: camera body-fixed position mod the tile (m), w: tile (m)
    float4 jitter;                    // xy: subpixel jitter (px), zw: blue-noise offset (px)
    float4 debug;                     // x: debug view, y: 1 when timings show
    float4 pointScale;                // x: pixels per point
    float4 reserved[3];
};

struct LocalLight {
    float4 positionRadius;            // xyz: camera-relative position (m), w: source radius (m)
    float4 axisLength;                // xyz: unit axis of a line light, w: length (m; 0 = point)
    float4 intensity;                 // rgb: luminous intensity (cd), w: range (m)
};

struct LightingUniforms {
    float4x4 shadowMatrices[ORBIT_MAX_SHADOW_MAPS]; // camera-relative world -> shadow clip (R4)
    float4 shadowMaps[ORBIT_MAX_SHADOW_MAPS];       // x: atlas layer, y: texel (m), z: depth range (m), w: 1 in use
    float4 shadowParams;              // x: maps in use, y: filter samples, z: normal-offset bias (texels), w: slope bias
    float4 sh9[9];                    // rgb: probe irradiance, SH9 (R3)
    float4 probe;                     // xyz: probe centre (camera-relative, m), w: specular mips (R3)
    float4 ambient;                   // rgb: night floor relative to exposure, w: earthshine scale (R3)
    float4 lightCount;                // x: local lights in use (P2)
    LocalLight lights[ORBIT_MAX_LOCAL_LIGHTS];
    float4 reserved[4];
};

struct AtmosphereUniforms {
    float4x4 worldToBody;             // world -> planet body axes, rotation only
    float4 planetCenter;              // xyz: camera-relative centre (m), w: bottom radius (m)
    float4 radii;                     // x: bottom, y: top (m), z: camera altitude (m), w: 1 with air
    float4 rayleighScattering;        // rgb: at the ground (1/m), w: scale height (m)
    float4 mieScattering;             // rgb: at the ground (1/m), w: scale height (m)
    float4 mieExtinction;             // rgb (1/m), w: phase asymmetry g
    float4 ozoneAbsorption;           // rgb: at the peak (1/m), w: layer centre altitude (m)
    float4 ozoneLayer;                // x: layer width (m)
    float4 groundAlbedo;              // rgb
    float4 sunTransmitted;            // rgb: Sun colour transmitted to the camera, w: its lux
    float4 skyIrradiance;             // rgb: sky irradiance at the camera (lux)
    float4 aerialPerspective;         // x: slices, y: far distance (m), z: distribution exponent
    float4x4 cloudShadowMatrix;       // camera-relative world -> cloud shadow uv (C2)
    float4 cloudLayer;                // x: base, y: top (m above ground), z: cover, w: 1 with clouds (C2)
    float4 reserved[4];
};

// Vertex v2, 64 bytes (R2 adopts it; VisualShape's surface coordinates fill it).
struct VertexV2 {
    float4 positionAO;                // xyz: construction frame (m), w: baked AO (1 = open)
    float4 normalIDs;                 // xyz: unit normal, w: material + 256 paint + 65536 decal (an exact integer)
    float4 tangent;                   // xyz: unit tangent along increasing azimuth, w: bitangent sign
    float4 surface;                   // x: station u (m), y: azimuth v (rad), z: local radius r (m), w: profile arc s (m)
};

// The point, line and plume pipelines' uniforms.
struct PointUniforms {
    float4x4 viewProjection;          // rotation-only view * projection
    float4 params;                    // x: point-size scale
};

// ------------------------------------------------------------- helpers ---

// Distance along the view axis (m) from a reversed-Z depth: exact for the
// infinite projection.
inline float orbit_linearDepth(float depth, float near) {
    return near / max(depth, 1e-30);
}

// The view ray through pixel `p` (pixel centres at +0.5), in view axes, not
// normalised (z = -1).
inline float3 orbit_viewRay(float2 p, constant FrameUniforms &f) {
    float2 ndc = float2(2.0 * p.x * f.viewport.z - 1.0, 1.0 - 2.0 * p.y * f.viewport.w);
    return float3(ndc.x * f.camera.y * f.camera.z, ndc.y * f.camera.y, -1.0);
}

// Karis' tone-mapped weighting, so an MSAA resolve does not alias bright
// highlights. Not for scene passes: under R1's HDR plan every pass that
// draws into the scene (P1-P3) writes linear Rec. 709 luminance times
// FrameUniforms.exposure.x, clamped below 6e4, and blends in linear light;
// the scene's last draw (HDRResolvePass) weights each sample for the resolve
// itself, with the weight in alpha, and post decodes it (PostShaders). A
// scene pass calling orbit_encodeHDR would have its light weighted twice;
// HDRRuleTests fails if any shader module calls these two.
inline float4 orbit_encodeHDR(float4 c) {
    return float4(c.rgb / (1.0 + max(c.r, max(c.g, c.b))), c.a);
}
inline float4 orbit_decodeHDR(float4 c) {
    return float4(c.rgb / max(1.0 - max(c.r, max(c.g, c.b)), 1e-4), c.a);
}

// NaN or infinity, from the bit pattern: fast math may fold isnan away.
inline bool orbit_isNotFinite(float x) {
    return (as_type<uint>(x) & 0x7f800000u) == 0x7f800000u;
}
inline bool orbit_isNotFinite(float3 v) {
    return orbit_isNotFinite(v.x) || orbit_isNotFinite(v.y) || orbit_isNotFinite(v.z);
}

// VertexV2's ids: x material, y paint set, z decal set.
inline uint3 orbit_surfaceIDs(float packed) {
    uint v = uint(rint(packed));
    return uint3(v & 255u, (v >> 8) & 255u, v >> 16);
}
"""#
