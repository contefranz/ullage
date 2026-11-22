import XCTest
import OrbitCore
@testable import OrbitInstruments

/// The CMC page (`CMCMFD`) as a display list at each step of P30 and P40,
/// its DSKY buttons and keys, the menu's key names, and the flight key map
/// (`FlightKeyMap`).
final class CMCPageTests: XCTestCase {
    func scenario() throws -> (Simulation, Vessel, MFDController) {
        let sim = Simulation(system: try SolarSystem.bundled(), time: VesselLibrary.apollo7RangeZero)
        let v = VesselLibrary.apollo7BeforeDeorbit(in: sim)
        (v.guidanceComputer as? CMCLite)?.clockZero = VesselLibrary.apollo7RangeZero
        let mfd = MFDController(left: .cmc, right: .deorbit)
        mfd.missionClockZero = VesselLibrary.apollo7RangeZero
        sim.advance(by: 0.02)
        return (sim, v, mfd)
    }

    func dump(_ p: MFDPage) -> String { p.lines.joined(separator: "\n") }

    // The page in P00, after an uplink (P30's N81 and N42), in P40 at V50N18,
    // and at V99: every row inside the body, the registers beside the first
    // buttons, the lamps and the prompt.
    func testPagesThroughP30AndP40() throws {
        let (sim, v, mfd) = try scenario()
        let cmc = try XCTUnwrap(v.guidanceComputer as? CMCLite)
        var p = mfd.page(.left, sim: sim)
        XCTAssertEqual(p.lines[0].prefix(19), "CMC  P00 CMC IDLING")
        XCTAssertTrue(p.shows("GET 259:38:00"), dump(p))
        XCTAssertTrue(p.shows("PROG 00 VERB NOUN"), dump(p))
        XCTAssertTrue(p.shows("NO LOAD"), dump(p))
        XCTAssertTrue(p.shows("UPLK . PROG . OPR . KREL ."), dump(p))
        XCTAssertTrue(p.shows("KEY __"), dump(p))
        XCTAssertTrue(p.shows("ATT SCS HOLD"), dump(p))
        XCTAssertTrue(p.shows("CMC IDLING"), dump(p))
        XCTAssertEqual(p.buttons.map { $0?.label }, ["PRG", "DSP", "V82", "KRL", "+", "-", "PRO", "ENT", "CLR", "RST",
                                                     "NXT", nil])

        let load = ApolloCSM.apollo7SPS8Load(for: v, at: sim.time, system: sim.system)
        XCTAssertEqual(cmc.uplink(load, at: sim.time), .accepted)
        p = mfd.page(.left, sim: sim)
        XCTAssertTrue(p.lines[0].hasPrefix("CMC  P30 EXTERNAL DV"), dump(p))
        XCTAssertTrue(p.shows("PROG 30 VERB 06 NOUN 81 *"), dump(p))
        XCTAssertTrue(p.shows("R1 DVX -210.6 FT/S"), dump(p))
        XCTAssertTrue(p.shows("R3 DVZ +283.8 FT/S"), dump(p))
        XCTAssertTrue(p.shows("LOAD SPS-8 SPS RTCC"), dump(p))
        XCTAssertTrue(p.shows("TIG 259:39:16.3 TTG 1:16"), dump(p))
        XCTAssertTrue(p.shows("[UPLK] PROG . OPR . KREL ."), dump(p))
        XCTAssertTrue(p.shows("CHECK THE LOAD: RETURN TO ACCEPT"), dump(p))
        for t in p.text where t.row > 0 {
            XCTAssertTrue(MFDPage.bodyColumns.contains(t.startColumn), "\(t)")
            XCTAssertTrue(MFDPage.bodyColumns.contains(t.startColumn + t.string.count - 1), "\(t)")
        }
        // Shift+P on the page is PRO: N42.
        XCTAssertTrue(mfd.handle(.p, side: .left, sim: sim))
        p = mfd.page(.left, sim: sim)
        XCTAssertTrue(p.shows("VERB 06 NOUN 42 *"), dump(p))
        XCTAssertTrue(p.shows("R1 HAPO"), dump(p))
        XCTAssertTrue(p.shows("R3 DVT +353.4 FT/S"), dump(p))

        // Shift+Return (ENT) with nothing keyed: OPR ERR, with the reason.
        XCTAssertTrue(mfd.handle(.returnKey, side: .left, sim: sim))
        p = mfd.page(.left, sim: sim)
        XCTAssertTrue(p.shows("[UPLK] PROG . [OPR] KREL ."), dump(p))
        XCTAssertTrue(p.shows("NOTHING KEYED"), dump(p))
        XCTAssertTrue(mfd.handle(.r, side: .left, sim: sim))   // RST
        XCTAssertTrue(mfd.handle(.p, side: .left, sim: sim))   // PRO: P00
        XCTAssertTrue(mfd.handle(.n, side: .left, sim: sim))   // NXT: P40
        sim.advance(by: 0.02)
        p = mfd.page(.left, sim: sim)
        XCTAssertTrue(p.lines[0].hasPrefix("CMC  P40 SPS"), dump(p))
        XCTAssertTrue(p.shows("VERB 50 NOUN 18 *"), dump(p))
        XCTAssertTrue(p.shows("R1 R ERR"), dump(p))
        XCTAssertTrue(p.shows("PLEASE PERFORM AUTO MANEUVER:"), dump(p))
        XCTAssertTrue(p.shows("RETURN OR G"), dump(p))
        cmc.press(.returnKey, at: sim.time)
        while sim.time - VesselLibrary.apollo7RangeZero < 934_756.3 - 4.9 { sim.advance(by: 0.1) }
        p = mfd.page(.left, sim: sim)
        XCTAssertTrue(p.shows("VERB 99 NOUN 40 *"), dump(p))
        XCTAssertTrue(p.shows("R1 TFI -00:04 MIN:S"), dump(p))
        XCTAssertTrue(p.shows("ENABLE ENGINE IGNITION? RETURN"), dump(p))
        XCTAssertTrue(p.shows("ATT G&N AUTO"), dump(p))
        // The SCS's HUD line repeats the flashing prompt.
        XCTAssertTrue(v.flightProgram!.status.contains("CMC P40 V99N40 ENABLE ENGINE IGNITION? RETURN"),
                      v.flightProgram!.status)
    }

