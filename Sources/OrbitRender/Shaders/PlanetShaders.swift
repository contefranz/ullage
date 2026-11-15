// The planets, ray-traced on a full-screen triangle (track E2 owns this
// module; A2 lights and hazes the Earth's ground through the atmosphere's
// tables, AtmosphereCommon, and draws its sky in the P2 composite).
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
    float4 atmosphere;        // x: 1 when lit through the atmosphere (AtmosphereUniforms: A2), y: march steps from
                              // space, z: 1 with A2's haze from space bound (textures 3, 4)
    float4 options;           // x: draw lat/lon grid, y: night floor (relative to the exposure),
                              // z: 1 with E1's albedo tiles bound (textures 5, 6, buffers 1, 2, sampler 1)
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

// The scene's colour is half float: light is clamped below its overflow.
#define PLANET_FP16_MAX 60000.0

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

// Photometric units (R1): luminance in cd/m², linear Rec. 709, times the
// frame's pre-exposure. A Lambert ground of albedo ρ under illuminance E
// has L = ρE/π. Through the air (A2) E is the Sun's above the air
// (FrameUniforms.sunIlluminance's colour) times A1's transmittance to the
// ground point, plus the sky's irradiance there; then the camera ray's
// aerial perspective: inside the atmosphere the sky-view LUT below the
// horizon and A1's transmittance, from space a march through the shell. The night floor (options.y) stays relative to the
// exposure, so the night side stays dark under any exposure (R1's rule).
fragment DepthColorOut planet_fragment(FullscreenOut in [[stage_in]],
                                       constant PlanetUniforms &u [[buffer(0)]],
                                       texture2d<float> tex [[texture(0)]],
                                       texture2d<float> irradiance [[texture(1)]],
                                       texture2d<float> profile [[texture(2)]],
                                       texture2d<float> spaceScatter [[texture(3)]],
                                       texture2d<float> spaceTransmittance [[texture(4)]],
                                       sampler smp [[sampler(0)]],
                                       texture2d_array<float> tileAtlas [[texture(5)]],
                                       texture2d_array<uint, access::read> tileIndirection [[texture(6)]],
                                       const device uint4 *tileDeep [[buffer(1)]],
                                       constant PlanetTileLayer &tileLayer [[buffer(2)]],
                                       sampler tileSampler [[sampler(1)]],
                                       constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]],
                                       constant AtmosphereUniforms &air [[buffer(ORBIT_BUFFER_ATMOSPHERE)]],
                                       texture2d<float> transmittance [[texture(ORBIT_TEXTURE_TRANSMITTANCE_LUT)]],
                                       texture2d<float> multiple [[texture(ORBIT_TEXTURE_MULTI_SCATTERING_LUT)]],
                                       texture2d<float> skyView [[texture(ORBIT_TEXTURE_SKY_VIEW_LUT)]],
                                       sampler linear [[sampler(ORBIT_SAMPLER_LINEAR_CLAMP)]]) {
    float3 dView = normalize(float3(in.ndc.x * u.params.y, in.ndc.y * u.params.z, -1.0));
    float3 d = (u.viewToWorld * float4(dView, 0.0)).xyz;
    float R = u.centerRadius.w;
    float s = u.figure.x;
    // The ray in figure coordinates: |ro + t df|^2 = R^2.
    float3 ro = u.origin.xyz;
    float3 df = (u.worldToBody * float4(d, 0.0)).xyz * float3(1.0, 1.0, s);
    float A = dot(df, df);
    float b = dot(ro, df);
    float c = u.origin.w;                       // |o|^2 - R^2, from the precise CPU position
    float disc = b * b - A * c;
    bool hit = disc >= 0.0 && (b < 0.0 || c < 0.0);
    // The sky is the atmosphere's composite (P2), not this pass's.
    if (!hit) { discard_fragment(); }

    float3 sun = u.sunDir.xyz;
    DepthColorOut o;
    float t = c / (-b + sqrt(disc));             // near intersection, stable near the surface
    if (c < 0.0) { t = (-b + sqrt(disc)) / A; }  // camera inside the figure (should not happen)
    float3 p = ro + df * t;                      // hit point, figure coordinates
    // The normal: the gradient of x^2 + y^2 + (z s)^2 in body axes; its
    // latitude is the geodetic one, as the maps are drawn.
    float3 nb = normalize(float3(p.xy, p.z * s));
    float3 n = (transpose(u.worldToBody) * float4(nb, 0.0)).xyz;

    float lat = asin(clamp(nb.z, -1.0, 1.0));
    float lon = atan2(nb.y, nb.x);
    float3 albedo = u.baseColor.rgb;
    if (u.baseColor.w > 0.5) {
        albedo = sampleEquirect(tex, smp, lon, lat).rgb;
    }
    if (u.options.z > 0.5) {
        // E1's tile store (E2 replaces this with the full surface): the
        // figure direction of the hit, filtered by its screen footprint.
        float3 dirF = normalize(p);
        float2 uv;
        uint face = planet_tile_face(dirF, uv);
        float2 dx = planet_tile_uv_delta(face, dirF, dfdx(dirF)), dy = planet_tile_uv_delta(face, dirF, dfdy(dirF));
        PlanetTileHit tile = planet_tile_find(tileIndirection, tileDeep, tileLayer, face, uv,
                                              planet_tile_level(tileLayer, dx, dy, 0.0));
        if (tile.found) { albedo = planet_tile_sample(tileAtlas, tileSampler, tile, dx, dy).rgb; }
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
    float3 night = albedo * u.options.y;
    float3 light;
    if (u.atmosphere.x > 0.5) {
        float rb = air.radii.x, rt = air.radii.y;
        float3 sunF = normalize((u.worldToBody * float4(sun, 0.0)).xyz * float3(1.0, 1.0, s));
        float3 up = p / max(length(p), 1.0);
        float muS = dot(up, sunF);
        // Per unit solar irradiance: the Sun through the air on the ground,
        // and the sky's light on a horizontal surface.
        float3 e = atmo_transmittanceToSun(transmittance, linear, rb, muS, rb, rt, frame.sunDirection.w) * diffuse
                 + atmo_sunTable(irradiance, linear, rb, muS, rb, rt);
        float3 solar = frame.sunIlluminance.rgb;
        light = albedo / M_PI_F * e * solar;
        float topAltitude = rt - rb;
        float scale = sqrt(A);
        float3 dF = df / scale;
        if (air.radii.z < topAltitude) {
            // Inside the air: the sky-view LUT's rows below the horizon hold
            // the light scattered toward the eye on the way to the ground.
            float rc = rb + max(air.radii.z, 0.0);
            float3 upC = normalize(ro);
            float mu = dot(dF, upC);
            float2 size = float2(skyView.get_width(), skyView.get_height());
            float3 inscatter = skyView.sample(linear, atmo_skyViewUV(rc, rb, mu, atmo_cosAzimuth(dF, sunF, upC), size),
                                              level(0)).rgb;
            float3 tv = atmo_transmittanceToGround(transmittance, linear, rc, upC, up, dF, rb, rt);
            light = light * tv + inscatter;
            night *= tv;
        } else if (u.atmosphere.z > 0.5) {
            // From space: A2's haze over the ground, marched in P0 at a
            // reduced resolution.
            float2 uv = float2(in.ndc.x * 0.5 + 0.5, 0.5 - in.ndc.y * 0.5);
            float3 tv = spaceTransmittance.sample(linear, uv, level(0)).rgb;
            light = light * tv + spaceScatter.sample(linear, uv, level(0)).rgb;
            night *= tv;
        } else {
            // The march itself (another view: R3's probe faces).
            float3 seg = atmo_airSegment(ro, dF, rb, rt);
            AtmoMarch m = atmo_march(ro, dF, seg.x, min(seg.y, t * scale), int(u.atmosphere.y), sunF, dot(d, sun),
                                     frame.sunDirection.w, air, transmittance, multiple, profile, linear);
            light = light * m.transmittance + m.radiance * solar;
            night *= m.transmittance;
        }
    } else {
        light = albedo / M_PI_F * diffuse * frame.sunIlluminance.rgb;
    }
    float3 color = light * frame.exposure.x + night;
    float3 hitView = dView * t;
    o.color = float4(orbit_isNotFinite(color) ? float3(0.0) : min(max(color, 0.0), PLANET_FP16_MAX), 1.0);
    o.depth = clamp(u.params.w / max(-hitView.z, 1e-6), 0.0, 1.0);
    return o;
}
"""#

extension ShaderModule {
    public static let planet = ShaderModule(name: "Planet", headers: [.shadowCommon, .atmosphereCommon, .planetTileCommon],
                                            source: planetShaderSource)
}
