// Vessels, their canopies and risers, and the sites (the pad), physically
// shaded (track R2 owns this module; VM1's paint and VM2's materials are its
// headers, LightingCommon its lighting).

// The vessel's surface as the material and paint hooks see it: a header
// after LightingCommon and before VM1's and VM2's, so their functions can
// take it.
let vesselSurfaceSource = #"""
// ------------------------------------------------------- vessel surface ---

// A material's defaults, by vertex v2's material id (`VesselMaterialTable`).
struct VesselMaterial {
    float4 albedo;      // rgb: albedo, or a metal's F0; w: metalness
    float4 params;      // x: perceptual roughness, y: a dielectric's F0, z: emissive role (1 heat shield), w: model
};

// A paint colour, by vertex v2's paint id until VM1's evaluator: id k is
// entry k (entry 0 unused).
struct VesselPaint {
    float4 albedo;      // rgb: albedo, w: metalness
    float4 params;      // x: perceptual roughness
};

// One fragment of a vessel or site surface.
struct VesselSurface {
    float3 position;    // camera-relative world, m
    float3 normal;      // interpolated geometric normal, world, unit, on the side seen
    float3 tangent;     // unit, along increasing azimuth (world)
    float3 bitangent;   // unit, normal x tangent x sign
    float3 view;        // unit, surface to camera
    float4 coords;      // x: station u (m), y: azimuth v (rad), z: local radius r (m), w: profile arc s (m)
    uint material;      // vertex v2's ids
    uint paint;
    uint decal;
    bool frontFacing;
};

// What the hooks may read beside the surface.
struct VesselResources {
    constant VesselMaterial *materials;
    constant VesselPaint *paints;
};

// The hooks (define the macro and the function in your header to replace
// the default, which this module keeps for when you have not):
//   VM2: #define ORBIT_VESSEL_MATERIAL and
//        SurfaceSample vessel_material(thread const VesselSurface &s, thread const VesselResources &r)
//        the surface's material: albedo, metalness, roughness, reflectance,
//        relief on the normal, occlusion.
//   VM1: #define ORBIT_VESSEL_PAINT and
//        void vessel_paint(thread SurfaceSample &sample, thread const VesselSurface &s,
//                          thread const VesselResources &r)
//        paint, decals, frost and char over the material.
"""#

let vesselShaderSource = #"""
// -------------------------------------------------------------- vessels ---

// The defaults until VM2 and VM1: the material table's entry, then the
// paint colour the Swift evaluator gave the vertex (front faces only).
#ifndef ORBIT_VESSEL_MATERIAL
inline SurfaceSample vessel_material(thread const VesselSurface &s, thread const VesselResources &r) {
    VesselMaterial m = r.materials[s.material];
    SurfaceSample o;
    o.albedo = m.albedo.rgb;
    o.metalness = m.albedo.w;
    o.normal = s.normal;
    o.roughness = m.params.x;
    o.emission = float3(0.0);
    o.reflectance = m.params.y;
    o.tangent = s.tangent;
    o.anisotropy = 0.0;
    o.occlusion = 1.0;
    o.coverage = 1.0;
    return o;
}
#endif

#ifndef ORBIT_VESSEL_PAINT
inline void vessel_paint(thread SurfaceSample &o, thread const VesselSurface &s, thread const VesselResources &r) {
    if (s.paint == 0u || !s.frontFacing) { return; }
    VesselPaint p = r.paints[min(s.paint, 15u)];
    o.albedo = p.albedo.rgb;
    o.metalness = p.albedo.w;
    o.roughness = p.params.x;
    o.reflectance = 0.04;
}
#endif

// Per draw (vertex and fragment, buffer 1).
struct VesselDraw {
    float4x4 model;         // part (or element) frame -> camera-relative world
    float4x4 normalMatrix;  // normals -> world (rotation, inverse scale)
    float4 ao;              // x: fade from the previous AO to the current, y: 1 with a current AO stream, z: 1 with a previous one
    float4 wire;            // x: 1 for a thin tube (phone-wire AA), y: its smallest radius (px), z: the model's scale
};

