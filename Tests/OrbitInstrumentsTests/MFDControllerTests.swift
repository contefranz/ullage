import XCTest
import OrbitCore
@testable import OrbitInstruments

/// Key routing: Orbiter's Shift keys, by side, through the keyboard state the
/// app keeps, and the side buttons.
final class MFDControllerTests: XCTestCase {
    let leftShift = ModifierKeys(eventFlags: 1 << 17 | 0x2)
    let rightShift = ModifierKeys(eventFlags: 1 << 17 | 0x4)

    /// Press `key` with `modifiers` on `keyboard` and give the MFD keys to
    /// `mfd`, as the app's MFD model does.
    func type(_ key: PhysicalKey, _ modifiers: ModifierKeys, _ keyboard: inout KeyboardState, _ mfd: MFDController,
              sim: Simulation? = nil) {
        keyboard.modifiersChanged(modifiers)
        keyboard.keyDown(key, modifiers: modifiers, isRepeat: false)
        keyboard.keyUp(key)
        keyboard.modifiersChanged([])
        for (side, k) in keyboard.takeMFDKeys() { mfd.handle(k, side: side, sim: sim) }
    }

    // Shift+F1 opens the select page; Shift+O then picks ORBIT. Shift+Tab is
    // SEL too, and SEL again goes back without a change.
    func testSelectPage() {
        let mfd = MFDController(left: .surface, right: .map)
        var kb = KeyboardState()
        type(.f1, leftShift, &kb, mfd)
        XCTAssertEqual(mfd.panel(.left).screen, .select)
        XCTAssertTrue(mfd.page(.left, sim: nil).shows("Orbit Shift-O"))
        type(.o, leftShift, &kb, mfd)
        XCTAssertEqual(mfd.panel(.left).screen, .mode)
        XCTAssertEqual(mfd.panel(.left).mode, .orbit)
        type(.tab, leftShift, &kb, mfd)
        XCTAssertEqual(mfd.panel(.left).screen, .select)
        type(.tab, leftShift, &kb, mfd)
        XCTAssertEqual(mfd.panel(.left).screen, .mode)
        XCTAssertEqual(mfd.panel(.left).mode, .orbit)
        // An unknown key on the select page does nothing.
        type(.f1, leftShift, &kb, mfd)
        XCTAssertFalse(mfd.handle(.q, side: .left, sim: nil))
        XCTAssertEqual(mfd.panel(.left).screen, .select)
        // Every mode has its key.
        mfd.handle(.f1, side: .left, sim: nil)
        XCTAssertEqual(mfd.panel(.left).screen, .mode)
        for id in MFDModeID.allCases {
            mfd.handle(.f1, side: .left, sim: nil)
            XCTAssertTrue(mfd.handle(id.selectKey, side: .left, sim: nil))
            XCTAssertEqual(mfd.panel(.left).mode, id)
        }
        // Nothing of this reached the flight controls.
        XCTAssertTrue(kb.held.isEmpty)
        XCTAssertTrue(kb.takePressed().isEmpty)
    }

    // Right-Shift keys reach the right display only, and left-Shift keys the
    // left one.
    func testSides() {
        let mfd = MFDController(left: .surface, right: .surface)
        var kb = KeyboardState()
        type(.f1, rightShift, &kb, mfd)
        type(.m, rightShift, &kb, mfd)
        XCTAssertEqual(mfd.panel(.right).mode, .map)
        XCTAssertEqual(mfd.panel(.left).mode, .surface)
        XCTAssertEqual(mfd.panel(.left).screen, .mode)
        type(.f1, leftShift, &kb, mfd)
        type(.e, leftShift, &kb, mfd)
        XCTAssertEqual(mfd.panel(.left).mode, .entry)
        XCTAssertEqual(mfd.panel(.right).mode, .map)
        // Shift+Z and Shift+X zoom the right MAP in and out, and never reach
        // the throttle (Z full, X cut without Shift).
        let map = mfd.mode(.map, on: .right) as! MapMFD
        type(.z, rightShift, &kb, mfd)
        type(.z, rightShift, &kb, mfd)
        XCTAssertEqual(map.zoom, 4)
        type(.x, rightShift, &kb, mfd)
        XCTAssertEqual(map.zoom, 2)
        type(.z, leftShift, &kb, mfd)    // ENTRY has no Z
        XCTAssertEqual(map.zoom, 2)
        XCTAssertTrue(kb.held.isEmpty)
        XCTAssertTrue(kb.takePressed().isEmpty)
    }

