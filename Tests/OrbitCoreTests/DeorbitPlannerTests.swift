import XCTest
@testable import OrbitCore

final class DeorbitPlannerTests: XCTestCase {
    let deg = Double.pi / 180
    let km = 1000.0

    /// Vallado, Fundamentals of Astrodynamics and Applications, Example 6-1:
    /// Hohmann transfer from 191.34411 km to 35,781.34857 km altitude (ER =
    /// 6378.1363 km, μ = 398,600.4418 km³/s²) costs 3.935224 km/s and takes
    /// 5.256713 h, as poliastro's tests/test_maneuver.py transcribes it
    /// (fetched 2026-10-19; it checks both to 1e-5).
    func testHohmannAgainstValladoExample6_1() {
        let mu = 398_600.4418 * km * km * km, er = 6378.1363 * km
        let h = DeorbitPlanner.hohmann(from: er + 191.34411 * km, to: er + 35_781.34857 * km, mu: mu)
        XCTAssertEqual((h.first + h.second) / km, 3.935224, accuracy: 3.935224e-5)
        XCTAssertEqual(h.transferTime / 3600, 5.256713, accuracy: 5.256713e-5)
        print(String(format: "Vallado 6-1: Δva %.6f km/s, Δvb %.6f km/s, total %.6f km/s, %.6f h", h.first / km,
                     h.second / km, (h.first + h.second) / km, h.transferTime / 3600))
        // Downwards it is the same two burns, the other way round.
        let down = DeorbitPlanner.hohmann(from: er + 35_781.34857 * km, to: er + 191.34411 * km, mu: mu)
        XCTAssertEqual(down.first, h.second, accuracy: 1e-9)
        XCTAssertEqual(down.second, h.first, accuracy: 1e-9)
    }

    /// The retrograde burn from Vallado's geosynchronous orbit down to a
    /// 191.34411 km perigee is the Hohmann transfer's apogee burn, and the
    /// planner's orbit after it has that perigee.
    func testRetrogradeToPerigeeIsTheHohmannBurn() {
        let mu = 398_600.4418 * km * km * km, er = 6378.1363 * km
        let r1 = er + 191.34411 * km, r2 = er + 35_781.34857 * km
        let body = CelestialBody(id: 1, name: "Earth", gm: mu, radius: er, rotation: .none, soiRadius: .infinity)
        let i = 28.5 * deg
        let geo = Kepler.State(position: Vec3(0, r2, 0), velocity: Vec3(-cos(i), 0, sin(i)) * (mu / r2).squareRoot())
        let expected = DeorbitPlanner.hohmann(from: r2, to: r1, mu: mu).first
        let dv = try! XCTUnwrap(DeorbitPlanner.retrogradeDeltaV(toPerigeeRadius: r1, state: geo, mu: mu))
        XCTAssertEqual(dv, expected, accuracy: 1e-9)

        let o = BodyOrientation(icrfToBody: .identity, angularVelocity: .zero)
        let plan = try! XCTUnwrap(DeorbitPlanner.plan(from: geo, around: body, orientation: o,
                                                      at: Epoch(tdbSecondsPastJ2000: 0),
                                                      target: .perigeeRadius(r1)))
        XCTAssertEqual(plan.deltaVMagnitude, expected, accuracy: 1e-9)
        XCTAssertEqual(plan.postBurnElements.periapsisRadius, r1, accuracy: 1e-6)
        XCTAssertEqual(plan.postBurnElements.apoapsisRadius, r2, accuracy: 1e-6)
        XCTAssertEqual(plan.deltaVLocal.x, -expected, accuracy: 1e-9)
        XCTAssertEqual(plan.deltaVLocal.y, 0, accuracy: 1e-9)
        XCTAssertEqual(plan.deltaVLocal.z, 0, accuracy: 1e-9)
        XCTAssertLessThan((plan.burnDirection + geo.velocity.normalized).length, 1e-12)
        XCTAssertNil(plan.entry)                 // a 191 km perigee does not reach EI
        XCTAssertNil(plan.burnTime)
    }

