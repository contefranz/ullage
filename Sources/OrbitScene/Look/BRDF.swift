import Foundation
import OrbitCore

/// The surface reflectance the renderer shades with (track R2), in pure
/// Swift: the reference the shaders (LightingCommon) mirror, and the bake of
/// the split-sum DFG table they sample.
///
/// - **Diffuse:** Lambert, albedo/π.
/// - **Specular:** the Cook-Torrance microfacet BRDF D·G2·F / (4 n·v n·l)
///   with the GGX (Trowbridge-Reitz) distribution, Smith's
///   height-correlated masking-shadowing (Heitz 2014, eq. 99) and Schlick's
///   Fresnel (Schlick 1994).
/// - **Roughness:** materials give a perceptual roughness r in 0...1; the
///   distribution's α is r² (Burley 2012; Karis 2013). The lighting clamps r
///   at `minimumRoughness`, where single precision still holds the
///   distribution's peak.
/// - **Multiple scattering:** single scattering loses energy at high
///   roughness. The table's directional albedo Ess = A + B restores it:
///   for an environment as Fdez-Agüera (2019) composes it
///   (`environmentWeights`), for a light by Kulla and Conty's factor
///   1 + F0 (1/Ess - 1) as Filament applies it (`energyCompensation`).
/// - **Specular anti-aliasing:** Tokuyoshi and Kaplanyan's NDF filtering
///   widens α² by the normal's variation over the pixel (`filteredAlpha2`).
/// - **The Sun's disc** is an area light for the specular lobe: Karis'
///   representative point and normalisation (`sunDiscNormalization`).
public enum BRDF {
    /// The smallest perceptual roughness the lighting uses (α = 0.002):
    /// Filament's single-precision floor.
    public static let minimumRoughness = 0.045

    /// α from a perceptual roughness, clamped at `minimumRoughness`.
    public static func alpha(roughness r: Double) -> Double {
        let c = min(max(r, minimumRoughness), 1)
        return c * c
    }

    // MARK: Lobes

    /// Lambert's diffuse BRDF for `albedo`.
    public static func lambert(albedo: Double) -> Double { albedo / Double.pi }

    /// The GGX distribution of normals at n·h = `nh`: α² / (π ((n·h)² (α² - 1) + 1)²)
    /// (Walter et al. 2007, eq. 33). Its projected area integrates to 1.
    public static func ggx(nh: Double, alpha: Double) -> Double {
        guard nh > 0 else { return 0 }
        let a2 = alpha * alpha
        let d = nh * nh * (a2 - 1) + 1
        return a2 / (Double.pi * d * d)
    }

    /// Smith's Λ for GGX at cos θ = `cosine` from the normal:
    /// (-1 + √(1 + α² tan² θ)) / 2 (Heitz 2014, eq. 86).
    public static func smithLambda(cosine mu: Double, alpha: Double) -> Double {
        let c = max(mu, 1e-9)
        let tan2 = max(0, 1 - c * c) / (c * c)
        return 0.5 * (-1 + (1 + alpha * alpha * tan2).squareRoot())
    }

    /// Smith's masking 1 / (1 + Λ) (Heitz 2014, eq. 43).
    public static func smithG1(cosine mu: Double, alpha: Double) -> Double {
        1 / (1 + smithLambda(cosine: mu, alpha: alpha))
    }

    /// Height-correlated masking-shadowing 1 / (1 + Λ(v) + Λ(l)) (Heitz
    /// 2014, eq. 99), for a light and a view on the normal's side.
    public static func smithG2(nv: Double, nl: Double, alpha: Double) -> Double {
        guard nv > 0, nl > 0 else { return 0 }
        return 1 / (1 + smithLambda(cosine: nv, alpha: alpha) + smithLambda(cosine: nl, alpha: alpha))
    }

    /// The visibility term G2 / (4 n·v n·l), in the form the shaders use
    /// (Lagarde and de Rousiers 2014, listing 2):
    /// 0.5 / (n·l √((n·v)² (1 - α²) + α²) + n·v √((n·l)² (1 - α²) + α²)).
    public static func visibility(nv: Double, nl: Double, alpha: Double) -> Double {
        guard nv > 0, nl > 0 else { return 0 }
        let a2 = alpha * alpha
        let gv = nl * (nv * nv * (1 - a2) + a2).squareRoot()
        let gl = nv * (nl * nl * (1 - a2) + a2).squareRoot()
        return 0.5 / (gv + gl)
    }

