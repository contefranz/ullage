// Shared lighting for the modules that shade surfaces: the BRDF, image-based
// lighting, the Sun's disc as an area light, specular anti-aliasing and the
// local lights. A header: every module that lights a surface includes it
// (track R2 owns this file). OrbitScene's `BRDF` is the Swift reference of
// every function here, and its tests pin them.
let lightingCommonSource = #"""
// ------------------------------------------------------------- lighting ---
//
// Units. Light is photometric: illuminance in lux, luminance (radiance) in
// cd/m², linear Rec. 709. A shader writes linear light times the frame's
// pre-exposure (FrameUniforms.exposure.x, R1), guarded and clamped by
// `orbit_exposed`, and blends linearly. It never calls orbit_encodeHDR: R1's
// HDRResolvePass alone weights the scene's samples for the resolve, so
// exactly one side encodes (VesselPassTests.testRadianceMatchesTheSwiftReference
// fails if a vessel's light is encoded twice, or not pre-exposed).
//
// Roughness. Materials give a perceptual roughness r in 0..1; the lobes use
// alpha = r^2, r clamped at ORBIT_MIN_ROUGHNESS.
//
// The SurfaceSample contract (VM1's paint and VM2's materials fill it, the
// lighting reads it; OrbitScene's `SurfaceSample` mirrors it):
//   albedo      linear Rec. 709, 0..1: a dielectric's diffuse albedo, or a
//               metal's reflectance at normal incidence (its F0 colour).
//   metalness   0 dielectric, 1 conductor (between only where a texel mixes
//               them): F0 = mix(reflectance, albedo, metalness), the diffuse
//               albedo (1 - metalness) * albedo.
//   roughness   perceptual r (alpha = r^2), before specular anti-aliasing,
//               which the lighting applies on the shading normal.
//   reflectance a dielectric's F0: 0.04 for paint, glass and plastics.
//   normal      the shading normal, world axes, unit, on the side seen (the
//               geometric normal plus relief).
//   occlusion   cavity occlusion of the indirect light that the material
//               knows (relief, crevices): 1 for none. The baked AO
//               (R5) multiplies it; neither touches the Sun.
//   emission    cd/m², added after the lighting (glow, lit windows).
//   anisotropy  reserved, -1..1 along `tangent`: every lobe is isotropic
//   tangent     until a track needs it.
//   coverage    0..1, honoured only on thin-wire draws, which the vessel
//               pass blends at their coverage after the opaque geometry
//               (Persson's phone-wire AA). Every other draw is opaque and
//               ignores it (R1's resolve ignores alpha too). A hook that
//               needs a hole calls discard_fragment() itself, which costs
//               the whole pipeline its hidden-surface removal: prefer
//               geometry.
// A material evaluation never lights: it gives these and returns.

#define ORBIT_PI 3.14159265358979
#define ORBIT_MIN_ROUGHNESS 0.045
#define ORBIT_MAX_HDR 60000.0

struct SurfaceSample {
    float3 albedo;
    float metalness;
    float3 normal;
    float roughness;
    float3 emission;
    float reflectance;
    float3 tangent;
    float anisotropy;
    float occlusion;
    float coverage;
};

// What the lobes need at one fragment, from its SurfaceSample and the view.
struct OrbitShadingPoint {
    float3 n;               // shading normal
    float3 v;               // unit, surface to camera
    float nv;
    float alpha;            // after specular anti-aliasing
    float roughness;        // sqrt(alpha): where the DFG table is read
    float3 f0;
    float3 diffuse;         // diffuse albedo
    float2 dfg;             // the split sum's A, B
    float3 energy;          // a light's multiple-scattering factor
    float3 specularWeight;  // the environment's: prefiltered radiance
    float3 diffuseWeight;   // the environment's: irradiance / pi (diffuse + multiple scattering)
    float3 diffuseLobe;     // a light's diffuse BRDF times pi: the albedo the specular leaves
};

// GGX (Walter et al. 2007), 1/sr.
inline float orbit_ggx(float nh, float alpha) {
    float a2 = alpha * alpha;
    float d = nh * nh * (a2 - 1.0) + 1.0;
    return a2 / (ORBIT_PI * d * d);
}

