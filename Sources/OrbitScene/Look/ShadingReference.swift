import Foundation
import OrbitCore

/// LightingCommon's shading of one fragment in Swift (no specular
/// anti-aliasing, which needs the fragment's neighbours): the reference
/// the GPU's output is checked against, and the furnace the shading path
/// must pass. One colour channel at a time; light in lux, radiance in
/// cd/m², before the pre-exposure.
public enum ShadingReference {
    /// The lobes at a fragment (LightingCommon's `OrbitShadingPoint`).
    public struct Point {
        public var n: Vec3
        public var v: Vec3
        public var nv: Double
        public var alpha: Double
        public var roughness: Double
        public var f0: Double
        public var diffuse: Double
        public var a: Double
        public var b: Double
        public var energy: Double
        public var specularWeight: Double
        public var diffuseWeight: Double
        public var diffuseLobe: Double
    }

    /// `orbit_shadingPoint` for one channel of `albedo`.
    public static func point(albedo: Double, metalness: Double, roughness: Double, reflectance: Double, n: Vec3,
                             v: Vec3, table: BRDF.DFGTable = BRDF.dfgTable, multipleScattering: Bool = true) -> Point {
        let r = min(max(roughness, BRDF.minimumRoughness), 1)
        let alpha = r * r
        let f0 = reflectance + (albedo - reflectance) * metalness
        let diffuse = albedo * (1 - metalness)
        let nv = min(max(n.dot(v), 1e-4), 1)
        let t = table.lookup(nv: nv, roughness: alpha.squareRoot())
        let ess = t.a + t.b, fssEss = f0 * t.a + t.b
        var multiple = 0.0, energy = 1.0
        if multipleScattering && ess > 1e-3 {
            let w = BRDF.environmentWeights(f0: f0, albedo: 0, a: t.a, b: t.b)
            multiple = w.multiple
            energy = BRDF.energyCompensation(f0: f0, a: t.a, b: t.b)
        }
        let left = min(max(1 - fssEss - multiple, 0), 1)
        return Point(n: n, v: v, nv: nv, alpha: alpha, roughness: alpha.squareRoot(), f0: f0, diffuse: diffuse,
                     a: t.a, b: t.b, energy: energy, specularWeight: fssEss, diffuseWeight: multiple + diffuse * left,
                     diffuseLobe: diffuse * left)
    }

    /// `orbit_light`: radiance from illuminance `e` from `l`, the specular
    /// lobe lit from `lSpecular` with `normalization`.
    public static func light(_ p: Point, l: Vec3, lSpecular: Vec3, normalization: Double, e: Double) -> Double {
        let nl = max(0, p.n.dot(l))
        let h = (p.v + lSpecular).normalized
        let nls = max(0, p.n.dot(lSpecular))
        let specular = BRDF.ggx(nh: max(0, p.n.dot(h)), alpha: p.alpha) * normalization
            * BRDF.visibility(nv: p.nv, nl: max(nls, 1e-9), alpha: p.alpha) * BRDF.schlick(f0: p.f0, vh: p.v.dot(h))
            * p.energy * nls
        return e * (p.diffuseLobe * nl / Double.pi + specular)
    }

    /// `orbit_sunLight`: the Sun's disc of angular radius `rho` about `toSun`.
    public static func sun(_ p: Point, toSun: Vec3, rho: Double, disc: Bool = true, e: Double) -> Double {
        guard disc else { return light(p, l: toSun, lSpecular: toSun, normalization: 1, e: e) }
        let r = p.n * (2 * p.n.dot(p.v)) - p.v
        let ls = BRDF.sunDiscDirection(sun: toSun, reflection: r, cosAngularRadius: cos(rho), sinAngularRadius: sin(rho))
        return light(p, l: toSun, lSpecular: ls,
                     normalization: BRDF.sunDiscNormalization(alpha: p.alpha, sinAngularRadius: sin(rho)), e: e)
    }

    /// `orbit_environmentLight` without a probe: a body's disc of
    /// `bodyRadiance` (sin² of its angular radius `bodySinSigma2`, towards
    /// `bodyDirection`) and a uniform irradiance `uniform` (lux), with
    /// ambient occlusion `ao`.
    public static func environment(_ p: Point, ao: Double = 1, bodyDirection: Vec3 = .zero, bodySinSigma2: Double = 0,
                                   bodyRadiance: Double = 0, uniform: Double) -> Double {
        let r = p.n * (2 * p.n.dot(p.v)) - p.v
        let u = uniform / Double.pi
        var bodyN = 0.0, bodyR = 0.0, inside = 0.0
        if bodySinSigma2 > 0 {
            bodyN = bodyRadiance * BRDF.sphereIrradiance(cosTheta: p.n.dot(bodyDirection), sinSigma2: bodySinSigma2)
                / Double.pi
            bodyR = bodyRadiance * BRDF.sphereIrradiance(cosTheta: r.dot(bodyDirection), sinSigma2: bodySinSigma2)
                / Double.pi
            let sigma = asin(min(bodySinSigma2, 1).squareRoot())
            let angle = acos(max(-1, min(1, r.dot(bodyDirection))))
            let w = 0.02 + p.alpha
            inside = 1 - smoothstep(sigma - w, sigma + w, angle)
        }
        let irradianceOverPi = bodyN + u
        let sharp = bodyRadiance * inside + u
        let t = min(max(p.alpha, 0), 1)
        let prefiltered = sharp + (bodyR + u - sharp) * t
        let so = min(max(pow(p.nv + ao, exp2(-16 * p.alpha - 1)) - 1 + ao, 0), 1)
        return prefiltered * p.specularWeight * so + irradianceOverPi * p.diffuseWeight * ao
    }

    /// MSL's smoothstep.
    static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