    /// Schlick's Fresnel F0 + (f90 - F0) (1 - v·h)⁵.
    public static func schlick(f0: Double, f90: Double = 1, vh: Double) -> Double {
        let m = 1 - min(max(vh, 0), 1)
        let m2 = m * m
        return f0 + (f90 - f0) * m2 * m2 * m
    }

    /// The specular BRDF (1/sr) for unit `n`, `v`, `l` and reflectance at
    /// normal incidence `f0`: D G2 F / (4 n·v n·l), single scattering.
    public static func specular(n: Vec3, v: Vec3, l: Vec3, alpha: Double, f0: Double) -> Double {
        let nv = n.dot(v), nl = n.dot(l)
        guard nv > 0, nl > 0 else { return 0 }
        let h = (v + l).normalized
        return ggx(nh: n.dot(h), alpha: alpha) * visibility(nv: nv, nl: nl, alpha: alpha) * schlick(f0: f0, vh: v.dot(h))
    }

    /// The reflectance at normal incidence of a conductor of complex
    /// refractive index n + ik in air: ((n - 1)² + k²) / ((n + 1)² + k²).
    public static func normalIncidenceReflectance(n: Double, k: Double) -> Double {
        ((n - 1) * (n - 1) + k * k) / ((n + 1) * (n + 1) + k * k)
    }

    // MARK: Split-sum DFG

    /// The split-sum terms at n·v = `nv` and `alpha`: the specular lobe's
    /// directional albedo is F0·A + B, with A = ∫ f/F (1 - Fc) cos and
    /// B = ∫ f/F Fc cos over the hemisphere, Fc = (1 - v·h)⁵ (Karis 2013,
    /// eq. 8). Estimated with `samples` points of a Hammersley set through
    /// Heitz's (2018) sampling of the visible normals, whose weight for
    /// f cos / pdf is F G2 / G1(v).
    public static func dfg(nv: Double, alpha: Double, samples: Int = 512) -> (a: Double, b: Double) {
        let mu = min(max(nv, 1e-4), 1)
        let v = Vec3((1 - mu * mu).squareRoot(), 0, mu)
        let g1v = smithG1(cosine: mu, alpha: alpha)
        var a = 0.0, b = 0.0
        for i in 0..<samples {
            let u1 = (Double(i) + 0.5) / Double(samples), u2 = radicalInverse(UInt32(i))
            let h = sampleVisibleNormal(v, alpha: alpha, u1, u2)
            let vh = v.dot(h)
            let l = h * (2 * vh) - v
            guard l.z > 0, vh > 0 else { continue }
            let w = smithG2(nv: mu, nl: l.z, alpha: alpha) / g1v
            let m = 1 - vh, m2 = m * m, fc = m2 * m2 * m
            a += (1 - fc) * w
            b += fc * w
        }
        return (a / Double(samples), b / Double(samples))
    }

    /// A normal of the GGX distribution seen from `v` (tangent space, z the
    /// normal), from two uniform numbers (Heitz 2018, listing 1, isotropic).
    static func sampleVisibleNormal(_ v: Vec3, alpha: Double, _ u1: Double, _ u2: Double) -> Vec3 {
        let vh = Vec3(alpha * v.x, alpha * v.y, v.z).normalized
        let lensq = vh.x * vh.x + vh.y * vh.y
        let t1 = lensq > 0 ? Vec3(-vh.y, vh.x, 0) * (1 / lensq.squareRoot()) : Vec3(1, 0, 0)
        let t2 = vh.cross(t1)
        let r = u1.squareRoot(), phi = 2 * Double.pi * u2
        let p1 = r * cos(phi)
        var p2 = r * sin(phi)
        let s = 0.5 * (1 + vh.z)
        p2 = (1 - s) * (1 - p1 * p1).squareRoot() + s * p2
        let nh = t1 * p1 + t2 * p2 + vh * max(0, 1 - p1 * p1 - p2 * p2).squareRoot()
        return Vec3(alpha * nh.x, alpha * nh.y, max(0, nh.z)).normalized
    }

