import XCTest
@testable import OrbitCore

/// P30 and P40 flying Apollo 7's deorbit, SPS-8, on M1.5's CSM: the load
/// uplinked into P30 and checked, P40's slew, Average-G from TIG−30 s with
/// the crew's ullage, V99, the computer's ignition at TIG, VG steering and
/// the cutoff on VG with the tail-off, the residuals, then the SM's
/// separation and the coast to entry interface, against the bands of
/// `Apollo7DeorbitTests`, which fly the same burn on Z and the EMS counter.
final class ExternalDeltaVTests: XCTestCase {
    let ft = CMCFlight.ft, lb = CMCFlight.lb, deg = CMCFlight.deg

    func testApollo7DeorbitThroughP30AndP40() throws {
        let f = try CMCFlight()
        let cmc = f.cmc, tig = CMCFlight.tigGET
        let load = f.sps8AsFlown()
        print(String(format: "SPS-8 load: %.2f m/s (%.1f ft/s)", load.deltaVMagnitude, load.deltaVMagnitude / ft))

        // P30: the uplink lands in P00, then N81 and N42, two Returns.
        XCTAssertEqual(cmc.uplink(load, at: f.sim.time), .accepted)
        XCTAssertEqual(cmc.program, 30)
        XCTAssertEqual(cmc.display.noun, 81)
        XCTAssertTrue(cmc.display.lamps.contains(.uplinkActivity))
        f.press(.returnKey)
        XCTAssertEqual(cmc.display.noun, 42)
        let n42 = cmc.display.registers
        print("N42: " + n42.map { "\($0.label) \($0.value) \($0.unit)" }.joined(separator: ", "))
        f.press(.returnKey)
        XCTAssertEqual(cmc.program, 0)
        XCTAssertEqual(cmc.load, load)
        XCTAssertFalse(cmc.display.lamps.contains(.uplinkActivity))
        // The warp comes down for it: 1x from TIG−30 s.
        XCTAssertTrue(f.v.flightProgram!.warpEvents(after: f.sim.time).contains { $0.reason == "TIG-30 s" })

        // NXT: P40, V50N18; Return gives the computer the attitude.
        f.press(.next)
        XCTAssertEqual(cmc.program, 40)
        XCTAssertEqual(cmc.display.verb, 50)
        XCTAssertTrue(cmc.display.flashing)
        f.press(.returnKey)
        f.fly(to: f.get + 1)
        XCTAssertTrue(f.scs.gnAuto)
        XCTAssertEqual(cmc.step, .countdown)   // the scenario holds the burn's attitude already
        XCTAssertTrue(f.logged("SPS gimbal test"))

        // The crew's ullage, U from 259:39:01.3 for 15 s; Average-G counts it.
        f.fly(to: tig - 15)
        XCTAssertNotNil(cmc.burn?.averageG.start)
        f.ullage(true)
        var vgAtV99: Double?
        f.fly(until: { cmc.step == .ignition }, limit: tig)
        // V99 at the step that starts at TIG−5 s (seen once that step is done).
        XCTAssertGreaterThan(f.get, tig - 5)
        XCTAssertLessThan(f.get, tig - 5 + 0.021)
        XCTAssertEqual(cmc.display.verb, 99)
        f.press(.returnKey)
        f.fly(to: tig)
        f.ullage(false)
        vgAtV99 = cmc.burn?.velocityToBeGained.length
        let m0 = f.v.mass

        // Ignition at TIG by the computer; the cutoff on VG.
        var cutoff: (get: Double, state: (speed: Double, gamma: Double, altitude: Double))?
        f.fly(to: tig + 20) {
            if cutoff == nil, let c = cmc.cutoff { cutoff = (c - ApolloCSM.apollo7RangeZero, f.state()) }
        }
        let ign = try XCTUnwrap(cmc.ignition) - ApolloCSM.apollo7RangeZero
        XCTAssertEqual(ign, tig, accuracy: 1e-6)
        XCTAssertFalse(cmc.scsBurn)
        let c = try XCTUnwrap(cutoff)
        let used = (m0 - f.v.mass) / lb
        let ref = ApolloCSM.apollo7SPS8Cutoff
        print(String(format: "P40: ullage counted %.2f m/s; cutoff %.3f s after TIG; at the cutoff %.1f ft/s (%.1f), "
                     + "%.3f° (%.3f), %.0f ft (%.0f); %.1f lb", load.deltaVMagnitude - (vgAtV99 ?? .nan),
                     c.get - tig, c.state.speed / ft, ref.speed, c.state.gamma / deg, ref.flightPathAngle,
                     c.state.altitude / ft, ref.altitude, used))
        XCTAssertEqual(c.get - tig, 11.9, accuracy: 0.05)
        XCTAssertEqual(c.state.speed / ft, ref.speed, accuracy: 4)
        XCTAssertEqual(c.state.gamma / deg, ref.flightPathAngle, accuracy: 0.03)
        XCTAssertEqual(c.state.altitude / ft, ref.altitude, accuracy: 2_000)
        XCTAssertEqual(used, 809, accuracy: 20)
        // The EMS counted the burn but did not cut it off.
        XCTAssertFalse(f.logged("SPS cutoff (ΔV counter)"))
        XCTAssertLessThan(try XCTUnwrap(f.scs.deltaVRemaining), 0)

        // N85: the residuals after the tail-off, within what the tail-off's
        // spread would leave (none is modelled: steering and the step's end).
        XCTAssertEqual(cmc.step, .residuals)
        XCTAssertEqual(cmc.display.noun, 85)
        let r = try XCTUnwrap(cmc.residuals)
        print(String(format: "N85: %+.2f %+.2f %+.2f ft/s", r.x / ft, r.y / ft, r.z / ft))
        XCTAssertLessThan(r.length, 0.2 * ft)
        f.press(.returnKey)
        XCTAssertEqual(cmc.display.noun, 44)
        print("N44: " + cmc.display.registers.map { "\($0.label) \($0.value)" }.joined(separator: ", "))
        f.press(.returnKey)
        XCTAssertEqual(cmc.program, 0)
        XCTAssertNil(cmc.load)
        XCTAssertTrue(f.v.flightProgram!.warpEvents(after: f.sim.time).isEmpty)

        // CM/SM separation at 259:43:33.8, then entry interface.
        f.fly(to: ApolloCSM.apollo7CMSMSeparation)
        XCTAssertNotNil(f.sim.stage(f.v, event: 7))
        var ei: (get: Double, speed: Double, gamma: Double)?
        var previous = (get: f.get, altitude: f.v.altitude, speed: f.v.velocity.length, gamma: f.state().gamma)
        let interface = ApolloCSM.apollo7EntryInterface.altitude * ft
        while ei == nil && f.get < ApolloCSM.apollo7EntryInterface.groundElapsedTime + 120 {
            f.fly(to: f.get + 0.5)
            let s = f.state()
            if f.v.altitude <= interface {
                let u = (previous.altitude - interface) / (previous.altitude - f.v.altitude)
                ei = (previous.get + u * (f.get - previous.get), previous.speed + u * (s.speed - previous.speed),
                      previous.gamma + u * (s.gamma - previous.gamma))
            }
            previous = (f.get, f.v.altitude, s.speed, s.gamma)
        }
        let e = try XCTUnwrap(ei)
        let eiRef = ApolloCSM.apollo7EntryInterface
        print(String(format: "Apollo 7 EI through P40: GET %.1f s (%.1f), %.1f ft/s (%.1f), %.3f° (%.3f)",
                     e.get, eiRef.groundElapsedTime, e.speed / ft, eiRef.speed, e.gamma / deg, eiRef.flightPathAngle))
        XCTAssertEqual(e.get, eiRef.groundElapsedTime, accuracy: 5)
        XCTAssertEqual(e.speed / ft, eiRef.speed, accuracy: 10)
        XCTAssertEqual(e.gamma / deg, eiRef.flightPathAngle, accuracy: 0.05)
    }
}