// Per vessel or site (fragment, buffer 2).
struct VesselObject {
    float4 sun;             // xyz: unit, to the Sun (world), w: its visible share
    float4 sunDisc;         // x: cos, y: sin of its angular radius, z: 1 area light
    float4 body;            // xyz: unit, to the reference body's centre, w: sin^2 of its angular radius
    float4 bodyRadiance;    // rgb: its lit disc's radiance (cd/m2)
    float4 sky;             // rgb: the sky's uniform irradiance (lux), stand-in until A2
    float4 floor_;          // rgb: the night floor (lux), stand-in until R3
    float4 glow;            // rgb: heat-shield glow (cd/m2)
    float4 flow;            // xyz: unit velocity through the air (world)
    float4 shading;         // x: pre-exposure, y: local lights, z: 1 specular AA, w: 1 multiple scattering
};

constant bool vesselEncodesHDR [[function_constant(0)]];

struct VesselOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float3 tangent;
    float tangentSign;
    float4 coords;
    float4 ao;              // this frame's front, back; the previous bake's front, back
    float coverage;
    float ids [[flat]];
};

// R5's packed AO (`AmbientOcclusion.unpack`): a vertex's own code to its
// front and back levels. Only ever on a vertex's own value: the pair is
// what the rasteriser interpolates.
inline float2 vessel_unpackAO(float w) {
    float back = floor(w * (1.0 / 1024.0));
    return float2(w - back * 1024.0, back) * (1.0 / 1023.0);
}

vertex VesselOut vessel_vertex(uint vid [[vertex_id]],
                               const device VertexV2 *vertices [[buffer(0)]],
                               constant VesselDraw &d [[buffer(1)]],
                               const device float *aoNow [[buffer(3)]],
                               const device float *aoBefore [[buffer(4)]],
                               constant FrameUniforms &f [[buffer(ORBIT_BUFFER_FRAME)]]) {
    VertexV2 v = vertices[vid];
    float3 n = normalize((d.normalMatrix * float4(v.normalIDs.xyz, 0.0)).xyz);
    float3 p = (d.model * float4(v.positionAO.xyz, 1.0)).xyz;
    float coverage = 1.0;
    if (d.wire.x > 0.5) {
        // Persson's phone-wire AA: a tube never thinner on screen than
        // wire.y pixels in radius; its coverage carries the rest.
        float r = v.surface.z * d.wire.z;
        float3 centre = p - n * r;
        float pixel = 2.0 * length(centre) * f.camera.y / max(f.viewport.y, 1.0);
        float wide = max(r, d.wire.y * pixel);
        p = centre + n * wide;
        coverage = r / max(wide, 1e-9);
    }
    VesselOut o;
    o.position = f.viewProjection * float4(p, 1.0);
    o.world = p;
    o.normal = n;
    float3 t = (d.model * float4(v.tangent.xyz, 0.0)).xyz;
    o.tangent = length(t) > 1e-9 ? normalize(t) : float3(0.0);
    o.tangentSign = v.tangent.w;
    o.coords = v.surface;
    float now = d.ao.y > 0.5 ? aoNow[vid] : v.positionAO.w;
    float before = d.ao.z > 0.5 ? aoBefore[vid] : 1048575.0;   // AmbientOcclusion.unoccluded
    o.ao = float4(vessel_unpackAO(now), vessel_unpackAO(before));
    o.coverage = coverage;
    o.ids = v.normalIDs.w;
    return o;
}

