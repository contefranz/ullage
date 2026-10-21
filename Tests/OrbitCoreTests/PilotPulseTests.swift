import XCTest
@testable import OrbitCore

/// The pilot's RCS pulses (`Vessel.firePilotPulse`), the RCS keys' taps.
final class PilotPulseTests: XCTestCase {
    /// The capsule at rest in free space, where nothing but its jets turns
    /// it, and gravity has no component along its +x axis.
    func capsuleInFreeSpace(warp: Double = 1) throws -> (Simulation, Vessel, Vec3) {
        let sim = try Simulation.forTests(perturbations: false)
        let v = VesselLibrary.capsule()
        sim.add(v)
        let x = sim.placeInFreeSpace(v)
        sim.warp = warp
        return (sim, v, x)
    }

    /// Run 1/60 s frames for `seconds` of simulation time at the warp set.
    /// Counted in frames: the epoch's last bit, near 1e9 s, is 1e-7 s.
    func fly(_ sim: Simulation, for seconds: Double) {
        for _ in 0..<max(1, Int((seconds * 60 / sim.warp).rounded())) { sim.advance(by: 1.0 / 60) }
    }

    // A pulse changes the capsule's pitch rate by its pitch authority over
    // its inertia times its length, Δω = M t / I, whatever the time warp its
    // 1/60 s frames run at (1×, 10×, 1000×): the steps end where the pulse
    // does, so the frames and steps do not cut it short or stretch it. A
    // 37 ms pulse, which neither the frames nor the 20 ms powered steps
    // divide. (The steps differ, so the propellant the jets burn moves the
    // mass properties a little differently: 1e-7.)
    func testTapImpulseIsTheSameAtAnyWarp() throws {
        var kicks: [Double] = []
        for warp in [1.0, 10, 1000] {
            let (sim, v, _) = try capsuleInFreeSpace(warp: warp)
            let expected = v.rotationAuthority().y / v.inertia[1, 1] * 0.037
            v.firePilotPulse(rotation: RotationCommand(pitch: 1), duration: 0.037)
            fly(sim, for: 2)
            XCTAssertFalse(v.pilotPulse.isActive)
            XCTAssertTrue(v.rotationInput.isZero)
            XCTAssertEqual(v.angularVelocity.y, expected, accuracy: 1e-4 * expected, "warp \(warp)")
            kicks.append(v.angularVelocity.y)
        }
        XCTAssertEqual(kicks[1], kicks[0], accuracy: 1e-6 * kicks[0])
        XCTAssertEqual(kicks[2], kicks[0], accuracy: 1e-6 * kicks[0])
    }

    // Nor on the frames' times: real frames are uneven, and a pulse's end
    // may fall a fraction of a millisecond into one, under the steps' 1 ms
    // floor. A tap and a fine tap, at 1× over frames of 15.3 to 17.9 ms (to
    // the propellant burned, 2e-6).
    func testTapImpulseDoesNotDependOnTheFrames() throws {
        let frames = [0.0163, 0.0171, 0.0158, 0.0179, 0.0153, 0.0167, 0.0161]
        for duration in [0.1, 0.014] {
            let (sim, v, _) = try capsuleInFreeSpace()
            let expected = v.rotationAuthority().y / v.inertia[1, 1] * duration
            v.firePilotPulse(rotation: RotationCommand(pitch: 1), duration: duration)
            for i in 0..<60 { sim.advance(by: frames[i % frames.count]) }
            XCTAssertFalse(v.pilotPulse.isActive)
            XCTAssertEqual(v.angularVelocity.y, expected, accuracy: 1e-5 * expected, "\(duration) s")
        }
    }

    // A fine (Control) tap fires 14 ms, the Apollo RCS minimum impulse:
    // 0.14 of a tap's turn (to the propellant burned), here at 100×, where
    // one frame holds either.
    func testFinePulseIsTheMinimumImpulse() throws {
        var kicks: [Double] = []
        for duration in [0.1, 0.014] {
            let (sim, v, _) = try capsuleInFreeSpace(warp: 100)
            v.firePilotPulse(rotation: RotationCommand(yaw: -1), duration: duration)
            fly(sim, for: 1)
            kicks.append(v.angularVelocity.z)
        }
        XCTAssertLessThan(kicks[0], 0)
        XCTAssertEqual(kicks[1] / kicks[0], 0.14, accuracy: 1e-6)
    }

    // A pulse at a level fires at that level: half the turn at 0.5.
    func testPulseLevel() throws {
        var kicks: [Double] = []
        for level in [1.0, 0.5] {
            let (sim, v, _) = try capsuleInFreeSpace()
            v.firePilotPulse(rotation: RotationCommand(roll: 1), duration: 0.1, level: level)
            fly(sim, for: 0.5)
            kicks.append(v.angularVelocity.x)
        }
        XCTAssertGreaterThan(kicks[0], 0)
        XCTAssertEqual(kicks[1] / kicks[0], 0.5, accuracy: 1e-5)
    }

