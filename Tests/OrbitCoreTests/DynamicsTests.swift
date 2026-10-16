import XCTest
@testable import OrbitCore

final class OrbitElementsTests: XCTestCase {
    func testCircularAndElliptic() {
        let mu = 3.986004418e14
        let r = 6_678_137.0
        let circ = OrbitalElements(position: Vec3(r, 0, 0), velocity: Vec3(0, (mu / r).squareRoot(), 0), mu: mu)
        XCTAssertEqual(circ.semiMajorAxis, r, accuracy: 1e-3)
        XCTAssertEqual(circ.eccentricity, 0, accuracy: 1e-12)
        XCTAssertEqual(circ.inclination, 0, accuracy: 1e-12)
        XCTAssertEqual(circ.period, 2 * Double.pi * (r * r * r / mu).squareRoot(), accuracy: 1e-6)

        // Periapsis state of an e = 0.2 orbit inclined 30 deg.
        let a = 8_000_000.0, e = 0.2, i = 30 * Double.pi / 180
        let rp = a * (1 - e)
        let vp = (mu * (1 + e) / rp).squareRoot()
        let ell = OrbitalElements(position: Vec3(rp, 0, 0), velocity: Vec3(0, vp * cos(i), vp * sin(i)), mu: mu)
        XCTAssertEqual(ell.semiMajorAxis, a, accuracy: 1e-3)
        XCTAssertEqual(ell.eccentricity, e, accuracy: 1e-12)
        XCTAssertEqual(ell.inclination, i, accuracy: 1e-12)
        XCTAssertEqual(ell.trueAnomaly, 0, accuracy: 1e-9)
        XCTAssertEqual(ell.apoapsisRadius, a * 1.2, accuracy: 1e-3)
        XCTAssertEqual(ell.timeToApoapsis, ell.period / 2, accuracy: 1e-6)
    }
}

final class DynamicsTests: XCTestCase {
    func makeSim(perturbations: Bool) throws -> Simulation {
        let system = try SolarSystem.bundled()
        if !perturbations {
            system.perturbers = []
            system.earth.j2 = 0
        }
        return Simulation(system: system, time: Epoch(utcYear: 1969, month: 7, day: 16, hour: 13, minute: 32))
    }

    func testTwoBodyOrbitClosesAfterTenRevolutions() throws {
        let sim = try makeSim(perturbations: false)
        let v = VesselLibrary.capsule()
        sim.add(v)
        // Above the 1000 km atmosphere ceiling, so the orbit is purely Keplerian.
        sim.placeInCircularOrbit(v, around: sim.system.earth, altitude: 1_500_000, inclination: 32)
        let r0 = v.position, energy0 = v.velocity.lengthSquared / 2 - sim.system.earth.gm / v.position.length
        let period = v.elements(snapshot: sim.snapshot).period
        sim.warp = 1
        var remaining = 10 * period
        while remaining > 0 {
            let h = min(remaining, sim.maxStep())
            sim.step(h)
            remaining -= h
        }
        let energy1 = v.velocity.lengthSquared / 2 - sim.system.earth.gm / v.position.length
        XCTAssertLessThan(abs((energy1 - energy0) / energy0), 1e-9)
        XCTAssertLessThan((v.position - r0).length, 20, "position error after 10 orbits")
    }

    func testRocketEquation() throws {
        let sim = try makeSim(perturbations: false)
        let v = VesselLibrary.capsule()
        sim.add(v)
        // Far from Earth, opposite the Moon, at rest; fire perpendicular to the radius.
        let moonDir = (sim.snapshot.position(sim.system.moon) - sim.snapshot.position(sim.system.earth)).normalized
        v.reference = sim.system.earth
        v.position = moonDir * -5e8
        v.velocity = .zero
        let x = moonDir.cross(.unitZ).normalized, z = moonDir, y = z.cross(x)
        v.attitude = Quat(matrix: Mat3(columns: x, y, z))
        let m0 = v.mass
        let tank = v.tanks.first { $0.name == "SM propellant" }!
        let engine = v.thrusters.first { $0.name == "SM engine" }!
        v.mainThrottle = 1
        v.autopilot = .killRotation
        sim.warp = 1
        while tank.mass > 0 { sim.advance(by: 0.5) }
        let expected = engine.ispVacuum * standardGravity * log(m0 / (m0 - tank.capacity))
        XCTAssertEqual(v.velocity.dot(x), expected, accuracy: 1.0)
    }

