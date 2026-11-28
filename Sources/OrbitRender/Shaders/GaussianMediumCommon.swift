import Foundation
import simd
import OrbitCore
import OrbitScene

// Gaussian media and smoke scattering (look round 2; track LR5 owns this
// header): what a module that marches or splats smoke includes after
// ShaderCommon and `.sphericalHarmonics`. The trail (LR5's TrailPass), the
// launch cloud (LR4) and the plumes' far field (LR3) include it, so a broken
// header disables all three; `ShaderModule.gaussianMediumCheck` is in
// `ShaderModule.all`, so the compile tests and scripts/check-shaders.sh
// catch it first. It mirrors OrbitScene's GaussianMedium and
// SmokeScattering line for line, in Float.
let gaussianMediumCommonSource = #"""
// ------------------------------------------------------ Gaussian media ---

// A smoke primitive: extinction sigma0 exp(-1/2 (p - c)^T Sigma^-1 (p - c)),
// sigmas along three orthonormal axes, cut off at ORBIT_GAUSSIAN_EXTENT
// sigma along each (its box). GaussianMediumGPU mirrors it.
#define ORBIT_GAUSSIAN_EXTENT 3.0

struct GaussianMedium {
    float4 centre;   // xyz: camera-relative centre (m), w: sigma0, the extinction there (1/m)
    float4 axisU;    // xyz: unit principal axis u, w: its sigma (m)
    float4 axisV;    // xyz: unit principal axis v (orthogonal to u), w: its sigma (m)
    float4 axisW;    // xyz: u x v, w: its sigma (m)
    float4 optics;   // rgb: single-scattering albedo, w: asymmetry g
};

// The error function (MSL has none): Abramowitz and Stegun 7.1.26,
// |error| <= 1.5e-7, odd. GaussianMedium.erf.
inline float orbit_erf(float x) {
    float z = min(abs(x), 9.0), t = 1.0 / (1.0 + 0.3275911 * z);
    float poly = t * (0.254829592 + t * (-0.284496736 + t * (1.421413741 + t * (-1.453152027 + t * 1.061405429))));
    float y = 1.0 - poly * exp(-z * z);
    return x < 0.0 ? -y : y;
}

// The point p in the primitive's axes, in sigma.
inline float3 orbit_gaussianLocal(GaussianMedium g, float3 p) {
    float3 x = p - g.centre.xyz;
    return float3(dot(x, g.axisU.xyz) / g.axisU.w, dot(x, g.axisV.xyz) / g.axisV.w, dot(x, g.axisW.xyz) / g.axisW.w);
}

// Along a ray o + t d (d unit, t in m) the extinction is itself a Gaussian
// in t: peak exp(-(t - centre)^2 / (2 width^2)). GaussianMedium.Ray.
struct GaussianRay {
    float centre;   // t of the nearest approach in the primitive's metric (m)
    float width;    // the 1-D sigma along the ray (m)
    float peak;     // the extinction there (1/m)
};

// The ray's Gaussian: with x = o - c and d in sigma, a = |d|^2, b = x.d, the
// nearest approach is at -b/a, the width 1/sqrt(a), the peak sigma0
// exp(-1/2 |x - (b/a) d|^2). For precision o should be near the primitive
// (the box's entry, say), not kilometres off.
inline GaussianRay orbit_gaussianRay(GaussianMedium g, float3 o, float3 d) {
    float3 x = orbit_gaussianLocal(g, o);
    float3 dl = float3(dot(d, g.axisU.xyz) / g.axisU.w, dot(d, g.axisV.xyz) / g.axisV.w, dot(d, g.axisW.xyz) / g.axisW.w);
    float a = max(dot(dl, dl), 1e-30), b = dot(x, dl);
    float3 miss = x - dl * (b / a);
    GaussianRay r;
    r.centre = -b / a;
    r.width = rsqrt(a);
    r.peak = g.centre.w * exp(-0.5 * dot(miss, miss));
    return r;
}

// The optical depth from t0 to t1 (t0 <= t1) in closed form (Condor et al.
// 2025): peak width sqrt(pi/2) (erf((t1 - c)/(sqrt2 w)) - erf((t0 - c)/(sqrt2 w))).
inline float orbit_gaussianDepth(GaussianRay r, float t0, float t1) {
    float k = 1.0 / (1.41421356 * r.width);
    float a = orbit_erf((t0 - r.centre) * k), b = orbit_erf((t1 - r.centre) * k);
    return max(r.peak * r.width * 1.25331414 * (b - a), 0.0);
}

// The optical depth along the whole line: peak width sqrt(2 pi).
inline float orbit_gaussianTotal(GaussianRay r) {
    return r.peak * r.width * 2.50662827;
}

