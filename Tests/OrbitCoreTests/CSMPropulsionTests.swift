import XCTest
@testable import OrbitCore

/// The CSM's SPS in flight: its gimbal trimmed through the offset centre
/// of mass under the SCS, its propellant use against an Apollo 7 burn, and
/// the EMS ΔV counter's cutoff.
final class CSMPropulsionTests: XCTestCase {
    let lb = 0.45359237, deg = Double.pi / 180

    /// Apollo 7's CSM at Table A.5-I row `row`, in free space, its SCS in
    /// charge and holding its attitude.
    func apollo7(row: Int) throws -> (sim: Simulation, v: Vessel, scs: ApolloSCS) {
        let sim = try Simulation.forTests(perturbations: false)
        let v = VesselLibrary.apolloCSM(.apollo7)
        let loads = ApolloCSM.apollo7Loads(row: row)
        ApolloCSM.setLoads(v, spsOxidizer: loads.spsOxidizer, spsFuel: loads.spsFuel, rcs: loads.rcs)
        sim.add(v)
        sim.placeInFreeSpace(v)
        v.autopilot = .attitudeHold
        return (sim, v, try XCTUnwrap(v.flightProgram as? ApolloSCS))
    }

    // An SPS burn on Apollo 7 at SPS-8's row (17: CG at Y_A -0.9 in, Z_A
    // +6.9 in, 140 in ahead of the gimbal): the SCS trims the gimbal so the
    // thrust passes through the centre of mass, 2.8° towards +Z_A and 0.4°
    // towards -Y_A at ignition, inside the ±4.5° about the nulls, and keeps
    // it there as the CG moves; the actuators settle on it; over 30 s the
    // gimbals hold pitch and yaw within 0.5° of the attitude held at
    // ignition and the SM RCS holds roll in its 0.5° dead band (the CSM's
    // law), firing only roll jets.
    func testSPSBurnTrimsThroughTheCentreOfMass() throws {
        let (sim, v, _) = try apollo7(row: 17)
        sim.tick()
        let held = v.attitude
        let sps = try XCTUnwrap(v.thrusters.first { $0.name == "SPS" })
        let sm = try XCTUnwrap(v.parts.first { $0.name == "SM" })
        v.mainThrottle = 1
        sim.tick()
        let ignitionTrim = sps.gimbal.map(\.bias)
        var worst = 0.0, worstRoll = 0.0, pitchYawJets = false
        sim.run(seconds: 30) {
            let e = rotationVector(v.attitude.conjugate * held)
            worst = max(worst, Vec3(0, e.y, e.z).length)
            worstRoll = max(worstRoll, abs(e.x))
            if v.thrusters.contains(where: { $0.name.hasPrefix("SM RCS") && $0.isDelivering
                && !($0.groups.contains(.rollLeft) || $0.groups.contains(.rollRight)) }) { pitchYawJets = true }
        }
        let r = v.centerOfMass - (sps.position + sm.offset)
        let torque = r.cross(sps.thrustDirection).length * 93_768
        print(String(format: "SPS trim: pitch %.3f°, yaw %.3f°, angles %.3f°, %.3f°; torque %.1f N m; error %.3f°, roll %.3f°",
                     sps.gimbal[0].bias / deg, sps.gimbal[1].bias / deg, sps.gimbal[0].angle / deg,
                     sps.gimbal[1].angle / deg, torque, worst / deg, worstRoll / deg))
        XCTAssertTrue(sps.isDelivering)
        XCTAssertEqual(ignitionTrim[0] / deg, atan(6.9 / 140) / deg, accuracy: 0.05)
        XCTAssertEqual(ignitionTrim[1] / deg, atan(-0.9 / 140) / deg, accuracy: 0.05)
        // 918 kg later the oxidizer, on the +Y_A side, has drained faster
        // than the fuel: the CG, and the trim with it, has moved to -Y_A.
        XCTAssertLessThan(sps.gimbal[1].bias, ignitionTrim[1] - 0.2 * deg)
        for a in sps.gimbal {
            XCTAssertEqual(a.angle, a.bias, accuracy: 0.05 * deg)
            XCTAssertTrue(a.range.contains(a.angle))
        }
        XCTAssertLessThan(torque, 100)
        XCTAssertLessThan(worst, 0.5 * deg)
        XCTAssertLessThan(worstRoll, 0.75 * deg)
        XCTAssertFalse(pitchYawJets)
    }

    // Apollo 7's SPS-5, 165:00:00.5 to 165:01:07.6 (Table 2-I): 67.1 s, and
    // the weight dropped 4,530 lb from row 11 to row 12 (Table A.5-I). The
    // model burns 67.1 s of 67.49 lb/s and its 0.54 s tail-off, 4,547 lb,
    // 0.4 % more.
    func testApollo7SPS5PropellantUse() throws {
        let (sim, v, _) = try apollo7(row: 11)
        let m0 = v.mass
        v.mainThrottle = 1
        sim.run(seconds: 67.1)
        v.mainThrottle = 0
        sim.run(seconds: 2)
        let used = (m0 - v.mass) / lb
        print(String(format: "SPS-5: %.1f lb", used))
        XCTAssertEqual(used, 4_530, accuracy: 0.005 * 4_530)
    }

    // The EMS ΔV counter: loaded with 50 m/s, it counts the Δv sensed along
    // X_A (thrust over mass) and cuts the SPS off as it reaches zero, the
    // simulation ending a step there; the tail-off, a 0.54 s ramp, then
    // takes it below zero by about 0.27 s x F / m.
    func testDeltaVCounterCutsTheSPSOff() throws {
        let (sim, v, scs) = try apollo7(row: 17)
        scs.loadDeltaV(50)
        XCTAssertEqual(scs.deltaVRemaining, 50)
        let x = v.attitude.rotate(.unitX), v0 = v.velocity
        v.mainThrottle = 1
        var cutoff: Double?, t = 0.0
        while t < 20 {
            for w in sim.vessels { sim.prepareControls(w) }
            let h = min(0.02, sim.maxStep())
            sim.step(h)
            t += h
            if cutoff == nil && v.mainThrottle == 0 { cutoff = t }
        }
        let at = try XCTUnwrap(cutoff)
        let fm = 93_768.5 / v.mass
        let remaining = try XCTUnwrap(scs.deltaVRemaining)
        print(String(format: "EMS: cutoff after %.3f s, %.3f m/s left, along X %.3f m/s", at, remaining,
                     (v.velocity - v0).dot(x)))
        XCTAssertEqual(remaining, -0.27 * fm, accuracy: 0.05)
        XCTAssertEqual((v.velocity - v0).dot(x), 50 - remaining, accuracy: 0.05)
        XCTAssertTrue(sim.events.contains { $0.message.contains("SPS cutoff (ΔV counter)") })
    }
}
