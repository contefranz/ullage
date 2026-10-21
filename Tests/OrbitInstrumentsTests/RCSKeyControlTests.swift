import XCTest
import OrbitCore
@testable import OrbitInstruments

/// The RCS keys as pulse controls: a tap pulses, a hold fires on, Control
/// makes both fine.
final class RCSKeyControlTests: XCTestCase {
    typealias C = RCSKeyControl

    /// One frame with `held` down.
    func frame(_ c: inout RCSKeyControl, pressed: [PhysicalKey] = [], held: Set<PhysicalKey>, fine: Bool = false,
               at now: Double) -> RCSKeyControl.Output {
        c.update(pressed: pressed, isHeld: { held.contains($0) }, fine: fine, now: now)
    }

    // A tap fires one 0.1 s pulse at full thrust and nothing held; a key
    // still down fires on only once it has been down 0.25 s, and stops when
    // it goes up.
    func testTapPulsesAndHoldFiresOn() {
        var c = RCSKeyControl()
        let tap = frame(&c, pressed: [.w], held: [.w], at: 10)
        XCTAssertEqual(tap.pulses, [C.Pulse(rotation: RotationCommand(pitch: -1), translation: .zero, duration: 0.1)])
        XCTAssertEqual(tap.rotation, RotationCommand())
        XCTAssertEqual(frame(&c, held: [.w], at: 10.2), C.Output())
        let hold = frame(&c, held: [.w], at: 10.25)
        XCTAssertEqual(hold.pulses, [])
        XCTAssertEqual(hold.rotation, RotationCommand(pitch: -1))
        XCTAssertEqual(frame(&c, held: [.w], at: 12).rotation, RotationCommand(pitch: -1))
        XCTAssertEqual(frame(&c, held: [], at: 12.1), C.Output())
    }

    // A key pressed and released within one frame still fires its pulse; a
    // key pressed again starts its hold delay afresh, even one firing on that
    // went up and down again between two frames.
    func testQuickTapsEachPulse() {
        var c = RCSKeyControl()
        XCTAssertEqual(frame(&c, pressed: [.k], held: [], at: 0).pulses.count, 1)
        XCTAssertEqual(frame(&c, pressed: [.k], held: [.k], at: 0.2).pulses.count, 1)
        XCTAssertEqual(frame(&c, held: [], at: 0.3), C.Output())
        let again = frame(&c, pressed: [.k], held: [.k], at: 0.4)
        XCTAssertEqual(again.pulses, [C.Pulse(rotation: RotationCommand(), translation: Vec3(0, 0, 1), duration: 0.1)])
        XCTAssertEqual(frame(&c, held: [.k], at: 0.6).translation, .zero)
        XCTAssertEqual(frame(&c, held: [.k], at: 0.65).translation, Vec3(0, 0, 1))
        let repressed = frame(&c, pressed: [.k], held: [.k], at: 2)
        XCTAssertEqual(repressed.pulses.count, 1)
        XCTAssertEqual(repressed.translation, .zero)
        XCTAssertEqual(frame(&c, held: [.k], at: 2.2).translation, .zero)
        XCTAssertEqual(frame(&c, held: [.k], at: 2.25).translation, Vec3(0, 0, 1))
    }

    // With Control down a tap fires the 14 ms minimum impulse and a hold a
    // tenth of the thrust; Control can come and go during a hold.
    func testFine() {
        var c = RCSKeyControl()
        let tap = frame(&c, pressed: [.l], held: [.l], fine: true, at: 0)
        XCTAssertEqual(tap.pulses, [C.Pulse(rotation: RotationCommand(), translation: Vec3(0, 1, 0), duration: 0.014)])
        XCTAssertEqual(frame(&c, held: [.l], fine: true, at: 0.3).translation, Vec3(0, 0.1, 0))
        XCTAssertEqual(frame(&c, held: [.l], fine: false, at: 0.4).translation, Vec3(0, 1, 0))
        XCTAssertEqual(frame(&c, held: [.l], fine: true, at: 0.5).translation, Vec3(0, 0.1, 0))
    }

    // Each key's axis and sign, as the app flew the held keys before:
    // roll E+/Q-, pitch S+/W-, yaw D+/A-; translation x U+/O-, y L+/J-,
    // z K+/I-. Other keys fire nothing.
    func testKeyAxes() {
        let rotations: [(PhysicalKey, RotationCommand)] = [
            (.e, RotationCommand(roll: 1)), (.q, RotationCommand(roll: -1)),
            (.s, RotationCommand(pitch: 1)), (.w, RotationCommand(pitch: -1)),
            (.d, RotationCommand(yaw: 1)), (.a, RotationCommand(yaw: -1)),
        ]
        for (key, r) in rotations {
            var c = RCSKeyControl()
            XCTAssertEqual(frame(&c, pressed: [key], held: [key], at: 0).pulses,
                           [C.Pulse(rotation: r, translation: .zero, duration: 0.1)], key.rawValue)
            XCTAssertEqual(frame(&c, held: [key], at: 1).rotation, r, key.rawValue)
        }
        let translations: [(PhysicalKey, Vec3)] = [
            (.u, Vec3(1, 0, 0)), (.o, Vec3(-1, 0, 0)), (.l, Vec3(0, 1, 0)), (.j, Vec3(0, -1, 0)),
            (.k, Vec3(0, 0, 1)), (.i, Vec3(0, 0, -1)),
        ]
        for (key, t) in translations {
            var c = RCSKeyControl()
            XCTAssertEqual(frame(&c, pressed: [key], held: [key], at: 0).pulses,
                           [C.Pulse(rotation: RotationCommand(), translation: t, duration: 0.1)], key.rawValue)
            XCTAssertEqual(frame(&c, held: [key], at: 1).translation, t, key.rawValue)
        }
        var c = RCSKeyControl()
        XCTAssertEqual(frame(&c, pressed: [.z, .space, .t, .digit1], held: [.z, .space, .t, .digit1], at: 0), C.Output())
        XCTAssertEqual(frame(&c, held: [.z, .space, .t, .digit1], at: 1), C.Output())
    }

    // Two keys tapped in one frame fire a pulse each; opposite keys held
    // cancel; a key found down with no press seen (held across a focus
    // change) waits its hold delay from then.
    func testSeveralKeys() {
        var c = RCSKeyControl()
        XCTAssertEqual(frame(&c, pressed: [.w, .d], held: [.w, .d], at: 0).pulses.count, 2)
        XCTAssertEqual(frame(&c, held: [.w, .d], at: 1).rotation, RotationCommand(pitch: -1, yaw: 1))
        XCTAssertEqual(frame(&c, pressed: [.s], held: [.w, .s, .d], at: 1.1).rotation, RotationCommand(pitch: -1, yaw: 1))
        XCTAssertEqual(frame(&c, held: [.w, .s, .d], at: 2).rotation, RotationCommand(yaw: 1))
        var d = RCSKeyControl()
        XCTAssertEqual(frame(&d, held: [.u], at: 5), C.Output())
        XCTAssertEqual(frame(&d, held: [.u], at: 5.25).translation, Vec3(1, 0, 0))
    }
}
