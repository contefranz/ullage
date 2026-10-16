import XCTest
@testable import OrbitCore

/// Gimbal kinematics, actuators, allocation and effector selection (design
/// tests G1-G12, and G13-G14 on the gimbal law), on toy vehicles unless noted. Every expected value is
/// worked out from the toy literals: these are mechanism checks, with no
/// external reference.
final class GimbalTests: XCTestCase {
    let deg = Double.pi / 180

    func engines(_ v: Vessel) -> [Thruster] { v.thrusters.filter { $0.groups.contains(.main) } }
    /// Command `rotation`, then put every actuator at its command.
    func settle(_ v: Vessel, _ rotation: RotationCommand) {
        v.applyControls(rotation: rotation)
        v.advanceActuators(dt: 1e3)
    }
    func torque(_ v: Vessel) -> Vec3 { v.thrustForceAndTorque(ambientPressure: 0, seaLevelPressure: 0).torque }
    func components(_ v: Vec3) -> [Double] { [v.x, v.y, v.z] }

    // G1: each angle is the deflection projected on its actuator's plane;
    // exactly `direction` at null.
    func testThrustDirection() {
        let t = Thruster(name: "E", position: .zero, direction: .unitX, rating: Toy.engine, feed: nil, groups: [.main],
                         gimbal: Toy.actuators())
        XCTAssertEqual(t.thrustDirection, Vec3.unitX)
        t.gimbal[0].angle = 3 * deg
        XCTAssertEqual(angleBetween(t.thrustDirection, .unitX), 3 * deg, accuracy: 1e-15)
        XCTAssertEqual(t.thrustDirection.y, 0)
        XCTAssertGreaterThan(t.thrustDirection.z, 0)
        t.gimbal[1].angle = -2 * deg
        let d = t.thrustDirection
        XCTAssertEqual(atan2(d.z, d.x), 3 * deg, accuracy: 1e-15)
        XCTAssertEqual(atan2(-d.y, d.x), -2 * deg, accuracy: 1e-15)
        XCTAssertEqual(d.length, 1, accuracy: 1e-15)
    }

    // G2: rate-limited ramp, then exponential lag, exact for any step;
    // commands clamped into the range.
    func testActuatorResponse() {
        var a = GimbalActuator(tilt: .unitZ, limit: 5 * deg, rateLimit: 5 * deg)
        a.setCommand(9 * deg)
        XCTAssertEqual(a.command, 5 * deg)
        a.advance(dt: 0.4)
        XCTAssertEqual(a.angle, 2 * deg, accuracy: 1e-15)
        a.advance(dt: 10)
        XCTAssertEqual(a.angle, 5 * deg)
        // Lag 0.2 s at 5°/s: a ramp until 1° from the command (0.6 s), then exponential.
        var lagged = GimbalActuator(tilt: .unitZ, limit: 5 * deg, rateLimit: 5 * deg, timeConstant: 0.2)
        lagged.setCommand(4 * deg)
        var stepped = lagged
        lagged.advance(dt: 1)
        for _ in 0..<50 { stepped.advance(dt: 0.02) }
        XCTAssertEqual(lagged.angle, stepped.angle, accuracy: 1e-15)
        XCTAssertEqual(lagged.angle, 4 * deg - 1 * deg * exp(-(1 - 0.6) / 0.2), accuracy: 1e-15)
    }

    // G3: the deflected force and its torque about the CoM come out of the
    // force/torque sum, applied at the gimbal point.
    func testDeflectedForceAndTorque() {
        let v = Toy.clusterRocket(engines: 1)
        v.mainThrottle = 1
        v.applyControls(rotation: RotationCommand())
        let e = engines(v)[0]
        e.gimbal[0].angle = 4 * deg
        let (f, tq) = v.thrustForceAndTorque(ambientPressure: 0, seaLevelPressure: 0)
        let expected = Vec3(cos(4 * deg), 0, sin(4 * deg)) * 1e6
        XCTAssertLessThan((f - expected).length, 1e-6)
        let r = e.position + v.parts[0].offset
        XCTAssertLessThan((tq - r.cross(expected)).length, 1e-6)
        XCTAssertGreaterThan(tq.y, 0)   // positive pitch angle, gimbal aft of the CoM: pitch up
    }

