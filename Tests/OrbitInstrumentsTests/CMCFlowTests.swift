import XCTest
import OrbitCore
@testable import OrbitInstruments

/// The computer flown through the pages' keys and the app's flight keys, on
/// Apollo 7's deorbit scenario: the CMC page on the left, DEORBIT on the
/// right; Return is the app's (`GuidanceComputer.press(.returnKey)`), G its
/// `ApolloSCS.selectGNAuto`, 8 its `clearGNAuto` then the hold. From the
/// review of #102 (and #101's findings its keys make reachable).
final class CMCFlowTests: XCTestCase {
    static let ft = 0.3048, deg = Double.pi / 180
    let ft = CMCFlowTests.ft

    struct Flight {
        let sim: Simulation
        let v: Vessel
        let mfd: MFDController
        var cmc: CMCLite { (v.guidanceComputer as? CMCLite)! }
        var scs: ApolloSCS { (v.flightProgram as? ApolloSCS)! }
        var get: Double { sim.time - VesselLibrary.apollo7RangeZero }
        var deorbit: DeorbitMFD { (mfd.mode(.deorbit, on: .right) as? DeorbitMFD)! }

        func fly(to t: Double) { while get < t - 1e-6 { sim.advance(by: min(0.1, t - get)) } }
        func fly(until done: () -> Bool, limit: Double) {
            while !done() && get < limit { sim.advance(by: min(0.02, limit - get)) }
        }
        @discardableResult
        func shift(_ key: PhysicalKey, _ side: MFDSide, times: Int = 1) -> Bool {
            var taken = true
            for _ in 0..<times { taken = mfd.handle(key, side: side, sim: sim) && taken }
            _ = mfd.page(side, sim: sim)
            return taken
        }
        func returnKey() { cmc.press(.returnKey, at: sim.time) }
        func page(_ side: MFDSide) -> MFDPage { mfd.page(side, sim: sim) }
        func logged(_ s: String) -> Bool { sim.events.contains { $0.message.contains(s) } }
        /// SPS-8 uplinked by the ground, accepted with two Returns: P00.
        func sps8Accepted() {
            XCTAssertEqual(cmc.uplink(ApolloCSM.apollo7SPS8Load(for: v, at: sim.time, system: sim.system), at: sim.time),
                           .accepted)
            returnKey()
            returnKey()
        }
    }

    func scenario() throws -> Flight {
        let sim = Simulation(system: try SolarSystem.bundled(), time: VesselLibrary.apollo7RangeZero)
        let v = VesselLibrary.apollo7BeforeDeorbit(in: sim)
        let mfd = MFDController(left: .cmc, right: .deorbit)
        mfd.missionClockZero = VesselLibrary.apollo7RangeZero
        let f = Flight(sim: sim, v: v, mfd: mfd)
        f.cmc.clockZero = VesselLibrary.apollo7RangeZero
        sim.advance(by: 0.02)
        _ = mfd.page(.left, sim: sim)
        _ = mfd.page(.right, sim: sim)
        return f
    }

    func dump(_ p: MFDPage) -> String { p.lines.joined(separator: "\n") }
    /// The angle between two attitudes, degrees.
    static func angle(_ a: Quat, _ b: Quat) -> Double {
        let q = a.conjugate * b
        return 2 * atan2((q.x * q.x + q.y * q.y + q.z * q.z).squareRoot(), abs(q.w)) / deg
    }
    static let tig = 934_756.3

    // #1: at V99, PRG on the page then the app's Return with nothing keyed
    // is OPR ERR and never enables ignition; the SPS stays dark past TIG.
    func testPRGThenReturnAtV99ThroughThePage() throws {
        let f = try scenario()
        f.sps8Accepted()
        f.shift(.n, .left)
        f.returnKey()
        f.fly(until: { f.cmc.step == .ignition }, limit: Self.tig)
        XCTAssertTrue(f.page(.left).shows("VERB 99 NOUN 40 *"))
        f.shift(.v, .left)   // PRG
        f.returnKey()
        XCTAssertFalse(f.cmc.ignitionEnabled)
        let p = f.page(.left)
        XCTAssertTrue(p.shows("VERB 37"), dump(p))
        XCTAssertTrue(p.shows("KEY THE PROGRAM"), dump(p))
        f.shift(.p, .left)   // PRO
        XCTAssertFalse(f.cmc.ignitionEnabled)
        f.fly(to: Self.tig + 2)
        XCTAssertNil(f.cmc.ignition)
    }

