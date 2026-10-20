import Foundation

/// Aerodynamics of a blunt, axisymmetric capsule flown heat shield first
/// with its centre of mass off the axis (the Apollo command module), as
/// `AerodynamicModel.capsule`. Angles follow Apollo: α is the total angle
/// from +x (the apex) to the velocity relative to the air, so 180° is heat
/// shield forward, and α' = π - α. The crossflow direction ê is that of
/// the velocity's component across the axis. Datasheet:
/// docs/CM-entry-datasheet.md.
///
/// - Supersonic (Mach ≥ `sphereCentreMach`), the sphere-centre model: the
///   pressure on a spherical heat shield acts nearly through one point on
///   the axis. The resultant C_R q S lies θ = k α' from +x, tilted against
///   the crossflow, and acts at the axis station x_cp. Each Mach row of the
///   trim table, at its own centre of mass (x_r, z_r off the axis), gives
///   C_R = hypot(C_L, C_D), δ = atan(C_L / C_D), θ_t = α'_t - δ, k = θ_t /
///   α'_t and x_cp = x_r + z_r / tan θ_t. Trim then emerges for any centre
///   of mass, with the lift towards its side of the axis.
/// - Subsonic (below `sphereCentreMach`), where θ_t falls to zero and
///   below, an anchored linear model: the same resultant and direction,
///   and a moment about the table's centre of mass of
///   `subsonicMomentSlope` (α'_p - α'_t) in the plane of that centre and
///   the axis, and `subsonicMomentSlope` α'_y across it; moved to the
///   actual centre of mass by r × F.
/// - Large angles: from α' = `newtonianBlend.start` to `.end` the loads
///   blend into a full-range modified-Newtonian model of the outer mould
///   line, scaled to C_R at the start of the blend. It has the apex-forward
///   trim a real capsule has.
///
/// No damping derivative and no roll moment: the force passes through the
/// axis, and the reaction control system damps rates, as on Apollo.
public struct CapsuleAerodynamics {
    /// One row of a trim table: the coefficients at trim for the table's
    /// centre of mass.
    public struct TrimPoint: Equatable {
        public var mach: Double
        /// α at trim, rad.
        public var angleOfAttack: Double
        public var lift: Double
        public var drag: Double
        public init(mach: Double, angleOfAttack: Double, lift: Double, drag: Double) {
            self.mach = mach
            self.angleOfAttack = angleOfAttack
            self.lift = lift
            self.drag = drag
        }
    }

    /// Which Mach rows of the trim table fly.
    public enum Calibration: Equatable {
        /// Every row as published: the preflight tables MSC flew its
        /// operational trajectories with.
        case operational
        /// The rows up to `flightConsistentMach`, that row's calibration
        /// held above it. Apollo 4's entry (TN D-5399) and DeRose's
        /// free-flight models (TN D-5276) trim independently of Mach above
        /// Mach 6-10; the tables' higher-Mach rows are wind-tunnel
        /// extrapolations.
        case flightConsistent
    }

    /// The trim table, by increasing Mach.
    public let trimTable: [TrimPoint]
    /// The coefficients' reference area S (m^2) and diameter d (m).
    public let referenceArea: Double
    public let referenceDiameter: Double
    /// The centre of mass the table is for, construction coordinates, m.
    public let referenceCenterOfMass: Vec3
    public var calibration: Calibration
    public var flightConsistentMach = 10.0
    /// Pitching-moment slope about the table's centre of mass below
    /// `sphereCentreMach`, per rad of α'.
    public var subsonicMomentSlope = -0.1
    /// The Mach number from which the sphere-centre model flies.
    public var sphereCentreMach = 1.1
    /// α' (rad) over which the loads blend into the Newtonian model.
    public var newtonianBlend = (start: 40 * Double.pi / 180, end: 60 * Double.pi / 180)
    /// Radius of the heat shield's stagnation region for convective heating
    /// (Sutton-Graves), m.
    public var noseRadius: Double
    /// The full-range Newtonian coefficients of the outer mould line.
    public let newtonian: NewtonianCoefficients

    /// One trim row's calibration.
    struct Knot {
        var mach: Double
        /// Resultant coefficient C_R and the force angle per unit α', θ / α'.
        var resultant: Double
        var k: Double
        /// α'_t, rad.
        var trim: Double
        /// x_cp, construction x (m); nil where θ_t is not positive.
        var centre: Double?
    }
    let knots: [Knot]