fragment float4 vessel_fragment(VesselOut in [[stage_in]], bool front [[front_facing]],
                                constant VesselMaterial *materials [[buffer(0)]],
                                constant VesselDraw &d [[buffer(1)]],
                                constant VesselObject &object [[buffer(2)]],
                                constant VesselPaint *paints [[buffer(3)]],
                                constant LocalLight *lights [[buffer(5)]],
                                constant FrameUniforms &f [[buffer(ORBIT_BUFFER_FRAME)]],
                                constant LightingUniforms &lighting [[buffer(ORBIT_BUFFER_LIGHTING)]],
                                constant AtmosphereUniforms &air [[buffer(ORBIT_BUFFER_ATMOSPHERE)]],
                                texturecube<float> specularCube [[texture(ORBIT_TEXTURE_ENV_SPECULAR)]],
                                texturecube<float> irradianceCube [[texture(ORBIT_TEXTURE_ENV_IRRADIANCE)]],
                                texture2d<float> dfgLUT [[texture(ORBIT_TEXTURE_DFG_LUT)]],
                                depth2d_array<float> shadowAtlas [[texture(ORBIT_TEXTURE_SHADOW_ATLAS)]],
                                sampler linear [[sampler(ORBIT_SAMPLER_LINEAR_CLAMP)]],
                                sampler shadowCompare [[sampler(ORBIT_SAMPLER_SHADOW_COMPARE)]]) {
    VesselSurface s;
    s.position = in.world;
    s.normal = normalize(in.normal);
    if (!front) { s.normal = -s.normal; }
    s.tangent = in.tangent;
    s.bitangent = cross(s.normal, in.tangent) * in.tangentSign;
    s.view = normalize(-in.world);
    s.coords = in.coords;
    uint3 ids = orbit_surfaceIDs(in.ids);
    s.material = ids.x;
    s.paint = ids.y;
    s.decal = ids.z;
    s.frontFacing = front;

    VesselResources r;
    r.materials = materials;
    r.paints = paints;
    SurfaceSample m = vessel_material(s, r);
    vessel_paint(m, s, r);

    // The heat shield's glow, strongest facing the oncoming air.
    if (abs(materials[s.material].params.z - 1.0) < 0.5) {
        m.emission += object.glow.rgb * (0.2 + 0.8 * max(dot(s.normal, object.flow.xyz), 0.0));
    }

    OrbitShadingPoint p = orbit_shadingPoint(m, s.view, dfgLUT, linear, object.shading.z > 0.5,
                                             object.shading.w > 0.5);
    // The Sun: through the air when A2 gives its transmission.
    float3 sunLux = (air.radii.w > 0.5 && air.sunTransmitted.w > 0.0) ? air.sunTransmitted.rgb : f.sunIlluminance.rgb;
    float shadow = orbit_sunShadow(in.world, s.normal, lighting, shadowAtlas, shadowCompare);
    float3 c = orbit_sunLight(p, object.sun.xyz, object.sunDisc.x, object.sunDisc.y, object.sunDisc.z > 0.5,
                              sunLux * (object.sun.w * shadow));
    int count = int(object.shading.y);
    for (int i = 0; i < count; i++) { c += orbit_lineLight(p, in.world, lights[i]); }

    // Baked AO for the face seen, faded in from the previous bake.
    float ao = mix(front ? in.ao.z : in.ao.w, front ? in.ao.x : in.ao.y, d.ao.x) * m.occlusion;
    OrbitStandInEnvironment standIn;
    standIn.bodyDirection = object.body.xyz;
    standIn.bodySinSigma2 = object.body.w;
    standIn.bodyRadiance = object.bodyRadiance.rgb;
    float3 sky = air.radii.w > 0.5 ? air.skyIrradiance.rgb : object.sky.rgb;
    standIn.uniform_ = sky + object.floor_.rgb;
    c += orbit_environmentLight(p, ao, lighting, standIn, specularCube, irradianceCube, linear);
    c += m.emission;

    float4 out = float4(orbit_exposed(c, object.shading.x), in.coverage * m.coverage);
    return vesselEncodesHDR ? orbit_encodeHDR(out) : out;
}
"""#

extension ShaderHeader {
    public static let vesselSurface = ShaderHeader(name: "VesselSurface", source: vesselSurfaceSource)
}

extension ShaderModule {
    public static let vessel = ShaderModule(name: "Vessel",
                                            headers: [.shadowCommon, .lightingCommon, .vesselSurface, .vesselPaint,
                                                      .vesselMaterial],
                                            source: vesselShaderSource)
}
