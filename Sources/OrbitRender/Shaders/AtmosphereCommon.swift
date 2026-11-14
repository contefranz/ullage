// The atmosphere's optics on the GPU: A1's tables (OrbitCore's
// AtmosphereLUT, docs/m16/atmosphere-luts.md) mirrored in MSL, the medium,
// the phase functions, the march along a ray in the planet's figure
// coordinates, and the aerial-perspective froxels' lookup. A header for
// every module that looks through air (the atmosphere's own, the planet's;
// the vessel's, clouds', plumes' and particles' when they adopt it). Track
// A2 owns this file; docs/look/atmosphere.md is its contract.
//
// Units: the tables are per unit solar irradiance; the sky-view LUT and the
// froxels hold cd/m² (not pre-exposed). Figure coordinates: the planet's
// body axes with z stretched by a/b, where its ellipsoid is the sphere of
// radius `AtmosphereUniforms.radii.x` (A1's ground) and the top is `radii.y`.
let atmosphereCommonSource = #"""
// ------------------------------------------------------ atmosphere common ---

// [0, 1] to a table's texel centres, and back (AtmosphereLUT.textureCoordinate).
inline float atmo_texcoord(float x, float size) { return 0.5 / size + x * (1.0 - 1.0 / size); }
inline float atmo_unit(float u, float size) { return (u - 0.5 / size) / (1.0 - 1.0 / size); }

// The transmittance table's uv for radius r and zenith cosine mu (Bruneton
// 2017's parameterisation; rb ground, rt top). Written so that r near the
// ground keeps its precision: r² - rb² as (r - rb)(r + rb).
inline float2 atmo_transmittanceUV(float r, float mu, float rb, float rt, float2 size) {
    float H = sqrt((rt - rb) * (rt + rb));
    float rr = clamp(r, rb, rt);
    float rho = sqrt(max((rr - rb) * (rr + rb), 0.0));
    float above = (rt - rr) * (rt + rr);                 // rt² - r²
    float root = sqrt(max(above + rr * rr * mu * mu, 0.0));
    float d = mu > 0.0 ? above / (rr * mu + root) : root - rr * mu;   // to the top along mu
    float dMin = rt - rr, dMax = rho + H;
    float xMu = dMax > dMin ? clamp((d - dMin) / (dMax - dMin), 0.0, 1.0) : 0.0;
    return float2(atmo_texcoord(xMu, size.x), atmo_texcoord(rho / H, size.y));
}

// Transmittance from radius r along mu to the top; rays into the ground
// read the horizon's (A1's transmittanceToTop).
inline float3 atmo_transmittanceToTop(texture2d<float> lut, sampler s, float r, float mu, float rb, float rt) {
    float2 size = float2(lut.get_width(), lut.get_height());
    return lut.sample(s, atmo_transmittanceUV(r, mu, rb, rt, size), level(0)).rgb;
}

// The Sun's transmittance at radius r with the Sun at zenith cosine muS,
// times the share of its disc above the planet's horizon there (A1's
// transmittanceToSun): the planet's shadow in the air.
inline float3 atmo_transmittanceToSun(texture2d<float> lut, sampler s, float r, float muS, float rb, float rt,
                                      float sunRadius) {
    float rr = max(r, rb);
    float sinH = rb / rr;
    float cosH = -sqrt(max((rr - rb) * (rr + rb), 0.0)) / rr;
    float edge = sinH * sunRadius;
    float visible = smoothstep(-edge, edge, muS - cosH);
    if (visible <= 0.0) { return float3(0.0); }
    return atmo_transmittanceToTop(lut, s, rr, muS, rb, rt) * visible;
}

// (u, v) on the multiple-scattering and irradiance tables: Sun zenith
// cosine on u, √ of the height fraction on v.
inline float2 atmo_sunTableUV(float r, float muS, float rb, float rt, float2 size) {
    float xMu = clamp(muS * 0.5 + 0.5, 0.0, 1.0);
    float xR = sqrt(clamp((r - rb) / (rt - rb), 0.0, 1.0));
    return float2(atmo_texcoord(xMu, size.x), atmo_texcoord(xR, size.y));
}

