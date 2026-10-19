import XCTest
@testable import OrbitCore

/// Vessels without gimballed or `activeStageOnly` thrusters keep M0's
/// controls exactly: the M0 authority, autopilot law and level setting,
/// copied verbatim from M0 (commit b0857b2), against the current code over
/// random states (a self-consistency check of the refactor).
final class M0ControlParityTests: XCTestCase {
    /// M0 `Vessel.rotationAuthority`, verbatim.
    func m0Authority(_ v: Vessel) -> Vec3 {
        let com = v.centerOfMass
        var authority = Vec3.zero
        for t in v.thrusters where t.isEnabled && t.hasPropellant {
            let torque = (t.position + v.offsetOfPart(owning: t) - com).cross(t.direction) * t.maxThrustVacuum
            if t.groups.contains(.rollRight) { authority.x += abs(torque.x) }
            if t.groups.contains(.pitchUp) { authority.y += abs(torque.y) }
            if t.groups.contains(.yawRight) { authority.z += abs(torque.z) }
        }
        return authority
    }

    /// M0 `Vessel.autopilotCommand`, verbatim.
    func m0Command(_ v: Vessel, _ mode: AttitudeAutopilot) -> RotationCommand {
        let inertia = v.inertia
        let authority = m0Authority(v)
        let alpha = Vec3(authority.x / max(inertia[0, 0], 1e-6),
                         authority.y / max(inertia[1, 1], 1e-6),
                         authority.z / max(inertia[2, 2], 1e-6))
        guard alpha.x > 0 || alpha.y > 0 || alpha.z > 0 else { return RotationCommand() }

        var desired = Vec3.zero
        if let target = mode.target(for: v), target.lengthSquared > 0.5 {
            let tb = v.attitude.inverseRotate(target)
            var axis = Vec3.unitX.cross(tb)
            let angle = atan2(axis.length, tb.x)
            if axis.length < 1e-9 { axis = angle > 1 ? .unitY : .zero } else { axis = axis.normalized }
            // Bang-bang-like profile: approach rate that can still be stopped in time.
            let a = max(min(alpha.y, alpha.z), 1e-6)
            let rate = min(0.1, (2 * a * angle * 0.5).squareRoot())
            desired = axis * rate
            if angle < 0.002 { desired = .zero }
        }

        let err = desired - v.angularVelocity
        let response = 0.5  // s
        func axisCommand(_ e: Double, _ a: Double) -> Double {
            guard a > 0 else { return 0 }
            let c = e / (a * response)
            if abs(c) < 0.02 && abs(e) < 2e-4 { return 0 }
            return max(-1, min(1, c))
        }
        return RotationCommand(roll: axisCommand(err.x, alpha.x),
                               pitch: axisCommand(err.y, alpha.y),
                               yaw: axisCommand(err.z, alpha.z))
    }

    /// M0 `Vessel.applyControls`, verbatim, returning the levels.
    func m0Levels(_ v: Vessel, _ rotation: RotationCommand) -> [Double] {
        for t in v.thrusters { t.level = 0 }
        func set(_ g: ThrusterGroup, _ level: Double) {
            guard level > 0 else { return }
            for t in v.thrusters where t.groups.contains(g) { t.level = t.clampedLevel(max(t.level, level)) }
        }
        // Main engines: only the lowest part that has main engines (the active
        // stage of a stack) responds to the main throttle.
        if v.mainThrottle > 0, let active = v.activeStage {
            for t in active.thrusters where t.groups.contains(.main) { t.level = t.clampedLevel(v.mainThrottle) }
        }
        set(.retro, v.retroThrottle)
        set(rotation.pitch > 0 ? .pitchUp : .pitchDown, abs(rotation.pitch))
        set(rotation.yaw > 0 ? .yawRight : .yawLeft, abs(rotation.yaw))
        set(rotation.roll > 0 ? .rollRight : .rollLeft, abs(rotation.roll))
        set(v.translationInput.x > 0 ? .translateForward : .translateBack, abs(v.translationInput.x))
        set(v.translationInput.y > 0 ? .translateRight : .translateLeft, abs(v.translationInput.y))
        set(v.translationInput.z > 0 ? .translateDown : .translateUp, abs(v.translationInput.z))
        return v.thrusters.map(\.level)
    }

    /// SplitMix64, so that a failure can be reproduced.
    struct Random: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // 100 random states per vessel: every M0 mode's command, the levels for
    // a random rotation command, and the authority; then the simulation's
    // control step (autopilot, or manual input overriding it) against M0's
    // command and levels. The drum's weakest axis is roll, which M0's
    // pointing modes leave out of their approach profile.
    func testM0VesselsKeepM0Controls() throws {
        let sim = try Simulation.forTests(perturbations: false)
        var rng = Random(state: 506)
        func r(_ s: Double) -> Double { Double.random(in: -s...s, using: &rng) }
        let modes = AttitudeAutopilot.allCases.filter { $0 != .attitudeHold && $0 != .entry }
        XCTAssertEqual(modes.count, 8)
        for v in [VesselLibrary.testRocket(), VesselLibrary.capsule(), Toy.rocket(), Toy.rollWeakDrum()] {
            v.position = Vec3(7e6, 0, 0)
            v.velocity = Vec3(0, 7.5e3, 0)
            for i in 0..<100 {
                v.attitude = Quat(axis: Vec3(r(1), r(1), r(1)), angle: r(3))
                v.angularVelocity = Vec3(r(0.05), r(0.05), r(0.05))
                v.mainThrottle = max(0, r(1.2))
                v.retroThrottle = max(0, r(1))
                v.translationInput = i % 3 == 0 ? .zero : Vec3(r(1), r(1), r(1))
                for mode in modes { XCTAssertEqual(v.autopilotCommand(mode), m0Command(v, mode), "\(mode)") }
                let rotation = RotationCommand(roll: r(1.2), pitch: r(1.2), yaw: r(1.2))
                let expected = m0Levels(v, rotation)
                v.applyControls(rotation: rotation)
                XCTAssertEqual(v.thrusters.map(\.level), expected)
                XCTAssertEqual(v.rotationAuthority(), m0Authority(v))

                let mode = modes[i % modes.count]
                v.autopilot = mode
                v.rotationInput = i % 4 == 0 ? rotation : RotationCommand()
                let command = v.rotationInput.isZero ? m0Command(v, mode) : v.rotationInput
                let stepLevels = m0Levels(v, command)
                sim.prepareControls(v)
                XCTAssertEqual(v.thrusters.map(\.level), stepLevels, "\(mode)")
                v.autopilot = nil
                v.rotationInput = RotationCommand()
            }
        }
    }
}