    // MNU lists the mode's buttons with their keys; a button key acts and
    // goes back to the mode's page; MNU again goes back too.
    func testMenu() {
        let mfd = MFDController(left: .map, right: .orbit)
        var kb = KeyboardState()
        type(.grave, leftShift, &kb, mfd)
        XCTAssertEqual(mfd.panel(.left).screen, .menu)
        let menu = mfd.page(.left, sim: nil)
        XCTAssertEqual(menu.title, "MAP MENU")
        XCTAssertTrue(menu.shows("ZM+ Z Zoom in"), menu.compactLines.joined(separator: "\n"))
        XCTAssertTrue(menu.shows("TRK K Track the vessel on/off"))
        type(.z, leftShift, &kb, mfd)
        XCTAssertEqual(mfd.panel(.left).screen, .mode)
        XCTAssertEqual((mfd.mode(.map, on: .left) as! MapMFD).zoom, 2)
        type(.isoSection, leftShift, &kb, mfd)    // § on ISO keyboards
        XCTAssertEqual(mfd.panel(.left).screen, .menu)
        type(.grave, leftShift, &kb, mfd)
        XCTAssertEqual(mfd.panel(.left).screen, .mode)
        // SURFACE has no buttons.
        mfd.handle(.f1, side: .right, sim: nil)
        mfd.handle(.s, side: .right, sim: nil)
        mfd.handle(.grave, side: .right, sim: nil)
        XCTAssertTrue(mfd.page(.right, sim: nil).shows("No buttons"))
    }

    // PWR switches a display off: it shows nothing and swallows every key
    // but PWR, which brings it back on the same mode.
    func testPower() {
        let mfd = MFDController(left: .map, right: .orbit)
        var kb = KeyboardState()
        type(.escape, leftShift, &kb, mfd)
        XCTAssertFalse(mfd.panel(.left).power)
        XCTAssertFalse(mfd.page(.left, sim: nil).powered)
        XCTAssertFalse(mfd.handle(.f1, side: .left, sim: nil))
        XCTAssertFalse(mfd.handle(.grave, side: .left, sim: nil))
        XCTAssertFalse(mfd.handle(.z, side: .left, sim: nil))
        XCTAssertFalse(mfd.press(.button(1), side: .left, sim: nil))
        XCTAssertEqual((mfd.mode(.map, on: .left) as! MapMFD).zoom, 1)
        XCTAssertEqual(mfd.panel(.left).screen, .mode)
        XCTAssertTrue(mfd.panel(.right).power)
        type(.escape, leftShift, &kb, mfd)
        XCTAssertTrue(mfd.panel(.left).power)
        XCTAssertEqual(mfd.panel(.left).mode, .map)
        XCTAssertTrue(mfd.page(.left, sim: nil).powered)
    }

    // The buttons beside the screen: on the select page they pick the modes
    // in order; on a mode's page they are its buttons; an inactive button
    // does nothing. A mode keeps its settings when the display leaves it.
    func testButtons() {
        let mfd = MFDController(left: .orbit, right: .orbit)
        mfd.press(.select, side: .left, sim: nil)
        XCTAssertEqual(mfd.page(.left, sim: nil).buttons.compactMap { $0?.label }, ["ORB", "SRF", "MAP", "DEO", "ENT"])
        XCTAssertTrue(mfd.press(.button(2), side: .left, sim: nil))
        XCTAssertEqual(mfd.panel(.left).mode, .map)
        let labels = mfd.page(.left, sim: nil).buttons
        XCTAssertEqual(labels[1]?.label, "ZM+")
        XCTAssertEqual(labels[6]?.label, "UP")
        XCTAssertEqual(labels[6]?.inactive, true)    // scrolling needs TRK off
        XCTAssertTrue(mfd.press(.button(1), side: .left, sim: nil))
        XCTAssertTrue(mfd.press(.button(1), side: .left, sim: nil))
        XCTAssertFalse(mfd.press(.button(6), side: .left, sim: nil))
        XCTAssertFalse(mfd.press(.button(11), side: .left, sim: nil))   // no button there
        mfd.press(.select, side: .left, sim: nil)
        mfd.press(.button(0), side: .left, sim: nil)
        XCTAssertEqual(mfd.panel(.left).mode, .orbit)
        mfd.press(.menu, side: .left, sim: nil)
        XCTAssertEqual(mfd.panel(.left).screen, .menu)
        mfd.press(.menu, side: .left, sim: nil)
        mfd.press(.select, side: .left, sim: nil)
        mfd.press(.button(2), side: .left, sim: nil)
        XCTAssertEqual((mfd.mode(.map, on: .left) as! MapMFD).zoom, 4)
        // The other display's MAP is its own.
        XCTAssertEqual((mfd.mode(.map, on: .right) as! MapMFD).zoom, 1)
        // ORBIT's TGT is inactive with no other vessel.
        mfd.press(.select, side: .left, sim: nil)
        mfd.press(.button(0), side: .left, sim: nil)
        XCTAssertEqual(mfd.page(.left, sim: nil).buttons[0]?.inactive, true)
        XCTAssertFalse(mfd.handle(.t, side: .left, sim: nil))
    }

