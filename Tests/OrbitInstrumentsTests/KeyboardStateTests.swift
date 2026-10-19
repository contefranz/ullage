import XCTest
@testable import OrbitInstruments

/// Physical keys and the keyboard state the app's `InputState` keeps.
final class KeyboardStateTests: XCTestCase {
    /// Device-independent Shift, Control flags and the device-dependent
    /// Shift sides of an `NSEvent`'s modifier flags.
    let shift: UInt = 1 << 17, control: UInt = 1 << 18, leftShiftBit: UInt = 0x2, rightShiftBit: UInt = 0x4
    var leftShift: ModifierKeys { ModifierKeys(eventFlags: shift | leftShiftBit) }
    var rightShift: ModifierKeys { ModifierKeys(eventFlags: shift | rightShiftBit) }

    func mfdKeys(_ k: inout KeyboardState) -> [String] {
        k.takeMFDKeys().map { "\($0.side == .left ? "L" : "R") \($0.key.rawValue)" }
    }

    // The ANSI virtual key codes (Carbon's Events.h, kVK_ANSI_* and kVK_*)
    // of the keys the app binds, and every name round-trips.
    func testKeyCodes() {
        let codes: [(PhysicalKey, UInt16)] = [
            (.a, 0), (.s, 1), (.d, 2), (.f, 3), (.h, 4), (.z, 6), (.x, 7), (.c, 8), (.v, 9), (.q, 12), (.w, 13),
            (.e, 14), (.t, 17), (.o, 31), (.u, 32), (.i, 34), (.p, 35), (.l, 37), (.j, 38), (.k, 40), (.m, 46),
            (.n, 45), (.y, 16), (.digit1, 18), (.digit2, 19), (.digit5, 23), (.digit6, 22), (.digit9, 25),
            (.digit0, 29), (.equal, 24), (.minus, 27), (.rightBracket, 30), (.leftBracket, 33), (.comma, 43),
            (.slash, 44), (.period, 47), (.grave, 50), (.isoSection, 10), (.tab, 48), (.space, 49), (.escape, 53),
            (.f1, 122), (.f2, 120), (.f3, 99), (.f4, 118), (.f5, 96), (.f6, 97), (.f7, 98), (.f8, 100),
            (.f9, 101), (.f10, 109), (.f11, 103), (.f12, 111), (.left, 123), (.right, 124), (.down, 125),
            (.up, 126),
        ]
        for (key, code) in codes {
            XCTAssertEqual(key.keyCode, code, key.rawValue)
            XCTAssertEqual(PhysicalKey(keyCode: code), key)
        }
        XCTAssertEqual(Set(PhysicalKey.allCases.map(\.keyCode)).count, PhysicalKey.allCases.count)
        for key in PhysicalKey.allCases { XCTAssertEqual(PhysicalKey(keyCode: key.keyCode), key) }
        XCTAssertEqual(PhysicalKey.allCases.count, 26 + 10 + 11 + 1 + 3 + 12 + 4)
        // Return, Delete, keypad 1 and left Shift are not named.
        for code: UInt16 in [36, 51, 83, 56] { XCTAssertNil(PhysicalKey(keyCode: code)) }
        XCTAssertEqual(PhysicalKey.allCases.compactMap(\.digit).sorted(), Array(0...9))
        XCTAssertEqual(PhysicalKey.digit7.digit, 7)
        XCTAssertNil(PhysicalKey.equal.digit)
    }

    func testModifierSides() {
        XCTAssertEqual(leftShift, .leftShift)
        XCTAssertEqual(leftShift.mfdSide, .left)
        XCTAssertEqual(rightShift, .rightShift)
        XCTAssertEqual(rightShift.mfdSide, .right)
        XCTAssertEqual(ModifierKeys(eventFlags: shift | leftShiftBit | rightShiftBit).mfdSide, .left)
        // Shift without its side (some keyboards) counts as left Shift.
        XCTAssertEqual(ModifierKeys(eventFlags: shift), .leftShift)
        // Caps Lock is not Shift; Control, Option and Command are no MFD's.
        XCTAssertEqual(ModifierKeys(eventFlags: 1 << 16), [])
        let others = ModifierKeys(eventFlags: control | 1 << 19 | 1 << 20)
        XCTAssertEqual(others, [.control, .option, .command])
        XCTAssertNil(others.mfdSide)
        XCTAssertNil(ModifierKeys(eventFlags: 0).mfdSide)
    }