    /// A capsule flying `trimTable` (on `newtonian`'s reference area and
    /// diameter) for a centre of mass at `referenceCenterOfMass`.
    public init(trimTable: [TrimPoint], referenceCenterOfMass: Vec3, calibration: Calibration,
                noseRadius: Double, newtonian: NewtonianCoefficients) {
        self.trimTable = trimTable.sorted { $0.mach < $1.mach }
        referenceArea = newtonian.referenceArea
        referenceDiameter = newtonian.referenceDiameter
        self.referenceCenterOfMass = referenceCenterOfMass
        self.calibration = calibration
        self.noseRadius = noseRadius
        self.newtonian = newtonian
        let offset = (referenceCenterOfMass.y * referenceCenterOfMass.y
            + referenceCenterOfMass.z * referenceCenterOfMass.z).squareRoot()
        knots = self.trimTable.map { row in
            let trim = Double.pi - row.angleOfAttack
            let theta = trim - atan2(row.lift, row.drag)
            return Knot(mach: row.mach, resultant: (row.lift * row.lift + row.drag * row.drag).squareRoot(),
                        k: theta / trim, trim: trim,
                        centre: theta > 1e-9 ? referenceCenterOfMass.x + offset / tan(theta) : nil)
        }
    }

    /// The calibration at `mach`, linear between rows and held beyond the
    /// end ones: the subsonic rows (to `sphereCentreMach`) or the
    /// sphere-centre ones (from it), as `calibration` flies them.
    func knot(at mach: Double, sphereCentre: Bool) -> Knot {
        let top = calibration == .flightConsistent ? flightConsistentMach + 1e-12 : .infinity
        var below: Knot?, above: Knot?
        for k in knots where k.mach <= top
            && (sphereCentre ? k.mach >= sphereCentreMach - 1e-12 : k.mach <= sphereCentreMach + 1e-12) {
            if k.mach <= mach { below = k } else if above == nil { above = k }
        }
        guard let a = below else { return above ?? knots[0] }
        guard let b = above else { return a }
        let f = (mach - a.mach) / (b.mach - a.mach)
        func lerp(_ x: Double, _ y: Double) -> Double { x + (y - x) * f }
        var c: Double?
        if let ca = a.centre, let cb = b.centre { c = lerp(ca, cb) }
        return Knot(mach: mach, resultant: lerp(a.resultant, b.resultant), k: lerp(a.k, b.k),
                    trim: lerp(a.trim, b.trim), centre: c)
    }

    /// The direction from the axis to the table's centre of mass (body axes,
    /// across the axis): the side the lift is on at trim.
    var referenceSide: Vec3 {
        let s = Vec3(0, referenceCenterOfMass.y, referenceCenterOfMass.z)
        return s.lengthSquared > 0 ? s.normalized : .unitZ
    }

    /// The loads for the vessel moving at `air` (body axes, m/s) relative to
    /// the air, its construction frame's origin at `structureOrigin` in the
    /// vessel frame (so the centre of mass, the vessel origin, may be off
    /// the axis). The torque is about the vessel origin.
    public func loads(air u: Vec3, atmosphere: AtmosphereState, structureOrigin o: Vec3) -> AerodynamicModel.Loads {
        let s = referenceArea, d = referenceDiameter
        var out = AerodynamicModel.Loads()
        let speed = u.length
        guard speed > 1e-6, atmosphere.density > 0 else { return out }
        let q = 0.5 * atmosphere.density * speed * speed
        let mach = atmosphere.speedOfSound > 0 ? speed / atmosphere.speedOfSound : 0
        let cross = Vec3(0, u.y, u.z), c = cross.length
        let alpha = atan2(c, u.x), alphaPrime = Double.pi - alpha
        let side = c > 1e-9 * speed ? cross / c : referenceSide
        out.angleOfAttack = alpha
        out.mach = mach
        let x = Vec3.unitX, pitchAxis = x.cross(side)

        // The trim model below the blend's end.
        var force = Vec3.zero, torque = Vec3.zero
        let w = blendWeight(alphaPrime)
        if w < 1 {
            let sphere = mach >= sphereCentreMach
            let kn = knot(at: mach, sphereCentre: sphere)
            let theta = kn.k * alphaPrime
            let f = (x * cos(theta) - side * sin(theta)) * (kn.resultant * q * s)
            var tq: Vec3
            if sphere, let xcp = kn.centre {
                tq = (o + Vec3(xcp, 0, 0)).cross(f)
            } else {
                // Pitch and yaw about the table's centre of mass, in its
                // plane and across it, then moved to the actual one.
                let g = referenceSide, h = x.cross(g)
                let back = -u.x
                let pitch = atan2(u.dot(g), back), yaw = atan2(u.dot(h), back)
                let m = subsonicMomentSlope * q * s * d
                tq = x.cross(g) * (m * (pitch - kn.trim)) + x.cross(h) * (m * yaw)
                tq += (o + referenceCenterOfMass).cross(f)
            }
            force += f * (1 - w)
            torque += tq * (1 - w)
        }
        // The Newtonian model from the blend's start.
        if w > 0 {
            let n = newtonian.coefficients(alphaPrime)
            let r0 = blendResultant(mach)
            let scale = r0 * q * s
            let f = (x * n.axial - side * n.normal) * scale
            let tq = pitchAxis * (n.moment * scale * d) + (o + Vec3(newtonian.referenceStation, 0, 0)).cross(f)
            force += f * w
            torque += tq * w
        }
        out.force = force
        out.torque = torque
        return out
    }