    // #7: G (the app's selectGNAuto) at V50N18 answers it: the countdown,
    // V99, and the SPS at TIG on Return.
    func testGAtV50N18ThroughTheApp() throws {
        let f = try scenario()
        f.sps8Accepted()
        f.shift(.n, .left)
        XCTAssertTrue(f.page(.left).shows("VERB 50 NOUN 18 *"))
        XCTAssertTrue(f.scs.selectGNAuto(f.v, in: f.sim))
        f.fly(until: { f.cmc.step == .ignition }, limit: Self.tig)
        f.returnKey()
        f.fly(to: Self.tig + 1)
        XCTAssertEqual(try XCTUnwrap(f.cmc.ignition) - VesselLibrary.apollo7RangeZero, Self.tig, accuracy: 1e-6)
    }

    // #5: G&N AUTO ends with the program: after N44's PRO on the page, and
    // after PRG 00 from the page during a slew.
    func testGNAutoEndsWithTheProgramThroughThePage() throws {
        let f = try scenario()
        f.sps8Accepted()
        f.shift(.n, .left)
        f.returnKey()
        f.fly(until: { f.cmc.step == .ignition }, limit: Self.tig)
        f.returnKey()
        f.fly(to: Self.tig + 20)
        XCTAssertTrue(f.scs.gnAuto)
        f.shift(.p, .left, times: 2)   // N85, N44
        f.fly(to: f.get + 0.1)
        XCTAssertFalse(f.scs.gnAuto)
        XCTAssertTrue(f.page(.left).shows("ATT SCS HOLD"))

        let g = try scenario()
        g.sps8Accepted()
        g.shift(.n, .left)
        g.returnKey()
        g.fly(to: g.get + 2)
        XCTAssertTrue(g.scs.gnAuto)
        for k: PhysicalKey in [.v, .digit0, .digit0, .returnKey] { g.shift(k, .left) }
        XCTAssertEqual(g.cmc.program, 0)
        g.fly(to: g.get + 0.1)
        XCTAssertFalse(g.scs.gnAuto)
    }

    // #6 and #17: a pointing mode ends G&N AUTO and takes the computer's
    // command off the vessel, so 8 then holds where the vessel is; and 8
    // pressed before the host's step withdraws a Return at V50N18.
    func testPointingModeThen8AndAPendingReturn() throws {
        let f = try scenario()
        var load = ApolloCSM.apollo7SPS8Load(for: f.v, at: f.sim.time, system: f.sim.system)
        let axis = f.v.position.cross(f.v.velocity).normalized
        load.deltaV = Quat(axis: axis, angle: 20 * Self.deg).rotate(load.deltaV)
        XCTAssertEqual(f.cmc.uplink(load, at: f.sim.time), .accepted)
        f.returnKey()
        f.returnKey()
        f.shift(.n, .left)
        f.returnKey()
        f.fly(to: f.get + 5)
        XCTAssertTrue(f.scs.gnAuto)
        f.v.autopilot = .prograde   // straight from G&N AUTO: the SCS sees it at its next step
        f.fly(to: f.get + 0.5)
        XCTAssertFalse(f.scs.gnAuto)
        XCTAssertNil(f.v.attitudeCommand)
        f.scs.holdAttitude(f.v, in: f.sim)   // 8
        let held = f.v.attitude
        f.fly(to: f.get + 10)
        XCTAssertNil(f.v.attitudeCommand)
        XCTAssertLessThan(Self.angle(held, f.v.attitude), 2)

        let g = try scenario()
        g.sps8Accepted()
        g.shift(.n, .left)
        g.returnKey()                                // V50N18 answered...
        g.scs.clearGNAuto(g.v, in: g.sim)            // ...and 8 before the next step
        g.v.autopilot = .attitudeHold
        g.fly(to: g.get + 2)
        XCTAssertFalse(g.scs.gnAuto)
    }

