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
        // Mechanism: five fixed nozzles at full level, F = 5 (F_vac - p A_e),
        // with the F-1 at first motion: 2,633 kg/s at 2,980.5 N s/kg and a
        // 10.10 m^2 exit (FER Figure 5-3, derived; `AS506.f1`).
        XCTAssertEqual(v.thrustAcceleration, 5 * (2_633 * 2_980.5 - p * 10.10) / m0,
                       accuracy: v.thrustAcceleration * 2e-4)
        // Independent: the stage's site thrust at liftoff, about 34.35 MN (FER
        // Figure 5-3, M; at the pad's 100.6 kPa, not the model's standard
        // atmosphere), and "a steady-state acceleration of approximately
        // 1.2 g" (FER §9.2.1).
        XCTAssertEqual(v.thrustAcceleration * m0, 34.35e6, accuracy: 34.35e6 * 0.01)
        XCTAssertEqual(v.thrustAcceleration / g0, 1.2, accuracy: 0.02)
    }

    // C3: vertical S-IC flight, centre engine cut at the published CECO: LOX
    // depletion ends the burn at the published OECO, and the origin stays at
    // the CoM. With no attitude control at all the stack stays vertical: the
    // thrust has no moment about the CoM and the gimbals stay at null (a
    // symmetry check; closed loop is tested below and in SaturnVControlTests).
    // The aerodynamic model is off: the Saturn V is aerodynamically unstable
    // (datasheet §11), so uncontrolled it would not stay vertical; the
    // generic drag along the airflow remains.
    func testVerticalSICFlight() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let v = onPad(sim)
        v.aerodynamics = []
        let engines = mains(v, "S-IC")
        let rp1 = v.tanks[1]
        v.mainThrottle = 1
        // Range time 135.20 s (SP-4029 Apollo 11 Timeline) is simulation time
        // 134.90 s, since simulation time 0 is first motion at range 0.30 s.
        let cecoStep = Int((134.90 / 0.02).rounded())
        var steps = 0, worstCoM = 0.0, worstTilt = 0.0, acceleration = 0.0, deflected = 0
        while engines[0].hasPropellant && steps < 9_000 {
            acceleration = v.thrustAcceleration
            sim.tick()
            steps += 1
            if steps == cecoStep { engines[4].isEnabled = false }
            worstCoM = max(worstCoM, v.centerOfMass.length)
            worstTilt = max(worstTilt, angleBetween(v.attitude.rotate(.unitX), v.position))
            if v.thrusters.contains(where: { $0.gimbal.contains { $0.angle != 0 } }) { deflected += 1 }
        }
        XCTAssertEqual(v.status, .flying)
        XCTAssertEqual(deflected, 0)
        XCTAssertLessThan(worstCoM, 1e-9)
        XCTAssertLessThan(worstTilt, 0.5 * deg)
        // Consistency: the F-1 flow and mixture-ratio scales were fitted to
        // these. LOX depletion at range 161.63 s (FER Table 2-2) with 13,954
        // kg of RP-1 aboard (FER Table 5-2).
        XCTAssertEqual(Double(steps) * 0.02 + 0.30, 161.63, accuracy: 0.03)
        XCTAssertEqual(rp1.mass, 13_954, accuracy: 13_954 * 1e-3)
        // Bookkeeping, given the FER's first-motion mass and LOX residual and
        // the fitted RP-1 residual: the vehicle at OECO is 664 kg above FER
        // Table 20-1's 827,292 kg, the S-IC's frost and purges (312 kg) and
        // the upper stages' frost and purge gas (349 kg), which the model
        // does not shed.
        XCTAssertEqual(v.mass - 827_292, 664, accuracy: 10)
        // Independent: 38.61 m/s^2 just before OECO (FER Table 4-1, the S-IC's
        // maximum total inertial acceleration; drag is negligible there).
        XCTAssertEqual(acceleration, 38.61, accuracy: 38.61 * 3e-3)
    }

    // C3 in closed loop: a pitch and yaw kick of 0.29°/s just after liftoff.
    // Kill-rotation deflects the outboard F-1s, which bring the rate back
    // below 2.5e-4 rad/s per axis in about 2 s; the nose turns about 0.2° on
    // the way. Uncontrolled, it would turn 0.87° in those 3 s. The APS stays
    // off, and the S-II and S-IVB engines stay at null (TVC datasheet §7.1:
    // locked until S-IC/S-II separation and S-IVB ignition).
    func testKillRotationDampsAKickWithGimbals() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let v = onPad(sim)
        let outboard = mains(v, "S-IC").prefix(4)
        let upper = mains(v, "S-II") + mains(v, "S-IVB")
        let aps = v.thrusters.filter { $0.name.hasPrefix("APS") }
        v.autopilot = .killRotation
        v.mainThrottle = 1
        sim.run(seconds: 1)
        XCTAssertEqual(v.status, .flying)
        v.angularVelocity += Vec3(0, 0.004, -0.003)
        let nose = v.attitude.rotate(.unitX)
        var peak = 0.0
        sim.run(seconds: 3) {
            peak = max(peak, outboard.flatMap { $0.gimbal.map { abs($0.angle) } }.max()!)
            XCTAssertFalse(aps.contains { $0.level > 0 })
            XCTAssertFalse(upper.contains { $0.gimbal.contains { $0.angle != 0 } })
        }
        XCTAssertGreaterThan(peak, 0.05 * deg)
        XCTAssertLessThan(peak, 1 * deg)
        XCTAssertLessThan(abs(v.angularVelocity.y), 2.5e-4)
        XCTAssertLessThan(abs(v.angularVelocity.z), 2.5e-4)
        XCTAssertLessThan(angleBetween(v.attitude.rotate(.unitX), nose), 0.3 * deg)
    }

    // C4 (A12 on the real stack): five Space presses separate the S-IC, the
    // interstage, the LES, the S-II with the aft interstage, then the S-IVB
    // ullage motors' cases. Nothing moves (the retros and ullage motors the
    // presses light have not burned yet), mass and momentum are conserved,
    // and only the LES separates ahead.
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
        XCTAssertEqual(separated, [["S-IC"], ["S-IC/S-II interstage"], ["LES"], ["S-II", "S-II/S-IVB interstage"],
                                   ["S-IVB ullage rockets"]])
        XCTAssertEqual(v.parts.map(\.name), ["S-IVB", "IU", "SLA", "LM", "CSM"])
        XCTAssertEqual(sim.vessels.count, 6)
        XCTAssertEqual(sim.vessels.reduce(0) { $0 + $1.mass }, m, accuracy: 1e-6)
        let after = sim.vessels.reduce(Vec3.zero) { $0 + $1.velocity * $1.mass }
        XCTAssertLessThan((after - momentum).length, momentum.length * 1e-12)
        guard ahead.count == 5 else { return XCTFail("expected 5 separations") }
        XCTAssertGreaterThan(ahead[2], 0)
        for i in [0, 1, 3, 4] { XCTAssertLessThan(ahead[i], 0) }
        // Bookkeeping: S-IVB 262,613 and IU 4,275 lb (SP-4029 Ground Ignition
        // Weights) less the S-IVB's ullage motors and aft frame, which left
        // with their parts (53 + 61 + 23 kg, FER Table 20-9), and the
        // spacecraft after LET jettison, 45,693 kg (FER Table 20-9).
        XCTAssertEqual(v.mass, (262_613 + 4_275) * lb - 53 - 61 - 23 + 45_693, accuracy: 1e-6)
    }

    // C5: gimbal authority at each stage's full thrust (vacuum), from the
    // model's own geometry (gimbal heights and the F-1 radius are L, so no
    // published torque is used): pitch and yaw n F L delta, roll 4 F R sqrt(2) delta for the
    // clusters (both actuators of a diagonal engine), the single J-2 none,
    // leaving roll to the APS (2 x 147 lbf at 3.5 m). Unit commands give
    // torque about their own axis only.
    func testGimbalAuthority() {
        let v = VesselLibrary.saturnV()
        func check(_ label: String, engines n: Double, range: Double) {
            v.mainThrottle = 1
            v.applyThrottles()
            // Past the start ramp: the gimbals count only thrust delivered.
            let ramp = v.activeStage!.thrusters.compactMap { $0.transients.map { $0.startDelay + $0.startRise } }
            for _ in 0...Int((ramp.max() ?? 0) / 0.02) + 1 { v.consumePropellant(dt: 0.02) }
            v.recenter()
            let c = v.controlAllocation()
            let e = v.activeStage!.thrusters.first { !$0.gimbal.isEmpty }!
            let L = -(e.position.x + v.activeStage!.offset.x), f = e.maxThrustVacuum, delta = range * deg
            let radius = (e.position.y * e.position.y + e.position.z * e.position.z).squareRoot()
            XCTAssertEqual(c.gimbalAuthority.y, n * f * L * delta, accuracy: n * f * L * delta * 1e-12, label)
            XCTAssertEqual(c.gimbalAuthority.z, n * f * L * delta, accuracy: n * f * L * delta * 1e-12, label)
            XCTAssertEqual(c.gimbalAuthority.x, n * f * radius * 2.squareRoot() * delta, accuracy: 1e-3, label)
            for (command, axis) in [(RotationCommand(roll: 1), 0), (RotationCommand(pitch: 1), 1),
                                    (RotationCommand(yaw: 1), 2)] {
                v.applyControls(rotation: command)
                v.advanceActuators(dt: 10)
                let tq = v.thrustForceAndTorque(ambientPressure: 0, seaLevelPressure: 0).torque
                let parts = [tq.x, tq.y, tq.z]
                for k in 0..<3 where k != axis { XCTAssertLessThan(abs(parts[k]), 1e-6 * abs(parts[axis]), label) }
            }
            v.mainThrottle = 0
            v.applyControls(rotation: RotationCommand())
            v.advanceActuators(dt: 10)
        }
        // F-1 ±5°; S-II J-2 ±7°; S-IVB J-2 ±7° (engine radii from the model).
        check("liftoff", engines: 4, range: 5)
        v.jettisonNextStage()
        check("S-II ignition", engines: 4, range: 7)
        for _ in 0..<3 { v.jettisonNextStage() }
        XCTAssertEqual(v.parts[0].name, "S-IVB")
        check("S-IVB ignition", engines: 1, range: 7)
        XCTAssertEqual(v.rotationAuthority().x, 2 * 147 * lbf * 3.5, accuracy: 1e-6)
    }

    // C5 through a shutdown ramp: the gimbals keep steering the decaying
    // thrust however the engines were cut, by the throttle (as the IU does
    // at T3, T4 and the S-IVB cutoff) or by disabling them, and stop when
    // it ends (0.66 s for the F-1).
    func testGimbalsSteerThroughTheTailOff() {
        for byThrottle in [true, false] {
            let v = VesselLibrary.saturnV()
            let outboard = mains(v, "S-IC").prefix(4)
            v.mainThrottle = 1
            v.applyThrottles()
            v.consumePropellant(dt: 0.02)
            let full = v.controlAllocation().gimbalAuthority.y
            if byThrottle {
                v.mainThrottle = 0
                v.applyThrottles()
            } else {
                for e in mains(v, "S-IC") { e.isEnabled = false }
            }
            XCTAssertTrue(outboard.allSatisfy { $0.isDelivering })
            XCTAssertEqual(v.controlAllocation().gimbalAuthority.y, full, accuracy: full * 0.02, "\(byThrottle)")
            for _ in 0..<33 { v.consumePropellant(dt: 0.02) }
            XCTAssertFalse(outboard.contains { $0.isDelivering })
            XCTAssertEqual(v.controlAllocation().gimbalAuthority.y, 0, "\(byThrottle)")
        }
    }

    // A start ramp at time warp: the simulation keeps its thrust steps from
    // the start command, not from the first thrust, so the S-IVB J-2's start
    // (nothing for 0.6 s, then a 1.9 s rise) gives the same velocity at 100x
    // and 1,000x as at 1x in the app's 1/60 s frames, after a coast frame.
    func testStartRampAtTimeWarp() throws {
        var gained: [Double] = []
        for (warp, frames) in [(1.0, 2_000), (100, 20), (1_000, 2)] {
            let sim = try Simulation.forTests(perturbations: false)
            let v = VesselLibrary.saturnV()
            for _ in 0..<4 { v.jettisonNextStage() }
            sim.add(v)
            let x = sim.placeInFreeSpace(v)
            sim.warp = warp
            sim.advance(by: 1.0 / 60)
            v.mainThrottle = 1
            for _ in 0..<frames { sim.advance(by: 1.0 / 60) }   // 33.3 s
            gained.append(v.velocity.dot(x))
        }
        XCTAssertGreaterThan(gained[0], 150)
        for g in gained.dropFirst() { XCTAssertEqual(g, gained[0], accuracy: gained[0] * 1e-4) }
    }

    // C5, the outboard cant (TVC datasheet §7.1 and §7.4 A): an actuator bias
    // that leans each outboard F-1's thrust line 2° radially inwards
    // ("approximately 2 degrees" outboard nozzles: EL, EH 8.13, M; the radial
    // reading is L) leaves no net lateral force or torque, cuts the outboard
    // axial thrust by cos 2° = 0.99939, and leaves 3.59° of the ±5° travel on
    // the cant side. Only the mechanism: the 20.6 s ramp is the IU item's.
    func testOutboardCantBias() {
        let v = VesselLibrary.saturnV()
        let outboard = Array(mains(v, "S-IC").prefix(4)), cant = 2 * deg
        let f = outboard[0].maxThrustVacuum
        for e in outboard {
            let r = (e.position.y * e.position.y + e.position.z * e.position.z).squareRoot()
            e.gimbal[0].bias = atan(-e.position.z / r * tan(cant))   // pitch plane, tilt +z
            e.gimbal[1].bias = atan(e.position.y / r * tan(cant))    // yaw plane, tilt -y
        }
        v.mainThrottle = 1
        v.applyControls(rotation: RotationCommand())
        v.advanceActuators(dt: 10)
        for e in outboard {
            let d = e.thrustDirection, outwards = Vec3(0, e.position.y, e.position.z).normalized
            XCTAssertEqual(angleBetween(d, .unitX), cant, accuracy: 1e-12, e.name)
            XCTAssertEqual(angleBetween(d - Vec3.unitX * d.x, -outwards), 0, accuracy: 1e-9, e.name)
        }
        let (force, torque) = v.thrustForceAndTorque(ambientPressure: 0, seaLevelPressure: 0)
        XCTAssertLessThan(Vec3(0, force.y, force.z).length, 1e-6 * force.x)
        XCTAssertLessThan(torque.length, 1e-6 * f)
        XCTAssertEqual((force.x - f) / (4 * f), 0.99939, accuracy: 1e-5)
        // The gimbal authority scales with the travel left about the bias.
        let travel = outboard[0].gimbal[0].travel
        XCTAssertEqual(travel / deg, 3.59, accuracy: 0.005)
        let canted = v.controlAllocation().gimbalAuthority
        for e in outboard { for i in e.gimbal.indices { e.gimbal[i].bias = 0 } }
        XCTAssertEqual(canted.y / v.controlAllocation().gimbalAuthority.y, travel / (5 * deg), accuracy: 1e-12)
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
        sim.run(seconds: 1)   // the F-1 tail-off
        twin.position = v.position
        twin.velocity = v.velocity
        v.angularVelocity = Vec3(0, 0.05, 0)
        sim.run(seconds: 60)
        let trueCoM = v.position + v.attitude.rotate(v.centerOfMass)
        XCTAssertLessThan((trueCoM - twin.position).length, 1e-6)
    }
}
