import Foundation

/// Positions, velocities and orientations of all bodies at one instant.
public struct SystemSnapshot {
    public let time: Epoch
    /// Barycentric (SSB) position/velocity, m and m/s, ICRF, keyed by NAIF id.
    public let positions: [Int: Vec3]
    public let velocities: [Int: Vec3]
    public let orientations: [Int: BodyOrientation]

    public func position(_ b: CelestialBody) -> Vec3 { positions[b.id]! }
    public func velocity(_ b: CelestialBody) -> Vec3 { velocities[b.id]! }
    public func orientation(_ b: CelestialBody) -> BodyOrientation { orientations[b.id]! }
}

/// The bodies of the simulation and their constants. GM values follow DE421;
/// radii and rotation elements follow the IAU WGCCRE reports. The Earth's
/// figure is WGS 84's ellipsoid; the other bodies are spheres.
public final class SolarSystem {
    public let ephemeris: ChebyshevEphemeris
    public let bodies: [CelestialBody]
    public let sun: CelestialBody
    public let earth: CelestialBody
    public let moon: CelestialBody

    /// Bodies whose gravity acts on vessels (in addition to the reference body).
    public var perturbers: [CelestialBody]

    private var cache: [(Double, SystemSnapshot)] = []

    public init(ephemeris: ChebyshevEphemeris) {
        self.ephemeris = ephemeris
        let deg = Double.pi / 180
        let perDay = deg / 86400

        func uniform(_ ra: Double, _ dec: Double, _ w0: Double, _ wdot: Double) -> RotationModel {
            .uniform(poleRA: ra * deg, poleDec: dec * deg, w0: w0 * deg, rate: wdot * perDay)
        }

        sun = CelestialBody(id: 10, name: "Sun", gm: 1.32712440041e20, radius: 696_000_000,
                            rotation: uniform(286.13, 63.87, 84.176, 14.1844), soiRadius: .infinity)
        let mercury = CelestialBody(id: 199, name: "Mercury", gm: 2.2032e13, radius: 2_439_700,
                                    rotation: uniform(281.0097, 61.4143, 329.5469, 6.1385025), soiRadius: 1.12e8)
        let venus = CelestialBody(id: 299, name: "Venus", gm: 3.24859e14, radius: 6_051_800,
                                  rotation: uniform(272.76, 67.16, 160.20, -1.4813688), soiRadius: 6.16e8)
        earth = CelestialBody(id: 399, name: "Earth", gm: 3.986004418e14, radius: 6_378_137,
                              j2: 1.08262668e-3, figure: .wgs84, rotation: .earth,
                              atmosphere: USStandardAtmosphere1976(), soiRadius: 9.24e8)
        moon = CelestialBody(id: 301, name: "Moon", gm: 4.9028e12, radius: 1_737_400,
                             j2: 2.0330e-4, rotation: .moonDE421, soiRadius: 6.61e7)
        let mars = CelestialBody(id: 499, name: "Mars", gm: 4.282837e13, radius: 3_396_200,
                                 rotation: uniform(317.68143, 52.88650, 176.630, 350.89198226), soiRadius: 5.77e8)
        let jupiter = CelestialBody(id: 5, name: "Jupiter", gm: 1.26712767e17, radius: 71_492_000,
                                    rotation: uniform(268.056595, 64.495303, 284.95, 870.5360000), soiRadius: 4.82e10)
        let saturn = CelestialBody(id: 6, name: "Saturn", gm: 3.79405852e16, radius: 60_268_000,
                                   rotation: uniform(40.589, 83.537, 38.90, 810.7939024), soiRadius: 5.48e10)

        moon.parent = earth
        for p in [mercury, venus, earth, mars, jupiter, saturn] { p.parent = sun }

        bodies = [sun, mercury, venus, earth, moon, mars, jupiter, saturn]
        perturbers = [sun, earth, moon, venus, jupiter]
    }

    public static func bundled() throws -> SolarSystem {
        SolarSystem(ephemeris: try ChebyshevEphemeris.bundled())
    }

    public func body(id: Int) -> CelestialBody? { bodies.first { $0.id == id } }
    public func body(named name: String) -> CelestialBody? {
        bodies.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Time span supported by the bundled ephemeris.
    public var validSpan: ClosedRange<Epoch> {
        let s = ephemeris.span
        return Epoch(tdbSecondsPastJ2000: s.lowerBound)...Epoch(tdbSecondsPastJ2000: s.upperBound)
    }

    /// Snapshot of all bodies at `t`. The last few snapshots are cached because
    /// every vessel's integrator samples the same intermediate times.
    public func snapshot(at t: Epoch) -> SystemSnapshot {
        if let hit = cache.first(where: { $0.0 == t.tdb }) { return hit.1 }
        var pos: [Int: Vec3] = [:], vel: [Int: Vec3] = [:], ori: [Int: BodyOrientation] = [:]
        for b in bodies {
            let s = ephemeris.barycentricState(naif: b.id, at: t)
            pos[b.id] = s.position
            vel[b.id] = s.velocity
            ori[b.id] = b.orientation(at: t, ephemeris: ephemeris)
        }
        let snap = SystemSnapshot(time: t, positions: pos, velocities: vel, orientations: ori)
        cache.append((t.tdb, snap))
        if cache.count > 8 { cache.removeFirst(cache.count - 8) }
        return snap
    }

    /// Gravitational acceleration on a point at `r` relative to `reference`,
    /// expressed in the non-rotating frame centred on (and accelerating with) the
    /// reference body: central term with J2, plus direct-minus-indirect terms of
    /// the perturbing bodies.
    public func acceleration(relativeTo reference: CelestialBody, at r: Vec3, snapshot s: SystemSnapshot) -> Vec3 {
        var a = reference.gravity(at: r, pole: s.orientation(reference).pole)
        let refPos = s.position(reference)
        for p in perturbers where p !== reference {
            let d = s.position(p) - refPos          // perturber relative to reference
            let rel = d - r                         // perturber relative to point
            let rl = rel.length, dl = d.length
            a += rel * (p.gm / (rl * rl * rl)) - d * (p.gm / (dl * dl * dl))
        }
        return a
    }

    /// The body whose sphere of influence contains barycentric position `p`
    /// (deepest in the hierarchy wins).
    public func dominantBody(forBarycentric p: Vec3, snapshot s: SystemSnapshot) -> CelestialBody {
        var best = sun
        var bestSOI = Double.infinity
        for b in bodies where b !== sun {
            let d = (p - s.position(b)).length
            if d < b.soiRadius && b.soiRadius < bestSOI {
                best = b
                bestSOI = b.soiRadius
            }
        }
        return best
    }
}