    func testStagingConservesMassAndMomentum() throws {
        let sim = try makeSim(perturbations: false)
        let v = VesselLibrary.testRocket()
        sim.add(v)
        sim.placeInCircularOrbit(v, around: sim.system.earth, altitude: 400_000)
        let m = v.mass, p = v.velocity * v.mass
        let com = v.position
        guard let spent = sim.stage(v) else { return XCTFail("no stage") }
        XCTAssertEqual(v.mass + spent.mass, m, accuracy: 1e-6)
        XCTAssertEqual(((v.velocity * v.mass + spent.velocity * spent.mass) - p).length, 0, accuracy: 1e-3)
        let newCom = (v.position * v.mass + spent.position * spent.mass) / m
        XCTAssertEqual((newCom - com).length, 0, accuracy: 1e-6)
        XCTAssertEqual(v.parts.count, 2)
        XCTAssertEqual(sim.vessels.count, 2)
        // The upper stack sits above the spent stage along the vessel axis.
        XCTAssertGreaterThan(v.attitude.inverseRotate(v.position - spent.position).x, 10)
    }

    func testVesselOnPadRotatesWithEarth() throws {
        let sim = try makeSim(perturbations: true)
        let v = VesselLibrary.testRocket()
        sim.add(v)
        sim.placeLanded(v, on: sim.system.earth, latitude: 28.6083, longitude: -80.6041, azimuth: 72)
        let base = v.baseHeight
        sim.warp = 100
        for _ in 0..<36 { sim.advance(by: 1) }
        XCTAssertEqual(v.status, .landed)
        XCTAssertEqual(v.altitude, base, accuracy: 1e-3)
        let ll = v.latitudeLongitude(snapshot: sim.snapshot)
        XCTAssertEqual(ll.lat * 180 / Double.pi, 28.6083, accuracy: 1e-9)
        XCTAssertEqual(ll.lon * 180 / Double.pi, -80.6041, accuracy: 1e-9)
        let expected = EarthOrientation.rotationRate * (sim.system.earth.radius + base) * cos(28.6083 * Double.pi / 180)
        XCTAssertEqual(v.velocity.length, expected, accuracy: 0.05)
        // Nose points up.
        XCTAssertGreaterThan(v.attitude.rotate(.unitX).dot(v.position.normalized), 0.999999)
    }

    func testLiftoffAndClimb() throws {
        let sim = try makeSim(perturbations: true)
        let v = VesselLibrary.testRocket()
        sim.add(v)
        sim.placeLanded(v, on: sim.system.earth, latitude: 28.6083, longitude: -80.6041)
        v.autopilot = .killRotation
        v.mainThrottle = 1
        for _ in 0..<(30 * 60) { sim.advance(by: 1.0 / 60) }
        XCTAssertEqual(v.status, .flying)
        XCTAssertTrue(sim.events.contains { $0.message.contains("liftoff") })
        XCTAssertGreaterThan(v.altitude, 1_000)
        XCTAssertLessThan(v.altitude, 5_000)
        // Still roughly vertical with rate damping on.
        XCTAssertGreaterThan(v.attitude.rotate(.unitX).dot(v.position.normalized), 0.99)
        XCTAssertGreaterThan(v.dynamicPressure, 1_000)
    }

    func testMoonSphereOfInfluenceSwitch() throws {
        let sim = try makeSim(perturbations: true)
        let v = VesselLibrary.capsule()
        sim.add(v)
        let s = sim.snapshot
        let earthToMoon = s.position(sim.system.moon) - s.position(sim.system.earth)
        v.reference = sim.system.earth
        v.position = earthToMoon - earthToMoon.normalized * 30_000_000
        v.velocity = s.velocity(sim.system.moon) - s.velocity(sim.system.earth)
        sim.step(1)
        XCTAssertTrue(v.reference === sim.system.moon)
        XCTAssertEqual(v.position.length, 30_000_000, accuracy: 2_000)
    }

    func testProgradeAutopilotAligns() throws {
        let sim = try makeSim(perturbations: false)
        let v = VesselLibrary.capsule()
        sim.add(v)
        sim.placeInCircularOrbit(v, around: sim.system.earth, altitude: 200_000)
        v.attitude = Quat(axis: Vec3(0.3, 1, 0.2), angle: 2.0) * v.attitude
        v.angularVelocity = Vec3(0.01, -0.02, 0.005)
        v.autopilot = .prograde
        for _ in 0..<(400 * 10) { sim.advance(by: 0.1) }
        let angle = angleBetween(v.attitude.rotate(.unitX), v.velocity) * 180 / Double.pi
        XCTAssertLessThan(angle, 1.0)
        XCTAssertLessThan(v.angularVelocity.length, 0.01)
    }

