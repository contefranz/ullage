import XCTest
@testable import OrbitCore

/// CMC-lite's keys and programs (docs/m2/design-flight-controls.md §9, C8),
/// on Apollo 7's deorbit scenario: PROG and OPR ERR with their reasons,
/// Return as ENTR or PRO, the uplink's handshake, V99 and the ignition, and
/// Z making an SCS burn.
final class CMCLiteTests: XCTestCase {
    let ft = CMCFlight.ft

    // PRG 40 with nothing loaded lights PROG, says why, and stays in P00;
    // RSET puts the lamp out. NXT with no load lights it too.
    func testPRG40WithNoLoadLightsPROG() throws {
        let f = try CMCFlight()
        f.press(.program)
        XCTAssertEqual(f.cmc.display.verb, 37)
        XCTAssertTrue(f.cmc.display.flashing)
        f.key("40")
        XCTAssertEqual(f.cmc.display.keyBuffer, "40")
        f.press(.returnKey)
        XCTAssertEqual(f.cmc.program, 0)
        XCTAssertTrue(f.cmc.display.lamps.contains(.programAlarm))
        XCTAssertEqual(f.cmc.display.reason, "NO LOAD FOR P40")
        XCTAssertTrue(f.logged("CMC: PROG, no load for p40"))
        f.press(.reset)
        XCTAssertFalse(f.cmc.display.lamps.contains(.programAlarm))
        XCTAssertNil(f.cmc.display.reason)
        f.press(.next)
        XCTAssertEqual(f.cmc.display.reason, "NO LOAD")
        // An unknown program is the operator's error.
        f.press(.reset, .program)
        f.key("63")
        f.press(.returnKey)
        XCTAssertTrue(f.cmc.display.lamps.contains(.operatorError))
        XCTAssertEqual(f.cmc.display.reason, "NO PROGRAM 63")
    }

    // The uplink lands only in P00, with UP TLM at ACCEPT and the ground in
    // contact; anywhere else it is refused, with the reason.
    func testUplinkOutsideP00IsRefused() throws {
        let f = try CMCFlight()
        let load = f.sps8AsFlown()
        f.press(.program)
        f.key("47")
        f.press(.returnKey)
        XCTAssertEqual(f.cmc.program, 47)
        XCTAssertEqual(f.cmc.uplink(load, at: f.sim.time), .refused("CMC NOT IN P00"))
        XCTAssertNil(f.cmc.load)
        f.press(.returnKey)   // P47's N83: Return ends it
        XCTAssertEqual(f.cmc.program, 0)
        f.cmc.uplinkAccept = false
        XCTAssertEqual(f.cmc.uplink(load, at: f.sim.time), .refused("UP TLM BLOCK"))
        f.cmc.uplinkAccept = true
        f.cmc.groundContact = false
        XCTAssertEqual(f.cmc.uplink(load, at: f.sim.time), .refused("NO CONTACT"))
        f.cmc.groundContact = true
        XCTAssertEqual(f.cmc.uplink(load, at: f.sim.time), .accepted)
        XCTAssertEqual(f.cmc.program, 30)
        // A second load while P30 checks the first is refused.
        XCTAssertEqual(f.cmc.uplink(load, at: f.sim.time), .refused("CMC NOT IN P00"))
    }

    // ENTR with nothing keyed is OPR ERR; PRO with digits keyed but not
    // entered is too, and leaves them; CLR clears them. Return with nothing
    // keyed proceeds only where the computer waits (it flashes).
    func testEnterWithNothingKeyedIsOprErr() throws {
        let f = try CMCFlight()
        f.press(.enter)
        XCTAssertTrue(f.cmc.display.lamps.contains(.operatorError))
        XCTAssertEqual(f.cmc.display.reason, "NOTHING KEYED")
        f.press(.reset)
        XCTAssertTrue(f.cmc.display.lamps.isEmpty)
        f.key("12")
        f.press(.proceed)
        XCTAssertTrue(f.cmc.display.lamps.contains(.operatorError))
        XCTAssertEqual(f.cmc.display.keyBuffer, "12")
        f.press(.clear, .reset)
        XCTAssertEqual(f.cmc.display.keyBuffer, "")
        f.press(.returnKey)   // P00 does not flash: nothing happens
        XCTAssertTrue(f.cmc.display.lamps.isEmpty)
        XCTAssertEqual(f.cmc.program, 0)
    }