    /// Off an apsis the burn keeps the flight-path angle, and the conic after
    /// it has the target perigee.
    func testRetrogradeOffApsis() {
        let mu = 3.986004418e14, re = 6_378_137.0
        let rp = re + 300 * km, ra = re + 3000 * km, a = (rp + ra) / 2, e = (ra - rp) / (ra + rp)
        let p = a * (1 - e * e), nu = 60 * deg
        let r = p / (1 + e * cos(nu))
        let s = Kepler.State(position: Vec3(cos(nu), sin(nu), 0) * r,
                             velocity: Vec3(-sin(nu), e + cos(nu), 0) * (mu / p).squareRoot())
        let target = re + 40 * km
        let dv = try! XCTUnwrap(DeorbitPlanner.retrogradeDeltaV(toPerigeeRadius: target, state: s, mu: mu))
        XCTAssertGreaterThan(dv, 0)
        let after = DeorbitPlanner.burned(s, dv)
        let el = OrbitalElements(position: after.position, velocity: after.velocity, mu: mu)
        XCTAssertEqual(el.periapsisRadius, target, accuracy: 1e-5)
        XCTAssertEqual(EntryInterface.flightPathAngle(position: after.position, velocity: after.velocity),
                       EntryInterface.flightPathAngle(position: s.position, velocity: s.velocity), accuracy: 1e-12)
        // Raising the perigee takes a burn along the velocity.
        let up = try! XCTUnwrap(DeorbitPlanner.retrogradeDeltaV(toPerigeeRadius: re + 500 * km, state: s, mu: mu))
        XCTAssertLessThan(up, 0)
        // No conic through here in this direction has its perigee above r cos γ.
        XCTAssertNil(DeorbitPlanner.retrogradeDeltaV(toPerigeeRadius: r, state: s, mu: mu))
    }

    /// The rocket equation: propellant m0 (1 - exp(-Δv/ve)) gives back Δv,
    /// and a constant-flow burn of that length integrates to Δv.
    func testBurnTimeFromTheRocketEquation() {
        let m0 = 10_000.0, thrust = 91_190.0, isp = 314.0, dv = 100.0
        let ve = isp * standardGravity
        let mp = DeorbitPlanner.propellantMass(deltaV: dv, mass: m0, specificImpulse: isp)
        XCTAssertEqual(ve * log(m0 / (m0 - mp)), dv, accuracy: 1e-9)
        let t = DeorbitPlanner.burnTime(deltaV: dv, mass: m0, thrust: thrust, specificImpulse: isp)
        XCTAssertEqual(t, mp / (thrust / ve), accuracy: 1e-12)
        var v = 0.0, m = m0
        let steps = 10_000, h = t / Double(steps), flow = thrust / ve
        for _ in 0..<steps {
            v += thrust / (m - flow * h / 2) * h        // midpoint
            m -= flow * h
        }
        XCTAssertEqual(v, dv, accuracy: 1e-6)
    }

    /// Targeting γ at EI on the Earth with J2: the burn lands EI at the
    /// target angle, a steeper one takes more Δv, and the perigee is below EI.
    func testEntryFlightPathAngleTargeting() throws {
        let system = try SolarSystem.bundled()
        let sim = Simulation(system: system, time: Epoch(utcYear: 1968, month: 10, day: 22, hour: 11, minute: 0))
        let v = VesselLibrary.capsule()
        sim.add(v)
        sim.placeInCircularOrbit(v, around: system.earth, altitude: 185_000, inclination: 31.6,
                                 ascendingNode: 200, argumentOfLatitude: 60)
        let engine = DeorbitPlanner.Engine(v.thrusters.first { $0.name == "SM engine" }!)
        let shallow = try XCTUnwrap(DeorbitPlanner.plan(v, snapshot: sim.snapshot,
                                                        target: .entryFlightPathAngle(-1.5 * deg), engine: engine))
        let steep = try XCTUnwrap(DeorbitPlanner.plan(v, snapshot: sim.snapshot,
                                                      target: .entryFlightPathAngle(-2.5 * deg), engine: engine))
        for (plan, gamma) in [(shallow, -1.5 * deg), (steep, -2.5 * deg)] {
            let ei = try XCTUnwrap(plan.entry)
            XCTAssertEqual(ei.inertialFlightPathAngle, gamma, accuracy: 1e-7)
            XCTAssertLessThan(plan.postBurnElements.periapsisRadius,
                              system.earth.radius + EntryInterface.standardHeight)
            XCTAssertEqual(plan.ignition, sim.time)
            // The capsule's SM engine: 20 kN at 310 s from 6.8 t.
            let t = try XCTUnwrap(plan.burnTime)
            XCTAssertEqual(t, DeorbitPlanner.burnTime(deltaV: plan.deltaVMagnitude, mass: v.mass, thrust: 20_000,
                                                      specificImpulse: 310), accuracy: 1e-9)
            XCTAssertEqual(plan.centredIgnition!.tdb, plan.ignition.tdb - t / 2, accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(plan.propellantMass), DeorbitPlanner.propellantMass(
                deltaV: plan.deltaVMagnitude, mass: v.mass, specificImpulse: 310), accuracy: 1e-9)
        }
        XCTAssertGreaterThan(steep.deltaVMagnitude, shallow.deltaVMagnitude)
        print(String(format: "deorbit from 185 km: γ -1.5° at EI for %.2f m/s, -2.5° for %.2f m/s",
                     shallow.deltaVMagnitude, steep.deltaVMagnitude))
        // The same Δv aimed at the resulting perigee gives the same orbit.
        let byPerigee = try XCTUnwrap(DeorbitPlanner.plan(v, snapshot: sim.snapshot,
            target: .perigeeRadius(shallow.postBurnElements.periapsisRadius)))
        XCTAssertEqual(byPerigee.deltaVMagnitude, shallow.deltaVMagnitude, accuracy: 1e-6)
        XCTAssertNil(DeorbitPlanner.plan(v, snapshot: sim.snapshot, target: .entryFlightPathAngle(1 * deg)))
    }