// The optical-depth-weighted mean t over t0...t1, whose depth is `depth`:
// c + w^2 (sigma(t0) - sigma(t1)) / depth, where a primitive's light is
// evaluated (one source per primitive); the nearest approach, clamped,
// where the depth is nil.
inline float orbit_gaussianCentroid(GaussianRay r, float t0, float t1, float depth) {
    if (depth <= 1e-12) { return clamp(r.centre, t0, t1); }
    float k = 1.0 / (2.0 * r.width * r.width);
    float e0 = exp(-(t0 - r.centre) * (t0 - r.centre) * k), e1 = exp(-(t1 - r.centre) * (t1 - r.centre) * k);
    return clamp(r.centre + r.width * r.width * r.peak * (e0 - e1) / depth, t0, t1);
}

// Where the ray o + t d is inside the box (+-ORBIT_GAUSSIAN_EXTENT sigma
// along each axis): (t0, t1), a miss where t0 >= t1.
inline float2 orbit_gaussianBox(GaussianMedium g, float3 o, float3 d) {
    float3 x = o - g.centre.xyz;
    float3 xl = float3(dot(x, g.axisU.xyz), dot(x, g.axisV.xyz), dot(x, g.axisW.xyz));
    float3 dl = float3(dot(d, g.axisU.xyz), dot(d, g.axisV.xyz), dot(d, g.axisW.xyz));
    float3 h = ORBIT_GAUSSIAN_EXTENT * float3(g.axisU.w, g.axisV.w, g.axisW.w);
    dl = select(dl, select(float3(1e-12), float3(-1e-12), dl < 0.0), abs(dl) < 1e-12);
    float3 a = (-h - xl) / dl, b = (h - xl) / dl;
    float3 lo = min(a, b), hi = max(a, b);
    return float2(max(lo.x, max(lo.y, lo.z)), min(hi.x, min(hi.y, hi.z)));
}

// The optical depth along o + t d between t0 and t1, within the box only.
inline float orbit_gaussianBoxDepth(GaussianMedium g, float3 o, float3 d, float t0, float t1) {
    float2 b = orbit_gaussianBox(g, o, d);
    float lo = max(t0, b.x), hi = min(t1, b.y);
    return hi > lo ? orbit_gaussianDepth(orbit_gaussianRay(g, o, d), lo, hi) : 0.0;
}

// A primitive's light over a segment of optical depth tau whose source is J
// (pre-exposed): premultiplied (J (1 - e^-tau), 1 - e^-tau), composited over
// what lies behind it, back to front.
inline float4 orbit_gaussianLight(float3 source, float tau) {
    float a = 1.0 - exp(-tau);
    return float4(source * a, a);
}

// ------------------------------------------------------ smoke scattering ---
// The source function J (cd/m2 per unit extinction, NOT pre-exposed) of a
// smoke of single-scattering albedo w and asymmetry g, one g for all three
// parts: the Sun's light scattered once (Henyey-Greenstein, through its
// optical depth to the Sun), the Sun's light scattered many times (C2's
// two-stream with absorption, the Sun's chord through the point as a slab
// lit face-on), and the ambient (R3's SH9 by the same phase, through the
// column around the point, fed diffusely from both sides).
// SmokeScattering, line for line.

#define ORBIT_SMOKE_PI 3.14159265

// Henyey and Greenstein, normalised over the sphere, of the cosine between
// the view ray (camera to point) and the direction to the Sun.
inline float orbit_smokePhase(float c, float g) {
    float d = 1.0 + g * g - 2.0 * g * c;
    return (1.0 - g * g) / (4.0 * ORBIT_SMOKE_PI * d * sqrt(d));
}

// E(x) = (1 - e^(-2kx))/k, its series where 2kx < 1e-2:
// 2x (1 - kx + 2/3 (kx)^2 - 1/3 (kx)^3 + 2/15 (kx)^4), 2x at k = 0.
inline float3 orbit_smokeE(float3 k, float x) {
    float3 y = 2.0 * k * x, q = k * x;
    float3 series = 2.0 * x * (1.0 - q * (1.0 - q * (2.0 / 3.0 - q * (1.0 / 3.0 - (2.0 / 15.0) * q))));
    return select((1.0 - exp(-y)) / max(k, float3(1e-30)), series, y < 1e-2);
}

struct SmokeStreams {
    float3 down;
    float3 up;
};