// Ψ_ms (multiple-scattering table) or the sky's irradiance on a horizontal
// surface facing up (irradiance table), per unit solar irradiance.
inline float3 atmo_sunTable(texture2d<float> lut, sampler s, float r, float muS, float rb, float rt) {
    float2 size = float2(lut.get_width(), lut.get_height());
    return lut.sample(s, atmo_sunTableUV(r, muS, rb, rt, size), level(0)).rgb;
}

// Rayleigh's phase function with the air's depolarisation (ρn = 0.0279), and
// Cornette-Shanks' for the aerosol; nu is the cosine between the view ray
// (outward from the eye) and the direction to the Sun (1/sr).
inline float atmo_rayleighPhase(float nu) {
    const float gamma = 0.0279 / (2.0 - 0.0279);
    return 3.0 / (16.0 * M_PI_F * (1.0 + 2.0 * gamma)) * ((1.0 + 3.0 * gamma) + (1.0 - gamma) * nu * nu);
}
inline float atmo_cornetteShanksPhase(float nu, float g) {
    float g2 = g * g;
    float k = 3.0 / (8.0 * M_PI_F) * (1.0 - g2) / (2.0 + g2);
    float d = max(1.0 + g2 - 2.0 * g * nu, 1e-6);
    return k * (1.0 + nu * nu) / (d * sqrt(d));
}

// The medium at altitude h (m): A1's profile times AtmosphereUniforms'
// coefficients. The air's density is the profile table's (US-1976 or the
// launch day's), the aerosol exponential and the ozone a tent, both exact.
struct AtmoMedium {
    float3 rayleigh;      // scattering, 1/m
    float3 mie;           // aerosol scattering, 1/m
    float3 extinction;    // 1/m
};

inline AtmoMedium atmo_medium(float h, constant AtmosphereUniforms &a, texture2d<float> profile, sampler s) {
    AtmoMedium m;
    float top = a.radii.y - a.radii.x;
    if (h > top) {
        m.rayleigh = float3(0.0); m.mie = float3(0.0); m.extinction = float3(0.0);
        return m;
    }
    float x = clamp(h / top, 0.0, 1.0);
    float air = profile.sample(s, float2(atmo_texcoord(x, float(profile.get_width())), 0.5), level(0)).r;
    float aerosol = exp(-max(h, 0.0) / a.mieScattering.w);
    float ozone = max(0.0, 1.0 - abs(h - a.ozoneAbsorption.w) / a.ozoneLayer.x);
    m.rayleigh = a.rayleighScattering.rgb * air;
    m.mie = a.mieScattering.rgb * aerosol;
    m.extinction = m.rayleigh + a.mieExtinction.rgb * aerosol + a.ozoneAbsorption.rgb * ozone;
    return m;
}

// Distances along o + t d (d unit) to a sphere of radius R about the
// origin: (near, far), or near > far when the line misses it. The closest
// approach comes from |o × d|, which keeps its precision far from the
// planet (from the Moon) where |o|² - R² would not.
inline float2 atmo_sphere(float3 o, float3 d, float R) {
    float tca = -dot(o, d);
    float3 c = cross(o, d);
    float ca = sqrt(dot(c, c));
    if (ca > R) { return float2(1.0, -1.0); }
    float half_ = sqrt(max((R - ca) * (R + ca), 0.0));
    return float2(tca - half_, tca + half_);
}