    /// Weight of the Newtonian model at α' (rad): 0 below the blend, 1
    /// beyond it, a smooth step between.
    func blendWeight(_ alphaPrime: Double) -> Double {
        let t = (alphaPrime - newtonianBlend.start) / (newtonianBlend.end - newtonianBlend.start)
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        return t * t * (3 - 2 * t)
    }

    /// The scale of the Newtonian coefficients at `mach`: the trim model's
    /// C_R over the Newtonian resultant at the start of the blend.
    func blendResultant(_ mach: Double) -> Double {
        let kn = knot(at: mach, sphereCentre: mach >= sphereCentreMach)
        let n = newtonian.coefficients(newtonianBlend.start)
        return kn.resultant / max((n.axial * n.axial + n.normal * n.normal).squareRoot(), 1e-9)
    }

    // MARK: Trim

    /// The trim the model gives at `mach` for a centre of mass at `center`
    /// (construction coordinates), heat shield forward: α' (rad) and L/D.
    /// The zero of the pitching moment in the plane of the centre of mass
    /// and the axis is found by bisection over `bracket` (α', rad; by
    /// default to the start of the Newtonian blend); nil where it does not
    /// fall through zero there.
    public func trim(mach: Double, centerOfMass center: Vec3, bracket: ClosedRange<Double>? = nil,
                     atmosphere: AtmosphereState? = nil) -> (alphaPrime: Double, liftToDrag: Double)? {
        let air = atmosphere ?? AtmosphereState(temperature: 288, pressure: 1, density: 1e-3, speedOfSound: 300)
        let o = -center, g = Vec3(0, center.y, center.z)
        let side = g.lengthSquared > 0 ? g.normalized : referenceSide
        let axis = Vec3.unitX.cross(side), speed = mach * air.speedOfSound
        func velocity(_ a: Double) -> Vec3 { (Vec3.unitX * -cos(a) + side * sin(a)) * speed }
        func moment(_ a: Double) -> Double {
            loads(air: velocity(a), atmosphere: air, structureOrigin: o).torque.dot(axis)
        }
        var lo = bracket?.lowerBound ?? 1e-6, hi = bracket?.upperBound ?? newtonianBlend.start
        guard moment(lo) > 0, moment(hi) < 0 else { return nil }
        for _ in 0..<100 {
            let mid = (lo + hi) / 2
            if moment(mid) > 0 { lo = mid } else { hi = mid }
        }
        let a = (lo + hi) / 2, u = velocity(a)
        let f = loads(air: u, atmosphere: air, structureOrigin: o).force
        let back = -u.normalized
        let drag = f.dot(back), lift = (f - back * drag).length
        return (a, lift / drag)
    }
}

/// Full-range modified-Newtonian coefficients of an axisymmetric outer mould
/// line (the pressure coefficient C_p,max sin² of the local incidence on
/// every windward panel, nothing on the lee), tabulated against α' and
/// interpolated linearly. Per unit q S: `axial` along +x, `normal` against
/// the crossflow; `moment` per unit q S d about `referenceStation` on the
/// axis, positive when it raises α'.
public struct NewtonianCoefficients {
    /// The mould line: (x, r) from the heat shield's vertex forward, m,
    /// as a polyline; x is construction x.
    public let profile: [(x: Double, r: Double)]
    /// Construction x of the moment reference, m.
    public let referenceStation: Double
    /// Reference area S (m^2) and diameter d (m) of the coefficients.
    public let referenceArea: Double
    public let referenceDiameter: Double
    public let stagnationPressure: Double
    /// α' of the rows (rad), and the coefficients there.
    let angles: [Double]
    let table: [(axial: Double, normal: Double, moment: Double)]

