import XCTest
@testable import OrbitCore

/// AS-506's terminal count on LC-39A (`TerminalCount`, `Plan.as506`): the
/// hold, the S-IC's 1-2-2 start and thrust buildup in the hold-down arms,
/// launch commit and the release, against FER-506's masses and the
/// first-motion state the ascent tests start from.
final class TerminalCountTests: XCTestCase {
    static let hold = -35.0
    let g0 = 9.80665

    /// A simulation `-hold` s before Apollo 11's range zero with the stack in
    /// its count, held.
    func countOnThePad(hold: Double = TerminalCountTests.hold) throws -> (Simulation, Vessel, TerminalCount) {
        let sim = try Simulation.forTests(perturbations: true)
        sim.setTime(AS506.rangeZero + hold)
        let count = VesselLibrary.apollo11InTerminalCount(in: sim, hold: hold)
        return (sim, count.vehicle!, count)
    }

    /// Steps as `Simulation.advance` does (`NominalFlight`'s loop), 0.02 s
    /// at most, until `done`.
    func run(_ sim: Simulation, until done: () -> Bool, limit: Double = 4_000) {
        let start = sim.time
        while !done() && sim.time - start < limit {
            for v in sim.vessels { sim.prepareControls(v) }
            sim.step(min(0.02, sim.maxStep()))
        }
    }

    func s(_ v: Vessel, _ name: String) -> Thruster { v.thrusters.first { $0.name == name }! }

    // FER Table 20-1: the vehicle at ground ignition, 6,477,875 lb (SP-4029's
    // Ground Ignition Weights; the table's 2,938,315 kg), is its first-motion
    // mass, 2,899,008 kg, plus Table 20-9's S-IC thrust buildup, 39,307 kg.
    // On the pad, held, the stack weighs the former; nothing moves until
    // Space resumes the count, however long it holds.
    func testTheCountHoldsUntilResumed() throws {
        let (sim, v, count) = try countOnThePad()
        XCTAssertTrue(count.isHolding)
        XCTAssertEqual(v.mass, 6_477_875 * 0.45359237, accuracy: 1.0, "FER Table 20-1, ground ignition")
        let fm = try Simulation.forTests(perturbations: true)
        let built = VesselLibrary.apollo11OnPad(in: fm).mass
        XCTAssertEqual(built, AS506.firstMotionMass, accuracy: 1.0, "FER Tables 20-1 and 20-9, first motion")
        XCTAssertEqual(v.mass - built, 39_307, accuracy: 1e-6, "FER Table 20-9, S-IC thrust buildup")
        let next = try XCTUnwrap((v.flightProgram as? SaturnIU)?.nextEvent(at: sim.time))
        XCTAssertTrue(next.name.contains("holding"), next.name)
        XCTAssertEqual(next.at - sim.time, 35, accuracy: 1e-9)
        v.mainThrottle = 1     // the pilot's Z: the count runs the engines, not the throttle
        sim.advance(by: 600)
        XCTAssertNotNil(v.landed)
        XCTAssertEqual(count.rangeTime(at: sim.time), -35)
        XCTAssertTrue(v.thrusters.allSatisfy { !$0.isDelivering })
        XCTAssertEqual(v.mass - built, 39_307, accuracy: 1e-6)
        // Space resumes it: range zero 35 s on.
        XCTAssertTrue(sim.stage(v) == nil)
        XCTAssertFalse(count.isHolding)
        XCTAssertEqual(count.rangeZero(at: sim.time) - sim.time, 35, accuracy: 1e-9)
        XCTAssertEqual(sim.events.last?.message, "Apollo 11: count resumed at T-35 s")
    }