    // Return with digits keyed enters them: in P30's N81 each Return loads a
    // register in turn (ft/s to a tenth), and Return with none keyed then
    // accepts the load as keyed. PRG 30 keys a PAD by hand: N33's TIG (h,
    // min, s to a hundredth), then N81's Δv; the load is the crew's.
    func testReturnWithDigitsEntersThem() throws {
        let f = try CMCFlight()
        XCTAssertEqual(f.cmc.uplink(f.sps8AsFlown(), at: f.sim.time), .accepted)
        f.key("-3534")
        f.press(.returnKey)
        XCTAssertEqual(f.cmc.display.registers[0].value, "-353.4")
        XCTAssertEqual(f.cmc.display.noun, 81)
        f.key("+0")
        f.press(.returnKey)
        f.key("0")
        f.press(.returnKey)
        f.press(.returnKey)
        XCTAssertEqual(f.cmc.display.noun, 42)
        let keyed = try XCTUnwrap(f.cmc.load)
        XCTAssertEqual(keyed.deltaVLocal.x, -353.4 * ft, accuracy: 1e-9)
        XCTAssertEqual(keyed.deltaVLocal.y, 0)
        XCTAssertEqual(keyed.source, .keyed)
        XCTAssertEqual(keyed.deltaVMagnitude, 353.4 * ft, accuracy: 1e-9)
        f.press(.returnKey)
        XCTAssertEqual(f.cmc.program, 0)

        // By hand: TIG 259:45:00.00, Δv 100 ft/s retrograde.
        f.press(.program)
        f.key("30")
        f.press(.returnKey)
        XCTAssertEqual(f.cmc.display.noun, 81)   // the load is still there: it shows first
        f.press(.display)
        XCTAssertEqual(f.cmc.display.noun, 33)
        for v in ["259", "45", "0"] {
            f.key(v)
            f.press(.returnKey)
        }
        f.press(.returnKey)
        XCTAssertEqual(f.cmc.display.noun, 81)
        f.key("-1000")
        f.press(.returnKey)
        f.press(.returnKey)
        XCTAssertEqual(f.cmc.display.noun, 42)
        let pad = try XCTUnwrap(f.cmc.load)
        XCTAssertEqual(pad.ignition - ApolloCSM.apollo7RangeZero, 259 * 3_600 + 45 * 60, accuracy: 1e-6)
        XCTAssertEqual(pad.deltaVLocal.x, -100 * ft, accuracy: 1e-9)
        XCTAssertEqual(pad.engine, .sps)
        XCTAssertNotNil(pad.burnTime)
    }

    /// The scenario with SPS-8 loaded through P30, in P40 counting down
    /// (V50N18 answered).
    func countingDown() throws -> CMCFlight {
        let f = try CMCFlight()
        XCTAssertEqual(f.cmc.uplink(f.sps8AsFlown(), at: f.sim.time), .accepted)
        f.press(.returnKey, .returnKey, .next, .returnKey)
        f.fly(to: f.get + 1)
        XCTAssertEqual(f.cmc.step, .countdown)
        return f
    }