    // Shift and a digit key the buffer, which the page shows; Shift+Delete
    // (CLR) clears it; PRG then the digits then ENT changes program. The
    // menu names Return and Delete as RET and DEL, and its help stays in
    // the body.
    func testDigitsAndTheMenu() throws {
        let (sim, v, mfd) = try scenario()
        let cmc = try XCTUnwrap(v.guidanceComputer as? CMCLite)
        XCTAssertTrue(mfd.handle(.digit4, side: .left, sim: sim))
        XCTAssertTrue(mfd.handle(.digit7, side: .left, sim: sim))
        XCTAssertTrue(mfd.page(.left, sim: sim).shows("KEY 47_"))
        XCTAssertTrue(mfd.handle(.delete, side: .left, sim: sim))
        XCTAssertTrue(mfd.page(.left, sim: sim).shows("KEY __"))
        for k: PhysicalKey in [.v, .digit4, .digit7, .returnKey] { XCTAssertTrue(mfd.handle(k, side: .left, sim: sim)) }
        XCTAssertEqual(cmc.program, 47)
        XCTAssertTrue(mfd.page(.left, sim: sim).shows("VERB 16 NOUN 83 *"))

        mfd.press(.menu, side: .left, sim: sim)
        let menu = mfd.page(.left, sim: sim)
        XCTAssertTrue(menu.shows("ENT RET Enter the digits"), dump(menu))
        XCTAssertTrue(menu.shows("CLR DEL Clear the digits"), dump(menu))
        for t in menu.text { XCTAssertLessThanOrEqual(t.startColumn + t.string.count - 1, 35, "\(t)") }

        // A vessel without a computer: the page says so, the buttons are dim.
        let other = VesselLibrary.capsule()
        sim.add(other)
        sim.focus = other
        mfd.press(.menu, side: .left, sim: sim)
        let none = mfd.page(.left, sim: sim)
        XCTAssertTrue(none.shows("NO COMPUTER ABOARD"), dump(none))
        XCTAssertFalse(mfd.handle(.digit1, side: .left, sim: sim))
        XCTAssertFalse(mfd.handle(.p, side: .left, sim: sim))
    }

    // DEORBIT's CLR clears the uplinked load with the counter and the
    // marker, while P30 has it.
    func testDeorbitCLRClearsTheLoad() throws {
        let (sim, v, mfd) = try scenario()
        _ = mfd.page(.right, sim: sim)
        XCTAssertTrue(mfd.handle(.s, side: .right, sim: sim))
        let cmc = try XCTUnwrap(v.guidanceComputer as? CMCLite)
        XCTAssertNotNil(cmc.load)
        XCTAssertNotNil(mfd.activeManeuver(for: v))
        XCTAssertTrue(mfd.handle(.c, side: .right, sim: sim))
        XCTAssertNil(cmc.load)
        XCTAssertEqual(cmc.program, 0)
        XCTAssertNil((v.flightProgram as? ApolloSCS)?.deltaVRemaining)
        XCTAssertNil(mfd.activeManeuver(for: v))
    }

    // The flight keys: one command per key, a help line for every command,
    // none on a key macOS keeps, on a held key (the throttle's, the RCS's)
    // or on a key the MFDs take with Shift for SEL, MNU or PWR; Return is the
    // computer's key and G G&N AUTO.
    func testFlightKeyMap() {
        let keys = FlightKeyMap.bindings.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count, "a key bound twice")
        for command in FlightCommand.allCases {
            let b = FlightKeyMap.bindings.filter { $0.command == command }
            XCTAssertFalse(b.isEmpty, "\(command) has no key")
            XCTAssertTrue(b.allSatisfy { !$0.help.isEmpty }, "\(command) has no help")
        }
        for b in FlightKeyMap.bindings {
            XCTAssertFalse(FlightKeyMap.reserved.contains(b.key), "\(b.key) is macOS's")
            XCTAssertFalse(FlightKeyMap.heldKeys.contains(b.key), "\(b.key) is a held key")
            XCTAssertFalse(MFDController.selectKeys.contains(b.key), "\(b.key) is SEL with Shift")
            XCTAssertEqual(FlightKeyMap.command(for: b.key), b.command)
        }
        XCTAssertEqual(FlightKeyMap.command(for: .returnKey), .computerKey)
        XCTAssertEqual(FlightKeyMap.command(for: .g), .gnAuto)
        XCTAssertEqual(FlightKeyMap.command(for: .z), .throttleOn)
        XCTAssertNil(FlightKeyMap.command(for: .u))
        XCTAssertNil(FlightKeyMap.command(for: .delete))
        XCTAssertNil(FlightKeyMap.command(for: .r))
        XCTAssertNil(FlightKeyMap.command(for: .backslash))
    }
}
