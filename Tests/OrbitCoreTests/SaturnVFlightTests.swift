import XCTest
@testable import OrbitCore

/// `VesselLibrary.saturnV()` in the simulation (design tests C1-C6, and A8-A11
/// on the real stack). Expected values are literals with their source, as in
/// `SaturnVDataTests`.
final class SaturnVFlightTests: XCTestCase {
    let lb = 0.45359237, lbf = 4.4482216152605, g0 = 9.80665
    let deg = Double.pi / 180

    /// The stack on LC-39A at its geocentric latitude (as the datasheet's orbit
    /// targets assume), nose up, crew's "up" towards the 72° azimuth.
    func onPad(_ sim: Simulation) -> Vessel {
        let v = VesselLibrary.saturnV()
        sim.add(v)
        sim.placeLanded(v, on: sim.system.earth, latitude: AS506.padLatitude, longitude: AS506.padLongitude,
                        azimuth: 72)
        return v
    }

    func mains(_ v: Vessel, _ stage: String) -> [Thruster] {
        v.parts.first { $0.name == stage }!.thrusters.filter { $0.groups.contains(.main) }
    }

    // C1: it stands on the pad through 60 s of time warp.
    func testStandsOnPad() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let v = onPad(sim)
        let m = v.mass
        sim.warp = 10
        sim.advance(by: 6)
        XCTAssertEqual(v.status, .landed)
        XCTAssertEqual(v.altitude, v.baseHeight, accuracy: 1e-3)
        XCTAssertGreaterThan(v.attitude.rotate(.unitX).dot(v.position.normalized), 0.999999)
        XCTAssertEqual(v.mass, m)
    }

    // C2: Z at any setting lights the F-1s at full thrust, and the stack lifts
    // off on the first step.
    func testLiftsOffOnFirstStep() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let v = onPad(sim)
        let m0 = v.mass
        let p = sim.system.earth.atmosphere!.state(altitude: v.altitude).pressure
        v.mainThrottle = 0.3
        sim.tick()
        XCTAssertEqual(v.status, .flying)
        XCTAssertTrue(sim.events.contains { $0.message == "Apollo 11: liftoff" })
        // Mechanism: five fixed nozzles at full level, F = 5 (F_vac - p A_e)
        // with the flight-matched F-1 (7,930,844 N, 9.96 m^2; M1 datasheet §3).
        XCTAssertEqual(v.thrustAcceleration, 5 * (7_930_844 - p * 9.96) / m0, accuracy: v.thrustAcceleration * 2e-3)
        // Liftoff thrust 7,648,000 lbf (This Day in Aviation, Braeunig; basis
        // unknown); the constant-flow model is about 1.7 % high at liftoff.
        XCTAssertEqual(v.thrustAcceleration * m0, 7_648_000 * lbf, accuracy: 7_648_000 * lbf * 0.025)
    }

    // C3: vertical S-IC flight, centre engine cut at the published CECO: LOX
    // depletion ends the burn at the published OECO, and the origin stays at
    // the CoM. With no attitude control at all the stack stays vertical: the
    // thrust has no moment about the CoM (a symmetry check; the stand-ins are
    // tested in closed loop below).
    func testVerticalSICFlight() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let v = onPad(sim)
        let engines = mains(v, "S-IC")
        let rp1 = v.tanks[1]
        v.mainThrottle = 1
        // Range time 135.20 s (SP-4029 Apollo 11 Timeline) is simulation time
        // 134.90 s, since simulation time 0 is first motion at range 0.30 s.
        let cecoStep = Int((134.90 / 0.02).rounded())
        var steps = 0, worstCoM = 0.0, worstTilt = 0.0, acceleration = 0.0
        while engines[0].hasPropellant && steps < 9_000 {
            acceleration = v.thrustAcceleration
            sim.tick()
            steps += 1
            if steps == cecoStep { engines[4].isEnabled = false }
            worstCoM = max(worstCoM, v.centerOfMass.length)
            worstTilt = max(worstTilt, angleBetween(v.attitude.rotate(.unitX), v.position))
        }
        XCTAssertEqual(v.status, .flying)
        XCTAssertLessThan(worstCoM, 1e-9)
        XCTAssertLessThan(worstTilt, 0.5 * deg)
        // Consistency: the F-1 flow was derived from these times and the
        // published consumption. OECO at range 161.63 s (SP-4029 Apollo 11
        // Summary); RP-1 at OECO 30,763 lb (SP-4029 Propellant Usage); vehicle
        // 1,817,735 lb (ground ignition weight less the consumption, SP-4029).
        XCTAssertEqual(Double(steps) * 0.02 + 0.30, 161.63, accuracy: 0.2)
        XCTAssertEqual(rp1.mass / lb, 30_763, accuracy: 30_763 * 1e-2)
        XCTAssertEqual(v.mass / lb, 1_817_735, accuracy: 1_817_735 * 5e-3)
        // Independent: 3.94 g just before OECO (SP-4029 Ascent Phase).
        XCTAssertEqual(acceleration / g0, 3.94, accuracy: 0.05)
    }

    // C3 in closed loop: a pitch and yaw kick of 0.29°/s just after liftoff.
    // Kill-rotation fires the stand-ins, which bring the rate back to the
    // autopilot's dead band (2e-4 rad/s per axis) in about 2 s; the nose turns
    // about 0.2° on the way. Uncontrolled, it would turn 0.87° in those 3 s.
    func testKillRotationDampsAKickWithTheStandIns() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let v = onPad(sim)
        let standIns = v.thrusters.filter { $0.name.contains("TVC stand-in") }
        v.autopilot = .killRotation
        v.mainThrottle = 1
        sim.run(seconds: 1)
        XCTAssertEqual(v.status, .flying)
        XCTAssertFalse(standIns.contains { $0.level > 0 })
        v.angularVelocity += Vec3(0, 0.004, -0.003)
        let nose = v.attitude.rotate(.unitX)
        var firing = 0
        sim.run(seconds: 3) { if standIns.contains(where: { $0.level > 0 }) { firing += 1 } }
        XCTAssertGreaterThan(firing, 0)
        XCTAssertLessThan(abs(v.angularVelocity.y), 2.5e-4)
        XCTAssertLessThan(abs(v.angularVelocity.z), 2.5e-4)
        XCTAssertLessThan(angleBetween(v.attitude.rotate(.unitX), nose), 0.3 * deg)
    }

    // C4 (A12 on the real stack): four Space presses separate the S-IC, the
    // interstage, the LES, then the S-II with the aft interstage. Nothing
    // moves, mass and momentum are conserved, and only the LES separates ahead.
    func testSpaceKeyStagingSequence() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let v = VesselLibrary.saturnV()
        sim.add(v)
        sim.placeInCircularOrbit(v, around: sim.system.earth, altitude: 400_000)
        let m = v.mass, momentum = v.velocity * m
        var construction: [ObjectIdentifier: Vec3] = [:]
        for p in v.parts { construction[ObjectIdentifier(p)] = p.offset - v.structureOrigin }
        var separated: [[String]] = []
        var ahead: [Double] = []
        while let spent = sim.stage(v) {
            separated.append(spent.parts.map(\.name))
            XCTAssertEqual(spent.name, "Apollo 11 – \(spent.parts[0].name)")
            ahead.append(v.attitude.inverseRotate(spent.position - v.position).x)
            for w in [v, spent] {
                XCTAssertLessThan(w.centerOfMass.length, 1e-9)
                for p in w.parts {
                    let c = p.offset - w.structureOrigin
                    XCTAssertLessThan((c - construction[ObjectIdentifier(p)]!).length, 1e-9, p.name)
                }
            }
            XCTAssertNil(sim.stage(spent))
        }
        XCTAssertEqual(separated, [["S-IC"], ["S-IC/S-II interstage"], ["LES"], ["S-II", "S-II/S-IVB interstage"]])
        XCTAssertEqual(v.parts.map(\.name), ["S-IVB", "IU", "SLA", "LM", "CSM"])
        XCTAssertEqual(sim.vessels.count, 5)
        XCTAssertEqual(sim.vessels.reduce(0) { $0 + $1.mass }, m, accuracy: 1e-6)
        let after = sim.vessels.reduce(Vec3.zero) { $0 + $1.velocity * $1.mass }
        XCTAssertLessThan((after - momentum).length, momentum.length * 1e-12)
        guard ahead.count == 4 else { return XCTFail("expected 4 separations") }
        XCTAssertGreaterThan(ahead[2], 0)
        for i in [0, 1, 3] { XCTAssertLessThan(ahead[i], 0) }
        // Bookkeeping: S-IVB 262,613 + IU 4,275 + spacecraft 109,646 less the
        // LES 8,890 lb (SP-4029 Ground Ignition Weights; LES by difference).
        XCTAssertEqual(v.mass / lb, 262_613 + 4_275 + 109_646 - 8_890, accuracy: 1e-6)
    }

    // C5: the interim stand-ins give 0.5 to 3 deg/s^2 in pitch and yaw at each
    // stage's ignition, as pure couples, and burn almost nothing.
    func testTVCStandInAuthority() {
        let v = VesselLibrary.saturnV()
        func check(_ label: String) {
            let inertia = v.inertia
            for (command, axis) in [(RotationCommand(pitch: 1), 1), (RotationCommand(yaw: 1), 2)] {
                v.applyControls(rotation: command)
                let (force, torque) = v.thrustForceAndTorque(ambientPressure: 0, seaLevelPressure: 0)
                let alpha = [torque.x, torque.y, torque.z][axis] / inertia[axis, axis] / deg
                XCTAssertGreaterThan(alpha, 0.5, label)
                XCTAssertLessThan(alpha, 3, label)
                XCTAssertLessThan(force.length, 1e-6, label)
            }
        }
        check("liftoff")
        // Full command for 160 s draws under 100 kg, all of it fuel.
        v.applyControls(rotation: RotationCommand(roll: 1, pitch: 1, yaw: 1))
        let before = v.tanks.map(\.mass)
        v.consumePropellant(dt: 160)
        let drawn = zip(before, v.tanks.map(\.mass)).map { $0 - $1 }
        XCTAssertLessThan(drawn.reduce(0, +), 100)
        for i in [0, 2, 4] { XCTAssertEqual(drawn[i], 0, v.tanks[i].name) }

        v.jettisonNextStage()
        check("S-II ignition")
        for _ in 0..<3 { v.jettisonNextStage() }
        XCTAssertEqual(v.parts[0].name, "S-IVB")
        check("S-IVB ignition")
    }

    // C6, with A8 and A11 on the real stack: in free space the HUD's stage Δv
    // matches the Δv a full S-IC burn achieves, while the origin stays at the
    // moving CoM and construction offsets stay fixed.
    func testHUDDeltaVMatchesFreeSpaceSICBurn() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let v = VesselLibrary.saturnV()
        sim.add(v)
        let x = sim.placeInFreeSpace(v)
        let construction = v.parts.map { $0.offset - v.structureOrigin }
        let station0 = v.structuralCenterOfMass.x
        let hud = v.mainDeltaV
        let engines = mains(v, "S-IC")
        v.mainThrottle = 1
        var worst = 0.0, steps = 0
        while engines[0].hasPropellant && steps < 20_000 {   // about 7,800
            sim.tick()
            steps += 1
            worst = max(worst, v.centerOfMass.length)
        }
        XCTAssertFalse(engines[0].hasPropellant)
        XCTAssertLessThan(worst, 1e-9)
        for (p, c) in zip(v.parts, construction) {
            XCTAssertLessThan((p.offset - v.structureOrigin - c).length, 1e-9, p.name)
        }
        XCTAssertGreaterThan(abs(v.structuralCenterOfMass.x - station0), 1)
        XCTAssertEqual(v.velocity.dot(x), hud, accuracy: hud * 1e-3)
    }

    // A9 on the real stack: the structure follows F/m wherever the propellant
    // sits; column and lumped tanks give the same construction-origin path.
    func testStructurePathDoesNotDependOnTankPlacement() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let a = VesselLibrary.saturnV(), b = VesselLibrary.saturnV()
        for t in b.tanks { t.geometry = .lumped }
        b.recenter()
        sim.add(a)
        sim.add(b)
        sim.placeInFreeSpace(a)
        sim.placeInFreeSpace(b)
        b.position += a.inertialPosition(ofStructuralPoint: .zero) - b.inertialPosition(ofStructuralPoint: .zero)
        let stations0 = (a.structuralCenterOfMass.x, b.structuralCenterOfMass.x)
        a.mainThrottle = 1
        b.mainThrottle = 1
        sim.run(seconds: 50)
        let gap = a.inertialPosition(ofStructuralPoint: .zero) - b.inertialPosition(ofStructuralPoint: .zero)
        XCTAssertLessThan(gap.length, 1e-4)
        let moved = (a.structuralCenterOfMass.x - stations0.0, b.structuralCenterOfMass.x - stations0.1)
        XCTAssertGreaterThan(abs(moved.0 - moved.1), 1)
    }

    // A10 on the real stack: after a 60 s S-IC burn, a tumbling stack's true
    // CoM coasts like a point mass.
    func testTumbleAfterBurnKeepsCenterOfMassOnItsPath() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let v = VesselLibrary.saturnV(), twin = VesselLibrary.capsule()
        sim.add(v)
        sim.add(twin)
        sim.placeInFreeSpace(v)
        sim.placeInFreeSpace(twin)
        v.mainThrottle = 1
        sim.run(seconds: 60)
        v.mainThrottle = 0
        twin.position = v.position
        twin.velocity = v.velocity
        v.angularVelocity = Vec3(0, 0.05, 0)
        sim.run(seconds: 60)
        let trueCoM = v.position + v.attitude.rotate(v.centerOfMass)
        XCTAssertLessThan((trueCoM - twin.position).length, 1e-6)
    }
}
