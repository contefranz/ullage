import XCTest
import OrbitCore
@testable import OrbitInstruments

/// Apollo 7's deorbit flown as the pilot flies it with M2's controls
/// (docs/m2/design-flight-controls.md §9, the first proof), from the
/// scenario "Apollo 7: deorbit and entry" (GET 259:38:00) to entry
/// interface on M1.5's CSM, through the keys only, in the app's frames
/// (`Simulation.advance`, its warp governor):
/// - the load: DEORBIT's SET (left MFD), whose uplink lands in the CMC's
///   P30 with ΔVC in the EMS counter and the navball's marker; or the
///   flight's PAD keyed by hand into P30 on the CMC page (right MFD);
/// - Return twice (P30's N81 and N42), the CMC's NXT, Return at V50N18
///   (G&N AUTO);
/// - U for 15 s of ullage before TIG, Return at V99: the CMC lights the
///   SPS at TIG, steers on VG and cuts off;
/// - Return at N85 and N44, Space twice at 259:43:33.8 (CM/SM separation),
///   and the CM's entry program on to entry interface.
///
/// DEORBIT's planner burns retrograde, while the flight's states put SPS-8
/// 57° below retrograde, mostly radial (`ApolloCSM.apollo7SPS8DeltaV`): its
/// PAD for the flight's EI angle comes in 150 s later and 90 ft/s slower,
/// and no retrograde burn at that TIG meets the flight's EI in time, speed
/// and angle together. So DEORBIT's flight is held to its own prediction,
/// and the flight's own PAD, keyed by hand, to the entry pins.
final class DeorbitThroughP40Tests: XCTestCase {
    static let ft = 0.3048, deg = Double.pi / 180
    let ft = DeorbitThroughP40Tests.ft, deg = DeorbitThroughP40Tests.deg

    /// CM/SM separation at 259:43:33.8 GET (Table 2-I), and entry interface
    /// at 259:53:27, 25,846.4 ft/s and −2.072° (Table 2-I, §5.16), as
    /// `ApolloCSM` holds them for Apollo7DeorbitTests.
    static let cmsmSeparation = 935_013.8
    static let entryInterface = (get: 935_607.0, speed: 25_846.4, gamma: -2.072)

    struct Flight {
        let sim: Simulation
        let v: Vessel
        let mfd: MFDController
        var get: Double { sim.time - VesselLibrary.apollo7RangeZero }
        var cmc: CMCLite { (v.guidanceComputer as? CMCLite)! }
        var scs: ApolloSCS { (v.flightProgram as? ApolloSCS)! }

        /// Frames of `frame` s at 1x to GET `t`, the last one shorter.
        func fly(to t: Double, frame: Double = 0.1) {
            while get < t - 1e-6 { sim.advance(by: min(frame, t - get)) }
        }

        func fly(until done: () -> Bool, limit: Double) {
            while !done() && get < limit { sim.advance(by: min(0.02, limit - get)) }
        }

        /// A Shift key on the left or right MFD, then the page drawn (as
        /// the app's MFD model refreshes it).
        @discardableResult
        func shift(_ key: PhysicalKey, _ side: MFDSide, times: Int = 1) -> Bool {
            var taken = true
            for _ in 0..<times { taken = mfd.handle(key, side: side, sim: sim) && taken }
            _ = mfd.page(side, sim: sim)
            return taken
        }

        /// Digits and a sign keyed on the CMC page (Shift and the key), then
        /// its ENT (Shift+Return).
        func enter(_ s: String) {
            for c in s {
                switch c {
                case "+": shift(.equal, .right)
                case "-": shift(.minus, .right)
                default: shift(PhysicalKey(rawValue: String(c))!, .right)
                }
            }
            shift(.returnKey, .right)
        }

        /// The flight key Return, as the app dispatches it.
        func returnKey() { v.guidanceComputer?.press(.returnKey, at: sim.time) }

        func state() -> (speed: Double, gamma: Double) {
            (v.velocity.length, asin(v.velocity.normalized.dot(v.position.normalized)))
        }
    }

