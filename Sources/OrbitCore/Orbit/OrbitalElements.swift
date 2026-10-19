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
    /// The reference frame the angles are measured in, as rows in the
    /// state's axes: z is the pole, and x, the direction longitudes are
    /// measured from, is +z × pole (+x when the pole is +z).
    public let referenceFrame: Mat3

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
        referenceFrame = toLocal
    }
}

// MARK: - Derived geometry

extension OrbitalElements {
    /// An angle reduced to [0, 2π).
    static func wrapped(_ a: Double) -> Double {
        let w = a.truncatingRemainder(dividingBy: 2 * Double.pi)
        return w < 0 ? w + 2 * Double.pi : w
    }

    /// b = a√(1 - e²) for an ellipse; for a hyperbola |a|√(e² - 1), the
    /// asymptotes' miss distance (m).
    public var semiMinorAxis: Double {
        abs(semiMajorAxis) * abs(1 - eccentricity * eccentricity).squareRoot()
    }

    /// p = h²/μ (m).
    public var semiLatusRectum: Double { angularMomentum.lengthSquared / mu }

    /// u = ω + ν: the angle from the ascending node to the position, in the
    /// direction of motion (rad, [0, 2π)).
    public var argumentOfLatitude: Double { Self.wrapped(argumentOfPeriapsis + trueAnomaly) }

    /// ϖ = Ω + ω (rad, [0, 2π)).
    public var longitudeOfPeriapsis: Double { Self.wrapped(longitudeOfAscendingNode + argumentOfPeriapsis) }

    /// l = Ω + ω + ν, measured in two planes as Orbiter's TrL is (rad, [0, 2π)).
    public var trueLongitude: Double { Self.wrapped(longitudeOfPeriapsis + trueAnomaly) }

    /// L = Ω + ω + M (rad, [0, 2π)); with the hyperbolic mean anomaly on an
    /// escape orbit.
    public var meanLongitude: Double { Self.wrapped(longitudeOfPeriapsis + meanAnomaly) }

    /// The perifocal basis in the state's axes: P towards periapsis, Q 90°
    /// ahead of it in the direction of motion, W along the angular momentum.
    /// On a circular orbit P is the ascending node (the state's +x on an
    /// equatorial one), where the true anomaly is measured from.
    public var perifocalBasis: (p: Vec3, q: Vec3, w: Vec3) {
        let m = referenceFrame.transposed
            * Mat3.rotZ(longitudeOfAscendingNode) * Mat3.rotX(inclination) * Mat3.rotZ(argumentOfPeriapsis)
        return (m.c0, m.c1, m.c2)
    }

    /// Radius at true anomaly `nu` (m): p / (1 + e cos ν); infinite or
    /// negative beyond an escape orbit's asymptotes.
    public func radius(atTrueAnomaly nu: Double) -> Double {
        semiLatusRectum / (1 + eccentricity * cos(nu))
    }

    /// Position at true anomaly `nu`, in the state's axes (m).
    public func position(atTrueAnomaly nu: Double) -> Vec3 {
        let b = perifocalBasis
        return (b.p * cos(nu) + b.q * sin(nu)) * radius(atTrueAnomaly: nu)
    }

    /// Velocity at true anomaly `nu`, in the state's axes (m/s):
    /// √(μ/p) (-sin ν P + (e + cos ν) Q).
    public func velocity(atTrueAnomaly nu: Double) -> Vec3 {
        let b = perifocalBasis
        return (b.p * -sin(nu) + b.q * (eccentricity + cos(nu))) * (mu / semiLatusRectum).squareRoot()
    }

    /// The true anomalies where the orbit passes `radius`: going out
    /// (ν in [0, π]) and coming in (2π minus it); nil if it never does, or
    /// on a circular orbit, where the radius does not fix a point.
    public func trueAnomalies(atRadius radius: Double) -> (outbound: Double, inbound: Double)? {
        guard eccentricity > 1e-10, radius > 0 else { return nil }
        let c = (semiLatusRectum / radius - 1) / eccentricity
        guard abs(c) <= 1 else { return nil }
        let nu = acos(c)
        return (nu, Self.wrapped(-nu))
    }

