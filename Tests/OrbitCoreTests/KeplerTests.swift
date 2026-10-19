import XCTest
@testable import OrbitCore

/// Universal-variable propagation and Kepler's equation against textbook
/// examples, a fine RK4 and the simulator. The textbook numbers are as
/// transcribed in poliastro's test suite (github.com/poliastro/poliastro,
/// tests/tests_twobody/test_propagation.py, fetched 2026-10-19).
final class KeplerTests: XCTestCase {
    let km = 1000.0
    let muEarth = 3.986004418e14

    /// Vallado, Fundamentals of Astrodynamics and Applications, Example 2-4
    /// (KEPLER): 40 minutes on from r0, v0, μ = 398,600.4418 km³/s². The book
    /// gives r to 0.1 m and v to 1 mm/s.
    func testValladoExample2_4() {
        let s0 = Kepler.State(position: Vec3(1131.340, -2282.343, 6672.423) * km,
                              velocity: Vec3(-5.64305, 4.30333, 2.42879) * km)
        let s = Kepler.propagate(s0, mu: muEarth, by: 40 * 60)
        let r = Vec3(-4219.7527, 4363.0292, -3958.7666) * km
        let v = Vec3(3.689866, -1.916735, -6.112511) * km
        XCTAssertLessThan((s.position - r).length, 0.2)
        XCTAssertLessThan((s.velocity - v).length, 1e-3)
    }

    /// Curtis, Orbital Mechanics for Engineering Students, Example 3.5: a
    /// hyperbola with a 300 km perigee (R = 6378 km, μ = 398,600 km³/s²) at
    /// 15 km/s; 14,941 s after perigee r = 163,180 km and v = 10.51 km/s.
    func testCurtisExample3_5Hyperbola() {
        let mu = 398_600 * km * km * km
        let s0 = Kepler.State(position: Vec3(6378 + 300, 0, 0) * km, velocity: Vec3(0, 15, 0) * km)
        let s = Kepler.propagate(s0, mu: mu, by: 14_941)
        XCTAssertEqual(s.position.length / km, 163_180, accuracy: 10)
        XCTAssertEqual(s.velocity.length / km, 10.51, accuracy: 0.005)
        // Back again.
        let back = Kepler.propagate(s, mu: mu, by: -14_941)
        XCTAssertLessThan((back.position - s0.position).length, 1e-3)
        XCTAssertLessThan((back.velocity - s0.velocity).length, 1e-6)
        // The elements' clock agrees with the propagation.
        let el = OrbitalElements(position: s.position, velocity: s.velocity, mu: mu)
        XCTAssertEqual(el.timeSincePeriapsis, 14_941, accuracy: 1e-6)
    }

    /// Curtis, problem 3.15: a parabola with p = 13,200 km reaches ν = 90°
    /// after 0.8897/2 h, and r = 304,700 km after 36 h.
    func testCurtisProblem3_15Parabola() {
        let mu = 398_600 * km * km * km
        let rp = 6600 * km
        let s0 = Kepler.State(position: Vec3(rp, 0, 0), velocity: Vec3(0, (2 * mu / rp).squareRoot(), 0))
        let quarter = Kepler.propagate(s0, mu: mu, by: 0.8897 / 2 * 3600)
        XCTAssertEqual(atan2(quarter.position.y, quarter.position.x) * 180 / .pi, 90, accuracy: 0.009)
        let later = Kepler.propagate(s0, mu: mu, by: 36 * 3600)
        XCTAssertEqual(later.position.length / km, 304_700, accuracy: 30)
        let energy = later.velocity.lengthSquared / 2 - mu / later.position.length
        XCTAssertEqual(energy, 0, accuracy: 1e-6 * mu / rp)
    }