    // The 1-2-2 start from T−5.3 s: engine 5, then 1 and 3, then 2 and 4, 0.3 s
    // apart, each rising linearly to full thrust; the buildup propellant comes
    // out of the S-IC's tanks at the engines' flow and mixture ratio (LOX and
    // RP-1 at the first-motion rating's 2.27), while the arms hold the stack
    // down against more than its weight. The accelerometers read the pad's
    // support, 1 g, all along (`EntryTelemetry`).
    func testTheOneTwoTwoStartInTheHoldDown() throws {
        let (sim, v, count) = try countOnThePad()
        let lox = v.parts[0].tanks[0], rp1 = v.parts[0].tanks[1]
        let lox0 = lox.mass, rp10 = rp1.mass
        let support = v.sensedAcceleration
        count.resume(at: sim.time, in: sim)
        let zero = try XCTUnwrap(count.rangeZero)
        XCTAssertEqual(zero, AS506.rangeZero, "resumed at once: T−0 at Apollo 11's range zero")
        // FER-506 Table 2-2's start commands, each igniting 3.35 s later.
        let names = ["S-IC engine 5", "S-IC engine 1", "S-IC engine 3", "S-IC engine 4", "S-IC engine 2"]
        let starts = [-6.4, -6.1, -6.1, -6.0, -5.9].map { $0 + 3.35 }
        let ratio = AS506.f1.mixtureRatio!
        let p0 = sim.atmosphere(of: sim.system.earth)!.seaLevelPressure
        var maxThrust = 0.0
        while true {
            for u in sim.vessels { sim.prepareControls(u) }
            if count.released != nil { break }
            let t = sim.time - zero
            for (name, start) in zip(names, starts) {
                let e = s(v, name)
                if t < start - 1e-6 {
                    XCTAssertFalse(e.isDelivering, "\(name) at \(t)")
                } else {
                    // At the middle of the coming step.
                    let g = try XCTUnwrap(e.groundStart, "\(name) at \(t)")
                    XCTAssertEqual(g, min(1, max(0, t - start) / count.plan.rise), accuracy: 0.0101 / count.plan.rise)
                }
            }
            maxThrust = max(maxThrust, v.thrusters.reduce(0) {
                $0 + $1.thrust(ambientPressure: v.atmosphere.pressure, seaLevelPressure: p0)
            })
            sim.step(min(0.02, sim.maxStep()))
            XCTAssertNotNil(v.landed, "held down at \(t)")
            XCTAssertEqual((v.sensedAcceleration - support).length, 0, accuracy: 1e-9 * g0)
            // What is burned comes out of the tanks at the mixture ratio.
            let burned = (lox0 - lox.mass) + (rp10 - rp1.mass)
            if burned > 1 { XCTAssertEqual((lox0 - lox.mass) / burned, ratio / (1 + ratio), accuracy: 1e-9) }
        }
        XCTAssertEqual((lox0 - lox.mass) + (rp10 - rp1.mass), 39_307, accuracy: 1e-6, "FER Table 20-9")
        XCTAssertGreaterThan(maxThrust, 1.1 * v.mass * g0, "the arms held more than the weight")
        let messages = sim.events.map(\.message)
        for e in ["S-IC intertank arm retract", "S-IC forward arm retract", "ignition sequence start",
                  "launch commit: thrust OK", "hold-down release"] {
            XCTAssertTrue(messages.contains("Apollo 11: \(e)"), e)
        }
    }

    // Released so that T−0 falls on Apollo 11's range zero, the count leaves
    // the stack at first motion exactly as `apollo11OnPad` builds it there,
    // the start the §17 ascent tests fly: the same epoch, mass, propellant
    // in every tank, each engine's thrust and flow, position, velocity,
    // attitude and centre of mass, bit for bit.
    func testFirstMotionIsTheBuildersBitForBit() throws {
        let (sim, v, count) = try countOnThePad()
        count.resume(at: sim.time, in: sim)
        run(sim) { sim.time >= AS506.rangeZero + AS506.holdDownRelease }
        XCTAssertEqual(sim.time, VesselLibrary.apollo11FirstMotion)
        let ref = try Simulation.forTests(perturbations: true)
        let b = VesselLibrary.apollo11OnPad(in: ref)
        b.mainThrottle = 1
        // The step at first motion: the count releases, the throttle lights the F-1s.
        sim.prepareControls(v)
        ref.prepareControls(b)
        XCTAssertNotNil(count.released)
        XCTAssertEqual(v.mass, b.mass)
        for (t, u) in zip(v.parts.flatMap(\.tanks), b.parts.flatMap(\.tanks)) { XCTAssertEqual(t.mass, u.mass, t.name) }
        let p0 = sim.atmosphere(of: sim.system.earth)!.seaLevelPressure
        for (e, f) in zip(v.thrusters, b.thrusters) {
            XCTAssertEqual(e.thrust(ambientPressure: v.atmosphere.pressure, seaLevelPressure: p0),
                           f.thrust(ambientPressure: b.atmosphere.pressure, seaLevelPressure: p0), e.name)
            XCTAssertEqual(e.massFlow, f.massFlow, e.name)
            XCTAssertEqual(e.burnTime, f.burnTime, e.name)
        }
        XCTAssertEqual(v.position, b.position)
        XCTAssertEqual(v.velocity, b.velocity)
        XCTAssertEqual(v.attitude, b.attitude)
        XCTAssertEqual(v.structureOrigin, b.structureOrigin)
        XCTAssertEqual(v.centerOfMass, b.centerOfMass)
    }