    // A translation tap's Δv along +x is a tenth of what the same jets give
    // in 1 s held: the pulse is 0.1 s of the held firing.
    func testTranslationPulseIsATenthOfASecondHeld() throws {
        let (sim, v, x) = try capsuleInFreeSpace()
        var u0 = v.velocity.dot(x)
        v.firePilotPulse(translation: Vec3(1, 0, 0), duration: 0.1)
        fly(sim, for: 0.5)
        let pulse = v.velocity.dot(x) - u0

        let (sim2, w, x2) = try capsuleInFreeSpace()
        u0 = w.velocity.dot(x2)
        w.setPilotInput(rotation: RotationCommand(), translation: Vec3(1, 0, 0))
        fly(sim2, for: 1)
        let held = w.velocity.dot(x2) - u0
        XCTAssertGreaterThan(held, 0)
        XCTAssertEqual(pulse / held, 0.1, accuracy: 1e-5)
    }

    // A key held on an axis wins: a tap there fires nothing, while the
    // tap's other axes pulse. A second tap on an axis still pulsing adds
    // its time.
    func testHeldKeyWinsOverATapOnItsAxis() throws {
        let (sim, v, _) = try capsuleInFreeSpace()
        v.setPilotInput(rotation: RotationCommand(pitch: 1), translation: .zero)
        v.firePilotPulse(rotation: RotationCommand(pitch: -1, yaw: 1), duration: 0.1)
        XCTAssertEqual(v.rotationInput, RotationCommand(pitch: 1, yaw: 1))
        XCTAssertEqual(v.pilotPulse.rotationRemaining.y, 0)
        sim.advance(by: 0.04)
        v.setPilotInput(rotation: RotationCommand(), translation: .zero)
        XCTAssertEqual(v.rotationInput, RotationCommand(yaw: 1))
        XCTAssertEqual(v.pilotPulse.rotationRemaining.z, 0.06, accuracy: 1e-12)
        v.firePilotPulse(rotation: RotationCommand(yaw: 1), duration: 0.1)
        XCTAssertEqual(v.pilotPulse.rotationRemaining.z, 0.16, accuracy: 1e-12)
        sim.advance(by: 0.1)
        XCTAssertEqual(v.rotationInput, RotationCommand(yaw: 1))
        sim.advance(by: 0.06)
        XCTAssertTrue(v.rotationInput.isZero)
        XCTAssertFalse(v.pilotPulse.isActive)
    }

    // Taps on an axis add up: a run of them fires the sum of their pulses
    // however fast they come, so three taps of U 0.3 s apart give the same
    // Δv at 0.1×, where each pulse lasts 1 s of real time and runs into the
    // next, as at 1×. Opposite taps net: U then O 0.3 s later, at 0.1×,
    // leave 0.03 s on each side and no Δv. (To the propellant burned, 1e-6.)
    func testTapsAddUp() throws {
        var dv: [Double] = []
        for warp in [1.0, 0.1] {
            let (sim, v, x) = try capsuleInFreeSpace(warp: warp)
            let u0 = v.velocity.dot(x)
            for _ in 0..<3 {
                v.firePilotPulse(translation: Vec3(1, 0, 0), duration: 0.1)
                for _ in 0..<18 { sim.advance(by: 1.0 / 60) }
            }
            fly(sim, for: 0.5)
            XCTAssertFalse(v.pilotPulse.isActive)
            dv.append(v.velocity.dot(x) - u0)
        }
        XCTAssertGreaterThan(dv[0], 0)
        XCTAssertEqual(dv[1], dv[0], accuracy: 1e-5 * dv[0])

        let (sim, v, x) = try capsuleInFreeSpace(warp: 0.1)
        let u0 = v.velocity.dot(x)
        v.firePilotPulse(translation: Vec3(1, 0, 0), duration: 0.1)
        for _ in 0..<18 { sim.advance(by: 1.0 / 60) }
        XCTAssertEqual(v.pilotPulse.translationRemaining.x, 0.07, accuracy: 1e-12)
        v.firePilotPulse(translation: Vec3(-1, 0, 0), duration: 0.1)
        XCTAssertEqual(v.pilotPulse.translation.x, -1)
        XCTAssertEqual(v.pilotPulse.translationRemaining.x, 0.03, accuracy: 1e-12)
        fly(sim, for: 0.5)
        XCTAssertFalse(v.pilotPulse.isActive)
        XCTAssertEqual(v.velocity.dot(x) - u0, 0, accuracy: 1e-5 * dv[0])
        v.firePilotPulse(translation: Vec3(0, 0, 1), duration: 0.1)
        v.firePilotPulse(translation: Vec3(0, 0, -1), duration: 0.1)
        XCTAssertFalse(v.pilotPulse.isActive)
        XCTAssertEqual(v.translationInput, .zero)
    }