    /// Against a fine RK4 two-body integration (T/20,000 steps, error well
    /// under a millimetre), within 1 m at points around one orbit: the
    /// 185 km parking orbit and a 300 x 3,000 km ellipse.
    func testAgainstRK4OverOneOrbit() {
        let mu = muEarth
        func rk4(_ s: Kepler.State, _ h: Double) -> Kepler.State {
            func acc(_ r: Vec3) -> Vec3 { r * (-mu / pow(r.length, 3)) }
            let r = s.position, v = s.velocity
            let a1 = acc(r), v2 = v + a1 * (h / 2), a2 = acc(r + v * (h / 2))
            let v3 = v + a2 * (h / 2), a3 = acc(r + v2 * (h / 2)), v4 = v + a3 * h, a4 = acc(r + v3 * h)
            return Kepler.State(position: r + (v + v2 * 2 + v3 * 2 + v4) * (h / 6),
                                velocity: v + (a1 + a2 * 2 + a3 * 2 + a4) * (h / 6))
        }
        let re = 6_378_137.0
        let circular = 6_563_137.0
        let i = 32.5 * Double.pi / 180
        let leo = Kepler.State(position: Vec3(circular, 0, 0),
                               velocity: Vec3(0, cos(i), sin(i)) * (mu / circular).squareRoot())
        let rp = re + 300_000, ra = re + 3_000_000, a = (rp + ra) / 2
        let ellipse = Kepler.State(position: Vec3(0, rp * cos(1), rp * sin(1)),
                                   velocity: Vec3(-1, 0, 0) * (mu * (2 / rp - 1 / a)).squareRoot())
        for s0 in [leo, ellipse] {
            let el = OrbitalElements(position: s0.position, velocity: s0.velocity, mu: mu)
            let steps = 20_000, h = el.period / Double(steps)
            var s = s0, worst = 0.0
            for k in 1...steps {
                s = rk4(s, h)
                if k % 2_500 == 0 {
                    let kepler = Kepler.propagate(s0, mu: mu, by: Double(k) * h)
                    worst = max(worst, (kepler.position - s.position).length)
                }
            }
            XCTAssertLessThan(worst, 1.0)
        }
    }

    /// Against the simulator's own RK4 two-body coast (no J2, no third
    /// bodies, no air), within 1 m after one orbit.
    func testAgainstSimulatorOverOneOrbit() throws {
        let system = try SolarSystem.bundled()
        system.perturbers = []
        system.earth.j2 = 0
        let sim = Simulation(system: system, time: Epoch(utcYear: 1969, month: 7, day: 16, hour: 13, minute: 32))
        sim.atmospheres[399] = NoAir()
        let v = VesselLibrary.capsule()
        sim.add(v)
        sim.placeInCircularOrbit(v, around: system.earth, altitude: 185_000, inclination: 32.5)
        v.velocity = v.velocity * 1.01      // a slight ellipse
        let s0 = Kepler.State(position: v.position, velocity: v.velocity)
        let period = v.elements(snapshot: sim.snapshot).period
        var remaining = period
        while remaining > 0 {
            let h = min(remaining, sim.maxStep())
            sim.step(h)
            remaining -= h
        }
        let kepler = Kepler.propagate(s0, mu: system.earth.gm, by: period)
        XCTAssertLessThan((kepler.position - v.position).length, 1.0)
        XCTAssertLessThan((kepler.position - s0.position).length, 1e-3)   // and one period closes the orbit
    }

    /// Forward and back returns the state; energy and angular momentum hold,
    /// over long elliptic arcs, both ways in time, and on a hyperbola.
    func testRoundTripAndInvariants() {
        let mu = muEarth
        let states = [
            Kepler.State(position: Vec3(7_000_000, 1_000_000, -500_000), velocity: Vec3(-1_000, 7_200, 1_500)),
            Kepler.State(position: Vec3(6_700_000, 0, 0), velocity: Vec3(0, 10_000, 6_000)),     // hyperbola
            Kepler.State(position: Vec3(-6_500_000, 2e6, 0), velocity: Vec3(-3_000, -9_500, 2_500)),
        ]
        for s0 in states {
            let e0 = s0.velocity.lengthSquared / 2 - mu / s0.position.length
            let h0 = s0.position.cross(s0.velocity)
            for dt in [1.0, -1_000, 4_000, 37_000, -55_000] {
                let s1 = Kepler.propagate(s0, mu: mu, by: dt)
                let e1 = s1.velocity.lengthSquared / 2 - mu / s1.position.length
                XCTAssertEqual(e1, e0, accuracy: 1e-9 * abs(e0))
                XCTAssertLessThan((s1.position.cross(s1.velocity) - h0).length, 1e-9 * h0.length)
                let back = Kepler.propagate(s1, mu: mu, by: -dt)
                XCTAssertLessThan((back.position - s0.position).length, 1e-3, "dt \(dt)")
                XCTAssertLessThan((back.velocity - s0.velocity).length, 1e-6, "dt \(dt)")
            }
        }
        XCTAssertEqual(Kepler.propagate(states[0], mu: mu, by: 0), states[0])
    }