    // G4: pitch and yaw by common deflection, roll by tangential deflection
    // of the outboard engines; authorities from the geometry, no cross-axis
    // torque.
    func testClusterPatternsAndAuthority() {
        let v = Toy.clusterRocket()
        v.mainThrottle = 1
        v.applyThrottles()
        let c = v.controlAllocation()
        let L = -(engines(v)[0].position.x + v.parts[0].offset.x), R = 2.0, rho = 5 * deg
        XCTAssertEqual(c.gimbalAuthority.y, 4 * 1e6 * L * rho, accuracy: 1e-3)
        XCTAssertEqual(c.gimbalAuthority.z, 4 * 1e6 * L * rho, accuracy: 1e-3)
        XCTAssertEqual(c.gimbalAuthority.x, 4 * 1e6 * R * 2.squareRoot() * rho, accuracy: 1e-3)
        XCTAssertEqual(c.slewTime, 1, accuracy: 1e-12)
        for (command, axis) in [(RotationCommand(roll: 1), 0), (RotationCommand(pitch: 1), 1),
                                (RotationCommand(yaw: 1), 2)] {
            settle(v, command)
            let tq = components(torque(v)), on = tq[axis]
            for k in 0..<3 where k != axis { XCTAssertLessThan(abs(tq[k]), 1e-9 * on) }
            XCTAssertEqual(engines(v)[4].gimbal.count, 0)
            let angles = engines(v).prefix(4).flatMap { $0.gimbal.map(\.angle) }
            switch axis {
            case 1: XCTAssertEqual(angles, [rho, 0, rho, 0, rho, 0, rho, 0])
            case 2: XCTAssertEqual(angles, [0, rho, 0, rho, 0, rho, 0, rho])
            default: for a in angles { XCTAssertEqual(abs(a), rho, accuracy: 1e-15) }
            }
        }
        // Realised pitch torque: 4 F L sin(5°) (the linearisation is 0.13 % high).
        settle(v, RotationCommand(pitch: 1))
        XCTAssertEqual(torque(v).y, 4 * 1e6 * L * sin(rho), accuracy: 1e-6)
    }

    // G5: with an engine out the others re-mix with almost no cross-axis
    // torque; the dead engine's actuators return to null.
    func testEngineOutStaysDecoupled() {
        let v = Toy.clusterRocket()
        v.mainThrottle = 1
        engines(v)[0].isEnabled = false
        settle(v, RotationCommand())
        let trim = torque(v)   // the moment of the missing engine
        for (command, axis) in [(RotationCommand(roll: 0.5), 0), (RotationCommand(pitch: 0.5), 1),
                                (RotationCommand(yaw: -0.5), 2)] {
            settle(v, command)
            let tq = components(torque(v) - trim), on = abs(tq[axis])
            // Decoupled to first order: the cosine loss of the deflected engines
            // moves their axial-thrust moments by a second-order amount.
            for k in 0..<3 where k != axis { XCTAssertLessThan(abs(tq[k]), 5e-3 * on) }
            XCTAssertEqual(engines(v)[0].gimbal.map(\.angle), [0, 0])
        }
    }

    // G6: saturation keeps the pitch:yaw direction and roll gets what is
    // left; nothing passes a stop; a bias (cant) narrows the authority to the
    // travel left on its tighter side, and a zero command rests at the bias.
    func testSaturationAndBias() {
        let v = Toy.clusterRocket()
        v.mainThrottle = 1
        settle(v, RotationCommand(roll: 1, pitch: 1, yaw: 0.5))
        let tq = torque(v)
        XCTAssertEqual(tq.z / tq.y, 0.5, accuracy: 1e-3)
        for t in engines(v) { for a in t.gimbal { XCTAssertLessThanOrEqual(abs(a.angle), 5 * deg) } }
        let full = v.controlAllocation().gimbalAuthority
        for t in engines(v) { for i in t.gimbal.indices { t.gimbal[i].bias = 2 * deg } }
        v.applyThrottles()
        let biased = v.controlAllocation().gimbalAuthority
        XCTAssertEqual(biased.y / full.y, 3.0 / 5, accuracy: 1e-12)
        settle(v, RotationCommand())
        for t in engines(v).prefix(4) { XCTAssertEqual(t.gimbal.map(\.angle), [2 * deg, 2 * deg]) }
    }

