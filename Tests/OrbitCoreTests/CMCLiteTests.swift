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

    /// The angle between two attitudes, degrees.
    func angle(_ a: Quat, _ b: Quat) -> Double { rotationVector(a.conjugate * b).length / CMCFlight.deg }

    /// SPS-8's load turned 20° in pitch, TIG `later` s after the flight's.
    func turnedLoad(_ f: CMCFlight, later: Double = 0) -> ManeuverPlan {
        var load = f.sps8AsFlown()
        let axis = f.v.position.cross(f.v.velocity).normalized
        load.deltaV = Quat(axis: axis, angle: 20 * CMCFlight.deg).rotate(load.deltaV)
        load.ignition = load.ignition + later
        return load
    }

    // PRG then Return with nothing keyed is refused (OPR ERR, V37 still
    // shown): it never answers V99 behind it. PRO is refused too, and so is
    // Return with a sign alone, which stays for CLR. Without the crew's own
    // Return at V99 the SPS stays dark past TIG.
    func testPRGThenReturnNeverAnswersV99() throws {
        let f = try countingDown()
        f.fly(until: { f.cmc.step == .ignition }, limit: CMCFlight.tigGET)
        f.press(.program, .returnKey)
        XCTAssertTrue(f.cmc.display.lamps.contains(.operatorError))
        XCTAssertEqual(f.cmc.display.reason, "KEY THE PROGRAM")
        XCTAssertEqual(f.cmc.display.verb, 37)
        XCTAssertFalse(f.cmc.ignitionEnabled)
        f.press(.proceed)
        XCTAssertFalse(f.cmc.ignitionEnabled)
        f.press(.clear, .reset, .plus, .returnKey)
        XCTAssertEqual(f.cmc.display.reason, "NO DIGITS")
        XCTAssertEqual(f.cmc.display.keyBuffer, "+")
        XCTAssertFalse(f.cmc.ignitionEnabled)
        f.press(.proceed)
        XCTAssertFalse(f.cmc.ignitionEnabled)
        f.press(.clear, .reset)
        f.fly(to: CMCFlight.tigGET + 2)
        XCTAssertNil(f.cmc.ignition)
        XCTAssertEqual(f.v.mainThrottle, 0)
    }

    // G answers V50N18 as Return does: the computer slews, counts down, asks
    // V99, and lights at TIG on the crew's Return there.
    func testGAnswersV50N18() throws {
        let f = try CMCFlight()
        XCTAssertEqual(f.cmc.uplink(f.sps8AsFlown(), at: f.sim.time), .accepted)
        f.press(.returnKey, .returnKey, .next)
        f.fly(to: f.get + 1)
        XCTAssertEqual(f.cmc.step, .maneuver)
        XCTAssertTrue(f.scs.selectGNAuto(f.v, in: f.sim))   // G
        f.fly(to: f.get + 1)
        XCTAssertTrue(f.scs.gnAuto)
        XCTAssertEqual(f.cmc.step, .countdown)
        f.fly(until: { f.cmc.step == .ignition }, limit: CMCFlight.tigGET)
        f.press(.returnKey)
        f.fly(to: CMCFlight.tigGET + 1)
        XCTAssertEqual(try XCTUnwrap(f.cmc.ignition) - CMCFlight.tig, 0, accuracy: 1e-6)
    }

    // A load P40 has lit is flown: PRG 00 at N85 clears it, so NXT finds no
    // load and the same Δv cannot be flown twice; the warp caps go with it.
    func testAFlownLoadIsCleared() throws {
        let f = try countingDown()
        f.fly(until: { f.cmc.step == .ignition }, limit: CMCFlight.tigGET)
        f.press(.returnKey)
        f.fly(to: CMCFlight.tigGET + 20)
        XCTAssertEqual(f.cmc.step, .residuals)
        f.press(.program)
        f.key("00")
        f.press(.returnKey)
        XCTAssertEqual(f.cmc.program, 0)
        XCTAssertNil(f.cmc.load)
        XCTAssertTrue(f.logged("SPS-8 flown, load cleared"))
        f.press(.next)
        XCTAssertEqual(f.cmc.display.reason, "NO LOAD")
        XCTAssertTrue(f.cmc.warpEvents(after: f.sim.time).isEmpty)
    }

    // G&N AUTO ends with the program (the SCS holds where the vessel is),
    // and the next P40 does not turn the CSM before the crew answers its
    // V50N18.
    func testGNAutoEndsWithTheProgramAndTheNextSlewWaits() throws {
        let f = try countingDown()
        XCTAssertTrue(f.scs.gnAuto)
        f.fly(until: { f.cmc.step == .ignition }, limit: CMCFlight.tigGET)
        f.press(.returnKey)
        f.fly(to: CMCFlight.tigGET + 20)
        f.press(.returnKey, .returnKey)   // N85, N44
        XCTAssertEqual(f.cmc.program, 0)
        f.fly(to: f.get + 0.1)
        XCTAssertFalse(f.scs.gnAuto)
        XCTAssertNil(f.v.attitudeCommand)
        XCTAssertTrue(f.logged("G&N AUTO off, the program ended, SCS hold"))

        XCTAssertEqual(f.cmc.uplink(turnedLoad(f, later: 1_200), at: f.sim.time), .accepted)
        f.press(.returnKey, .returnKey, .next)
        XCTAssertEqual(f.cmc.display.verb, 50)
        let before = f.v.attitude
        f.fly(to: f.get + 10)
        XCTAssertEqual(f.cmc.step, .maneuver)
        XCTAssertLessThan(angle(before, f.v.attitude), 1)
    }

    // A pointing mode under G&N AUTO hands the attitude back to the SCS and
    // takes the computer's command off the vessel, so a later hold captures
    // where the vessel is.
    func testAPointingModeHandsTheAttitudeBack() throws {
        let f = try CMCFlight()
        XCTAssertEqual(f.cmc.uplink(turnedLoad(f), at: f.sim.time), .accepted)
        f.press(.returnKey, .returnKey, .next, .returnKey)
        f.fly(to: f.get + 5)
        XCTAssertTrue(f.scs.gnAuto)
        XCTAssertNotNil(f.v.attitudeCommand)
        f.v.autopilot = .prograde
        f.fly(to: f.get + 0.1)
        XCTAssertFalse(f.scs.gnAuto)
        XCTAssertNil(f.v.attitudeCommand)
        XCTAssertTrue(f.logged("G&N AUTO off, Prograde"))
    }

    // NXT from P30's N42 accepts the load as PRO does: UPLINK ACTY goes out.
    func testNXTFromN42PutsTheUplinkLampOut() throws {
        let f = try CMCFlight()
        XCTAssertEqual(f.cmc.uplink(f.sps8AsFlown(), at: f.sim.time), .accepted)
        f.press(.returnKey)
        XCTAssertEqual(f.cmc.display.noun, 42)
        XCTAssertTrue(f.cmc.display.lamps.contains(.uplinkActivity))
        f.press(.next)
        XCTAssertEqual(f.cmc.program, 40)
        XCTAssertFalse(f.cmc.display.lamps.contains(.uplinkActivity))
        XCTAssertTrue(f.logged("CMC: P30 SPS-8 accepted"))
    }

    // The warp caps follow the burn as lit: lit 50 s late, past the planned
    // burn's end, it still flies under the 10x cap until its cutoff.
    func testTheWarpCapsFollowALateBurn() throws {
        let f = try countingDown()
        f.fly(to: CMCFlight.tigGET + 50)
        f.press(.returnKey)
        f.fly(to: CMCFlight.tigGET + 52)
        XCTAssertNotNil(f.cmc.ignition)
        XCTAssertNil(f.cmc.cutoff)
        let caps = f.scs.warpEvents(after: f.sim.time).filter { $0.holds(at: f.sim.time) }
        XCTAssertLessThanOrEqual(caps.map(\.maxWarp).min() ?? .infinity, 10)
        f.fly(to: CMCFlight.tigGET + 70)
        XCTAssertNotNil(f.cmc.cutoff)
        XCTAssertTrue(f.scs.warpEvents(after: f.sim.time).isEmpty)
    }

    // On the Saturn stack the CM's computer, under the IU, sees the state
    // (Vessel.guidanceComputer, observed each step): V82 gives the parking
    // orbit's apsides, an uplink's N42 its prediction; P40 refuses, as the
    // IU flies the stack.
    func testTheComputerOnTheStack() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let v = VesselLibrary.apollo11InParkingOrbit(in: sim)
        let cmc = try XCTUnwrap(v.guidanceComputer as? CMCLite)
        for _ in 0..<5 { sim.tick() }
        cmc.press(.orbitParameters, at: sim.time)
        let d = cmc.display
        XCTAssertEqual(d.noun, 44)
        let el = v.elements(snapshot: sim.snapshot), r = v.reference.radius, nm = 1_852.0
        XCTAssertEqual(Double(d.registers[0].value) ?? .nan, (el.apoapsisRadius - r) / nm, accuracy: 0.2)
        XCTAssertEqual(Double(d.registers[1].value) ?? .nan, (el.periapsisRadius - r) / nm, accuracy: 0.2)
        print("V82 on the stack: " + d.registers.map { "\($0.label) \($0.value)" }.joined(separator: ", "))
        cmc.press(.returnKey, at: sim.time)
        let plan = ManeuverPlan(name: "TEST", ignition: sim.time + 600, deltaV: v.velocity.normalized * 10,
                                deltaVLocal: Vec3(10, 0, 0), burnTime: 1, stateEpoch: sim.time, source: .transfer)
        XCTAssertEqual(cmc.uplink(plan, at: sim.time), .accepted)
        cmc.press(.returnKey, at: sim.time)
        XCTAssertEqual(cmc.display.noun, 42)
        XCTAssertNotEqual(cmc.display.registers[0].value, "OVFL")
        cmc.press(.returnKey, at: sim.time)
        cmc.press(.next, at: sim.time)
        XCTAssertEqual(cmc.program, 0)
        XCTAssertEqual(cmc.display.reason, "NO CONTROL OF THE VEHICLE")
    }
}