    // Without Return at V99 there is no ignition: at TIG and well after, the
    // SPS is off and V99 still flashes.
    func testNoReturnAtV99MeansNoIgnition() throws {
        let f = try countingDown()
        f.fly(to: CMCFlight.tigGET + 10)
        XCTAssertEqual(f.cmc.step, .ignition)
        XCTAssertEqual(f.cmc.display.verb, 99)
        XCTAssertTrue(f.cmc.display.flashing)
        XCTAssertNil(f.cmc.ignition)
        XCTAssertEqual(f.v.mainThrottle, 0)
        XCTAssertFalse(f.v.thrusters.contains { $0.name == "SPS" && $0.isDelivering })
        // TFI counts up (as of the computer's last step, 0.02 s before).
        XCTAssertEqual(f.cmc.display.registers[0].label, "TFI")
        XCTAssertEqual(f.cmc.display.registers[0].value, "+00:09")
    }

    // A late Return lights the SPS late by the delay, at the step it came in.
    func testALateReturnLightsLate() throws {
        let f = try countingDown()
        f.fly(to: CMCFlight.tigGET + 3)
        XCTAssertNil(f.cmc.ignition)
        f.press(.returnKey)
        f.fly(to: CMCFlight.tigGET + 4)
        let lit = try XCTUnwrap(f.cmc.ignition) - CMCFlight.tig
        XCTAssertEqual(lit, 3, accuracy: 1e-6)
        XCTAssertTrue(f.cmc.ownsThrust)
        XCTAssertTrue(f.logged("CMC: SPS ignition, 3.0 s late"))
    }

    // 8 hands the attitude back to the SCS where the vessel is: after the
    // computer has slewed it 20° (an SPS-8 load turned 20° in pitch), the
    // hold keeps it there and does not swing back to where it held before.
    func testEightHandsTheAttitudeBackWhereItIs() throws {
        let f = try CMCFlight()
        var load = f.sps8AsFlown()
        let axis = f.v.position.cross(f.v.velocity).normalized
        load.deltaV = Quat(axis: axis, angle: 20 * CMCFlight.deg).rotate(load.deltaV)
        XCTAssertEqual(f.cmc.uplink(load, at: f.sim.time), .accepted)
        f.press(.returnKey, .returnKey, .next, .returnKey)
        let start = f.v.attitude
        f.fly(to: f.get + 20)
        XCTAssertTrue(f.scs.gnAuto)
        let turned = rotationVector(start.conjugate * f.v.attitude).length / CMCFlight.deg
        XCTAssertGreaterThan(turned, 8)   // under way at 0.5°/s
        f.scs.clearGNAuto(f.v, in: f.sim)   // 8
        f.v.autopilot = .attitudeHold
        XCTAssertFalse(f.scs.gnAuto)
        let handed = f.v.attitude
        f.fly(to: f.get + 20)
        XCTAssertLessThan(rotationVector(handed.conjugate * f.v.attitude).length / CMCFlight.deg, 1.5)
        XCTAssertTrue(f.logged("G&N AUTO off, SCS hold"))
        // G gives it back to the computer, from where it is.
        XCTAssertTrue(f.scs.selectGNAuto(f.v, in: f.sim))
        XCTAssertTrue(f.scs.gnAuto)
    }

    // Z in P40 before TIG makes the burn an SCS burn: the SPS lights at
    // once, the EMS counter (the scenario's load) cuts it off, and the
    // computer only monitors, then shows N85.
    func testZInP40MakesAnSCSBurnTheEMSCutsOff() throws {
        let f = try countingDown()
        f.fly(to: CMCFlight.tigGET - 2)
        f.v.mainThrottle = 1   // Z
        f.fly(to: CMCFlight.tigGET + 20)
        XCTAssertTrue(f.cmc.scsBurn)
        XCTAssertFalse(f.cmc.ownsThrust)
        XCTAssertEqual(try XCTUnwrap(f.cmc.ignition) - CMCFlight.tig, -2, accuracy: 0.021)
        XCTAssertTrue(f.logged("SPS cutoff (ΔV counter)"))
        XCTAssertFalse(f.logged("SPS cutoff (VG)"))
        XCTAssertEqual(f.cmc.step, .residuals)
        XCTAssertEqual(f.cmc.display.noun, 85)
        XCTAssertEqual(f.v.mainThrottle, 0)
    }
}