    // 8 holds where the vessel is whoever set the hold's command: Apollo 7's
    // scenario holds the flight's SPS-8 attitude (a standing command, which
    // Apollo7DeorbitTests fly by); 2 swings the nose round, and 8 then holds
    // there instead of swinging 54° back.
    func testEightAfterAPointingModeOnTheScenariosStandingCommand() throws {
        let f = try scenario()
        let standing = try XCTUnwrap(f.v.attitudeCommand).attitude
        f.v.autopilot = .retrograde   // 2
        f.fly(to: f.get + 20)
        XCTAssertGreaterThan(Self.angle(standing, f.v.attitude), 20)
        f.scs.holdAttitude(f.v, in: f.sim)   // 8
        XCTAssertNil(f.v.attitudeCommand)
        f.fly(to: f.get + 2)
        let held = f.v.attitude
        f.fly(to: f.get + 20)
        XCTAssertLessThan(Self.angle(held, f.v.attitude), 2)
        XCTAssertGreaterThan(Self.angle(standing, f.v.attitude), 20)
    }

    // DEORBIT names the program from the computer's state, not from its
    // display (blank from TIG-35 s to TIG-30 s), and shows the latest
    // refusal: a CLR refused after a refused SET.
    func testDeorbitNamesTheProgramAndTheLatestRefusal() throws {
        let f = try scenario()
        f.shift(.minus, .right, times: 9)   // TIG (impulsive) 259:40:00
        XCTAssertTrue(f.shift(.s, .right))
        XCTAssertTrue(f.shift(.s, .right))   // refused: P30 has the first
        XCTAssertTrue(f.page(.right).shows("UPLINK REFUSED: CMC NOT IN P00"))
        f.returnKey()
        f.returnKey()
        f.shift(.n, .left)
        let tig = try XCTUnwrap(f.cmc.load).ignition - VesselLibrary.apollo7RangeZero
        f.v.autopilot = .retrograde   // 2, then Return at V50N18 once round
        f.fly(until: { angleBetween(f.v.attitude.rotate(.unitX), -f.v.velocity) < 2 * Self.deg }, limit: tig - 60)
        f.returnKey()
        f.fly(until: { f.cmc.step == .countdown }, limit: tig - 36)
        XCTAssertEqual(f.cmc.step, .countdown)
        f.fly(to: tig - 32)
        XCTAssertNil(f.cmc.display.program)   // the blank
        XCTAssertTrue(f.shift(.c, .right))
        let p = f.page(.right)
        XCTAssertTrue(p.shows("LOAD IN CMC P40"), dump(p))
        XCTAssertTrue(p.shows("CLR REFUSED: P40 HAS THE LOAD"), dump(p))
        XCTAssertFalse(p.shows("UPLINK REFUSED"), dump(p))
    }

    // With a computer that flies the vehicle the marker is its load alone:
    // once a re-keyed load is dropped, SET's own record does not come back
    // as a marker for a burn nobody will fly.
    func testNoPhantomMarkerAfterARekey() throws {
        let f = try scenario()
        f.shift(.minus, .right, times: 10)
        XCTAssertTrue(f.shift(.s, .right))
        f.cmc.press(.minus, at: f.sim.time)
        for c in "500" { f.cmc.press(.digit(Int(String(c))!), at: f.sim.time) }
        f.returnKey()   // DVX re-keyed: -50.0 ft/s
        XCTAssertEqual(try XCTUnwrap(f.mfd.activeManeuver(for: f.v)).deltaV, try XCTUnwrap(f.cmc.load).deltaV)
        for k: PhysicalKey in [.v, .digit0, .digit0, .returnKey] { f.shift(k, .left) }   // PRG 00: abandoned
        XCTAssertNil(f.cmc.load)
        XCTAssertNotNil(f.mfd.data(for: f.v).maneuver)
        XCTAssertGreaterThan(try XCTUnwrap(f.scs.deltaVRemaining), 1)
        XCTAssertNil(f.mfd.activeManeuver(for: f.v))
    }