    /// Points on the conic, in the state's axes, relative to the focus
    /// (m). A whole ellipse is `n` intervals evenly spaced in eccentric
    /// anomaly from periapsis, so its last point repeats the first. Escape
    /// orbits, and ellipses whose apoapsis is beyond `maxRadius`, are one
    /// arc through periapsis, `n` intervals even in true anomaly, cut at
    /// `maxRadius`; without it an escape orbit runs to within 0.02 rad of
    /// its asymptotes. Empty if periapsis is beyond `maxRadius`.
    public func conicPoints(_ n: Int, maxRadius: Double? = nil) -> [Vec3] {
        guard n > 0, semiLatusRectum > 0 else { return [] }
        let e = eccentricity
        let b = perifocalBasis
        if e < 1, maxRadius.map({ $0 >= apoapsisRadius }) ?? true {
            let a = semiMajorAxis, minor = semiMinorAxis
            return (0...n).map { k in
                let ea = 2 * Double.pi * Double(k) / Double(n)
                return b.p * (a * (cos(ea) - e)) + b.q * (minor * sin(ea))
            }
        }
        var maxNu = e < 1 ? Double.pi : acos(-1 / e) - 0.02
        if let rMax = maxRadius {
            guard rMax >= periapsisRadius else { return [] }
            if e > 1e-12 {
                let c = (semiLatusRectum / rMax - 1) / e
                if c > -1 { maxNu = min(maxNu, acos(min(1, c))) }
            }
        }
        return (0...n).map { k in
            let nu = -maxNu + 2 * maxNu * Double(k) / Double(n)
            return (b.p * cos(nu) + b.q * sin(nu)) * radius(atTrueAnomaly: nu)
        }
    }

    /// Unit vector towards the ascending node on the reference equator, in
    /// the state's axes; nil on an equatorial orbit.
    public var ascendingNodeDirection: Vec3? {
        let n = referenceFrame.r2.cross(angularMomentum)
        return n.length > 1e-9 * angularMomentum.length ? n.normalized : nil
    }

    /// The ascending node's longitude measured from `reference` (in the
    /// state's axes) projected on the reference equator, eastward about the
    /// pole (rad, [0, 2π)); nil on an equatorial orbit. From the equinox of
    /// date (the first row of `EarthOrientation.biasPrecessionMatrix`) it is
    /// the textbook RAAN, whereas `longitudeOfAscendingNode` is measured from
    /// +z × pole, which for the Earth's pole of date swings with the epoch
    /// (RA 269° in 1969, 316° in 2000, 91° in 2026).
    public func longitudeOfAscendingNode(from reference: Vec3) -> Double? {
        guard let n = ascendingNodeDirection else { return nil }
        let pole = referenceFrame.r2
        let x = (reference - pole * reference.dot(pole)).normalized, y = pole.cross(x)
        return Self.wrapped(atan2(n.dot(y), n.dot(x)))
    }

    /// Where the orbit crosses the reference equator northbound, in the
    /// state's axes (m); nil on an equatorial orbit, or an escape orbit that
    /// does not reach it.
    public var ascendingNode: Vec3? { nodePosition(trueAnomaly: -argumentOfPeriapsis) }

    /// Where the orbit crosses the reference equator southbound (m); nil as
    /// for `ascendingNode`.
    public var descendingNode: Vec3? { nodePosition(trueAnomaly: Double.pi - argumentOfPeriapsis) }

    private func nodePosition(trueAnomaly nu: Double) -> Vec3? {
        guard ascendingNodeDirection != nil, 1 + eccentricity * cos(nu) > 1e-12 else { return nil }
        return position(atTrueAnomaly: nu)
    }
}