    // A key pressed without Shift is held until it goes up, and queued once.
    func testHeldAndPressed() {
        var k = KeyboardState()
        k.keyDown(.w, modifiers: [], isRepeat: false)
        k.keyDown(.w, modifiers: [], isRepeat: true)
        k.keyDown(.equal, modifiers: ModifierKeys(eventFlags: control), isRepeat: false)
        XCTAssertEqual(k.held, [.w, .equal])
        XCTAssertEqual(k.takePressed(), [.w, .equal])
        XCTAssertEqual(k.takePressed(), [])
        k.keyUp(.w)
        XCTAssertEqual(k.held, [.equal])
        k.keyUp(.equal)
        XCTAssertTrue(k.held.isEmpty)
        XCTAssertTrue(mfdKeys(&k).isEmpty)
    }

    // Keys pressed with Shift go to that side's MFD only: never held, never
    // pressed, so Shift+Z cannot throttle up. Releasing Shift first leaves
    // nothing held (M1's character keys left "=" held after Shift+0 on an
    // Italian layout, and the throttle ran away).
    func testShiftedKeysGoToTheMFDsOnly() {
        var k = KeyboardState()
        k.modifiersChanged(leftShift)
        k.keyDown(.z, modifiers: leftShift, isRepeat: false)
        k.keyDown(.digit0, modifiers: leftShift, isRepeat: false)
        k.keyDown(.digit0, modifiers: leftShift, isRepeat: true)
        XCTAssertEqual(k.modifiers, .leftShift)
        k.modifiersChanged([])
        XCTAssertTrue(k.held.isEmpty)
        k.keyUp(.digit0)
        k.keyUp(.z)
        k.keyDown(.f1, modifiers: rightShift, isRepeat: false)
        k.keyUp(.f1)
        XCTAssertTrue(k.held.isEmpty)
        XCTAssertTrue(k.takePressed().isEmpty)
        XCTAssertEqual(mfdKeys(&k), ["L z", "L 0", "R f1"])
        XCTAssertTrue(mfdKeys(&k).isEmpty)
    }

    // A key held before Shift goes down stays held until its own key-up.
    func testKeyHeldBeforeShift() {
        var k = KeyboardState()
        k.keyDown(.equal, modifiers: [], isRepeat: false)
        k.modifiersChanged(rightShift)
        k.keyDown(.equal, modifiers: rightShift, isRepeat: true)
        XCTAssertTrue(k.isHeld(.equal))
        k.keyUp(.equal)
        k.modifiersChanged([])
        XCTAssertFalse(k.isHeld(.equal))
        XCTAssertEqual(k.takePressed(), [.equal])
        XCTAssertTrue(mfdKeys(&k).isEmpty)
    }

    // Unread MFD keys are capped; losing focus forgets held keys and modifiers.
    func testQueueLimitAndReleaseAll() {
        var k = KeyboardState()
        for _ in 0..<(KeyboardState.mfdQueueLimit + 5) { k.keyDown(.a, modifiers: leftShift, isRepeat: false) }
        k.keyDown(.b, modifiers: leftShift, isRepeat: false)
        let queued = mfdKeys(&k)
        XCTAssertEqual(queued.count, KeyboardState.mfdQueueLimit)
        XCTAssertEqual(queued.last, "L b")
        k.keyDown(.d, modifiers: [], isRepeat: false)
        k.modifiersChanged(rightShift)
        k.releaseAll()
        XCTAssertTrue(k.held.isEmpty)
        XCTAssertEqual(k.modifiers, [])
    }
}