    // G7, G8: one gimballed engine on the axis cannot roll. The rotation
    // groups take roll, the gimbal pitch and yaw, and translation still
    // fires; with the engine off the groups fly every axis.
    func testSingleEngineHandsRollToTheGroups() {
        let v = Toy.clusterRocket(engines: 1)
        engines(v)[0].position = Vec3(-10, 0, 0)
        v.parts[0].addRCS(foreX: 8, aftX: -8, radius: 2, thrust: 2_000, isp: 280, tank: v.parts[0].tanks[1])
        v.mainThrottle = 1
        v.translationInput = Vec3(0, 1, 0)
        v.applyControls(rotation: RotationCommand(roll: 1, pitch: 1, yaw: 1))
        let axes = v.controlAllocation().gimbalAxes
        XCTAssertEqual([axes.roll, axes.pitch, axes.yaw], [false, true, true])
        let rcs = v.thrusters.filter { !$0.groups.contains(.main) && $0.level > 0 }
        XCTAssertTrue(rcs.contains { $0.groups.contains(.rollRight) })
        XCTAssertFalse(rcs.contains { $0.groups.contains(.pitchUp) || $0.groups.contains(.pitchDown) })
        XCTAssertTrue(rcs.contains { $0.groups.contains(.translateRight) })
        XCTAssertEqual(engines(v)[0].gimbal.map(\.command), [5 * deg, 5 * deg])
        v.mainThrottle = 0
        v.applyControls(rotation: RotationCommand(pitch: 1))
        XCTAssertTrue(v.thrusters.contains { $0.groups.contains(.pitchUp) && $0.level > 0 })
        XCTAssertEqual(engines(v)[0].gimbal.map(\.command), [0, 0])
        XCTAssertEqual(v.rotationAuthority(), v.rcsAuthority())
    }

    // G9: a thruster in a roll group and a yaw group fires on the signed sum
    // of the two commands, so roll plus yaw gives half of each authority (the
    // S-IVB APS, whose roll/yaw engines serve both axes).
    func testSignedMixingOfTwoAxisThrusters() {
        let v = VesselLibrary.saturnV()
        for _ in 0..<4 { v.jettisonNextStage() }
        let c = v.controlAllocation()
        v.applyControls(rotation: RotationCommand(roll: 0.5, yaw: 0.5))
        let tq = torque(v)
        XCTAssertEqual(tq.x, 0.5 * c.groupAuthority.x, accuracy: 1e-6)
        XCTAssertEqual(tq.z, 0.5 * c.groupAuthority.z, accuracy: 1e-6)
        XCTAssertEqual(tq.y, 0, accuracy: 1e-6)
    }