    // An F-1 that fails in the buildup is short of thrust at T−0: no commit,
    // the engines stop and the arms keep the stack on the pad, the propellant
    // it did not burn still aboard.
    func testAnEngineOutOnThePadScrubs() throws {
        let (sim, v, count) = try countOnThePad()
        count.resume(at: sim.time, in: sim)
        run(sim) { sim.time - count.rangeZero! >= -3 }
        s(v, "S-IC engine 2").fail()
        run(sim) { sim.time - count.rangeZero! >= 5 }
        XCTAssertNil(count.committed)
        XCTAssertNil(count.released)
        XCTAssertNotNil(count.scrub)
        XCTAssertTrue(count.scrub!.reason.contains("S-IC engine 2"))
        XCTAssertNotNil(v.landed)
        XCTAssertTrue(v.thrusters.allSatisfy { !$0.isDelivering })
        XCTAssertGreaterThan(v.mass, AS506.firstMotionMass + 0.2 * 39_307 / 5, "engine 2's unburned share aboard")
    }
}

extension TerminalCountTests {
    /// The IU's orbit `seconds` after its S-IVB cutoff, from a count resumed
    /// `delay` s after it opens: its inclination and descending node (from the
    /// launch meridian at guidance reference release, east), apsides over the
    /// 6,378,165 m sphere (km), and the count.
    func flyToOrbit(delay: Double) throws -> (i: Double, node: Double, apo: Double, peri: Double, count: TerminalCount,
                                              iu: SaturnIU) {
        let (sim, v, count) = try countOnThePad()
        if delay > 0 { sim.advance(by: delay) }
        XCTAssertTrue(count.isHolding)
        sim.stage(v)
        let iu = v.flightProgram as! SaturnIU
        var cutoff: Epoch?
        while cutoff.map({ sim.time < $0 + 10 }) ?? true {
            for u in sim.vessels { sim.prepareControls(u) }
            sim.step(min(0.02, sim.maxStep()))
            if cutoff == nil, let t5 = iu.timeBases[.t5] { cutoff = t5 }
            XCTAssertLessThan(sim.time - count.rangeZero(at: sim.time), 900, "no cutoff")
            if sim.time - count.rangeZero(at: sim.time) > 900 { break }
        }
        let frame = try XCTUnwrap(iu.spaceFixed)
        let pole = frame.conjugate.rotate(sim.snapshot.orientation(sim.system.earth).pole)
        let r = frame.conjugate.rotate(v.position), w = frame.conjugate.rotate(v.velocity)
        let h = r.cross(w).normalized, meridian = (Vec3.unitX - pole * pole.x).normalized
        let node = -pole.cross(h).normalized
        var nodeAngle = atan2(node.dot(pole.cross(meridian)), node.dot(meridian)) * 180 / .pi
        if nodeAngle < 0 { nodeAngle += 360 }
        let el = v.elements(snapshot: sim.snapshot), sphere = 6_378_165.0
        return (acos(h.dot(pole)) * 180 / .pi, nodeAngle, (el.apoapsisRadius - sphere) / 1000,
                (el.periapsisRadius - sphere) / 1000, count, iu)
    }

    // The launch window's targeting (GE504 Table 4-I): at guidance reference
    // release the IU takes the flight azimuth for the time of launch, from
    // Apollo 11's 72.058° at the window's opening up 36° in its 4 h 22 min to
    // the 108° limit (MOR M-932-69-11, Table 2), and the IGM's plane from
    // SA-504's polynomials in that azimuth (GE504 Table 5-I), anchored on
    // AS-506's nominal plane. On time it is the plan's, bit for bit; due east
    // the plane's inclination is about the pad's latitude (28.6°); at the
    // limit about the opening's, 72° and 108° lying either side of east.
    func testTheLaunchWindowsTargeting() {
        let iu = SaturnIU.as506(), deg = Double.pi / 180
        let onTime = iu.target(launchDelay: 0)
        XCTAssertEqual(onTime.azimuth, iu.plan.flightAzimuth)
        XCTAssertEqual(onTime.inclination, iu.plan.guidance!.presettings.inclination)
        XCTAssertEqual(onTime.descendingNode, iu.plan.guidance!.presettings.descendingNode)
        XCTAssertEqual(onTime.inclination / deg, 32.531, accuracy: 1e-9, "FER Table 4-5")
        let rate = (108.0 - 72) / (4 * 3600 + 22 * 60)
        let east = iu.target(launchDelay: (90 - 72.058) / rate)
        XCTAssertEqual(east.azimuth / deg, 90, accuracy: 1e-9)
        XCTAssertEqual(east.inclination / deg, 28.6, accuracy: 0.3)
        XCTAssertEqual(east.descendingNode / deg, 90, accuracy: 0.3)
        let closed = iu.target(launchDelay: 6 * 3600)
        XCTAssertEqual(closed.azimuth / deg, 108, accuracy: 1e-9, "held at range safety's limit")
        XCTAssertEqual(closed.inclination / deg, 33.1, accuracy: 0.3)
        XCTAssertEqual(closed.descendingNode / deg, 180 - 123.1, accuracy: 0.5)
    }