    func scenario() throws -> Flight {
        let sim = Simulation(system: try SolarSystem.bundled(), time: VesselLibrary.apollo7RangeZero)
        let v = VesselLibrary.apollo7BeforeDeorbit(in: sim)
        let mfd = MFDController(left: .deorbit, right: .cmc)
        mfd.missionClockZero = VesselLibrary.apollo7RangeZero
        let f = Flight(sim: sim, v: v, mfd: mfd)
        f.cmc.clockZero = VesselLibrary.apollo7RangeZero
        sim.advance(by: 0.02)
        _ = mfd.page(.left, sim: sim)
        _ = mfd.page(.right, sim: sim)
        return f
    }

    /// From P00 with the load accepted: NXT, Return at V50N18 (after
    /// swinging the nose round on 2 first, if `retrograde`), U for 15 s
    /// before TIG, Return at V99, the burn, Return at N85 and N44. Returns
    /// the burn's length and the residuals at N85 (crew axes, m/s).
    func flyP40(_ f: Flight, retrograde: Bool) throws -> (burn: Double, residuals: Vec3) {
        let zero = VesselLibrary.apollo7RangeZero
        let tig = try XCTUnwrap(f.cmc.load).ignition - zero
        XCTAssertTrue(f.shift(.n, .right))
        XCTAssertEqual(f.cmc.program, 40)
        XCTAssertEqual(f.cmc.display.verb, 50)
        f.fly(to: f.get + 0.5)
        print("V50N18: " + f.cmc.display.registers.map { "\($0.label) \($0.value)" }.joined(separator: ", "))
        if retrograde {
            // 2 (retrograde) swings the nose round on the SCS, faster than
            // the computer's 0.5°/s, which would not get there by TIG.
            f.v.autopilot = .retrograde
            f.fly(until: { angleBetween(f.v.attitude.rotate(.unitX), -f.v.velocity) < 2 * deg }, limit: tig - 40)
            print(String(format: "retrograde at TIG-%.1f s", tig - f.get))
        }
        f.returnKey()
        f.fly(until: { f.cmc.step == .countdown }, limit: tig - 30)
        XCTAssertEqual(f.cmc.step, .countdown)
        XCTAssertTrue(f.scs.gnAuto)
        print(String(format: "attitude reached at TIG-%.1f s", tig - f.get))

        f.fly(to: tig - 15)
        f.v.setPilotInput(rotation: RotationCommand(), translation: Vec3(1, 0, 0))
        f.fly(until: { f.cmc.step == .ignition }, limit: tig)
        XCTAssertEqual(f.cmc.display.verb, 99)
        f.returnKey()
        f.fly(to: tig, frame: 0.02)
        f.v.setPilotInput(rotation: RotationCommand(), translation: .zero)
        f.fly(to: tig + 20)
        XCTAssertEqual(try XCTUnwrap(f.cmc.ignition) - zero, tig, accuracy: 1e-6)
        let burn = try XCTUnwrap(f.cmc.cutoff) - f.cmc.ignition!
        let r = try XCTUnwrap(f.cmc.residuals)
        XCTAssertEqual(f.cmc.display.noun, 85)
        print(String(format: "P40: %.2f s burn, N85 %+.2f %+.2f %+.2f ft/s, EMS %+.2f m/s", burn, r.x / ft,
                     r.y / ft, r.z / ft, f.scs.deltaVRemaining ?? .nan))
        f.returnKey()
        XCTAssertEqual(f.cmc.display.noun, 44)
        f.returnKey()
        XCTAssertEqual(f.cmc.program, 0)
        XCTAssertNil(f.mfd.activeManeuver(for: f.v))
        return (burn, r)
    }

    /// Space twice at 259:43:33.8, then on to 400,000 ft.
    func flyToEntryInterface(_ f: Flight) throws -> (get: Double, speed: Double, gamma: Double) {
        f.fly(to: Self.cmsmSeparation)
        XCTAssertNil(f.sim.stage(f.v))      // armed
        XCTAssertNotNil(f.sim.stage(f.v))   // within 2 s
        var ei: (get: Double, speed: Double, gamma: Double)?
        var previous = (get: f.get, altitude: f.v.altitude, speed: f.v.velocity.length, gamma: f.state().gamma)
        let interface = 400_000 * ft
        while ei == nil && f.get < Self.entryInterface.get + 300 {
            f.fly(to: f.get + 0.5, frame: 0.5)
            let s = f.state()
            if f.v.altitude <= interface {
                let u = (previous.altitude - interface) / (previous.altitude - f.v.altitude)
                ei = (previous.get + u * (f.get - previous.get), previous.speed + u * (s.speed - previous.speed),
                      previous.gamma + u * (s.gamma - previous.gamma))
            }
            previous = (f.get, f.v.altitude, s.speed, s.gamma)
        }
        return try XCTUnwrap(ei)
    }

