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

// The inverse error function: Giles's single-precision approximation
// (GPU Computing Gems Jade, 2011), then two Newton steps on orbit_erf.
// GaussianMedium.erfInverse.
inline float orbit_erfInverse(float x) {
    x = clamp(x, -1.0 + 1e-6, 1.0 - 1e-6);
    float w = -log((1.0 - x) * (1.0 + x)), p;
    if (w < 5.0) {
        w -= 2.5;
        p = 2.81022636e-08;
        p = 3.43273939e-07 + p * w; p = -3.5233877e-06 + p * w; p = -4.39150654e-06 + p * w;
        p = 0.00021858087 + p * w; p = -0.00125372503 + p * w; p = -0.00417768164 + p * w;
        p = 0.246640727 + p * w; p = 1.50140941 + p * w;
    } else {
        w = sqrt(w) - 3.0;
        p = -0.000200214257;
        p = 0.000100950558 + p * w; p = 0.00134934322 + p * w; p = -0.00367342844 + p * w;
        p = 0.00573950773 + p * w; p = -0.0076224613 + p * w; p = 0.00943887047 + p * w;
        p = 1.00167406 + p * w; p = 2.83297682 + p * w;
    }
    float y = p * x;
    for (int i = 0; i < 2; i++) { y -= (orbit_erf(y) - x) / (1.128379167 * exp(-y * y)); }
    return y;
}

// The t past t0 where the depth from t0 reaches tau (inverting the depth):
// c + erfinv(erf((t0 - c)k) + tau / P) / k, k = 1/(sqrt2 w), P = peak w sqrt(pi/2).
inline float orbit_gaussianTimeAtDepth(GaussianRay r, float t0, float tau) {
    float k = 1.0 / (1.41421356 * r.width), p = r.peak * r.width * 1.25331414;
    if (p <= 0.0) { return t0; }
    float e = clamp(orbit_erf((t0 - r.centre) * k) + max(tau, 0.0) / p, -1.0 + 1e-6, 1.0 - 1e-6);
    return r.centre + orbit_erfInverse(e) / k;
}

// Where a segment t0...t1 is shaded with one source: midway between the
// depth exact for light falling as e^-tau from its entry (front-lit),
// -ln((1 + e^-T)/2), and the one exact for light rising as e^tau
// (back-lit), ln(T/(1 - e^-T)): within 0.3 % for either on segments of depth
// 0.25. Below depth 0.05 their mean's series, T/2 - T^2/12 + T^4/360 (the
// logarithms cancel in Float there). GaussianMedium.Ray.shadingTime.
// The depth into a segment of depth d its one source sits at (for a
// caller that walks the segments by their depths and so knows each one's).
// GaussianMedium.Ray.shadingDepth.
inline float orbit_gaussianShadingDepth(float d) {
    if (d <= 1e-9) { return 0.0; }
    return d < 0.05 ? d * (0.5 - d * (1.0 / 12.0 - d * d / 360.0))
                    : 0.5 * (-log(0.5 * (1.0 + exp(-d))) + log(d / (1.0 - exp(-d))));
}

inline float orbit_gaussianShadingTime(GaussianRay r, float t0, float t1) {
    float d = orbit_gaussianDepth(r, t0, t1);
    if (d <= 1e-9) { return clamp(r.centre, t0, t1); }
    return clamp(orbit_gaussianTimeAtDepth(r, t0, orbit_gaussianShadingDepth(d)), t0, t1);
}

// How many segments a chord of optical depth `depth` is shaded in: 0.25
// deep from the entry, at most 16; past depth 3.75 the first 12 stay 0.25
// deep and the last 4 split the rest evenly (lit from behind, light leaves
// every depth about alike). A caller walks them, boundary k at
// orbit_gaussianTimeAtDepth(r, t0, orbit_gaussianSegmentBoundary(k, n,
// depth)) (the exit t1 for the last), each lit with one source at its
// orbit_gaussianShadingTime.
#define ORBIT_GAUSSIAN_SEGMENT_DEPTH 0.25
#define ORBIT_GAUSSIAN_MAX_SEGMENTS 16
#define ORBIT_GAUSSIAN_EVEN_SEGMENTS 4
inline int orbit_gaussianSegments(float depth) {
    return clamp(int(ceil(max(depth, 0.0) / ORBIT_GAUSSIAN_SEGMENT_DEPTH)), 1, ORBIT_GAUSSIAN_MAX_SEGMENTS);
}