    /// Van der Corput's base-2 radical inverse.
    static func radicalInverse(_ k: UInt32) -> Double {
        var bits = k
        bits = (bits << 16) | (bits >> 16)
        bits = ((bits & 0x5555_5555) << 1) | ((bits & 0xAAAA_AAAA) >> 1)
        bits = ((bits & 0x3333_3333) << 2) | ((bits & 0xCCCC_CCCC) >> 2)
        bits = ((bits & 0x0F0F_0F0F) << 4) | ((bits & 0xF0F0_F0F0) >> 4)
        bits = ((bits & 0x00FF_00FF) << 8) | ((bits & 0xFF00_FF00) >> 8)
        return Double(bits) * 0x1p-32
    }

    /// The DFG table the shaders sample (texture 22, rg): `size` × `size`
    /// texels, n·v along x and perceptual roughness along y, texel i at
    /// i / (size - 1), so that the first and last texels sit on 0 and 1
    /// exactly (a table of texel-centred samples would stop at 0.992 and
    /// read α = 1 3 % high). The shader reads it at
    /// (x (size - 1) + 0.5) / size (`orbit_dfg`). Red is A, green B.
    public struct DFGTable {
        public let size: Int
        /// Row-major from roughness 0, (A, B) per texel.
        public let values: [Float]

        /// A and B at the texel (`i` along n·v, `j` along roughness).
        public func texel(_ i: Int, _ j: Int) -> (a: Double, b: Double) {
            let k = 2 * (j * size + i)
            return (Double(values[k]), Double(values[k + 1]))
        }

        /// A and B at (`nv`, `roughness`) as the GPU's bilinear sampler
        /// reads them.
        public func lookup(nv: Double, roughness: Double) -> (a: Double, b: Double) {
            let n = Double(size - 1)
            let x = min(max(nv, 0), 1) * n, y = min(max(roughness, 0), 1) * n
            let i0 = Int(x), j0 = Int(y), i1 = min(i0 + 1, size - 1), j1 = min(j0 + 1, size - 1)
            let fx = x - Double(i0), fy = y - Double(j0)
            func mix(_ p: (a: Double, b: Double), _ q: (a: Double, b: Double), _ t: Double) -> (a: Double, b: Double) {
                (p.a + (q.a - p.a) * t, p.b + (q.b - p.b) * t)
            }
            return mix(mix(texel(i0, j0), texel(i1, j0), fx), mix(texel(i0, j1), texel(i1, j1), fx), fy)
        }
    }

    /// The table's default size, 64² (design-renderer-core §5).
    public static let dfgTableSize = 64

