import XCTest
@testable import OrbitCore

/// Closed-loop attitude control of `VesselLibrary.saturnV()` by its gimbals
/// and the S-IVB APS (design tests S3-S8, and S9-S13; TVC datasheet §7.4).
/// The pad tests fly the stack's aerodynamics (datasheet §11) through
/// US-1976 with no wind and without the IU; they stay checks of the law's own
/// behaviour, and `testEngineOutTrim` turns the aerodynamic model off for its
/// thrust-only moment balance. Published control performance (FER
/// deflections, attitude errors) is checked with the IU in SaturnIUTests; the
/// external references here are the SP-4029 roll program, the APS roles and
/// the APS thrust. Checks that only guard the law's own behaviour say so.
final class SaturnVControlTests: XCTestCase {
    let deg = Double.pi / 180, lbf = 4.4482216152605

    enum Phase { case liftoff, sIIIgnition, sIVBIgnition }

    /// The stack at a stage's ignition, in free space with its engines lit
    /// and past their start ramp (2.2 s on the S-II, 2.5 s on the S-IVB), so
    /// the tests begin at full thrust.
    func freeSpace(_ phase: Phase) throws -> (Simulation, Vessel) {
        let sim = try Simulation.forTests(perturbations: false)
        let v = VesselLibrary.saturnV()
        switch phase {
        case .liftoff: break
        case .sIIIgnition: v.jettisonNextStage()
        case .sIVBIgnition: for _ in 0..<4 { v.jettisonNextStage() }
        }
        sim.add(v)
        sim.placeInFreeSpace(v)
        v.mainThrottle = 1
        let ramp = v.activeStage?.thrusters.compactMap { $0.transients.map { $0.startDelay + $0.startRise } }.max() ?? 0
        if ramp > 0 { sim.run(seconds: ramp + 0.02) }
        return (sim, v)
    }

    /// The stack on LC-39A placed as the Saturn sat on the pad: +z (Position
    /// I) east, the 90° pad azimuth (TVC datasheet §7.1).
    func onPad(_ sim: Simulation) -> Vessel {
        let v = VesselLibrary.saturnV()
        sim.add(v)
        sim.placeLanded(v, on: sim.system.earth, latitude: AS506.padLatitude, longitude: AS506.padLongitude,
                        azimuth: 270)
        return v
    }

    func gimbalAngles(_ v: Vessel) -> [Double] { v.thrusters.flatMap { $0.gimbal.map(\.angle) } }
    func firingAPS(_ v: Vessel) -> Set<String> {
        Set(v.thrusters.filter { $0.name.hasPrefix("APS") && $0.level > 0 }.map(\.name))
    }

    // S3: a 10° pointing step at each stage's ignition settles without a
    // limit cycle and with every actuator off its stops. Mass properties are
    // frozen at ignition. A regression guard on the law: M0's law
    // limit-cycles here by 1-5°. The slew (the reference at 0.5 alpha / Kd:
    // 1.7°/s at liftoff and S-IVB ignition, 1.0°/s at S-II ignition, which
    // the stack overshoots to 2.2 and 1.2°/s) stays below the 3°/s pitch and
    // yaw EDS overrate (datasheet §7.4 C, L).
    func testPointingStepsSettleWithoutLimitCycle() throws {
        for phase in [Phase.liftoff, .sIIIgnition, .sIVBIgnition] {
            let (sim, v) = try freeSpace(phase)
            let r = v.position.normalized, u = v.attitude.rotate(.unitX)
            let nose = r * cos(10 * deg) + u * sin(10 * deg), z = nose.cross(r.cross(u)).normalized
            v.attitude = Quat(matrix: Mat3(columns: nose, z.cross(nose), z))
            v.autopilot = .radialOut
            let full = v.tanks.map(\.mass)
            var t = 0.0, reached = -1.0, after = 0.0, onStop = 0, peakRate = 0.0
            sim.run(seconds: 30) {
                t += 0.02
                for (tank, m) in zip(v.tanks, full) { tank.mass = m }
                v.recenter()
                let e = angleBetween(v.attitude.rotate(.unitX), v.position)
                if reached < 0 && e < 0.5 * deg { reached = t }
                if reached >= 0 { after = max(after, e) }
                if v.thrusters.contains(where: { $0.gimbal.contains { abs($0.angle) >= $0.range.upperBound } }) {
                    onStop += 1
                }
                let w = v.angularVelocity
                peakRate = max(peakRate, (w.y * w.y + w.z * w.z).squareRoot())
            }
            XCTAssertLessThan(peakRate, 3 * deg, "\(phase)")
            XCTAssertGreaterThan(reached, 0, "\(phase)")
            XCTAssertLessThan(reached, 12, "\(phase)")
            XCTAssertLessThan(after, 0.5 * deg, "\(phase)")
            XCTAssertLessThan(angleBetween(v.attitude.rotate(.unitX), v.position), 0.01 * deg, "\(phase)")
            XCTAssertEqual(onStop, 0, "\(phase)")
        }
    }

