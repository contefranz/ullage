import Foundation

/// Classical osculating elements of a two-body orbit.
public struct OrbitalElements {
    public let mu: Double
    public let semiMajorAxis: Double      // m (negative for hyperbolic)
    public let eccentricity: Double
    public let inclination: Double        // rad, w.r.t. the reference equator
    public let longitudeOfAscendingNode: Double  // rad
    public let argumentOfPeriapsis: Double       // rad
    public let trueAnomaly: Double               // rad
    public let specificEnergy: Double            // J/kg
    public let angularMomentum: Vec3             // m^2/s, in the frame the state was given in

    public var periapsisRadius: Double { semiMajorAxis * (1 - eccentricity) }
    public var apoapsisRadius: Double { eccentricity < 1 ? semiMajorAxis * (1 + eccentricity) : .infinity }
    public var isBound: Bool { eccentricity < 1 }
    public var period: Double {
        isBound ? 2 * Double.pi * (semiMajorAxis * semiMajorAxis * semiMajorAxis / mu).squareRoot() : .infinity
    }
    public var meanMotion: Double { (mu / pow(abs(semiMajorAxis), 3)).squareRoot() }

    /// Mean anomaly (elliptic) or hyperbolic mean anomaly.
    public var meanAnomaly: Double {
        let e = eccentricity, nu = trueAnomaly
        if e < 1 {
            let ea = 2 * atan(((1 - e) / (1 + e)).squareRoot() * tan(nu / 2))
            return ea - e * sin(ea)
        } else {
            let h = 2 * atanh(((e - 1) / (e + 1)).squareRoot() * tan(nu / 2))
            return e * sinh(h) - h
        }
    }

    /// Time until next periapsis passage (s); negative past periapsis on escape trajectories.
    public var timeToPeriapsis: Double {
        let m = meanAnomaly
        if isBound {
            var dm = 2 * Double.pi - m
            dm = dm.truncatingRemainder(dividingBy: 2 * Double.pi)
            if dm < 0 { dm += 2 * Double.pi }
            return dm / meanMotion
        }
        return -m / meanMotion
    }

    /// Time until next apoapsis passage (s), bound orbits only.
    public var timeToApoapsis: Double {
        guard isBound else { return .infinity }
        var dm = Double.pi - meanAnomaly
        dm = dm.truncatingRemainder(dividingBy: 2 * Double.pi)
        if dm < 0 { dm += 2 * Double.pi }
        return dm / meanMotion
    }

    /// - Parameters:
    ///   - r, v: state relative to the central body (any inertial axes).
    ///   - pole: unit vector of the reference plane's normal (e.g. the body's spin axis).
    public init(position r: Vec3, velocity v: Vec3, mu: Double, pole: Vec3 = .unitZ) {
        self.mu = mu
        // Express the state in a frame whose z axis is `pole`.
        let z = pole.normalized
        var xRef = Vec3.unitZ.cross(z)
        if xRef.length < 1e-9 { xRef = .unitX } else { xRef = xRef.normalized }
        let yRef = z.cross(xRef)
        let toLocal = Mat3(rows: xRef, yRef, z)
        let rl = toLocal * r, vl = toLocal * v

        let rn = rl.length
        let h = rl.cross(vl)
        let hn = h.length
        let energy = vl.lengthSquared / 2 - mu / rn
        let eVec = vl.cross(h) / mu - rl / rn
        let e = eVec.length
        let a = -mu / (2 * energy)
        let i = acos(max(-1, min(1, h.z / hn)))
        let node = Vec3.unitZ.cross(h)
        let nn = node.length

        var raan = 0.0, argp = 0.0, nu = 0.0
        if nn > 1e-12 * hn {
            raan = atan2(node.y, node.x)
        }
        if e > 1e-10 {
            if nn > 1e-12 * hn {
                argp = atan2(node.cross(eVec).dot(h) / hn, node.dot(eVec))
            } else {
                argp = atan2(eVec.y, eVec.x) * (h.z >= 0 ? 1 : -1)
            }
            nu = atan2(eVec.cross(rl).dot(h) / hn, eVec.dot(rl))
        } else {
            // Circular: measure from the ascending node (or x axis if equatorial).
            let ref = nn > 1e-12 * hn ? node : Vec3.unitX
            nu = atan2(ref.cross(rl).dot(h) / hn, ref.dot(rl))
        }
        func wrap(_ x: Double) -> Double { x < 0 ? x + 2 * Double.pi : x }

        semiMajorAxis = a
        eccentricity = e
        inclination = i
        longitudeOfAscendingNode = wrap(raan)
        argumentOfPeriapsis = wrap(argp)
        trueAnomaly = wrap(nu)
        specificEnergy = energy
        angularMomentum = r.cross(v)
    }
}