    /// Integrate the mould line `profile` at `step` (rad) of α' from 0 to π,
    /// on reference area `area` and diameter `diameter`, about construction
    /// x `referenceStation`; `azimuthPanels` panels around the axis.
    public init(profile: [(x: Double, r: Double)], referenceStation: Double, area: Double, diameter: Double,
                stagnationPressure: Double = 1.839, step: Double = 2 * Double.pi / 180, azimuthPanels: Int = 180) {
        self.profile = profile
        self.referenceStation = referenceStation
        referenceArea = area
        referenceDiameter = diameter
        self.stagnationPressure = stagnationPressure
        let n = Int((Double.pi / step).rounded())
        angles = (0...n).map { Double($0) * Double.pi / Double(n) }
        // Panels: centroid, outward normal and area, in body axes with the
        // crossflow along +y.
        var panels: [(c: Vec3, n: Vec3, a: Double)] = []
        let dphi = 2 * Double.pi / Double(azimuthPanels)
        for (p, q) in zip(profile, profile.dropFirst()) {
            let dx = q.x - p.x, dr = q.r - p.r, ds = (dx * dx + dr * dr).squareRoot()
            guard ds > 0 else { continue }
            let nx = -dr / ds, nr = dx / ds
            // Centroid radius of the strip's lateral area.
            let rc = p.r + q.r > 0 ? (p.r * p.r + p.r * q.r + q.r * q.r) / (1.5 * (p.r + q.r)) : 0
            let xc = p.r + q.r > 0 ? p.x + dx * (p.r + 2 * q.r) / (3 * (p.r + q.r)) : (p.x + q.x) / 2
            let area = Double.pi * (p.r + q.r) * ds / Double(azimuthPanels)
            for k in 0..<azimuthPanels {
                let phi = (Double(k) + 0.5) * dphi
                panels.append((Vec3(xc, rc * cos(phi), rc * sin(phi)), Vec3(nx, nr * cos(phi), nr * sin(phi)), area))
            }
        }
        table = angles.map { a in
            let u = Vec3(-cos(a), sin(a), 0)   // the vessel's velocity relative to the air
            var f = Vec3.zero, m = Vec3.zero
            for p in panels {
                let s = p.n.dot(u)
                guard s > 0 else { continue }
                let df = p.n * (-stagnationPressure * s * s * p.a)
                f += df
                m += (p.c - Vec3(referenceStation, 0, 0)).cross(df)
            }
            return (f.x / area, -f.y / area, m.z / (area * diameter))
        }
    }

    /// The coefficients at α' (rad).
    public func coefficients(_ alphaPrime: Double) -> (axial: Double, normal: Double, moment: Double) {
        let a = min(max(alphaPrime, 0), Double.pi)
        let f = a / Double.pi * Double(angles.count - 1)
        let i = min(Int(f), angles.count - 2), t = f - Double(i)
        let p = table[i], q = table[i + 1]
        return (p.axial + (q.axial - p.axial) * t, p.normal + (q.normal - p.normal) * t,
                p.moment + (q.moment - p.moment) * t)
    }
}

// MARK: - The Apollo command module

extension CapsuleAerodynamics {
    /// MSC Internal Note 68-FM-184 (Apollo 7 operational trajectory, Rev. 1,
    /// 31 July 1968), Table I(a): the Block II CM's coefficients at trim
    /// against Mach, for the centre of mass `apollo7TrimCenterOfMass`. Read
    /// from the page image by two readers, every row graded H
    /// (tools/data/68fm184_table1a_cm_trim.csv). On S = 129.35 ft^2 and
    /// d = 154 in (TN D-5399), which the table does not print.
    public static let apollo7TrimTable: [TrimPoint] = [
        (0.2, 170.8, 0.23620, 0.82481), (0.4, 167.36, 0.23987, 0.85383), (0.7, 164.68, 0.25990, 0.98724),
        (0.9, 162.00, 0.31644, 1.06770), (1.1, 155.29, 0.48722, 1.1748), (1.2, 155.49, 0.47292, 1.1603),
        (1.35, 154.36, 0.55642, 1.2831), (1.65, 153.56, 0.54558, 1.2700), (2.0, 153.5, 0.52922, 1.2791),
        (2.4, 154.02, 0.50380, 1.2486), (3.0, 154.5, 0.47542, 1.2245), (4.0, 156.44, 0.43792, 1.2208),
        (10.0, 157.09, 0.42515, 1.2307), (29.5, 160.37, 0.38353, 1.2951),
    ].map { TrimPoint(mach: $0.0, angleOfAttack: $0.1 * Double.pi / 180, lift: $0.2, drag: $0.3) }