// Height-correlated Smith visibility G2 / (4 n.v n.l) (Heitz 2014;
// Lagarde and de Rousiers 2014).
inline float orbit_visibility(float nv, float nl, float alpha) {
    float a2 = alpha * alpha;
    float gv = nl * sqrt(nv * nv * (1.0 - a2) + a2);
    float gl = nv * sqrt(nl * nl * (1.0 - a2) + a2);
    return 0.5 / max(gv + gl, 1e-7);
}

inline float3 orbit_schlick(float3 f0, float vh) {
    float m = 1.0 - saturate(vh);
    float m2 = m * m;
    return f0 + (1.0 - f0) * (m2 * m2 * m);
}

// Tokuyoshi and Kaplanyan's conservative isotropic NDF filtering (JCGT
// 10(2), 2021, listing 5): alpha^2 widened by the normal's change across the
// pixel, sigma^2 = 1/(2 pi), kappa = 0.18. Fragment functions only.
inline float orbit_filteredAlpha2(float alpha2, float3 n) {
    float3 dx = dfdx(n), dy = dfdy(n);
    float widening = 2.0 * 0.15915494 * (dot(dx, dx) + dot(dy, dy));
    return saturate(alpha2 + min(widening, 0.18));
}

// The DFG table's A and B at (n.v, perceptual roughness): its texels sit on
// i / (size - 1), so the coordinates are scaled onto the texel centres
// (`BRDF.DFGTable`).
inline float2 orbit_dfg(texture2d<float> dfgLUT, sampler linear, float nv, float roughness) {
    float n = float(dfgLUT.get_width());
    float2 uv = (saturate(float2(nv, roughness)) * (n - 1.0) + 0.5) / n;
    return dfgLUT.sample(linear, uv, level(0.0)).rg;
}

// The fragment's lobes: F0 and the diffuse albedo from the sample, alpha
// filtered (`specularAA`), the DFG table read at (n.v, sqrt(alpha)), and the
// multiple-scattering terms (Fdez-Aguera 2019 for the environment; Kulla
// and Conty's 1 + F0 (1/Ess - 1), as Filament applies it, for lights).
inline OrbitShadingPoint orbit_shadingPoint(SurfaceSample s, float3 v, texture2d<float> dfgLUT, sampler linear,
                                            bool specularAA, bool multipleScattering) {
    OrbitShadingPoint p;
    p.n = s.normal;
    p.v = v;
    p.nv = clamp(dot(s.normal, v), 1e-4, 1.0);
    float r = clamp(s.roughness, ORBIT_MIN_ROUGHNESS, 1.0);
    float a2 = r * r * r * r;
    if (specularAA) { a2 = orbit_filteredAlpha2(a2, s.normal); }
    p.alpha = sqrt(a2);
    p.roughness = sqrt(p.alpha);
    p.f0 = mix(float3(s.reflectance), s.albedo, s.metalness);
    p.diffuse = s.albedo * (1.0 - s.metalness);
    p.dfg = orbit_dfg(dfgLUT, linear, p.nv, p.roughness);
    float ess = p.dfg.x + p.dfg.y;
    float3 fssEss = p.f0 * p.dfg.x + p.dfg.y;
    float3 multiple = float3(0.0);
    if (multipleScattering && ess > 1e-3) {
        float ems = 1.0 - ess;
        float3 fAvg = p.f0 + (1.0 - p.f0) / 21.0;
        float3 fms = fssEss * fAvg / (1.0 - ems * fAvg);
        multiple = fms * ems;
        p.energy = 1.0 + p.f0 * (1.0 / ess - 1.0);
    } else {
        p.energy = float3(1.0);
    }
    float3 left = saturate(1.0 - fssEss - multiple);
    p.specularWeight = fssEss;
    p.diffuseLobe = p.diffuse * left;
    p.diffuseWeight = multiple + p.diffuseLobe;
    return p;
}

// Radiance from a light of illuminance `e` (lux, on a surface facing it)
// from direction `l`, its specular lobe lit from `lSpecular` (a
// representative point) with `normalization` (an area light's energy).
inline float3 orbit_light(OrbitShadingPoint p, float3 l, float3 lSpecular, float normalization, float3 e) {
    float nl = saturate(dot(p.n, l));
    float3 h = normalize(p.v + lSpecular);
    float nls = saturate(dot(p.n, lSpecular));
    float nh = saturate(dot(p.n, h)), vh = saturate(dot(p.v, h));
    float3 specular = orbit_ggx(nh, p.alpha) * normalization * orbit_visibility(p.nv, nls, p.alpha)
        * orbit_schlick(p.f0, vh) * p.energy * nls;
    return e * (p.diffuseLobe * (nl / ORBIT_PI) + specular);
}