// The depth from the chord's entry of segment boundary k of n (with 16,
// the last 4 in equal parts). GaussianMedium.segmentBoundary.
inline float orbit_gaussianSegmentBoundary(int k, int n, float depth) {
    if (k >= n) { return depth; }
    int fixed = n >= ORBIT_GAUSSIAN_MAX_SEGMENTS ? n - ORBIT_GAUSSIAN_EVEN_SEGMENTS : n;
    if (k <= fixed) { return min(float(k) * ORBIT_GAUSSIAN_SEGMENT_DEPTH, depth); }
    float start = min(float(fixed) * ORBIT_GAUSSIAN_SEGMENT_DEPTH, depth);
    return start + (depth - start) * float(k - fixed) / float(n - fixed);
}

// The column the ambient lights a point p through along its unit axis
// (towards its up side): (the depth from p to the up side, the whole chord
// along the axis through p), both scaled by the body's own aspect along the
// axis, min(sigma) / the line's width, where under 1: an elongated body
// along the axis takes its skylight through its sides, and the scale
// depends on its shape alone, not on p or the axes' labels.
// GaussianMedium.ambientColumn.
inline float2 orbit_gaussianAmbientColumn(GaussianMedium g, float3 p, float3 axis) {
    GaussianRay r = orbit_gaussianRay(g, p, axis);
    float chord = orbit_gaussianTotal(r);
    if (chord <= 1e-12) { return float2(0.0); }
    float up = orbit_gaussianDepth(r, 0.0, r.centre + 10.0 * r.width + abs(r.centre));
    float scale = min(1.0, min(g.axisU.w, min(g.axisV.w, g.axisW.w)) / r.width);
    return float2(up, chord) * scale;
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
// smoke of single-scattering albedo w and asymmetry g, one g for every part
// and C2's two-stream (with absorption, its diffusivity 5/3 on absorption
// only) for all the light scattered many times: the Sun's beam entering
// its chord face-on, its single scattering by Henyey-Greenstein; the
// ambient as two fluxes along SH9's dominant axis, each entering the chord
// along it from its own side, its unscattered share swapped for SH9's
// in-scatter by the same phase. SmokeScattering, line for line.

#define ORBIT_SMOKE_PI 3.14159265
#define ORBIT_SMOKE_DIFFUSIVITY (5.0 / 3.0)

// Henyey and Greenstein, normalised over the sphere, of the cosine between
// the view ray (camera to point) and the direction to the Sun.
inline float orbit_smokePhase(float c, float g) {
    float d = 1.0 + g * g - 2.0 * g * c;
    return (1.0 - g * g) / (4.0 * ORBIT_SMOKE_PI * d * sqrt(d));
}

// (1 - e^-y)/y, its series where |y| < 1e-2.
inline float3 orbit_smokePhi(float3 y) {
    float3 series = 1.0 - y * (0.5 - y * (1.0 / 6.0 - y * (1.0 / 24.0 - y / 120.0)));
    return select((1.0 - exp(-y)) / select(y, float3(1.0), abs(y) < 1e-2), series, abs(y) < 1e-2);
}

struct SmokeStreams {
    float3 down;   // the downward flux, the direct beam's e^-t and the diffuse
    float3 up;
};

// The two-stream of a beam entering the top of a column of optical depth tau
// face-on, per unit flux, nothing its bottom, at depth t: Meador and Weaver
// with gamma1 = D(1 - w) + w b, gamma2 = w b, gamma3 = b, b = (1 - g)/2. The
// diffuse-incidence solution H, plus the beam's share past unit
// diffusivity, c = (D - 1)(1 - w), written so that its resonance at k = 1
// cancels. At w = 1 C2's cloud_streams exactly. SmokeScattering.streams.
inline SmokeStreams orbit_smokeStreams(float t, float tau, float3 w, float g) {
    tau = max(tau, 0.0);
    t = clamp(t, 0.0, tau);
    float u = tau - t, b = 0.5 * (1.0 - g);
    w = clamp(w, 0.0, 1.0);
    float3 a = ORBIT_SMOKE_DIFFUSIVITY * (1.0 - w);
    float3 g1 = a + w * b, g2 = w * b;
    float3 k = sqrt(a * (a + 2.0 * w * b));
    // E(x) = (1 - e^(-2kx))/k = 2x phi(2kx).
    float3 eTau = 2.0 * tau * orbit_smokePhi(2.0 * k * tau), eU = 2.0 * u * orbit_smokePhi(2.0 * k * u);
    float3 den = 1.0 + exp(-2.0 * k * tau) + g1 * eTau, down0 = exp(-k * t);
    SmokeStreams s;
    s.down = down0 * (1.0 + exp(-2.0 * k * u) + g1 * eU) / den;
    s.up = down0 * g2 * eU / den;
    float3 c = (ORBIT_SMOKE_DIFFUSIVITY - 1.0) * (1.0 - w);
    // e1(x) = (e^-x - e^-kx)/(k - 1) = e^-x x phi((k - 1) x).
    float3 km1 = k - 1.0;
    float3 e1t = select((exp(-t) - exp(-k * t)) / select(km1, float3(1.0), abs(km1 * t) < 1e-2),
                        exp(-t) * t * orbit_smokePhi(km1 * t), abs(km1 * t) < 1e-2);
    float3 e1tau = select((exp(-tau) - exp(-k * tau)) / select(km1, float3(1.0), abs(km1 * tau) < 1e-2),
                          exp(-tau) * tau * orbit_smokePhi(km1 * tau), abs(km1 * tau) < 1e-2);
    float3 rho = g2 / (g1 + k), ek = exp(-k * tau);
    float3 nearOne = (a + k) / (g1 + k) + rho * k * tau * orbit_smokePhi(k * tau);
    float3 q = c * (g2 * e1tau + rho * ek) / (k + 1.0);
    float3 aa = rho * ek * q / max(nearOne * (1.0 + rho * ek), float3(1e-30));
    float3 beta = -q - aa * rho * ek;
    float3 ekt = exp(-k * t), eku = exp(-k * u);
    s.down += c * (g1 + 1.0) * e1t / (k + 1.0) + aa * ekt + beta * rho * eku;
    s.up = max(s.up + c * (g2 * e1t + rho * ekt) / (k + 1.0) + aa * rho * ekt + beta * eku, float3(0.0));
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

// The ambient's light scattered towards the eye per unit albedo (cd/m2):
// E/pi `up` (from the side the axis points to) and `down`, through the
// chord along the axis (the point `depth` from the up side, `column` in
// all), seen at cosAxis (the view ray, camera to point, on the axis); the
// unscattered light the streams show, up (1 + c)/2 e^-t + down (1 - c)/2
// e^-(tau - t), swapped for `inScatter` shared between the sides in the
// same proportion, each carried through from its own side.
// SmokeScattering.ambientDiffuse.
inline float3 orbit_smokeAmbientDiffuse(float depth, float column, float cosAxis, float3 w, float g, float3 up,
                                        float3 down, float3 inScatter) {
    column = max(column, 0.0);
    depth = clamp(depth, 0.0, column);
    float c = clamp(cosAxis, -1.0, 1.0);
    SmokeStreams a = orbit_smokeStreams(depth, column, w, g);
    SmokeStreams b = orbit_smokeStreams(column - depth, column, w, g);
    float fromUp = exp(-depth), fromDown = exp(-(column - depth));
    float3 sideUp = ORBIT_SMOKE_PI * orbit_smokeStreamRadiance(a.down - fromUp, a.up, -c);
    float3 sideDown = ORBIT_SMOKE_PI * orbit_smokeStreamRadiance(b.down - fromDown, b.up, c);
    float3 wu = up * (0.5 * (1.0 + c)), wd = down * (0.5 * (1.0 - c));
    float3 unscattered = select(float3(0.5 * (1.0 + c) * fromUp + 0.5 * (1.0 - c) * fromDown),
                                (wu * fromUp + wd * fromDown) / max(wu + wd, float3(1e-30)), wu + wd > 1e-30);
    return up * sideUp + down * sideDown + inScatter * unscattered;
}

// What the caller knows of the light at the point.
struct SmokeLight {
    float3 sun;          // the Sun's illuminance on the smoke from outside it (lux), every other shadow applied
    float3 ambient;      // the ambient's in-scatter by the smoke's phase (cd/m2): orbit_smokeAmbient
    float3 ambientUp;    // E/pi along the ambient's axis, and against it (cd/m2)
    float3 ambientDown;
    float cosView;       // the view ray (camera to point) on the direction to the Sun
    float cosAxis;       // the view ray on the ambient's axis
    float sunDepth;      // the smoke's optical depth from the point to the Sun
    float sunChord;      // its whole optical depth along that line through the point
    float ambientDepth;  // the smoke's optical depth from the point along the axis (to its up side),
    float ambientChord;  // and its whole depth along that line: orbit_gaussianAmbientColumn
};

// J, cd/m2 per unit extinction: w (E (p e^-tauSun + D) + the ambient's).
inline float3 orbit_smokeSource(float3 albedo, float g, SmokeLight l) {
    float phase = orbit_smokePhase(l.cosView, g), direct = exp(-l.sunDepth);
    float3 diffuse = orbit_smokeSunDiffuse(l.sunDepth, l.sunChord, l.cosView, albedo, g);
    float3 ambient = orbit_smokeAmbientDiffuse(l.ambientDepth, l.ambientChord, l.cosAxis, albedo, g, l.ambientUp,
                                               l.ambientDown, l.ambient);
    return albedo * (l.sun * (phase * direct + diffuse) + ambient);
}

// The ambient as smoke takes it: SH9's in-scatter along the unit view ray v
// by Henyey-Greenstein of g (cd/m2, not pre-exposed), its dominant axis
// (the first band's luminance, towards the light; +z where it has none) and
// E/pi along and against it, when the probe is drawn (lighting.probe.w);
// else the caller's stand-in in every direction. Needs `.sphericalHarmonics`
// before this header. SmokeScattering.ambient.
struct SmokeAmbient {
    float3 inScatter;
    float3 up;
    float3 down;
    float3 axis;
};

inline SmokeAmbient orbit_smokeAmbient(constant LightingUniforms &lighting, float3 v, float g, float3 standIn) {
    SmokeAmbient a;
    if (lighting.probe.w <= 0.5) {
        a.inScatter = standIn;
        a.up = standIn;
        a.down = standIn;
        a.axis = float3(0.0, 0.0, 1.0);
        return a;
    }
    float3 lum = float3(0.2126, 0.7152, 0.0722);
    float3 dipole = float3(dot(lighting.sh9[3].rgb, lum), dot(lighting.sh9[1].rgb, lum), dot(lighting.sh9[2].rgb, lum));
    float l0 = abs(dot(lighting.sh9[0].rgb, lum));
    a.axis = length(dipole) > 1e-6 * max(l0, 1e-30) ? normalize(dipole) : float3(0.0, 0.0, 1.0);
    a.inScatter = orbit_sh9InScatter(lighting, v, g);
    a.up = orbit_sh9Irradiance(lighting, a.axis);
    a.down = orbit_sh9Irradiance(lighting, -a.axis);
    return a;
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
    float4 origin;       // xyz: the ray's origin (camera-relative, m), w: t0
    float4 direction;    // xyz: unit, w: t1
    float4 column;       // x: depth, y: column (optical depths), z: albedo (grey), w: g, for the streams
    float4 view;         // x: cosView, y: sunDepth, z: sunChord, w: ambientDepth
    float4 extra;        // x: ambientChord, y: the error function's argument, z: cosAxis, w: a depth to invert
    float4 sun;          // rgb: lux
    float4 ambient;      // rgb: the in-scatter (cd/m2), also the stand-in
    float4 ambientUp;    // rgb: E/pi along the axis
    float4 ambientDown;  // rgb: E/pi against it
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
    out[8 * i + 0] = float4(r.centre, r.width, r.peak, depth);
    out[8 * i + 1] = float4(box, orbit_gaussianBoxDepth(c.medium, o, d, t0, t1), orbit_gaussianShadingTime(r, t0, t1));
    SmokeStreams s = orbit_smokeStreams(c.column.x, c.column.y, float3(c.column.z), c.column.w);
    out[8 * i + 2] = float4(s.down.x, s.up.x,
                            orbit_smokeAmbientDiffuse(c.column.x, c.column.y, c.extra.z, float3(c.column.z), c.column.w,
                                                      c.ambientUp.rgb, c.ambientDown.rgb, c.ambient.rgb).x,
                            orbit_smokeSunDiffuse(c.column.x, c.column.y, c.view.x, float3(c.column.z), c.column.w).x);
    SmokeLight l;
    l.sun = c.sun.rgb;
    l.ambient = c.ambient.rgb;
    l.ambientUp = c.ambientUp.rgb;
    l.ambientDown = c.ambientDown.rgb;
    l.cosView = c.view.x;
    l.cosAxis = c.extra.z;
    l.sunDepth = c.view.y;
    l.sunChord = c.view.z;
    l.ambientDepth = c.view.w;
    l.ambientChord = c.extra.x;
    float3 source = orbit_smokeSource(c.medium.optics.rgb, c.medium.optics.w, l);
    out[8 * i + 3] = float4(source, orbit_erf(c.extra.y));
    out[8 * i + 4] = orbit_gaussianLight(source, depth);
    SmokeAmbient a = orbit_smokeAmbient(lighting, d, c.medium.optics.w, c.ambient.rgb);
    out[8 * i + 5] = float4(a.inScatter.x, a.up.x, a.down.x, orbit_gaussianTotal(r));
    out[8 * i + 6] = float4(orbit_gaussianTimeAtDepth(r, t0, c.extra.w), orbit_erfInverse(clamp(c.extra.y / 3.5, -0.99, 0.99)),
                            float(orbit_gaussianSegments(depth)), a.axis.z);
    int n = orbit_gaussianSegments(depth);
    out[8 * i + 7] = float4(orbit_gaussianAmbientColumn(c.medium, o + d * r.centre, normalize(c.ambientUp.xyz + float3(0.0, 0.0, 1e-3))),
                            orbit_gaussianSegmentBoundary(n - 1, n, depth), orbit_gaussianShadingTime(r, t0, t0 + 0.02 * r.width));
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