    /// Bakes the DFG table: each texel's (A, B), roughness unclamped (α =
    /// r², so the first row is a mirror's), spread over the cores. About
    /// 0.1 s at -O on an M3 Pro.
    public static func bakeDFG(size: Int = dfgTableSize, samples: Int = 512) -> DFGTable {
        var values = [Float](repeating: 0, count: 2 * size * size)
        values.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: size) { j in
                let r = Double(j) / Double(size - 1)
                for i in 0..<size {
                    let nv = Double(i) / Double(size - 1)
                    let t = dfg(nv: nv, alpha: r * r, samples: samples)
                    out[2 * (j * size + i)] = Float(t.a)
                    out[2 * (j * size + i) + 1] = Float(t.b)
                }
            }
        }
        return DFGTable(size: size, values: values)
    }

    /// The bake every renderer shares, made once.
    public static let dfgTable = bakeDFG()

    // MARK: Multiple scattering

    /// The factor multiplying a light's single-scattering specular so that
    /// it keeps the energy multiple scattering would (Kulla and Conty 2017,
    /// as Filament applies it): 1 + F0 (1 / Ess - 1), Ess = A + B.
    public static func energyCompensation(f0: Double, a: Double, b: Double) -> Double {
        1 + f0 * (1 / max(a + b, 1e-4) - 1)
    }

    /// Fdez-Agüera's (2019, listing 3) split of an environment's light,
    /// for reflectance `f0`, diffuse `albedo` and the table's A and B: the
    /// prefiltered radiance is weighted by `specular` (FssEss = F0 A + B),
    /// the cosine-weighted irradiance over π by `multiple` (Fms Ems, the
    /// specular's multiple scattering) plus `diffuse` (the albedo times
    /// what the specular leaves, 1 - FssEss - Fms Ems). In a white furnace
    /// the three sum to 1 when `albedo` is 1.
    public static func environmentWeights(f0: Double, albedo: Double, a: Double, b: Double)
        -> (specular: Double, multiple: Double, diffuse: Double) {
        let fssEss = f0 * a + b
        let ess = a + b, ems = 1 - ess
        let fAvg = f0 + (1 - f0) / 21
        let fms = fssEss * fAvg / (1 - ems * fAvg)
        let edss = 1 - (fssEss + fms * ems)
        return (fssEss, fms * ems, albedo * edss)
    }

    // MARK: Anti-aliasing

    /// Tokuyoshi and Kaplanyan's conservative isotropic NDF filtering
    /// (JCGT 10(2), 2021, listing 5): α² widened by the shading normal's
    /// change across the pixel, 2σ² (|∂n/∂x|² + |∂n/∂y|²) with σ² = 1/(2π),
    /// clamped at κ = 0.18.
    public static func filteredAlpha2(_ alpha2: Double, normalDerivatives d2: Double) -> Double {
        let kernel = 2 * specularAAVariance * d2
        return min(max(alpha2 + min(kernel, specularAAClamp), 0), 1)
    }

    /// σ² and κ of `filteredAlpha2`.
    public static let specularAAVariance = 1 / (2 * Double.pi)
    public static let specularAAClamp = 0.18

    // MARK: The Sun's disc

    /// Karis' (2013) normalisation of a sphere light's representative-point
    /// specular, (α / α')² with α' = saturate(α + sin ρ / 3) (eqs. 10, 14),
    /// for a distant disc of angular radius ρ (`sinAngularRadius` = sin ρ).
    public static func sunDiscNormalization(alpha: Double, sinAngularRadius s: Double) -> Double {
        let widened = min(alpha + s / 3, 1)
        return (alpha / widened) * (alpha / widened)
    }

    /// The direction within a disc of angular radius ρ about the unit `sun`
    /// closest to the unit reflection `r`: `r` itself inside the disc, else
    /// `sun` turned towards `r` by ρ (Karis' representative point, eq. 11,
    /// for a light at infinity, in Filament's exact form).
    public static func sunDiscDirection(sun: Vec3, reflection r: Vec3, cosAngularRadius c: Double,
                                        sinAngularRadius s: Double) -> Vec3 {
        let lr = sun.dot(r)
        guard lr < c else { return r }
        let across = r - sun * lr
        let d = across.length
        guard d > 1e-12 else { return sun }
        return (sun * c + across * (s / d)).normalized
    }

    // MARK: A sphere's irradiance

    /// π times the view factor from a surface element to a sphere of
    /// angular radius σ (sin²σ = `sinSigma2`) whose centre is at cos θ =
    /// `cosTheta` from its normal, horizon included: the irradiance from a
    /// sphere of unit radiance (Lagarde and de Rousiers 2014, listing 7,
    /// after Snyder 1996). It is π sin²σ cos θ while the whole sphere is
    /// above the horizon (Howell's factor for a sphere fully seen), and 0
    /// once θ > 90° + σ.
    public static func sphereIrradiance(cosTheta: Double, sinSigma2: Double) -> Double {
        let s2 = min(max(sinSigma2, 1e-12), 1)
        let c = min(max(cosTheta, -1), 1)
        if c * c >= s2 { return Double.pi * s2 * max(c, 0) }
        let sinTheta = (1 - c * c).squareRoot()
        let x = (1 / s2 - 1).squareRoot()
        let y = min(max(-x * (c / max(sinTheta, 1e-12)), -1), 1)
        let sinThetaSqrtY = sinTheta * (1 - y * y).squareRoot()
        let e = (c * acos(y) - x * sinThetaSqrtY) * s2 + atan(sinThetaSqrtY / max(x, 1e-12))
        return max(e, 0)
    }
}
