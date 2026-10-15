import Foundation

/// How a body's body-fixed frame is oriented in ICRF.
public enum RotationModel {
    /// Earth: IAU 1976 precession + GMST (IAU 1982). Nutation and polar motion
    /// are ignored (errors below ~20 arcsec).
    case earth
    /// Moon: DE421 principal-axis libration from the ephemeris, rotated into the
    /// mean-Earth/polar-axis (ME) frame used for lunar coordinates.
    case moonDE421
    /// IAU/WGCCRE-style uniform rotation: pole RA/Dec (rad) and prime meridian
    /// W0 (rad) + rate (rad/s) measured from J2000 TDB.
    case uniform(poleRA: Double, poleDec: Double, w0: Double, rate: Double)
    /// No rotation (body frame == ICRF).
    case none
}

public struct BodyOrientation {
    /// ICRF -> body-fixed rotation matrix.
    public let icrfToBody: Mat3
    /// Angular velocity of the body-fixed frame, expressed in ICRF (rad/s).
    public let angularVelocity: Vec3
    /// The rotation pole (body +Z) in ICRF.
    public var pole: Vec3 { icrfToBody.r2 }

    public func toBody(_ v: Vec3) -> Vec3 { icrfToBody * v }
    public func toInertial(_ v: Vec3) -> Vec3 { icrfToBody.transposed * v }
}

public final class CelestialBody: Identifiable, CustomStringConvertible {
    public let id: Int              // NAIF id
    public let name: String
    public let gm: Double           // m^3/s^2
    public let radius: Double       // mean / equatorial radius, m
    public var j2: Double           // unnormalised zonal harmonic (var so tests can switch it off)
    public let rotation: RotationModel
    public let atmosphere: Atmosphere?
    /// Sphere-of-influence radius (m) used to choose a vessel's reference body.
    public let soiRadius: Double
    /// Parent body for the SOI hierarchy (nil for the Sun).
    public weak var parent: CelestialBody?

    public init(id: Int, name: String, gm: Double, radius: Double, j2: Double = 0,
                rotation: RotationModel, atmosphere: Atmosphere? = nil, soiRadius: Double) {
        self.id = id; self.name = name; self.gm = gm; self.radius = radius; self.j2 = j2
        self.rotation = rotation; self.atmosphere = atmosphere; self.soiRadius = soiRadius
    }

    public var description: String { name }

    // MARK: Gravity

    /// Gravitational acceleration at `r` (m, ICRF, relative to the body centre),
    /// including the J2 oblateness term about `pole`.
    public func gravity(at r: Vec3, pole: Vec3) -> Vec3 {
        let r2 = r.lengthSquared
        let rn = r2.squareRoot()
        var a = r * (-gm / (r2 * rn))
        if j2 != 0 {
            let zc = r.dot(pole)
            let k = -1.5 * j2 * gm * radius * radius / (r2 * r2 * rn)
            a += (r * (1 - 5 * zc * zc / r2) + pole * (2 * zc)) * k
        }
        return a
    }
}

// MARK: - Orientation

public enum EarthOrientation {
    /// IAU 1976 precession matrix, J2000 mean equator -> mean equator of date.
    public static func precession(centuries t: Double) -> Mat3 {
        let as2r = Double.pi / (180 * 3600)
        let zeta = (2306.2181 * t + 0.30188 * t * t + 0.017998 * t * t * t) * as2r
        let z = (2306.2181 * t + 1.09468 * t * t + 0.018203 * t * t * t) * as2r
        let theta = (2004.3109 * t - 0.42665 * t * t - 0.041833 * t * t * t) * as2r
        return Mat3.frameZ(-z) * Mat3.frameY(theta) * Mat3.frameZ(-zeta)
    }

    /// Greenwich mean sidereal time (rad), IAU 1982, from a UT1 Julian date.
    public static func gmst(julianDateUT1 jd: Double) -> Double {
        let t = (jd - 2451545.0) / 36525
        var seconds = 67310.54841 + (876600 * 3600 + 8640184.812866) * t + 0.093104 * t * t - 6.2e-6 * t * t * t
        seconds = seconds.truncatingRemainder(dividingBy: 86400)
        if seconds < 0 { seconds += 86400 }
        return seconds / 86400 * 2 * Double.pi
    }

    /// Mean sidereal rotation rate (rad/s).
    public static let rotationRate = 7.292115146706979e-5
}

extension CelestialBody {
    public func orientation(at t: Epoch, ephemeris: ChebyshevEphemeris) -> BodyOrientation {
        switch rotation {
        case .earth:
            let p = EarthOrientation.precession(centuries: t.centuriesTDB)
            let gmst = EarthOrientation.gmst(julianDateUT1: t.julianDateUT1)
            let m = Mat3.frameZ(gmst) * p
            // Angular velocity along the true-of-date pole, expressed in ICRF.
            return BodyOrientation(icrfToBody: m, angularVelocity: m.r2 * EarthOrientation.rotationRate)
        case .moonDE421:
            let (pa, omega) = ephemeris.lunarPrincipalAxes(at: t)
            return BodyOrientation(icrfToBody: MoonFrames.paToME * pa, angularVelocity: omega)
        case let .uniform(ra, dec, w0, rate):
            let w = w0 + rate * t.tdb
            let m = Mat3.frameZ(w) * Mat3.frameX(Double.pi / 2 - dec) * Mat3.frameZ(ra + Double.pi / 2)
            return BodyOrientation(icrfToBody: m, angularVelocity: m.r2 * rate)
        case .none:
            return BodyOrientation(icrfToBody: .identity, angularVelocity: .zero)
        }
    }
}

public enum MoonFrames {
    /// MOON_PA_DE421 -> MOON_ME_DE421 constant rotation (NAIF moon_080317.tf).
    public static let paToME: Mat3 = {
        let as2r = Double.pi / (180 * 3600)
        return Mat3.rotX(0.30 * as2r) * Mat3.rotY(78.56 * as2r) * Mat3.rotZ(67.92 * as2r)
    }()
}
