// Vessel meshes and parachute canopies (track R2 owns this module; VM1's
// paint and VM2's materials are its headers).
let vesselShaderSource = #"""
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
"""#

extension ShaderModule {
    public static let vessel = ShaderModule(name: "Vessel",
                                            headers: [.shadowCommon, .lightingCommon, .vesselPaint, .vesselMaterial],
                                            source: vesselShaderSource)
}