// The Sun as a disc of angular radius rho (cos, sin) about the unit `toSun`:
// diffuse from its centre, specular from the disc's point nearest the
// reflection with Karis' (2013) normalisation (alpha/alpha')^2, alpha' =
// saturate(alpha + sin rho / 3); `e` its illuminance (lux).
inline float3 orbit_sunLight(OrbitShadingPoint p, float3 toSun, float cosRho, float sinRho, bool disc, float3 e) {
    float3 lSpecular = toSun;
    float normalization = 1.0;
    if (disc) {
        float3 r = reflect(-p.v, p.n);
        float lr = dot(toSun, r);
        if (lr < cosRho) {
            float3 across = r - toSun * lr;
            float d = length(across);
            lSpecular = d > 1e-6 ? normalize(toSun * cosRho + across * (sinRho / d)) : toSun;
        } else {
            lSpecular = r;
        }
        float widened = saturate(p.alpha + sinRho / 3.0);
        normalization = (p.alpha / widened) * (p.alpha / widened);
    }
    return orbit_light(p, toSun, lSpecular, normalization, e);
}

// A line light (a plume): a segment of `axisLength.w` m along
// `axisLength.xyz` centred on `positionRadius.xyz` (camera-relative), a
// column `positionRadius.w` m in radius, of luminous intensity
// `intensity.rgb` cd broadside, cut off smoothly at `intensity.w` m. The
// irradiance is Picott's segment integral (Karis 2013, eq. 15), which tends
// to I cos / d^2 for a short one; the specular lobe takes the segment's
// point nearest the reflection (eq. 19), then the column's (eq. 11), with
// the sphere's and the line's normalisations (eqs. 14, 20).
inline float3 orbit_lineLight(OrbitShadingPoint p, float3 position, LocalLight light) {
    float3 c = light.positionRadius.xyz - position;
    float radius = max(light.positionRadius.w, 1e-3);
    float range = light.intensity.w;
    float dc = length(c);
    if (range > 0.0 && dc > range) { return float3(0.0); }
    float fall = range > 0.0 ? saturate(1.0 - pow(dc / range, 4.0)) : 1.0;
    float3 half_ = light.axisLength.xyz * (0.5 * light.axisLength.w);
    float3 l0 = c - half_, l1 = c + half_;
    float d0 = max(length(l0), 1e-4), d1 = max(length(l1), 1e-4);
    float irradiance = max(dot(p.n, l0) / d0 + dot(p.n, l1) / d1, 0.0)
        / (d0 * d1 + dot(l0, l1) + radius * radius);
    if (irradiance <= 0.0) { return float3(0.0); }
    // The specular lobe's representative point.
    float3 r = reflect(-p.v, p.n);
    float3 ld = l1 - l0;
    float rld = dot(r, ld);
    float t = (dot(r, l0) * rld - dot(l0, ld)) / max(dot(ld, ld) - rld * rld, 1e-6);
    float3 point_ = l0 + saturate(t) * ld;
    float3 toRay = dot(point_, r) * r - point_;
    float tr = length(toRay);
    if (tr > 1e-6) { point_ += toRay * saturate(radius / tr); }
    float dp = max(length(point_), 1e-4);
    float sphere = saturate(p.alpha + radius / (3.0 * dp));
    float line_ = saturate(p.alpha + 0.5 * light.axisLength.w / (3.0 * max(dc, 1e-4)));
    float normalization = (p.alpha / sphere) * (p.alpha / sphere) * (p.alpha / line_);
    float3 l = normalize(c);
    // `orbit_light` scales by the irradiance on a surface facing the light;
    // the segment integral already holds the cosine.
    float facing = max(dot(p.n, l), 0.05);
    return orbit_light(p, l, point_ / dp, normalization, light.intensity.rgb * (fall * irradiance / facing))
        * step(0.0, dot(p.n, l) + 0.05);
}