    // DEORBIT's N81 and P30's re-key share the J2 coast: for a TIG an apsis
    // away, the load re-keyed with its own digits is the same burn.
    func testARekeyAnApsisAwayIsTheSameBurn() throws {
        let f = try scenario()
        XCTAssertTrue(f.shift(.a, .right))   // TIG at the next apoapsis
        XCTAssertTrue(f.shift(.s, .right))
        let load = try XCTUnwrap(f.cmc.load)
        print(String(format: "TIG %.0f s away", load.ignition - f.sim.time))
        XCTAssertGreaterThan(load.ignition - f.sim.time, 600)
        let x = load.deltaVLocal.x / ft
        f.cmc.press(x < 0 ? .minus : .plus, at: f.sim.time)
        for c in String(Int((abs(x) * 10).rounded())) { f.cmc.press(.digit(Int(String(c))!), at: f.sim.time) }
        f.returnKey()
        f.returnKey()
        let rekeyed = try XCTUnwrap(f.cmc.load)
        XCTAssertEqual(rekeyed.source, .keyed)
        XCTAssertLessThan(angleBetween(rekeyed.deltaV, load.deltaV) / Self.deg, 0.02)
    }

    // #2 (a): SET, then the SCS way (Z at TIG, the EMS cutting off) with the
    // load still in P30: once that burn is over the load goes, the marker
    // with it, and NXT finds no load.
    func testSETThenZClearsTheLoadAfterTheBurn() throws {
        let f = try scenario()
        f.shift(.minus, .right, times: 10)   // TIG (impulsive) 259:39:00
        XCTAssertTrue(f.shift(.s, .right))
        XCTAssertEqual(f.cmc.program, 30)
        let tig = try XCTUnwrap(f.cmc.load).ignition - VesselLibrary.apollo7RangeZero
        f.fly(to: tig)
        f.v.mainThrottle = 1   // Z
        f.fly(to: tig + 20)
        XCTAssertTrue(f.logged("SPS cutoff (ΔV counter)"))
        XCTAssertNil(f.cmc.load)
        XCTAssertEqual(f.cmc.program, 0)
        XCTAssertTrue(f.logged("DEORBIT flown on the SCS, load cleared"))
        XCTAssertNil(f.mfd.activeManeuver(for: f.v))
        f.shift(.n, .left)
        XCTAssertEqual(f.cmc.display.reason, "NO LOAD")
        XCTAssertFalse(f.page(.right).shows("LOAD IN CMC"))
    }

    // #2 (b): CM/SM separation at N85: the computer's flight ends, the load
    // and the marker go.
    func testSeparationAtN85DropsTheLoad() throws {
        let f = try scenario()
        f.sps8Accepted()
        f.shift(.n, .left)
        f.returnKey()
        f.fly(until: { f.cmc.step == .ignition }, limit: Self.tig)
        f.returnKey()
        f.fly(to: Self.tig + 20)
        XCTAssertEqual(f.cmc.display.noun, 85)
        XCTAssertNotNil(f.sim.stage(f.v, event: 7))
        f.fly(to: f.get + 0.1)
        XCTAssertNil(f.cmc.load)
        XCTAssertEqual(f.cmc.program, 0)
        XCTAssertNil(f.mfd.activeManeuver(for: f.v))
        XCTAssertFalse(f.cmc.controlsVehicle)
        XCTAssertTrue(f.page(.left).shows("ATT CM"), dump(f.page(.left)))
    }

    // #4: DEORBIT's CLR is refused while P40 has its load, and changes
    // nothing; with a load DEORBIT did not uplink (the ground's, or keyed),
    // CLR leaves the computer alone.
    func testDeorbitCLR() throws {
        let f = try scenario()
        f.shift(.minus, .right, times: 10)
        XCTAssertTrue(f.shift(.s, .right))
        f.returnKey()
        f.returnKey()
        f.shift(.n, .left)
        XCTAssertEqual(f.cmc.program, 40)
        let ems = f.scs.deltaVRemaining
        XCTAssertTrue(f.shift(.c, .right))
        XCTAssertNotNil(f.cmc.load)
        XCTAssertEqual(f.scs.deltaVRemaining, ems)
        XCTAssertNotNil(f.mfd.data(for: f.v).maneuver)
        XCTAssertTrue(f.page(.right).shows("CLR REFUSED: P40 HAS THE LOAD"), dump(f.page(.right)))

        let g = try scenario()
        g.sps8Accepted()
        XCTAssertEqual(g.cmc.program, 0)
        XCTAssertTrue(g.shift(.c, .right))
        XCTAssertEqual(g.cmc.load?.name, "SPS-8")
        XCTAssertNil(g.scs.deltaVRemaining)
    }