    // The controlled release (MAN506 p. 8-8; FER-506 Table 11-1): eight rods,
    // each about 400 kN at the release, falling linearly to nothing over the
    // first 6 in of rise. The rods hold the stack's acceleration to about
    // 0.08 g of its 0.195 g at first; the liftoff switches close at 3/4 in
    // about 0.2 s after the release, and the stroke ends about 0.55 s after
    // it, near FER-506 Figure 9-1's 0.6 s, at about 0.6 m/s. The accelerometers
    // read the rods: about 1.1 g at the release, rising to T/W.
    func testTheControlledRelease() throws {
        let (sim, v, count) = try countOnThePad()
        count.resume(at: sim.time, in: sim)
        run(sim) { count.released != nil && v.landed == nil }
        let release = try XCTUnwrap(count.released)
        var stroke: (t: Double, speed: Double)?
        var sensed: [Double] = []
        run(sim) {
            let rise = count.rise(of: v, snapshot: sim.snapshot) ?? 0
            sensed.append(v.loadFactor)
            if stroke == nil, rise >= 6 * 0.0254 {
                stroke = (sim.time - release, v.surfaceVelocity(snapshot: sim.snapshot).length)
            }
            return stroke != nil
        }
        let s = try XCTUnwrap(stroke)
        XCTAssertEqual(s.t, 0.55, accuracy: 0.05, "FER-506 Figure 9-1: the rods' force gone about 0.6 s after release")
        XCTAssertEqual(s.speed, 0.7, accuracy: 0.1)
        let switches = try XCTUnwrap(count.liftoffSwitch) - release
        XCTAssertEqual(switches, 0.21, accuracy: 0.03)
        // The model's T/W at first motion, 1.21 (FER-506 Table 11-1: 1.195),
        // less the rods' 3.2 MN at the release.
        let tw = 1.213, rods = 8 * 400_000 / (AS506.firstMotionMass * 9.80665)
        XCTAssertEqual(sensed.first ?? 0, tw - rods, accuracy: 0.02)
        XCTAssertEqual(sensed.last ?? 0, tw, accuracy: 0.02)
    }

    // Resumed at once, the live count flies AS-506's parking orbit: the
    // controlled release costs the ascent little, and the IGM takes it out.
    // Resumed two hours late, the IU flies the window's 88.5° and its plane,
    // an orbit as round, its node from the launch meridian moved with the
    // azimuth: a late launch flies to orbit at any time of the window.
    func testOnTimeAndLateLaunchesReachTheirParkingOrbits() throws {
        let onTime = try flyToOrbit(delay: 0)
        XCTAssertEqual(onTime.i, 32.532, accuracy: 0.005)
        XCTAssertEqual(onTime.node, 123.102, accuracy: 0.01)
        XCTAssertEqual(onTime.apo, 186.0, accuracy: 1)
        XCTAssertEqual(onTime.peri, 185.2, accuracy: 0.5)
        let late = try flyToOrbit(delay: 7_200)
        XCTAssertEqual(late.count.rangeZero! - AS506.rangeZero, 7_200, accuracy: 1e-6)
        let target = late.iu.targeting, deg = Double.pi / 180
        XCTAssertEqual(target.azimuth / deg, 72.058 + 7_200 * 36 / 15_720, accuracy: 1e-9)
        XCTAssertEqual(late.i, target.inclination / deg, accuracy: 0.005)
        XCTAssertEqual(late.node, target.descendingNode / deg, accuracy: 0.01)
        XCTAssertEqual(late.apo, 186.0, accuracy: 1)
        XCTAssertEqual(late.peri, 185.2, accuracy: 0.5)
        print(String(format: "late launch (2 h): azimuth %.3f°, i %.3f°, node %.3f°, %.1f x %.1f km",
                     target.azimuth / deg, late.i, late.node, late.apo, late.peri))
    }
}