// pi times the view factor to a sphere of angular radius sigma (sin^2 sigma
// = `sinSigma2`) whose centre is at cos theta = `cosTheta` from the normal,
// its horizon included (Lagarde and de Rousiers 2014, listing 7; Howell's
// factor while the whole sphere is above the horizon).
inline float orbit_sphereIrradiance(float cosTheta, float sinSigma2) {
    float s2 = clamp(sinSigma2, 1e-6, 1.0);
    float c = clamp(cosTheta, -1.0, 1.0);
    if (c * c >= s2) { return ORBIT_PI * s2 * max(c, 0.0); }
    float sinTheta = sqrt(max(1.0 - c * c, 1e-12));
    float x = sqrt(max(1.0 / s2 - 1.0, 1e-12));
    float y = clamp(-x * (c / sinTheta), -1.0, 1.0);
    float sinThetaSqrtY = sinTheta * sqrt(1.0 - y * y);
    return max((c * acos(y) - x * sinThetaSqrtY) * s2 + atan(sinThetaSqrtY / x), 0.0);
}

// Lagarde and de Rousiers' (2014) specular occlusion from the ambient
// occlusion `ao`.
inline float orbit_specularOcclusion(float nv, float ao, float alpha) {
    return saturate(pow(nv + ao, exp2(-16.0 * alpha - 1.0)) - 1.0 + ao);
}

// The light around a surface before R3's probe: a body seen as a disc of
// uniform radiance, and a uniform irradiance (sky and night floor). R2's
// documented stand-in for M1.5's earthshine and sky light.
struct OrbitStandInEnvironment {
    float3 bodyDirection;   // unit, to the body's centre (zero for none)
    float bodySinSigma2;    // sin^2 of its angular radius
    float3 bodyRadiance;    // cd/m2, its lit disc's mean
    float3 uniform_;        // lux, from every direction
};

// The environment's light at a fragment (cd/m2), with ambient occlusion
// `ao`. With R3's probe (lighting.probe.w = its specular mip count): the
// prefiltered cube read at the lobe's roughness (texture 20, radiance) and
// the irradiance cube (texture 21, E/pi, in cd/m2). Without it, the
// stand-in: the body's disc where the reflection meets it, widened by the
// lobe, blurred to the cosine-weighted value as the surface roughens.
inline float3 orbit_environmentLight(OrbitShadingPoint p, float ao, constant LightingUniforms &lighting,
                                     OrbitStandInEnvironment standIn, texturecube<float> specularCube,
                                     texturecube<float> irradianceCube, sampler linear) {
    float3 r = reflect(-p.v, p.n);
    float3 prefiltered, irradianceOverPi;
    if (lighting.probe.w > 0.5) {
        prefiltered = specularCube.sample(linear, r, level(p.roughness * (lighting.probe.w - 1.0))).rgb;
        irradianceOverPi = irradianceCube.sample(linear, p.n).rgb;
    } else {
        float s2 = standIn.bodySinSigma2;
        float3 u = standIn.uniform_ / ORBIT_PI;
        float3 bodyN = float3(0.0), bodyR = float3(0.0);
        float inside = 0.0;
        if (s2 > 0.0) {
            float3 d = standIn.bodyDirection;
            bodyN = standIn.bodyRadiance * (orbit_sphereIrradiance(dot(p.n, d), s2) / ORBIT_PI);
            bodyR = standIn.bodyRadiance * (orbit_sphereIrradiance(dot(r, d), s2) / ORBIT_PI);
            float sigma = asin(sqrt(min(s2, 1.0)));
            float angle = acos(clamp(dot(r, d), -1.0, 1.0));
            float w = 0.02 + p.alpha;
            inside = 1.0 - smoothstep(sigma - w, sigma + w, angle);
        }
        irradianceOverPi = bodyN + u;
        float3 sharp = standIn.bodyRadiance * inside + u;
        prefiltered = mix(sharp, bodyR + u, saturate(p.alpha));
    }
    float so = orbit_specularOcclusion(p.nv, ao, p.alpha);
    return prefiltered * p.specularWeight * so + irradianceOverPi * p.diffuseWeight * ao;
}

// Pre-exposure, a NaN guard and the FP16 ceiling: what a shader writes. The
// guard comes first: min() returns its other argument for a NaN (and clamps
// an infinity), so after it a NaN would read as a 6e4 highlight. Any NaN or
// infinity in a channel blacks the sample out.
inline float3 orbit_exposed(float3 radiance, float preExposure) {
    float3 c = radiance * preExposure;
    if (orbit_isNotFinite(c)) { return float3(0.0); }
    return clamp(c, float3(0.0), float3(ORBIT_MAX_HDR));
}
"""#

extension ShaderHeader {
    public static let lightingCommon = ShaderHeader(name: "LightingCommon", source: lightingCommonSource)
}