    /// Kepler's equation inverts, on ellipses, the parabola and hyperbolas.
    func testKeplersEquationInverts() {
        for e in [0.0, 0.001, 0.3, 0.9, 0.999, 1.0, 1.001, 1.5, 4.0] {
            let limit = e < 1 ? Double.pi : (e == 1 ? 0.95 * .pi : acos(-1 / e) * 0.999)
            for k in -9...9 {
                let nu = limit * Double(k) / 9.5
                let m = Kepler.meanAnomaly(trueAnomaly: nu, eccentricity: e)
                XCTAssertEqual(Kepler.trueAnomaly(meanAnomaly: m, eccentricity: e), nu, accuracy: 1e-9,
                               "e \(e) nu \(nu)")
            }
        }
    }

    /// Times to an anomaly and to a radius land the propagation there.
    func testTimeToAnomalyAndRadius() {
        let mu = muEarth
        let s0 = Kepler.State(position: Vec3(7_000_000, 1_000_000, -500_000), velocity: Vec3(-1_000, 7_200, 1_500))
        let el = OrbitalElements(position: s0.position, velocity: s0.velocity, mu: mu)
        for nu in stride(from: 0.0, to: 2 * .pi, by: 0.7) {
            let t = try! XCTUnwrap(el.timeTo(trueAnomaly: nu))
            XCTAssertGreaterThanOrEqual(t, 0)
            XCTAssertLessThan(t, el.period)
            let s = Kepler.propagate(s0, mu: mu, by: t)
            let at = OrbitalElements(position: s.position, velocity: s.velocity, mu: mu)
            XCTAssertEqual(remainder(at.trueAnomaly - nu, 2 * .pi), 0, accuracy: 1e-9)
        }
        let r = (el.periapsisRadius + el.apoapsisRadius) / 2
        let up = try! XCTUnwrap(el.timeTo(radius: r, outbound: true))
        let down = try! XCTUnwrap(el.timeTo(radius: r, outbound: false))
        XCTAssertEqual(el.timeTo(radius: r), min(up, down))
        for (t, sign) in [(up, 1.0), (down, -1.0)] {
            let s = Kepler.propagate(s0, mu: mu, by: t)
            XCTAssertEqual(s.position.length, r, accuracy: 1e-3)
            XCTAssertEqual(s.position.dot(s.velocity).sign == .minus ? -1.0 : 1.0, sign)
        }
        XCTAssertNil(el.timeTo(radius: el.apoapsisRadius * 1.01))
        XCTAssertEqual(el.timeTo(trueAnomaly: Double.pi)!, el.timeToApoapsis, accuracy: 1e-6)

        // A hyperbola past periapsis never comes back in.
        let hyp = Kepler.State(position: Vec3(6_700_000, 0, 0), velocity: Vec3(0, 10_000, 6_000))
        let out = Kepler.propagate(hyp, mu: mu, by: 600)
        let hel = OrbitalElements(position: out.position, velocity: out.velocity, mu: mu)
        XCTAssertNil(hel.timeTo(trueAnomaly: -0.5))
        XCTAssertNil(hel.timeTo(radius: 6_800_000, outbound: false))
        let t = try! XCTUnwrap(hel.timeTo(radius: 2e7))
        XCTAssertEqual(Kepler.propagate(out, mu: mu, by: t).position.length, 2e7, accuracy: 1e-2)
    }
}

/// An atmosphere that is vacuum everywhere, to coast in the simulator without drag.
final class NoAir: Atmosphere {
    func state(altitude h: Double) -> AtmosphereState { .vacuum }
    var ceiling: Double { 0 }
    var seaLevelPressure: Double { 101_325 }
}
