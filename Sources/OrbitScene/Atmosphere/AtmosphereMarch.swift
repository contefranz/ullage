import Foundation
import OrbitCore

/// The renderer's march through the air (AtmosphereCommon's `atmo_march`)
/// in Swift and double precision: the reference the GPU is tested against,
/// and the light of any ray for the tests of the sky itself.
///
/// Along a ray in the planet's figure coordinates, from `origin` (relative
/// to the centre) in unit `direction`, over [t0, t1]: single scattering of
/// the Sun's light through the Rayleigh and aerosol phase functions, the
/// Sun's transmittance from A1's table (zero in the planet's shadow), plus
/// σs·Ψ_ms, each step's attenuation integrated exactly; steps crowded
/// quadratically toward the ray's lowest point. Per unit solar irradiance.
/// It is A1's `AtmosphereLUT.march` on a ray given in space rather than by
/// (r, μ), cut at any distance: the aerial perspective to a point.
public enum AtmosphereMarch {
    public struct Result: Equatable {
        /// In-scattered radiance, 1/sr per unit solar irradiance.
        public var radiance = Spectrum3.zero
        public var transmittance = Spectrum3.one
    }

    /// Where the ray is in the air, up to the ground: (t0, t1, ends on the
    /// ground), nil if it never is.
    public static func airSegment(origin o: Vec3, direction d: Vec3, bottomRadius rb: Double,
                                  topRadius rt: Double) -> (t0: Double, t1: Double, ground: Bool)? {
        guard let top = sphere(origin: o, direction: d, radius: rt), top.far > 0 else { return nil }
        let t0 = max(top.near, 0)
        if let g = sphere(origin: o, direction: d, radius: rb), g.far > 0 {
            return (t0, max(g.near, 0), true)
        }
        return (t0, top.far, false)
    }

    /// Distances along the line to a sphere about the origin, nil if it misses.
    public static func sphere(origin o: Vec3, direction d: Vec3, radius r: Double) -> (near: Double, far: Double)? {
        let tca = -o.dot(d)
        let ca = o.cross(d).length
        guard ca <= r else { return nil }
        let half = max(0, (r - ca) * (r + ca)).squareRoot()
        return (tca - half, tca + half)
    }

    /// The march over [t0, t1] in `steps` steps; `sun` is a unit vector in
    /// figure coordinates and `nu` the cosine between the view ray and the
    /// Sun (world).
    public static func march(_ lut: AtmosphereLUT, origin o: Vec3, direction d: Vec3, from t0: Double, to t1: Double,
                             steps: Int, sun: Vec3, cosView nu: Double) -> Result {
        var m = Result()
        guard t1 > t0, steps > 0 else { return m }
        let rp = OpticalAtmosphere.rayleighPhase(cosTheta: nu), mp = lut.optics.aerosolPhase(cosTheta: nu)
        let tca = min(max(-o.dot(d), t0), t1)
        let l1 = tca - t0, l2 = t1 - tca
        let n1 = l1 > 0 ? min(max(Int((Double(steps) * l1 / (l1 + l2)).rounded()), 1), steps) : 0
        let n2 = l2 > 0 ? max(steps - n1, 1) : 0
        var previous = t0
        if n1 > 0 {
            for k in 1...n1 {
                let x = 1 - Double(k) / Double(n1)
                let t = tca - l1 * x * x
                step(&m, lut, o, d, previous, t, sun, rp, mp)
                previous = t
            }
        }
        if n2 > 0 {
            for k in 1...n2 {
                let x = Double(k) / Double(n2)
                let t = tca + l2 * x * x
                step(&m, lut, o, d, previous, t, sun, rp, mp)
                previous = t
            }
        }
        return m
    }

    /// One step over [ta, tb], at its midpoint (`atmo_step`).
    public static func step(_ m: inout Result, _ lut: AtmosphereLUT, _ o: Vec3, _ d: Vec3, _ ta: Double, _ tb: Double,
                            _ sun: Vec3, _ rayleighPhase: Double, _ aerosolPhase: Double) {
        let dt = tb - ta
        guard dt > 0 else { return }
        let p = o + d * (ta + 0.5 * dt)
        let r = p.length
        let medium = lut.optics.medium(altitude: r - lut.bottomRadius)
        let muS = min(max(p.dot(sun) / r, -1), 1)
        let tSun = lut.transmittanceToSun(radius: max(r, lut.bottomRadius), cosSun: muS)
        let psi = lut.multipleScattering(radius: r, cosSun: muS)
        let source = tSun * (medium.rayleighScattering * rayleighPhase + medium.aerosolScattering * aerosolPhase)
            + psi * medium.scattering
        let ext = medium.extinction
        let stepT = (ext * dt).attenuation
        func integral(_ sigma: Double, _ t: Double) -> Double {
            sigma * dt < 1e-3 ? dt * (1 - 0.5 * sigma * dt) : (1 - t) / sigma
        }
        m.radiance += m.transmittance * source
            * Spectrum3(integral(ext.r, stepT.r), integral(ext.g, stepT.g), integral(ext.b, stepT.b))
        m.transmittance *= stepT
    }

    /// The light of the ray from `origin` along `direction` through all the
    /// air to the ground or out of the top: the sky (with the ground not
    /// added), or the aerial perspective to the ground.
    public static func sky(_ lut: AtmosphereLUT, origin o: Vec3, direction d: Vec3, steps: Int, sun: Vec3,
                           cosView nu: Double) -> Result {
        guard let s = airSegment(origin: o, direction: d, bottomRadius: lut.bottomRadius,
                                 topRadius: lut.topRadius) else { return Result() }
        return march(lut, origin: o, direction: d, from: s.t0, to: s.t1, steps: steps, sun: sun, cosView: nu)
    }

    /// The froxels' value at slice `slice` of `slices` along a ray (the
    /// atmosphere module's `atmosphere_froxels`): the march from the camera
    /// to the slice's distance, within the air.
    public static func froxel(_ lut: AtmosphereLUT, origin o: Vec3, direction d: Vec3, slices: FroxelSlices,
                              slice: Int, steps: Int, sun: Vec3, cosView nu: Double) -> Result {
        guard let seg = airSegment(origin: o, direction: d, bottomRadius: lut.bottomRadius,
                                   topRadius: lut.topRadius) else { return Result() }
        return march(lut, origin: o, direction: d, from: seg.t0, to: min(slices.distance(slice: slice), seg.t1),
                     steps: steps, sun: sun, cosView: nu)
    }

    /// The haze over the ground seen from space (`atmosphere_spaceGround`):
    /// the march to where the ray meets the ground, or, if it misses it, to
    /// its closest approach to the planet.
    public static func spaceGround(_ lut: AtmosphereLUT, origin o: Vec3, direction d: Vec3, steps: Int, sun: Vec3,
                                   cosView nu: Double) -> Result {
        guard let seg = airSegment(origin: o, direction: d, bottomRadius: lut.bottomRadius,
                                   topRadius: lut.topRadius) else { return Result() }
        let end = seg.ground ? seg.t1 : min(seg.t1, max(-o.dot(d), seg.t0))
        return march(lut, origin: o, direction: d, from: seg.t0, to: end, steps: steps, sun: sun, cosView: nu)
    }
}