    func testFormats() {
        XCTAssertEqual(MFDFormat.si(185_000), "185.0k")
        XCTAssertEqual(MFDFormat.si(6_563_137), "6.563M")
        XCTAssertEqual(MFDFormat.si(7_793.4), "7.793k")
        XCTAssertEqual(MFDFormat.si(950), "950.0")
        XCTAssertEqual(MFDFormat.si(12.3), "12.30")
        XCTAssertEqual(MFDFormat.si(1.5), "1.500")
        XCTAssertEqual(MFDFormat.si(999.96), "1.000k")
        XCTAssertEqual(MFDFormat.si(-12_340), "-12.34k")
        XCTAssertEqual(MFDFormat.si(-0.0001), "0.000")
        XCTAssertEqual(MFDFormat.si(.infinity), "inf")
        XCTAssertEqual(MFDFormat.si(.nan), "---")
        let deg = Double.pi / 180
        XCTAssertEqual(MFDFormat.degrees(32.5 * deg), "32.50°")
        XCTAssertEqual(MFDFormat.degrees(235.64 * deg), "235.6°")
        XCTAssertEqual(MFDFormat.degrees(5.1234 * deg), "5.123°")
        XCTAssertEqual(MFDFormat.degrees(1.5 * deg, signed: true), "+1.500°")
        XCTAssertEqual(MFDFormat.degrees(-2 * deg, signed: true), "-2.000°")
        XCTAssertEqual(MFDFormat.heading(72.06 * deg), "072.1°")
        XCTAssertEqual(MFDFormat.heading(-90 * deg), "270.0°")
        XCTAssertEqual(MFDFormat.heading(359.99 * deg), "000.0°")
        XCTAssertEqual(MFDFormat.latitude(28.608 * deg), "28.61°N")
        XCTAssertEqual(MFDFormat.longitude(-80.604 * deg), "80.60°W")
        XCTAssertEqual(MFDFormat.longitude(279.396 * deg), "80.60°W")
        XCTAssertEqual(MFDFormat.duration(5291.4), "1:28:11")
        XCTAssertEqual(MFDFormat.duration(59.9), "0:59")
        XCTAssertEqual(MFDFormat.duration(-12), "-0:12")
        XCTAssertEqual(MFDFormat.duration(90_061), "1d 01:01:01")
        XCTAssertEqual(MFDFormat.duration(.infinity), "---")
        let zero = Epoch(utcYear: 1969, month: 7, day: 16, hour: 13, minute: 32)
        XCTAssertEqual(MFDFormat.clock(zero + 4_965.2, zero: zero), "+01:22:45")
        XCTAssertEqual(MFDFormat.clock(zero + -5, zero: zero), "-00:00:05")
        XCTAssertEqual(MFDFormat.clock(zero + 600, zero: nil), "13:42:00Z")
    }

    // The page's text as the grid shows it.
    func testPageGrid() {
        var page = MFDPage(title: "ORBIT  Earth")
        page.field(4, 2, "PeA", "185.0k", valueEnd: 14)
        page.add(35, 0, "EQU", alignment: .trailing)
        XCTAssertEqual(page.lines[0], "ORBIT  Earth                     EQU")
        XCTAssertEqual(page.lines[2], "    PeA  185.0k")
        XCTAssertTrue(page.shows("PeA 185.0k"))
        XCTAssertEqual(page.lines.count, MFDPage.rows)
        XCTAssertEqual(MFDPage.buttonRow(0), 4)
        XCTAssertEqual(MFDPage.buttonRow(5), 19)
        XCTAssertEqual(MFDPage.buttonRow(11), 19)
    }
}