    // A hold that takes over from a tap's pulse on its axis ends it, so the
    // jets stop when the key goes up: at 0.1× the tap's 0.1 s pulse lasts
    // 1 s of real time, past the keys' 0.25 s hold delay. The pulses on the
    // other axes run on.
    func testHoldEndsTheTapsPulseOnItsAxis() throws {
        let (sim, v, _) = try capsuleInFreeSpace(warp: 0.1)
        v.firePilotPulse(rotation: RotationCommand(roll: 1), translation: Vec3(0, -1, 0), duration: 0.1)
        sim.advance(by: 0.25)
        XCTAssertEqual(v.pilotPulse.rotationRemaining.x, 0.075, accuracy: 1e-12)
        v.setPilotInput(rotation: RotationCommand(roll: 1), translation: .zero)
        XCTAssertEqual(v.pilotPulse.rotationRemaining.x, 0)
        XCTAssertEqual(v.pilotPulse.translationRemaining.y, 0.075, accuracy: 1e-12)
        sim.advance(by: 0.25)
        v.setPilotInput(rotation: RotationCommand(), translation: .zero)
        XCTAssertEqual(v.rotationInput, RotationCommand())
        XCTAssertEqual(v.translationInput, Vec3(0, -1, 0))
        sim.advance(by: 0.5)
        XCTAssertEqual(v.translationInput, .zero)
        XCTAssertFalse(v.pilotPulse.isActive)
    }

    // An autopilot gives way to a pulse, which turns the capsule by its full
    // impulse, and takes over again once it ends: kill rotation damps the
    // rate the pulse left to within its 2e-4 rad/s dead band.
    func testAutopilotTakesOverAgainWhenThePulseEnds() throws {
        let (sim, v, _) = try capsuleInFreeSpace()
        v.autopilot = .killRotation
        let expected = v.rotationAuthority().z / v.inertia[2, 2] * 0.1
        v.firePilotPulse(rotation: RotationCommand(yaw: 1), duration: 0.1)
        sim.advance(by: 0.1)
        XCTAssertEqual(v.angularVelocity.z, expected, accuracy: 1e-4 * expected)
        fly(sim, for: 2)
        XCTAssertLessThan(v.angularVelocity.length, 2e-4)
        XCTAssertLessThan(v.angularVelocity.length, 0.03 * expected)
        XCTAssertEqual(v.autopilot, .killRotation)
    }

    // A pulse names its axes as the pilot does, like the held keys: in
    // Apollo's axes (`ApolloAxes.rotation`, the CSM's and the CM's pilot
    // axes, Rx(π) from construction), pitch, yaw and the y and z
    // translations reverse on the body axes and roll and x keep theirs.
    func testPulseTakesThePilotAxes() {
        let v = VesselLibrary.capsule()
        v.controlFrame = ApolloAxes.rotation
        let rotation = RotationCommand(roll: 1, pitch: 1, yaw: -1), translation = Vec3(1, -1, 1)
        v.setPilotInput(rotation: rotation, translation: translation)
        let held = (v.rotationInput, v.translationInput)
        XCTAssertEqual(held.0, RotationCommand(roll: 1, pitch: -1, yaw: 1))
        XCTAssertEqual(held.1, Vec3(1, 1, -1))
        v.setPilotInput(rotation: RotationCommand(), translation: .zero)
        v.firePilotPulse(rotation: rotation, translation: translation, duration: 0.1)
        XCTAssertEqual(v.rotationInput, held.0)
        XCTAssertEqual(v.translationInput, held.1)
    }

    // The steps end where a pulse does, however short: a 0.4 ms pulse, under
    // the 1 ms floor of the other limits, holds the next step to 0.4 ms.
    func testStepEndsWithThePulse() throws {
        let (sim, v, _) = try capsuleInFreeSpace()
        XCTAssertGreaterThan(sim.maxStep(for: v), 0.001)
        v.firePilotPulse(translation: Vec3(0, 0, 1), duration: 0.0004)
        XCTAssertEqual(sim.maxStep(for: v), 0.0004, accuracy: 1e-15)
    }

    // Staging hands a pulse on with the flight program's controls, and the
    // vessel left behind starts with none.
    func testPulseGoesWithTheControls() {
        let v = VesselLibrary.capsule(), w = VesselLibrary.capsule()
        v.setPilotInput(rotation: RotationCommand(pitch: 1), translation: .zero)
        v.firePilotPulse(rotation: RotationCommand(roll: -1), duration: 0.1)
        w.takeControls(from: v)
        v.resetControls()
        XCTAssertEqual(w.pilotPulse.rotation.x, -1)
        XCTAssertEqual(w.pilotPulse.rotationRemaining.x, 0.1)
        XCTAssertEqual(w.rotationInput, RotationCommand(roll: -1, pitch: 1))
        XCTAssertFalse(v.pilotPulse.isActive)
        XCTAssertTrue(v.rotationInput.isZero)
        w.setPilotInput(rotation: RotationCommand(), translation: .zero)
        XCTAssertEqual(w.rotationInput, RotationCommand(roll: -1))
    }
}