    // DEORBIT's PAD for the flight's EI angle, through SET, P30 and P40:
    // TIG (impulsive) from 259:49:00, the page's default (ten minutes ahead,
    // on the next whole minute), to 259:39:20 (T− ten minutes, then STP to
    // 10 s and T+ twice), its centred TIG 1.5 s before the flight's
    // 259:39:16.3; the EI angle from −1.750° to −2.050° by six V−. SET
    // uplinks the burn into P30, ΔVC into the EMS and the marker; the
    // flight ends where DEORBIT predicted it would: entry interface within
    // 5 s, 10 ft/s and 0.05° of its prediction.
    func testApollo7DeorbitFromDEORBITSetToEntryInterface() throws {
        let f = try scenario()
        let zero = VesselLibrary.apollo7RangeZero
        let mode = try XCTUnwrap(f.mfd.mode(.deorbit, on: .left) as? DeorbitMFD)
        XCTAssertEqual(try XCTUnwrap(mode.ignition) - zero, 259 * 3_600 + 49 * 60, accuracy: 1e-6)
        XCTAssertTrue(f.shift(.minus, .left, times: 10))
        f.shift(.i, .left, times: 2)
        XCTAssertEqual(mode.step, 10)
        f.shift(.equal, .left, times: 2)
        XCTAssertEqual(try XCTUnwrap(mode.ignition) - zero, 259 * 3_600 + 39 * 60 + 20, accuracy: 1e-6)
        f.shift(.leftBracket, .left, times: 6)
        XCTAssertTrue(f.mfd.page(.left, sim: f.sim).shows("TGT EI -2.050°"))
        let plan = try XCTUnwrap(mode.plan)
        let predicted = try XCTUnwrap(plan.entry)
        let tig = try XCTUnwrap(plan.centredIgnition) - zero
        print(String(format: "DEORBIT PAD: TIG %.2f GET, Δv %.2f m/s, BT %.2f s; EI %.1f GET, %.1f ft/s, %.3f°",
                     tig, plan.deltaVMagnitude, plan.burnTime ?? .nan, predicted.time - zero,
                     predicted.inertialSpeed / ft, predicted.inertialFlightPathAngle / deg))

        // SET: the uplink lands in P30 (N81, UPLK lit), the EMS gets ΔVC.
        XCTAssertTrue(f.shift(.s, .left))
        XCTAssertEqual(mode.uplink, .accepted)
        XCTAssertEqual(f.cmc.program, 30)
        XCTAssertEqual(f.cmc.display.noun, 81)
        XCTAssertTrue(f.mfd.page(.left, sim: f.sim).shows("UPLINK: CMC P30"))
        let load = try XCTUnwrap(f.cmc.load)
        XCTAssertEqual(load.source, .deorbit)
        XCTAssertEqual(load.ignition - zero, tig, accuracy: 1e-9)
        XCTAssertEqual(load.deltaV, plan.deltaV)
        let dvc = try XCTUnwrap(f.scs.deltaVRemaining)
        print(String(format: "ΔVT %.2f m/s, ΔVC %.2f m/s (tail-off %.2f)", plan.deltaVMagnitude, dvc,
                     plan.deltaVMagnitude - dvc))
        XCTAssertEqual(dvc, try XCTUnwrap(load.deltaVCounter), accuracy: 1e-12)
        XCTAssertEqual(plan.deltaVMagnitude - dvc, 2.4, accuracy: 0.2)
        XCTAssertEqual(try XCTUnwrap(f.mfd.activeManeuver(for: f.v)).deltaV, plan.deltaV)
        let page = f.mfd.page(.right, sim: f.sim)
        XCTAssertTrue(page.shows("[UPLK]"), page.lines.joined(separator: "\n"))
        XCTAssertTrue(page.shows("LOAD DEORBIT SPS DEORBIT"), page.lines.joined(separator: "\n"))
        // A second SET while P30 checks the first is refused, and says so.
        XCTAssertTrue(f.shift(.s, .left))
        XCTAssertEqual(mode.uplink, .refused("CMC NOT IN P00"))
        XCTAssertTrue(f.mfd.page(.left, sim: f.sim).shows("UPLINK REFUSED: CMC NOT IN P00"))

        // P30's two Returns, then P40.
        f.returnKey()
        XCTAssertEqual(f.cmc.display.noun, 42)
        f.returnKey()
        XCTAssertEqual(f.cmc.program, 0)
        let (burn, r) = try flyP40(f, retrograde: true)
        XCTAssertFalse(f.mfd.page(.left, sim: f.sim).shows("UPLINK: CMC P30"))   // flown
        XCTAssertEqual(burn, try XCTUnwrap(plan.burnTime), accuracy: 0.6)
        XCTAssertLessThan(r.length, 0.2 * ft)

        let e = try flyToEntryInterface(f)
        let pin = Self.entryInterface
        print(String(format: "Apollo 7 EI from DEORBIT SET: GET %.1f (DEORBIT %.1f, flight %.1f), %.1f ft/s (%.1f, %.1f), "
                     + "%.3f° (%.3f, %.3f)", e.get, predicted.time - zero, pin.get, e.speed / ft,
                     predicted.inertialSpeed / ft, pin.speed, e.gamma / deg, predicted.inertialFlightPathAngle / deg,
                     pin.gamma))
        XCTAssertEqual(e.get, predicted.time - zero, accuracy: 5)
        XCTAssertEqual(e.speed, predicted.inertialSpeed, accuracy: 10 * ft)
        XCTAssertEqual(e.gamma, predicted.inertialFlightPathAngle, accuracy: 0.05 * deg)
    }