// The two-stream's diffuse fluxes at optical depth t from the top of a
// column of optical depth tau, per unit flux entering its top and none its
// bottom: gamma1 = 1 - w(1 - b), gamma2 = w b, b = (1 - g)/2, k =
// sqrt(gamma1^2 - gamma2^2), u = tau - t;
// down = e^(-kt) (1 + e^(-2ku) + gamma1 E(u)) / (1 + e^(-2k tau) + gamma1 E(tau)),
// up = e^(-kt) gamma2 E(u) / (same). At w = 1 C2's cloud_streams exactly.
inline SmokeStreams orbit_smokeStreams(float t, float tau, float3 w, float g) {
    tau = max(tau, 0.0);
    t = clamp(t, 0.0, tau);
    float u = tau - t, b = 0.5 * (1.0 - g);
    w = clamp(w, 0.0, 1.0);
    float3 g1 = 1.0 - w * (1.0 - b), g2 = w * b;
    float3 k = sqrt((1.0 - w) * (1.0 - w + 2.0 * w * b));
    float3 den = 1.0 + exp(-2.0 * k * tau) + g1 * orbit_smokeE(k, tau), down0 = exp(-k * t);
    float3 eu = orbit_smokeE(k, u);
    SmokeStreams s;
    s.down = down0 * (1.0 + exp(-2.0 * k * u) + g1 * eu) / den;
    s.up = down0 * g2 * eu / den;
    return s;
}

// The streams' radiance towards a direction whose cosine with the column's
// top normal is muUp (the light's travel), per unit flux: F/pi over each
// hemisphere, blended by the direction (C2's cloud_streamRadiance).
inline float3 orbit_smokeStreamRadiance(float3 down, float3 up, float muUp) {
    float w = 0.5 * (1.0 + clamp(muUp, -1.0, 1.0));
    return (w * up + (1.0 - w) * down) * (1.0 / ORBIT_SMOKE_PI);
}

// The Sun's light scattered many times at the point, per unit solar
// irradiance (1/sr): the two-stream of its chord to the Sun, lit face-on,
// the point sunDepth into it, less the direct beam.
inline float3 orbit_smokeSunDiffuse(float sunDepth, float sunChord, float cosView, float3 w, float g) {
    SmokeStreams s = orbit_smokeStreams(sunDepth, max(sunChord, sunDepth), w, g);
    return orbit_smokeStreamRadiance(max(s.down - exp(-sunDepth), float3(0.0)), s.up, -cosView);
}

// The share of the ambient radiance reaching a point `depth` into a column
// of optical depth `column` fed diffusely from both sides: half its four
// streams. 1 at w = 1; (1 + e^-tau)/2 at the face of a black column.
inline float3 orbit_smokeAmbientShare(float depth, float column, float3 w, float g) {
    column = max(column, 0.0);
    depth = clamp(depth, 0.0, column);
    SmokeStreams a = orbit_smokeStreams(depth, column, w, g);
    SmokeStreams b = orbit_smokeStreams(column - depth, column, w, g);
    return 0.5 * (a.down + a.up + b.down + b.up);
}

// What the caller knows of the light at the point.
struct SmokeLight {
    float3 sun;          // the Sun's illuminance on the smoke from outside it (lux), every other shadow applied
    float3 ambient;      // the ambient radiance scattered per unit albedo (cd/m2): orbit_smokeAmbient
    float cosView;       // cosine between the view ray (camera to point) and the direction to the Sun
    float sunDepth;      // the smoke's optical depth from the point to the Sun
    float sunChord;      // its whole optical depth along that line through the point
    float ambientDepth;  // the point's optical depth into the column the ambient lights
    float ambientChord;  // that column's whole optical depth
};

// J, cd/m2 per unit extinction: w (E (p e^-tauSun + D) + L_amb A).
inline float3 orbit_smokeSource(float3 albedo, float g, SmokeLight l) {
    float phase = orbit_smokePhase(l.cosView, g), direct = exp(-l.sunDepth);
    float3 diffuse = orbit_smokeSunDiffuse(l.sunDepth, l.sunChord, l.cosView, albedo, g);
    float3 share = orbit_smokeAmbientShare(l.ambientDepth, l.ambientChord, albedo, g);
    return albedo * (l.sun * (phase * direct + diffuse) + l.ambient * share);
}