    // S4: attitude hold after a (0.57, 0.57, -0.43)°/s kick: never more than
    // 0.8° off, back within 0.05° in 7 s, no actuator faster than its rate
    // limit. On the S-IVB the APS holds roll inside its ±1° dead band (EH
    // 8.30, M) plus one minimum pulse throughout, and its pitch engines never
    // fire while the J-2 burns. Self-consistency only.
    func testHoldAfterKick() throws {
        for phase in [Phase.liftoff, .sIIIgnition, .sIVBIgnition] {
            let (sim, v) = try freeSpace(phase)
            v.autopilot = .attitudeHold
            sim.run(seconds: 1)
            let held = v.heldAttitude!
            v.angularVelocity += Vec3(0.01, 0.01, -0.0075)
            var last = gimbalAngles(v), worst = 0.0, worstRoll = 0.0, tooFast = 0, apsPitch = 0
            let rates = v.thrusters.flatMap { $0.gimbal.map(\.rateLimit) }
            // The APS's roll on the S-IVB is bounded on its own (below).
            let apsRoll = phase == .sIVBIgnition
            sim.run(seconds: 7) {
                let now = gimbalAngles(v)
                for k in now.indices where abs(now[k] - last[k]) > rates[k] * 0.02 + 1e-15 { tooFast += 1 }
                last = now
                let e = rotationVector(v.attitude.conjugate * held)
                worst = max(worst, apsRoll ? (e.y * e.y + e.z * e.z).squareRoot() : e.length)
                worstRoll = max(worstRoll, abs(e.x))
                if firingAPS(v).contains(where: { $0.hasSuffix("pitch") }) { apsPitch += 1 }
            }
            let e = rotationVector(v.attitude.conjugate * held)
            XCTAssertEqual(tooFast, 0, "\(phase)")
            XCTAssertEqual(apsPitch, 0, "\(phase)")
            XCTAssertLessThan(worst, 0.8 * deg, "\(phase)")
            if apsRoll { XCTAssertLessThan(worstRoll, 1.1 * deg, "\(phase)") }
            XCTAssertLessThan((e.y * e.y + e.z * e.z).squareRoot(), 0.05 * deg, "\(phase)")
            XCTAssertLessThan(abs(e.x), apsRoll ? 1.1 * deg : 0.05 * deg, "\(phase)")
        }
    }

    // S5: S-IC engine 1 out at 30 s in attitude hold (thrust-to-weight is
    // below 1 at first motion with four engines, so it fails in flight). The
    // three other outboard engines trim the missing engine's moment: each
    // actuator at atan(d / 3L) within 1 % (an analytic moment balance on the
    // model's geometry: d = R / sqrt 2, the engine's offset from each axis,
    // and L the gimbal-to-CoM distance; R is L-graded, so it is read from the
    // model); the
    // rate dies out and the error stays a few degrees (the law has no
    // integral term). Kill-rotation, which only damps rates, drifts at about
    // 1.6°/s here; selected again, the hold captures the drifting attitude at
    // once (a steady drift is within the law's linear range) and stops it.
    // Self-consistency, apart from the moment balance. The aerodynamic model
    // is off, so the balance is the thrust's alone (from 30 s the air would
    // add its own moment as the engine-out stack drifts across the flow).
    func testEngineOutTrim() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let v = onPad(sim)
        v.aerodynamics = []
        v.autopilot = .attitudeHold
        v.mainThrottle = 1
        sim.run(seconds: 30)
        let engine1 = v.thrusters.first { $0.name == "S-IC engine 1" }!
        engine1.isEnabled = false
        var worst = 0.0
        sim.run(seconds: 10) { worst = max(worst, rotationVector(v.attitude.conjugate * v.heldAttitude!).length) }
        let L = -(engine1.position.x + v.parts[0].offset.x), d = abs(engine1.position.y)
        let trim = atan(d / (3 * L))
        for i in 2...4 {
            for a in v.thrusters.first(where: { $0.name == "S-IC engine \(i)" })!.gimbal {
                XCTAssertEqual(abs(a.angle), trim, accuracy: trim * 1e-2)
            }
        }
        XCTAssertEqual(engine1.gimbal.map(\.angle), [0, 0])
        XCTAssertLessThan(v.angularVelocity.length, 0.01 * deg)
        XCTAssertLessThan(worst, 5 * deg)