// Where the ray from o along d is in the air, up to the ground: (t0, t1),
// t0 >= t1 when it never is; z: 1 when it ends on the ground.
inline float3 atmo_airSegment(float3 o, float3 d, float rb, float rt) {
    float2 top = atmo_sphere(o, d, rt);
    if (top.x > top.y || top.y <= 0.0) { return float3(0.0, 0.0, 0.0); }
    float t0 = max(top.x, 0.0), t1 = top.y, ground = 0.0;
    float2 g = atmo_sphere(o, d, rb);
    if (g.x <= g.y && g.y > 0.0) {
        t1 = max(g.x, 0.0);
        ground = 1.0;
    }
    return float3(t0, t1, ground);
}

// The sky-view LUT's uv (Hillaire 2020; OrbitScene's
// SkyViewParameterization) for a view at zenith cosine mu and azimuth
// cosine cosAz from the Sun's vertical, from radius r: the horizon, dipped
// by the height, between the middle rows; above it the sky, below it the
// light scattered toward the eye on the way to the ground.
inline float2 atmo_skyViewUV(float r, float rb, float mu, float cosAz, float2 size) {
    float vHorizon = sqrt(max((r - rb) * (r + rb), 0.0));
    float beta = acos(clamp(vHorizon / r, 0.0, 1.0));
    float zh = M_PI_F - beta;
    float zenith = acos(clamp(mu, -1.0, 1.0));
    float y = zenith < zh ? 0.5 * (1.0 - sqrt(max(1.0 - zenith / zh, 0.0)))
                          : 0.5 + 0.5 * sqrt(clamp((zenith - zh) / max(beta, 1e-6), 0.0, 1.0));
    float x = sqrt(max(0.5 - 0.5 * cosAz, 0.0));
    return float2(atmo_texcoord(x, size.x), atmo_texcoord(clamp(y, 0.0, 1.0), size.y));
}

// The azimuth cosine of a direction d from the Sun's vertical about `up`
// (all unit, figure coordinates).
inline float atmo_cosAzimuth(float3 d, float3 sun, float3 up) {
    float3 h = d - up * dot(d, up), hs = sun - up * dot(sun, up);
    float lh = length(h), ls = length(hs);
    return (lh > 1e-6 && ls > 1e-6) ? clamp(dot(h, hs) / (lh * ls), -1.0, 1.0) : 1.0;
}

// The transmittance between the camera at radius rc and a point on the
// ground below it along d (figure coordinates, unit up vectors at both
// ends), as the ratio of A1's transmittance to the top along the reversed
// ray from each end (Bruneton 2008): neither of those meets the ground.
inline float3 atmo_transmittanceToGround(texture2d<float> lut, sampler s, float rc, float3 upCamera, float3 upGround,
                                         float3 d, float rb, float rt) {
    float3 fromGround = atmo_transmittanceToTop(lut, s, rb, clamp(dot(-d, upGround), 0.0, 1.0), rb, rt);
    float3 fromCamera = atmo_transmittanceToTop(lut, s, rc, clamp(dot(-d, upCamera), -1.0, 1.0), rb, rt);
    return clamp(fromGround / max(fromCamera, float3(1e-30)), 0.0, 1.0);
}

// What the air sends toward the eye along a ray, per unit solar irradiance:
// in-scattered radiance (1/sr) and the transmittance.
struct AtmoMarch {
    float3 radiance;
    float3 transmittance;
};

// One step over [ta, tb] at its midpoint: single scattering of the Sun's
// light through the phase functions (the Sun's transmittance from the
// table, 0 in the planet's shadow), plus σs·Ψ_ms, the step's attenuation
// integrated exactly (Hillaire 2015).
inline void atmo_step(thread AtmoMarch &m, float3 o, float3 d, float ta, float tb, float3 sun, float rayleighPhase,
                      float miePhase, float sunRadius, constant AtmosphereUniforms &a, texture2d<float> transmittance,
                      texture2d<float> multiple, texture2d<float> profile, sampler s) {
    float dt = tb - ta;
    if (dt <= 0.0) { return; }
    float rb = a.radii.x, rt = a.radii.y;
    float3 p = o + d * (ta + 0.5 * dt);
    float r = length(p);
    AtmoMedium med = atmo_medium(r - rb, a, profile, s);
    float muS = dot(p, sun) / r;
    float3 tSun = atmo_transmittanceToSun(transmittance, s, r, muS, rb, rt, sunRadius);
    float3 psi = atmo_sunTable(multiple, s, r, muS, rb, rt);
    float3 source = tSun * (med.rayleigh * rayleighPhase + med.mie * miePhase) + psi * (med.rayleigh + med.mie);
    float3 tau = med.extinction * dt;
    float3 stepT = exp(-tau);
    float3 integral = select((1.0 - stepT) / max(med.extinction, float3(1e-30)), dt * (1.0 - 0.5 * tau),
                             tau < float3(1e-3));
    m.radiance += m.transmittance * source * integral;
    m.transmittance *= stepT;
}