// The ambient radiance a smoke of asymmetry g scatters toward the eye along
// the unit view ray v per unit albedo (cd/m2, not pre-exposed): R3's SH9
// when the probe is drawn (lighting.probe.w), else the caller's stand-in
// (A2's sky, the earthshine). Needs `.sphericalHarmonics` before this header.
inline float3 orbit_smokeAmbient(constant LightingUniforms &lighting, float3 v, float g, float3 standIn) {
    return lighting.probe.w > 0.5 ? orbit_sh9InScatter(lighting, v, g) : standIn;
}
"""#

extension ShaderHeader {
    /// Gaussian media and the smoke scattering function, for the trail
    /// (LR5), the launch cloud (LR4) and the plumes' far field (LR3).
    /// Include it after `.sphericalHarmonics`.
    public static let gaussianMedium = ShaderHeader(name: "GaussianMediumCommon", source: gaussianMediumCommonSource)
}

/// The header's `GaussianMedium`, as the passes upload it: five float4s,
/// the centre camera-relative.
public struct GaussianMediumGPU: Equatable {
    /// xyz: camera-relative centre (m), w: σ0 (1/m).
    public var centre: SIMD4<Float>
    /// xyz: unit axes u, v and u × v, w: their σ (m).
    public var axisU: SIMD4<Float>
    public var axisV: SIMD4<Float>
    public var axisW: SIMD4<Float>
    /// rgb: albedo, w: asymmetry g.
    public var optics: SIMD4<Float>

    public init(_ g: GaussianMedium, camera: Vec3) {
        centre = SIMD4<Float>(g.centre - camera, Float(g.peakExtinction))
        axisU = SIMD4<Float>(g.axisU, Float(g.sigma.x))
        axisV = SIMD4<Float>(g.axisV, Float(g.sigma.y))
        axisW = SIMD4<Float>(g.axisW, Float(g.sigma.z))
        optics = SIMD4<Float>(Float(g.albedo.r), Float(g.albedo.g), Float(g.albedo.b), Float(g.asymmetry))
    }
}

// The header's check: a kernel that evaluates every function of it on a
// list of cases, for OrbitRenderTests to hold against OrbitScene's mirror.
// In `ShaderModule.all`, so a broken header fails the compile tests before
// any pass includes it.
let gaussianMediumCheckSource = #"""
struct GaussianMediumCheckCase {
    GaussianMedium medium;
    float4 origin;      // xyz: the ray's origin (camera-relative, m), w: t0
    float4 direction;   // xyz: unit, w: t1
    float4 column;      // x: depth, y: column (optical depths), z: albedo (grey), w: g, for the streams
    float4 view;        // x: cosView, y: sunDepth, z: sunChord, w: ambientDepth
    float4 extra;       // x: ambientChord, y: the error function's argument
    float4 sun;         // rgb: lux
    float4 ambient;     // rgb: cd/m2, the stand-in
};

kernel void gaussianMedium_check(device const GaussianMediumCheckCase *cases [[buffer(0)]],
                                 device float4 *out [[buffer(1)]],
                                 constant LightingUniforms &lighting [[buffer(ORBIT_BUFFER_LIGHTING)]],
                                 uint i [[thread_position_in_grid]]) {
    GaussianMediumCheckCase c = cases[i];
    float3 o = c.origin.xyz, d = c.direction.xyz;
    float t0 = c.origin.w, t1 = c.direction.w;
    GaussianRay r = orbit_gaussianRay(c.medium, o, d);
    float depth = orbit_gaussianDepth(r, t0, t1);
    float2 box = orbit_gaussianBox(c.medium, o, d);
    out[6 * i + 0] = float4(r.centre, r.width, r.peak, depth);
    out[6 * i + 1] = float4(box, orbit_gaussianBoxDepth(c.medium, o, d, t0, t1), orbit_gaussianCentroid(r, t0, t1, depth));
    SmokeStreams s = orbit_smokeStreams(c.column.x, c.column.y, float3(c.column.z), c.column.w);
    out[6 * i + 2] = float4(s.down.x, s.up.x, orbit_smokeAmbientShare(c.column.x, c.column.y, float3(c.column.z), c.column.w).x,
                            orbit_smokeSunDiffuse(c.column.x, c.column.y, c.view.x, float3(c.column.z), c.column.w).x);
    SmokeLight l;
    l.sun = c.sun.rgb;
    l.ambient = c.ambient.rgb;
    l.cosView = c.view.x;
    l.sunDepth = c.view.y;
    l.sunChord = c.view.z;
    l.ambientDepth = c.view.w;
    l.ambientChord = c.extra.x;
    float3 source = orbit_smokeSource(c.medium.optics.rgb, c.medium.optics.w, l);
    out[6 * i + 3] = float4(source, orbit_erf(c.extra.y));
    out[6 * i + 4] = orbit_gaussianLight(source, depth);
    out[6 * i + 5] = float4(orbit_smokeAmbient(lighting, d, c.medium.optics.w, c.ambient.rgb), orbit_gaussianTotal(r));
}

kernel void gaussianMedium_sizes(device uint *out [[buffer(0)]]) {
    out[0] = sizeof(GaussianMedium);
    out[1] = sizeof(GaussianMediumCheckCase);
}
"""#

extension ShaderModule {
    /// The Gaussian-medium header's check kernels (tests only; never drawn).
    public static let gaussianMediumCheck = ShaderModule(name: "GaussianMediumCheck",
                                                         headers: [.sphericalHarmonics, .gaussianMedium],
                                                         source: gaussianMediumCheckSource)
}