    // Attitude hold on an RCS-only vessel (the M0 law on the full attitude
    // error, roll included): it returns to the attitude captured when
    // selected after a kick, then turns 86° about a skew axis to a commanded
    // attitude. Self-consistency only.
    func testAttitudeHoldOnRCS() throws {
        let sim = try makeSim(perturbations: false)
        let v = VesselLibrary.capsule()
        sim.add(v)
        sim.placeInCircularOrbit(v, around: sim.system.earth, altitude: 200_000)
        v.autopilot = .attitudeHold
        sim.advance(by: 0.1)
        let held = v.attitude
        v.angularVelocity += Vec3(0.01, -0.02, 0.005)
        for _ in 0..<(60 * 10) { sim.advance(by: 0.1) }
        XCTAssertLessThan(angleBetween(v.attitude.rotate(.unitX), held.rotate(.unitX)) * 180 / .pi, 0.2)
        XCTAssertLessThan(angleBetween(v.attitude.rotate(.unitZ), held.rotate(.unitZ)) * 180 / .pi, 0.2)
        let target = Quat(axis: Vec3(0.3, 1, 0.2), angle: 1.5) * held
        v.attitudeCommand = AttitudeCommand(attitude: target)
        for _ in 0..<(60 * 10) { sim.advance(by: 0.1) }
        XCTAssertLessThan(angleBetween(v.attitude.rotate(.unitX), target.rotate(.unitX)) * 180 / .pi, 0.2)
        XCTAssertLessThan(angleBetween(v.attitude.rotate(.unitZ), target.rotate(.unitZ)) * 180 / .pi, 0.2)
        XCTAssertLessThan(v.angularVelocity.length, 1e-3)
    }

    // The hold captures afresh after manual input and after a mode change,
    // rather than going back to an attitude captured before: on RCS, where
    // the input is released (after a 3 s pitch pulse, 19° away), and where
    // radial-out left the capsule. Self-consistency only.
    func testAttitudeHoldRecaptures() throws {
        let sim = try makeSim(perturbations: false)
        let v = VesselLibrary.capsule()
        sim.add(v)
        sim.placeInCircularOrbit(v, around: sim.system.earth, altitude: 200_000)
        func degrees(_ a: Quat, _ b: Quat) -> Double { rotationVector(a.conjugate * b).length * 180 / .pi }
        v.autopilot = .attitudeHold
        sim.advance(by: 0.1)
        let first = v.attitude
        v.rotationInput = RotationCommand(pitch: 1)
        for _ in 0..<30 { sim.advance(by: 0.1) }
        v.rotationInput = RotationCommand()
        let released = v.attitude
        for _ in 0..<(60 * 10) { sim.advance(by: 0.1) }
        XCTAssertGreaterThan(degrees(first, released), 10)
        XCTAssertLessThan(degrees(v.attitude, released), 0.2)
        v.autopilot = .radialOut
        for _ in 0..<(60 * 10) { sim.advance(by: 0.1) }
        v.autopilot = .attitudeHold
        sim.advance(by: 0.1)
        let reselected = v.attitude
        for _ in 0..<(30 * 10) { sim.advance(by: 0.1) }
        XCTAssertGreaterThan(degrees(released, reselected), 10)
        XCTAssertLessThan(degrees(v.attitude, reselected), 0.2)
    }

    // The hold's approach rate is profiled on the weakest group axis the turn
    // involves, roll included: on the drum, whose roll accelerates 3.5 times
    // slower than its pitch and yaw, a 30° roll command overshoots by under
    // 0.005 rad (the dead band is 0.002 rad; profiled on pitch, as M0's
    // pointing modes are, it overshoots by 0.15 rad). Self-consistency only.
    func testHoldProfilesRollWhenItIsTheWeakestAxis() throws {
        let sim = try makeSim(perturbations: false)
        let v = Toy.rollWeakDrum()
        sim.add(v)
        sim.placeInCircularOrbit(v, around: sim.system.earth, altitude: 200_000)
        let alpha = v.rotationAuthority().x / v.inertia[0, 0]
        XCTAssertLessThan(alpha, v.rotationAuthority().y / v.inertia[1, 1])
        v.autopilot = .attitudeHold
        sim.advance(by: 0.1)
        let goal = v.attitude * Quat(axis: .unitX, angle: 30 * .pi / 180)
        v.attitudeCommand = AttitudeCommand(attitude: goal)
        var overshoot = 0.0
        for _ in 0..<(60 * 10) {
            sim.advance(by: 0.1)
            overshoot = max(overshoot, -rotationVector(v.attitude.conjugate * goal).x)
        }
        XCTAssertLessThan(overshoot, 0.005)
        XCTAssertLessThan(rotationVector(v.attitude.conjugate * goal).length, 0.003)
    }
}