    // #8 and #10: on the Saturn stack DEORBIT's SET is not offered (the CM's
    // computer is on standby and nothing there counts ΔV), and the CMC
    // page says the IU holds the attitude.
    func testOnTheStack() throws {
        let sim = Simulation(system: try SolarSystem.bundled(), time: VesselLibrary.apollo11Insertion)
        let v = VesselLibrary.apollo11InParkingOrbit(in: sim)
        sim.advance(by: 0.1)
        let mfd = MFDController(left: .cmc, right: .deorbit)
        let p = mfd.page(.right, sim: sim)
        XCTAssertEqual(p.buttons[10]?.label, "SET")
        XCTAssertEqual(p.buttons[10]?.inactive, true)
        XCTAssertFalse(mfd.handle(.s, side: .right, sim: sim))
        XCTAssertNil(v.guidanceComputer?.load)
        let standby = try XCTUnwrap(v.guidanceComputer)
        XCTAssertFalse(standby.controlsVehicle)
        let cmc = mfd.page(.left, sim: sim)
        XCTAssertTrue(cmc.shows("ATT IU HOLD"), dump(cmc))
    }

    // #11, #12 and #14: DEORBIT's N81 is in its TIG's own frame (the
    // centred ignition), so the load re-keyed with its own digits is the
    // same burn; re-keyed, the ground's ΔVC goes; the HUD's next event names
    // the burn as the marker does.
    func testDeorbitLoadFrameRekeyAndNextEvent() throws {
        let f = try scenario()
        f.shift(.minus, .right, times: 10)
        XCTAssertTrue(f.shift(.s, .right))
        let load = try XCTUnwrap(f.cmc.load)
        XCTAssertEqual(f.cmc.nextEvent(at: f.sim.time)?.name, "DEORBIT TIG")
        let atTIG = Kepler.propagate(Kepler.State(position: f.v.position, velocity: f.v.velocity),
                                     mu: f.v.reference.gm, by: load.ignition - f.sim.time)
        let n81 = DeorbitPlanner.localVerticalFrame(atTIG) * load.deltaV
        XCTAssertEqual((n81 - load.deltaVLocal).length, 0, accuracy: 0.02)
        XCTAssertNotNil(load.deltaVCounter)
        let x = load.deltaVLocal.x / ft
        f.cmc.press(.minus, at: f.sim.time)
        for c in String(Int((abs(x) * 10).rounded())) { f.cmc.press(.digit(Int(String(c))!), at: f.sim.time) }
        f.returnKey()
        f.returnKey()
        let rekeyed = try XCTUnwrap(f.cmc.load)
        XCTAssertEqual(rekeyed.source, .keyed)
        XCTAssertNil(rekeyed.deltaVCounter)
        XCTAssertNil(rekeyed.with)
        XCTAssertLessThan(angleBetween(rekeyed.deltaV, load.deltaV) / Self.deg, 0.01)
        XCTAssertTrue(f.page(.left).shows("DVC ---"), dump(f.page(.left)))
    }

    // #15: the page wraps a long reason, and P47's title is whole.
    func testNoSilentTruncation() throws {
        let f = try scenario()
        for c in "12" { f.cmc.press(.digit(Int(String(c))!), at: f.sim.time) }
        f.shift(.p, .left)
        var p = f.page(.left)
        XCTAssertTrue(p.shows("KEYED, NOT ENTERED: RETURN OR"), dump(p))
        XCTAssertTrue(p.shows("CLR"), dump(p))
        f.shift(.delete, .left)
        f.shift(.r, .left)
        for k: PhysicalKey in [.v, .digit4, .digit7, .returnKey] { f.shift(k, .left) }
        p = f.page(.left)
        XCTAssertTrue(p.lines[0].hasPrefix("CMC P47 THRUST MONITOR"), dump(p))
        for t in p.text where t.row > 0 {
            XCTAssertLessThanOrEqual(t.startColumn + t.string.count - 1, 35, "\(t)")
        }
    }
}