// The march over [t0, t1] in `steps` steps, crowded quadratically toward
// the ray's lowest point (where the air is densest), as A1's CPU march is.
// o: relative to the planet's centre, d: unit, sun: unit (figure
// coordinates); nu: the view-Sun cosine (world).
inline AtmoMarch atmo_march(float3 o, float3 d, float t0, float t1, int steps, float3 sun, float nu, float sunRadius,
                            constant AtmosphereUniforms &a, texture2d<float> transmittance, texture2d<float> multiple,
                            texture2d<float> profile, sampler s) {
    AtmoMarch m;
    m.radiance = float3(0.0);
    m.transmittance = float3(1.0);
    if (t1 <= t0 || steps < 1) { return m; }
    float rp = atmo_rayleighPhase(nu), mp = atmo_cornetteShanksPhase(nu, a.mieExtinction.w);
    float tca = clamp(-dot(o, d), t0, t1);
    float l1 = tca - t0, l2 = t1 - tca;
    int n1 = l1 > 0.0 ? clamp(int(rint(float(steps) * l1 / (l1 + l2))), 1, steps) : 0;
    int n2 = l2 > 0.0 ? max(steps - n1, 1) : 0;
    float previous = t0;
    for (int k = 1; k <= n1; k++) {
        float x = 1.0 - float(k) / float(n1);
        float t = tca - l1 * x * x;
        atmo_step(m, o, d, previous, t, sun, rp, mp, sunRadius, a, transmittance, multiple, profile, s);
        previous = t;
    }
    for (int k = 1; k <= n2; k++) {
        float x = float(k) / float(n2);
        float t = tca + l2 * x * x;
        atmo_step(m, o, d, previous, t, sun, rp, mp, sunRadius, a, transmittance, multiple, profile, s);
        previous = t;
    }
    return m;
}

// The aerial perspective to a point at distance t (m) along the view ray
// through screen uv (0..1, y down), from the froxels: rgb in-scattered
// luminance (cd/m², not pre-exposed), a the transmittance (the channels'
// mean). Slice i ends at far·((i + 1)/n)^k (AtmosphereUniforms.
// aerialPerspective: x n, y far, z k; x 0 when there are none: no air).
inline float4 atmo_aerialPerspective(texture3d<float> froxels, sampler s, float2 uv, float t,
                                     constant AtmosphereUniforms &a) {
    float n = a.aerialPerspective.x;
    if (n < 1.0) { return float4(0.0, 0.0, 0.0, 1.0); }
    float slice = n * pow(clamp(t / a.aerialPerspective.y, 0.0, 1.0), 1.0 / a.aerialPerspective.z) - 1.0;
    float w = (clamp(slice, 0.0, n - 1.0) + 0.5) / n;
    float4 v = froxels.sample(s, float3(uv, w), level(0));
    float weight = clamp(slice + 1.0, 0.0, 1.0);
    return float4(v.rgb * weight, mix(1.0, v.a, weight));
}
"""#

extension ShaderHeader {
    public static let atmosphereCommon = ShaderHeader(name: "AtmosphereCommon", source: atmosphereCommonSource)
}