    /// The centre of mass Table I(a) is for: X 1040.58, Y -0.11 and Z 5.91 in,
    /// Apollo axes (H), in construction coordinates.
    public static let apollo7TrimCenterOfMass = ApolloAxes.construction(xa: 1040.58, ya: -0.11, za: 5.91)

    /// The Block II CM's outer mould line in Apollo stations (in), from the
    /// heat shield's vertex at X 1000 (its tangent plane, the datum of the CM
    /// stations; TN D-5399's footnote, DeRose's x/d) forward: (station, r).
    /// - Heat shield: a spherical cap of radius 184.8 in (R/D 1.2) (M).
    /// - Shoulder: a torus of 7.7 in section radius (0.05 D) (M), at the
    ///   154 in maximum diameter (H).
    /// - Afterbody: a 33° half-angle cone (M) to 16.5 in radius, then the
    ///   docking tunnel to X 1137, the apex (AS506Data, L).
    public static let apolloOuterMouldLine: [(x: Double, r: Double)] = {
        let sphere = 184.8, shoulder = 7.7, half = 77.0, cone = 33 * Double.pi / 180
        let rim = (sphere - shoulder), thetaC = asin((half - shoulder) / rim)
        let centre = (x: sphere - rim * cos(thetaC), r: half - shoulder)
        var points: [(x: Double, r: Double)] = []
        for i in 0...60 {
            let phi = thetaC * Double(i) / 60
            points.append((sphere * (1 - cos(phi)), sphere * sin(phi)))
        }
        let top = Double.pi / 2 + cone
        for i in 1...30 {
            let beta = thetaC + (top - thetaC) * Double(i) / 30
            points.append((centre.x - shoulder * cos(beta), centre.r + shoulder * sin(beta)))
        }
        let start = points[points.count - 1], tunnel = 16.5
        let coneEnd = start.x + (start.r - tunnel) / tan(cone)
        for i in 1...20 {
            let f = Double(i) / 20
            points.append((start.x + (coneEnd - start.x) * f, start.r + (tunnel - start.r) * f))
        }
        points.append((137, tunnel))
        points.append((137, 0))
        return points.map { (1000 + $0.x, $0.r) }
    }()

    /// Reference diameter d = 154 in and area S = π d^2 / 4 = 129.35 ft^2
    /// (TN D-5399), m and m^2.
    public static let apolloReferenceDiameter = 154 * AS506.inch
    public static let apolloReferenceArea = Double.pi * apolloReferenceDiameter * apolloReferenceDiameter / 4

    /// The CM's mould line integrated once (heat shield vertex as reference).
    static let apolloNewtonian = NewtonianCoefficients(
        profile: apolloOuterMouldLine.map { (ApolloAxes.construction(xa: $0.x).x, $0.r * AS506.inch) },
        referenceStation: ApolloAxes.construction(xa: 1000).x, area: apolloReferenceArea,
        diameter: apolloReferenceDiameter)

    /// The effective radius of the CM's stagnation heating, m: Apollo 7's
    /// entry from 68-FM-184 Table IX(b) (Apollo7EntryTests) then peaks at
    /// 57.9 BTU/ft^2 s and totals 13,100 BTU/ft^2, against §5.4.4's 59.8 and
    /// 12,649 (L: fitted to both, as neither document gives the radius; the
    /// heat shield's own 184.8 in gives 34 and 7,800). A blunt spherical
    /// segment's stagnation region sees a much smaller effective radius than
    /// its sphere's.
    public static let apolloNoseRadius = 1.65

    /// The Block II command module calibrated on Apollo 7's trim table.
    public static func apolloCommandModule(calibration: Calibration = .flightConsistent) -> CapsuleAerodynamics {
        CapsuleAerodynamics(trimTable: apollo7TrimTable, referenceCenterOfMass: apollo7TrimCenterOfMass,
                            calibration: calibration, noseRadius: apolloNoseRadius, newtonian: apolloNewtonian)
    }
}

extension AerodynamicModel {
    /// The Apollo command module's model, "Apollo CM": it applies while the
    /// "CM" is aboard, so it goes after the launch and CSM models in
    /// `Vessel.aerodynamics`.
    public static func apolloCommandModule(calibration: CapsuleAerodynamics.Calibration = .flightConsistent)
        -> AerodynamicModel {
        var model = AerodynamicModel(name: "Apollo CM", requiredParts: ["CM"],
                                     referenceArea: CapsuleAerodynamics.apolloReferenceArea,
                                     referenceDiameter: CapsuleAerodynamics.apolloReferenceDiameter,
                                     referenceStation: 0, forebodyAxial: LinearTable([(0, 0)]))
        model.capsule = .apolloCommandModule(calibration: calibration)
        return model
    }
}