        v.autopilot = .killRotation
        sim.run(seconds: 5)
        XCTAssertGreaterThan(v.angularVelocity.length, 1 * deg)
        v.autopilot = .attitudeHold
        let drifted = v.attitude
        sim.tick()
        XCTAssertEqual(v.heldAttitude, drifted)
        worst = 0
        sim.run(seconds: 10) { worst = max(worst, rotationVector(v.attitude.conjugate * v.heldAttitude!).length) }
        XCTAssertLessThan(v.angularVelocity.length, 0.01 * deg)
        XCTAssertLessThan(worst, 5 * deg)
    }

    // S6: the AS-506 roll program. From range 13.2 s (SP-4029 Apollo 11
    // Timeline, H) the stack rolls +17.942° about +x at 1°/s, taking Position
    // I from the 90° pad azimuth to the 72.058° flight azimuth (SP-4029, H),
    // done at range 31.1 s (Timeline, M). The test supplies the command, as
    // the IU item will; the gimbals fly it. Position I is within 0.1° of
    // 72.058° at 31.1 s and 0.01° at 40 s, and mid-ramp the stack rolls at
    // +1.00°/s ± 0.02 (datasheet §7.4 C: a positive roll swings Position I
    // from east towards north). Rates stay far below the EDS overrate limits
    // (20°/s roll, M; 3°/s pitch and yaw, the lowest reading, L).
    func testRollProgram() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let v = onPad(sim)
        let q0 = v.attitude, up = q0.rotate(.unitX), east = q0.rotate(.unitZ), north = up.cross(east)
        func azimuth() -> Double {   // of +z, Position I
            let z = v.attitude.rotate(.unitZ)
            return atan2(z.dot(east), z.dot(north)) / deg
        }
        XCTAssertEqual(azimuth(), 90, accuracy: 1e-9)
        let total = (90 - 72.058) * deg, start = 13.2 - 0.30, rate = 1 * deg   // sim time = range time - 0.30 s
        v.autopilot = .attitudeHold
        v.mainThrottle = 1
        var t = 0.0, worstOffAxis = 0.0, peak = 0.0, worstRate = Vec3.zero, aps = 0
        while t < 39.7 - 1e-9 {
            let roll = min(total, max(0, t - start) * rate)
            v.attitudeCommand = AttitudeCommand(attitude: Quat(axis: up, angle: roll) * q0,
                                                rate: t >= start && roll < total ? up * rate : .zero)
            sim.tick()
            t += 0.02
            let e = rotationVector(v.attitude.conjugate * v.attitudeCommand!.attitude)
            worstOffAxis = max(worstOffAxis, (e.y * e.y + e.z * e.z).squareRoot())
            peak = max(peak, gimbalAngles(v).map(abs).max()!)
            let w = v.angularVelocity
            worstRate = Vec3(max(worstRate.x, abs(w.x)), max(worstRate.y, abs(w.y)), max(worstRate.z, abs(w.z)))
            if !firingAPS(v).isEmpty { aps += 1 }
            if abs(t - 21.9) < 0.01 { XCTAssertEqual(w.x / deg, 1, accuracy: 0.02) }
            if abs(t - (31.1 - 0.30)) < 0.01 { XCTAssertEqual(azimuth(), 72.058, accuracy: 0.1) }
        }
        XCTAssertEqual(azimuth(), 72.058, accuracy: 0.01)
        XCTAssertLessThan(worstOffAxis, 0.05 * deg)
        XCTAssertLessThan(peak, 1 * deg)
        XCTAssertLessThan(worstRate.x, 20 * deg)
        XCTAssertLessThan(max(worstRate.y, worstRate.z), 3 * deg)
        XCTAssertEqual(aps, 0)
    }

    // S7: the APS roles (APS-TN; EH 8.30): during the S-IVB burn it gives
    // roll only, so only the roll/yaw engines fire, in roll couples; in coast
    // all three axes, pitch engines included. Its phase-plane logic leaves
    // each axis inside the ±1° dead band (EH 8.30, M) plus one minimum pulse.
    // It draws only on its own tanks.
    func testAPSRollDuringBurnThreeAxesInCoast() throws {
        let (sim, v) = try freeSpace(.sIVBIgnition)
        v.autopilot = .attitudeHold
        sim.run(seconds: 1)
        v.angularVelocity += Vec3(0.005, 0.003, -0.003)
        // Every step, a roll couple at one level or nothing: no APS yaw.
        let couples: [Set<String>] = [[], ["APS I roll/yaw +t", "APS III roll/yaw +t"],
                                      ["APS I roll/yaw -t", "APS III roll/yaw -t"]]
        var fired = Set<String>(), notCouple = 0
        sim.run(seconds: 10) {
            let firing = firingAPS(v)
            fired.formUnion(firing)
            let levels = Set(v.thrusters.filter { firing.contains($0.name) }.map(\.level))
            if !couples.contains(firing) || levels.count > 1 { notCouple += 1 }
        }
        XCTAssertEqual(notCouple, 0)
        XCTAssertFalse(fired.isEmpty)
        XCTAssertTrue(fired.isSubset(of: ["APS I roll/yaw +t", "APS I roll/yaw -t", "APS III roll/yaw +t",
                                          "APS III roll/yaw -t"]))
        XCTAssertLessThan(abs(rotationVector(v.attitude.conjugate * v.heldAttitude!).x), 1.1 * deg)
        v.mainThrottle = 0
        sim.run(seconds: 0.5)   // the J-2's 0.42 s tail-off draws its last propellant
        v.angularVelocity += Vec3(0.002, 0.001, -0.001)
        let lox = v.tanks[0].mass, lh2 = v.tanks[1].mass, aps = v.tanks.dropFirst(2).map(\.mass)
        fired = []
        sim.run(seconds: 60) { fired.formUnion(firingAPS(v)) }
        XCTAssertTrue(fired.contains { $0.hasSuffix("pitch") })
        XCTAssertTrue(fired.contains { $0.contains("roll/yaw") })
        XCTAssertFalse(fired.contains { $0.hasSuffix("ullage") })
        XCTAssertEqual(v.tanks[0].mass, lox)
        XCTAssertEqual(v.tanks[1].mass, lh2)
        XCTAssertTrue(zip(aps, v.tanks.dropFirst(2).map(\.mass)).contains { $0 > $1 })
        let e = rotationVector(v.attitude.conjugate * v.heldAttitude!)
        XCTAssertLessThan(max(abs(e.x), abs(e.y), abs(e.z)), 1.1 * deg)
    }

    // S7, geometry (datasheet §7.4 D): about the S-IVB stack's real CoM, at
    // ignition and at cutoff, every APS attitude engine's torque has the sign
    // of each of its groups and none about the other axes; a roll couple
    // gives no yaw and a yaw pair no roll. The directions are inferred (L);
    // the check guards the group derivation.
    func testAPSTorquesMatchTheirGroups() {
        let v = VesselLibrary.saturnV()
        for _ in 0..<4 { v.jettisonNextStage() }
        let j2 = v.thrusters.first { $0.name == "S-IVB engine" }!
        for label in ["ignition", "cutoff"] {
            if label == "cutoff" {   // burn 1: 147.13 s (SP-4029 Apollo 11 Summary)
                j2.level = 1
                for _ in 0..<Int((147.13 / 0.02).rounded()) { v.consumePropellant(dt: 0.02) }
                j2.level = 0
                v.recenter()
            }
            let part = v.parts.first { $0.name == "S-IVB" }!
            var torques: [String: Vec3] = [:]
            for t in part.thrusters where t.name.hasPrefix("APS") && !t.name.hasSuffix("ullage") {
                let tq = (t.position + part.offset - v.centerOfMass).cross(t.direction)
                torques[t.name] = tq
                let pairs: [(ThrusterGroup, ThrusterGroup, Double)] = [(.rollRight, .rollLeft, tq.x),
                                                                      (.pitchUp, .pitchDown, tq.y),
                                                                      (.yawRight, .yawLeft, tq.z)]
                for (plus, minus, component) in pairs {
                    let sign: Double? = t.groups.contains(plus) ? 1 : t.groups.contains(minus) ? -1 : nil
                    if let sign {
                        XCTAssertGreaterThan(component * sign, 0, "\(t.name) \(label)")
                    } else {
                        XCTAssertEqual(component, 0, accuracy: 1e-9 * tq.length, "\(t.name) \(label)")
                    }
                }
            }
            let roll = torques["APS I roll/yaw +t"]! + torques["APS III roll/yaw +t"]!
            let yaw = torques["APS I roll/yaw +t"]! + torques["APS III roll/yaw -t"]!
            XCTAssertEqual(roll.z, 0, accuracy: 1e-9 * roll.length, label)
            XCTAssertEqual(yaw.x, 0, accuracy: 1e-9 * yaw.length, label)
        }
    }

    // S7, ullage (datasheet §7.4 D): the TB5 ullage burn after S-IVB cutoff,
    // both 72 lbf engines (APS-TN; NASM, H) for 88 s (MAN503 and EH, L-M),
    // gives 0.4173 m/s at the mass after the S-IVB's first thrust decay,
    // 135,102 kg (FER Table 20-5); the model's, after burn 1's 147.13 s and
    // its decay, is within 0.3 % of it (it guards the thrust and the
    // wiring, ±0.5 %).
    // The propellant follows F t / (Isp g0) with the model's Isp (a
    // placeholder: never tested against a value).
    func testTB5UllageBurn() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let v = VesselLibrary.saturnV()
        for _ in 0..<4 { v.jettisonNextStage() }
        let j2 = v.thrusters.first { $0.name == "S-IVB engine" }!
        j2.level = 1
        for _ in 0..<Int((147.13 / 0.02).rounded()) { v.consumePropellant(dt: 0.02) }
        j2.level = 0
        for _ in 0..<25 { v.consumePropellant(dt: 0.02) }   // the tail-off
        v.recenter()
        XCTAssertEqual(v.mass, 135_102, accuracy: 135_102 * 3e-3)
        sim.add(v)
        let x = sim.placeInFreeSpace(v)
        let apsTanks = v.tanks.dropFirst(2), before = apsTanks.reduce(0) { $0 + $1.mass }
        v.translationInput = Vec3(1, 0, 0)
        for _ in 0..<88 { sim.tick(1) }   // constant thrust: 1 s steps are exact enough
        let ullage = v.thrusters.filter { $0.name.hasSuffix("ullage") }
        XCTAssertEqual(ullage.filter { $0.level > 0 }.count, 2)
        XCTAssertEqual(firingAPS(v).count, 2)
        XCTAssertEqual(v.velocity.dot(x), 0.4173, accuracy: 0.4173 * 5e-3)
        XCTAssertLessThan(v.angularVelocity.length, 1e-9)
        let used = before - apsTanks.reduce(0) { $0 + $1.mass }
        let flow = ullage.reduce(0) { $0 + $1.rating.thrustVacuum / ($1.rating.ispVacuum * 9.80665) }
        XCTAssertEqual(used, flow * 88, accuracy: 1e-9)
    }

    // S8: the hold survives 10x time warp through liftoff, with the steps
    // `advance` chooses; the APS stays off. Self-consistency only.
    func testHoldThroughLiftoffAtWarp() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let v = onPad(sim)
        v.autopilot = .attitudeHold
        v.mainThrottle = 1
        sim.warp = 10
        var aps = 0
        for _ in 0..<120 {
            sim.advance(by: 1.0 / 60)
            if !firingAPS(v).isEmpty { aps += 1 }
        }
        XCTAssertEqual(v.status, .flying)
        XCTAssertLessThan(rotationVector(v.attitude.conjugate * v.heldAttitude!).length, 0.01 * deg)
        XCTAssertEqual(aps, 0)
    }

    // S9: released from manual input at 11°/s (a 3 s full pitch pulse at
    // liftoff mass), the hold damps the turn and captures once it is within
    // the law's linear range (Kd w <= alpha): one swing, about 2° past the
    // capture, and it settles where the turn stopped, with no swing back
    // past the hold and not back to where the input was released. Mass
    // properties frozen. Self-consistency only.
    func testHoldCapturesWhereAFastTurnStops() throws {
        let (sim, v) = try freeSpace(.liftoff)
        v.autopilot = .attitudeHold
        sim.run(seconds: 1)
        let full = v.tanks.map(\.mass)
        func freeze() {
            for (tank, m) in zip(v.tanks, full) { tank.mass = m }
            v.recenter()
        }
        v.rotationInput = RotationCommand(pitch: 1)
        sim.run(seconds: 3, afterEach: freeze)
        v.rotationInput = RotationCommand()
        XCTAssertGreaterThan(v.angularVelocity.y, 10 * deg)
        let released = v.attitude
        var pitch: [Double] = []
        sim.run(seconds: 30) {
            freeze()
            pitch.append(rotationVector(released.conjugate * v.attitude).y)
        }
        let peak = pitch.max()!, final = pitch.last!
        XCTAssertGreaterThan(final, 30 * deg)
        XCTAssertLessThan(peak - final, 3 * deg)
        XCTAssertGreaterThan(pitch[pitch.firstIndex(of: peak)!...].min()!, final - 0.5 * deg)
        XCTAssertLessThan(rotationVector(v.attitude.conjugate * v.heldAttitude!).length, 0.01 * deg)
    }

    // S10: in the S-IVB burn the APS flies roll and the J-2 pitch and yaw. A
    // hold command 150° away in roll and 3° in pitch brings the nose in as
    // fast as the 3° pitch alone: the gimbals track the nose only, so the
    // slow APS roll neither holds back the nose's slew nor mixes into its
    // error. Self-consistency only.
    func testSIVBBurnNoseIgnoresTheRollCommand() throws {
        var settled: [Double] = []
        for roll in [0.0, 150.0] {
            let (sim, v) = try freeSpace(.sIVBIgnition)
            v.autopilot = .attitudeHold
            sim.tick()
            let goal = v.attitude * Quat(axis: .unitX, angle: roll * deg) * Quat(axis: .unitY, angle: 3 * deg)
            v.attitudeCommand = AttitudeCommand(attitude: goal)
            var t = 0.0, last = 0.0
            sim.run(seconds: 12) {
                t += 0.02
                if angleBetween(v.attitude.rotate(.unitX), goal.rotate(.unitX)) > 0.05 * deg { last = t }
            }
            settled.append(last)
        }
        XCTAssertLessThan(settled[0], 7)
        XCTAssertEqual(settled[1], settled[0], accuracy: 1)
    }

    // S11: released from a short manual tap (1.0 and 1.3 s in pitch, 0.1 s
    // in roll, at liftoff mass), the hold waits for the actuators to unwind
    // before it captures: on release they are still at full deflection and
    // speed the turn up for about a second. It settles past the release,
    // within the law's swing (about 0.4 alpha: 1.8° in pitch) of where the
    // turn stops, the longer tap further, and no actuator reaches a stop
    // after the capture. In roll, ten times more agile with the FER's roll
    // inertia (datasheet §4), the hold captures during the turn and settles
    // back near the capture, past the release but short of the turn's end.
    // Self-consistency only.
    func testHoldAfterAShortTapSettlesPastTheRelease() throws {
        var finals: [Double] = []
        for (pitch, tap) in [(true, 1.0), (true, 1.3), (false, 0.1)] {
            let (sim, v) = try freeSpace(.liftoff)
            v.autopilot = .attitudeHold
            sim.run(seconds: 1)
            let full = v.tanks.map(\.mass)
            func freeze() {
                for (tank, m) in zip(v.tanks, full) { tank.mass = m }
                v.recenter()
            }
            v.rotationInput = pitch ? RotationCommand(pitch: 1) : RotationCommand(roll: 1)
            sim.run(seconds: tap, afterEach: freeze)
            v.rotationInput = RotationCommand()
            let released = v.attitude
            var angle: [Double] = [], onStop = 0
            sim.run(seconds: 20) {
                freeze()
                let r = rotationVector(released.conjugate * v.attitude)
                angle.append(pitch ? r.y : r.x)
                if v.heldAttitude != nil
                    && v.thrusters.contains(where: { $0.gimbal.contains { abs($0.angle) >= $0.range.upperBound } }) {
                    onStop += 1
                }
            }
            let peak = angle.max()!, final = angle.last!, label = "\(pitch ? "pitch" : "roll") \(tap) s"
            XCTAssertEqual(onStop, 0, label)
            XCTAssertGreaterThan(final, pitch ? 0.6 * peak : 0, label)
            XCTAssertLessThan(peak - final, (pitch ? 2.5 : 14) * deg, label)
            XCTAssertLessThan(rotationVector(v.attitude.conjugate * v.heldAttitude!).length, 0.01 * deg, label)
            finals.append(final)
        }
        XCTAssertGreaterThan(finals[1], finals[0])
    }

    // S12: hold selected while the stack turns about all three axes, each
    // below its own single-axis capture rate (Kd w = alpha). Roll uses the
    // travel pitch and yaw leave on the same actuators, so the hold damps
    // first and captures once the damping command fits all of them at once:
    // no actuator reaches a stop after the capture, and the roll swing stays
    // within the law's single-axis swing (0.41 alpha rad with the default
    // gains). Mass properties frozen. Self-consistency only.
    func testHoldCapturesAThreeAxisTurnOffTheStops() throws {
        for (roll, pitchYaw) in [(0.6, 0.95), (0.95, 0.95)] {
            let (sim, v) = try freeSpace(.liftoff)
            let full = v.tanks.map(\.mass)
            func freeze() {
                for (tank, m) in zip(v.tanks, full) { tank.mass = m }
                v.recenter()
            }
            sim.run(seconds: 0.2, afterEach: freeze)
            v.applyThrottles()
            let control = v.controlAllocation(), inertia = v.inertia, gains = v.tvcGains
            let alpha = Vec3(control.authority.x / inertia[0, 0], control.authority.y / inertia[1, 1],
                             control.authority.z / inertia[2, 2])
            let kd = 2 * gains.dampingRatio * min(gains.naturalFrequency, 3 / control.slewTime)
            v.angularVelocity = Vec3(roll * alpha.x, pitchYaw * alpha.y, pitchYaw * alpha.z) * (1 / kd)
            v.autopilot = .attitudeHold
            var onStop = 0, swing = 0.0
            sim.run(seconds: 10) {
                freeze()
                guard let held = v.heldAttitude else { return }
                if v.thrusters.contains(where: { $0.gimbal.contains { abs($0.angle) >= $0.range.upperBound } }) {
                    onStop += 1
                }
                swing = max(swing, abs(rotationVector(held.conjugate * v.attitude).x))
            }
            XCTAssertNotNil(v.heldAttitude, "\(roll)")
            XCTAssertEqual(onStop, 0, "\(roll)")
            XCTAssertLessThan(swing, 0.42 * alpha.x, "\(roll)")
        }
    }

    // S13: in the S-IVB burn, a hold command with the nose exactly reversed
    // (a 180° yaw, or a half turn about another axis across the nose) turns
    // the nose about the command's own axis, as for a command a hair short
    // of reversed: it arrives with the command's roll, so the APS has no
    // roll to fly; the APS tanks off the axis couple the turn into roll
    // gyroscopically, by 0.002°/s on the FER's roll inertia. Self-consistency
    // only.
    func testSIVBBurnNoseReversalTurnsAboutTheCommandsAxis() throws {
        for axis in [Vec3.unitZ, Vec3(0, 0.5, 0.75.squareRoot())] {
            let (sim, v) = try freeSpace(.sIVBIgnition)
            v.autopilot = .attitudeHold
            sim.tick()
            v.attitudeCommand = AttitudeCommand(attitude: v.attitude * Quat(axis: axis, angle: .pi))
            var aps = 0, roll = 0.0
            sim.run(seconds: 5) {
                if !firingAPS(v).isEmpty { aps += 1 }
                roll = max(roll, abs(v.angularVelocity.x))
            }
            XCTAssertEqual(aps, 0, "\(axis)")
            XCTAssertLessThan(roll, 0.005 * deg, "\(axis)")
        }
    }
}