    // The flight's own PAD for SPS-8 (`ApolloCSM.apollo7SPS8Load`) keyed by
    // hand on the CMC page: PRG 30, N33's TIG 259:39:16.30, N81's Δv to a
    // tenth of a ft/s, each register's digits then ENT; Return to N42 and to
    // P00; then P40 as above, with no swing (the scenario holds the burn's
    // attitude). Entry interface within Apollo7DeorbitTests' pins.
    func testApollo7DeorbitFromAPADKeyedByHand() throws {
        let f = try scenario()
        let pad = ApolloCSM.apollo7SPS8Load(for: f.v, at: f.sim.time, system: f.sim.system)
        f.shift(.v, .right)
        XCTAssertEqual(f.cmc.display.verb, 37)
        f.enter("30")
        XCTAssertEqual(f.cmc.program, 30)
        XCTAssertEqual(f.cmc.display.noun, 33)
        for value in ["259", "39", "1630"] { f.enter(value) }
        f.returnKey()
        XCTAssertEqual(f.cmc.display.noun, 81)
        let n81 = pad.deltaVLocal / ft
        for x in [n81.x, n81.y, n81.z] { f.enter((x < 0 ? "-" : "+") + String(Int((abs(x) * 10).rounded()))) }
        print("N81 keyed: " + f.cmc.display.registers.map { "\($0.label) \($0.value)" }.joined(separator: ", "))
        f.returnKey()
        XCTAssertEqual(f.cmc.display.noun, 42)
        let load = try XCTUnwrap(f.cmc.load)
        XCTAssertEqual(load.source, .keyed)
        XCTAssertEqual(load.ignition - pad.ignition, 0, accuracy: 0.006)
        XCTAssertEqual((load.deltaV - pad.deltaV).length, 0, accuracy: 0.1 * ft)
        f.returnKey()
        XCTAssertEqual(f.cmc.program, 0)
        let (burn, r) = try flyP40(f, retrograde: false)
        XCTAssertEqual(burn, 11.9, accuracy: 0.05)
        XCTAssertLessThan(r.length, 0.2 * ft)

        let e = try flyToEntryInterface(f)
        let pin = Self.entryInterface
        print(String(format: "Apollo 7 EI from the keyed PAD: GET %.1f s (%.1f), %.1f ft/s (%.1f), %.3f° (%.3f)",
                     e.get, pin.get, e.speed / ft, pin.speed, e.gamma / deg, pin.gamma))
        XCTAssertEqual(e.get, pin.get, accuracy: 5)
        XCTAssertEqual(e.speed / ft, pin.speed, accuracy: 10)
        XCTAssertEqual(e.gamma / deg, pin.gamma, accuracy: 0.05)
    }
}