    /// TIG at the next apoapsis or periapsis of the conic, or at a given time.
    func testIgnitionTimes() {
        let mu = 3.986004418e14, re = 6_378_137.0
        let body = CelestialBody(id: 1, name: "Earth", gm: mu, radius: re, rotation: .none, soiRadius: .infinity)
        let o = BodyOrientation(icrfToBody: .identity, angularVelocity: .zero)
        let rp = re + 200 * km, ra = re + 400 * km, a = (rp + ra) / 2, e = (ra - rp) / (ra + rp)
        let p = a * (1 - e * e), nu = 1.0
        let s = Kepler.State(position: Vec3(cos(nu), sin(nu), 0) * (p / (1 + e * cos(nu))),
                             velocity: Vec3(-sin(nu), e + cos(nu), 0) * (mu / p).squareRoot())
        let t0 = Epoch(tdbSecondsPastJ2000: 1000)
        let el = OrbitalElements(position: s.position, velocity: s.velocity, mu: mu)
        let target = DeorbitPlanner.Target.perigeeRadius(re + 30 * km)
        let atApo = try! XCTUnwrap(DeorbitPlanner.plan(from: s, around: body, orientation: o, at: t0,
                                                       ignition: .apoapsis, target: target))
        XCTAssertEqual(atApo.ignition - t0, el.timeToApoapsis, accuracy: 1e-9)
        XCTAssertEqual(atApo.preBurn.position.length, ra, accuracy: 1e-3)
        XCTAssertEqual(atApo.deltaVLocal.z, 0, accuracy: 1e-6)          // horizontal there
        let atPeri = try! XCTUnwrap(DeorbitPlanner.plan(from: s, around: body, orientation: o, at: t0,
                                                        ignition: .periapsis, target: target))
        XCTAssertEqual(atPeri.preBurn.position.length, rp, accuracy: 1e-3)
        XCTAssertGreaterThan(atPeri.deltaVMagnitude, atApo.deltaVMagnitude)   // lowering perigee is cheapest at apogee
        let later = try! XCTUnwrap(DeorbitPlanner.plan(from: s, around: body, orientation: o, at: t0,
                                                       ignition: .at(t0 + 100), target: target))
        XCTAssertEqual(later.ignition, t0 + 100)
        XCTAssertLessThan((later.preBurn.position - Kepler.propagate(s, mu: mu, by: 100).position).length, 1e-6)
        XCTAssertNil(DeorbitPlanner.plan(from: s, around: body, orientation: o, at: t0, ignition: .at(t0 + -1),
                                         target: target))
    }

    /// P30's axes: X horizontal forward, Y opposite the orbit normal, Z down,
    /// right-handed.
    func testLocalVerticalFrame() {
        let s = Kepler.State(position: Vec3(6.6e6, 1e6, 2e6), velocity: Vec3(-1_000, 6_500, 3_000))
        let m = DeorbitPlanner.localVerticalFrame(s)
        XCTAssertEqual(m.determinant, 1, accuracy: 1e-12)
        XCTAssertLessThan((m.r2 + s.position.normalized).length, 1e-12)
        XCTAssertLessThan((m.r1 + s.position.cross(s.velocity).normalized).length, 1e-12)
        XCTAssertEqual(m.r0.dot(s.position), 0, accuracy: 1e-6)
        XCTAssertGreaterThan(m.r0.dot(s.velocity), 0)
        let local = m * s.velocity
        XCTAssertEqual(local.y, 0, accuracy: 1e-9)
        XCTAssertLessThan(local.z, 0)                                   // climbing
    }
}