    // G10: gimbal authority follows the thrust: ambient pressure and level.
    func testAuthorityFollowsThrust() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let v = Toy.clusterRocket()
        sim.add(v)
        sim.placeInFreeSpace(v)
        v.mainThrottle = 1
        v.applyThrottles()
        let vacuum = v.controlAllocation().gimbalAuthority
        v.atmosphere = USStandardAtmosphere1976().state(altitude: 0)
        let p = v.atmosphere.pressure
        let sea = v.controlAllocation().gimbalAuthority
        XCTAssertEqual(sea.y / vacuum.y, (1e6 - p * 0.8) / 1e6, accuracy: 1e-12)   // F_vac - p A_e
        v.mainThrottle = 0
        v.applyThrottles()
        XCTAssertEqual(v.controlAllocation().gimbalAuthority, .zero)
    }

    // G11: a step uses the angles at its start; then they move, with the
    // step's command held, at the rate limit (5°/s: 0.1° per 0.02 s).
    func testActuatorsMoveAfterTheStep() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let v = Toy.clusterRocket()
        sim.add(v)
        sim.placeInFreeSpace(v)
        v.mainThrottle = 1
        v.rotationInput = RotationCommand(pitch: 1)
        sim.tick()
        XCTAssertEqual(v.angularVelocity.length, 0, accuracy: 1e-12)   // no torque during the first step
        XCTAssertEqual(engines(v)[0].gimbal[0].angle, 0.1 * deg, accuracy: 1e-15)
        sim.tick()
        XCTAssertGreaterThan(v.angularVelocity.y, 0)
        XCTAssertEqual(engines(v)[0].gimbal[0].angle, 0.2 * deg, accuracy: 1e-15)
    }

    // G12: thrusters marked `activeStageOnly` (the S-IVB APS) respond, and
    // count in the group authority, only while their part is the active stage.
    func testActiveStageOnlyThrusters() {
        let v = VesselLibrary.saturnV()
        let aps = v.thrusters.filter { $0.name.hasPrefix("APS") }
        XCTAssertEqual(aps.count, 8)
        v.translationInput = Vec3(1, 0, 0)
        v.applyControls(rotation: RotationCommand(roll: 1, pitch: 1, yaw: 1))
        XCTAssertFalse(aps.contains { $0.level > 0 })
        XCTAssertEqual(v.rcsAuthority(), .zero)
        for _ in 0..<4 { v.jettisonNextStage() }
        v.applyControls(rotation: RotationCommand(roll: 1, pitch: 1, yaw: 1))
        XCTAssertTrue(aps.contains { $0.level > 0 && $0.name.hasSuffix("ullage") })
        XCTAssertTrue(aps.contains { $0.level > 0 && $0.name.hasSuffix("pitch") })
        XCTAssertGreaterThan(v.rcsAuthority().x, 0)
    }

    // G13: slow actuators lower the gimbal law's natural frequency to 3 / the
    // null-to-stop time, here 10 s (±0.5° at 0.05°/s on the toy cluster):
    // 0.3 rad/s instead of 0.8. A 10° pointing step then settles with no
    // limit cycle and no actuator on a stop; at 0.8 rad/s it tumbles. Mass
    // properties frozen.
    func testSlowActuatorsLowerTheLoopFrequency() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let v = Toy.clusterRocket(actuators: Toy.actuators(limit: 0.5 * deg, rate: 0.05 * deg))
        sim.add(v)
        sim.placeInFreeSpace(v)
        v.mainThrottle = 1
        let r = v.position.normalized, u = v.attitude.rotate(.unitX)
        let nose = r * cos(10 * deg) + u * sin(10 * deg), z = nose.cross(r.cross(u)).normalized
        v.attitude = Quat(matrix: Mat3(columns: nose, z.cross(nose), z))
        v.autopilot = .radialOut
        let full = v.tanks.map(\.mass)
        var t = 0.0, reached = -1.0, after = 0.0, onStop = 0
        sim.run(seconds: 45) {
            t += 0.02
            for (tank, m) in zip(v.tanks, full) { tank.mass = m }
            v.recenter()
            let e = angleBetween(v.attitude.rotate(.unitX), v.position)
            if reached < 0 && e < 0.5 * deg { reached = t }
            if reached >= 0 { after = max(after, e) }
            if v.thrusters.contains(where: { $0.gimbal.contains { abs($0.angle) >= $0.range.upperBound } }) {
                onStop += 1
            }
        }
        XCTAssertEqual(v.controlAllocation().slewTime, 10, accuracy: 1e-9)
        XCTAssertGreaterThan(reached, 0)
        XCTAssertLessThan(reached, 15)
        XCTAssertLessThan(after, 0.5 * deg)
        XCTAssertLessThan(angleBetween(v.attitude.rotate(.unitX), v.position), 0.01 * deg)
        XCTAssertEqual(onStop, 0)
    }

    // G14: with no authority at all (engines off, no rotation groups) the
    // gimbal law drops its reference, so a slew under way does not carry on
    // in the reference while the engines are off; relit, the hold restarts
    // from the current attitude and reaches the command.
    func testReferenceDroppedWithoutAuthority() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let v = Toy.clusterRocket()
        sim.add(v)
        sim.placeInFreeSpace(v)
        v.mainThrottle = 1
        v.autopilot = .attitudeHold
        sim.run(seconds: 0.1)
        let goal = Quat(axis: v.attitude.rotate(.unitY), angle: 10 * deg) * v.attitude
        v.attitudeCommand = AttitudeCommand(attitude: goal)
        sim.run(seconds: 1)
        XCTAssertNotEqual(v.referenceRate, .zero)
        v.mainThrottle = 0
        var kept = 0
        sim.run(seconds: 1) { if v.referenceAttitude != nil || v.referenceRate != .zero { kept += 1 } }
        XCTAssertEqual(kept, 0)
        v.mainThrottle = 1
        sim.run(seconds: 20)
        XCTAssertLessThan(rotationVector(v.attitude.conjugate * goal).length, 0.01 * deg)
    }
}
