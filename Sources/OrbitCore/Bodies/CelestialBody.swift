import Foundation

/// How a body's body-fixed frame is oriented in ICRF.
public enum RotationModel {
    /// Earth: IAU 2006 precession and frame bias, IAU 2000B nutation and
    /// apparent sidereal time on UT1 (`EarthOrientation`). The body frame is
    /// the CIP's: polar motion is not modelled (8.5 m at the surface on
    /// 16 July 1969).
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
    public let radius: Double       // mean / equatorial radius, m; J2's reference radius
    public var j2: Double           // unnormalised zonal harmonic (var so tests can switch it off)
    /// The surface: altitude, latitude and the vertical are geodetic on it.
    /// A sphere of `radius` unless given.
    public let figure: Ellipsoid
    public let rotation: RotationModel
    public let atmosphere: Atmosphere?
    /// Sphere-of-influence radius (m) used to choose a vessel's reference body.
    public let soiRadius: Double
    /// Parent body for the SOI hierarchy (nil for the Sun).
    public weak var parent: CelestialBody?
    /// The Earth's precession and nutation, evaluated every 10 minutes.
    let precessionNutation = EarthOrientation.PrecessionNutation.Cache()

    public init(id: Int, name: String, gm: Double, radius: Double, j2: Double = 0, figure: Ellipsoid? = nil,
                rotation: RotationModel, atmosphere: Atmosphere? = nil, soiRadius: Double) {
        self.id = id; self.name = name; self.gm = gm; self.radius = radius; self.j2 = j2
        self.figure = figure ?? .sphere(radius)
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

    // MARK: Surface

    /// Geodetic latitude, longitude (rad) and height (m) on `figure` of a
    /// point at `r` (ICRF, relative to the body centre), the body oriented as `o`.
    public func geodetic(_ r: Vec3, orientation o: BodyOrientation) -> (latitude: Double, longitude: Double,
                                                                        height: Double) {
        figure.geodetic(o.toBody(r))
    }

    /// The local vertical through `r` (ICRF): the figure's outward normal.
    public func vertical(at r: Vec3, orientation o: BodyOrientation) -> Vec3 {
        o.toInertial(figure.normal(at: o.toBody(r)))
    }
}

// MARK: - Orientation

extension CelestialBody {
    public func orientation(at t: Epoch, ephemeris: ChebyshevEphemeris) -> BodyOrientation {
        switch rotation {
        case .earth:
            let m = precessionNutation.terms(ttSecondsPastJ2000: t.tdb).celestialToTerrestrial(ut1: t.ut1, tt: t.tt)
            // The Earth rotation angle's rate about the CIP, expressed in ICRF.
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
