import XCTest
import OrbitCore
@testable import OrbitScene

/// The plumes in the airflow (P2's (B)): the far field bent into the
/// relative wind, the flame in the stream, the hand-over to P4's trail, all
/// moving continuously with the flight: sweeps through the angle of attack,
/// the airspeed through max-Q, and AS-506's pitch program.
final class PlumeAirflowTests: XCTestCase {
    static let system = try! SolarSystem.bundled()
    let us76 = USStandardAtmosphere1976()

    /// The S-IC's five F-1s firing along -z at `altitude`, into a relative
    /// wind of `speed` m/s at `alpha` rad off their axis (towards +x),
    /// clustered.
    func five(altitude: Double, speed: Double, alpha: Double) -> PlumeCluster {
        let spec = ApolloExhaust.f1.spec
        let air = us76.state(altitude: altitude)
        let axis = Vec3(0, 0, -1)
        let wind = (axis * cos(alpha) + Vec3(1, 0, 0) * sin(alpha)) * speed
        let state = PlumeModel.state(spec, flowFraction: 1, ambient: air, streamAlong: speed * cos(alpha),
                                     streamAcross: speed * abs(sin(alpha)))
        var exits = [Vec3.zero]
        for i in 0..<4 {
            let a = 2 * Double.pi * (Double(i) + 0.5) / 4
            exits.append(Vec3(4.9 * cos(a), 4.9 * sin(a), 0))
        }
        let members = exits.map { e -> PlumeMember in
            var m = PlumeLook.member(spec, state: state, exit: e, axis: axis, exitRadius: spec.exitRadius, ambient: air)
            m.relativeWind = wind
            return m
        }
        return PlumeClusters.cluster(members)
    }

    /// The centre member's centreline at `fraction` of its length.
    func centre(_ c: PlumeCluster, _ fraction: Double) -> Vec3 {
        let m = c.members[0]
        return m.centre(atX: fraction * m.length)
    }

    // At max-Q (13 km, 480 m/s) the far field turns towards the stream: at
    // 5° off the axis, its end lies towards the stream's side, by less than
    // the stream's angle; none at 0°. Through -10° to 10° every quarter
    // degree the centreline's far end, the plume's length and its flame
    // move by about the same each step (no jump).
    func testAngleOfAttackSweep() throws {
        let deg = Double.pi / 180
        let at5 = five(altitude: 13_000, speed: 480, alpha: 5 * deg)
        let end = centre(at5, 1)
        XCTAssertGreaterThan(end.x, 0, "towards the stream")
        XCTAssertLessThan(atan2(end.x, -end.z), 5 * deg, "never past it")
        XCTAssertEqual(centre(five(altitude: 13_000, speed: 480, alpha: 0), 1).x, 0, accuracy: 1e-6)
        var ends: [Double] = [], lengths: [Double] = []
        for a in stride(from: -10.0, through: 10, by: 0.25) {
            let c = five(altitude: 13_000, speed: 480, alpha: a * deg)
            ends.append(centre(c, 0.9).x)
            lengths.append(c.members[0].length)
        }
        let steps = zip(ends.dropFirst(), ends).map { $0 - $1 }
        for (k, (a, b)) in zip(steps.dropFirst(), steps).enumerated() {
            XCTAssertEqual(a, b, accuracy: 0.25 * max(abs(a), abs(b)) + 0.05, "step \(k): \(b) then \(a) m")
        }
        for (k, (a, b)) in zip(lengths.dropFirst(), lengths).enumerated() {
            XCTAssertEqual(a / b, 1, accuracy: 0.02, "length at step \(k)")
        }
        print(String(format: "PlumeAirflowTests: at 5° and 480 m/s the far end lies %.1f m to the stream's side of %.0f m",
                     end.x, -end.z))
    }

    // From the pad to beyond max-Q (0 to 600 m/s at 13 km's air, 3° off the
    // axis), every 5 m/s: the far end, the length and the flame move under
    // 3 % of themselves a step, and the flame lengthens throughout.
    func testAirspeedSweep() {
        let deg = Double.pi / 180
        var last: PlumeCluster?
        for u in stride(from: 0.0, through: 600, by: 5) {
            let c = five(altitude: 13_000, speed: u, alpha: 3 * deg)
            if let l = last {
                let a = centre(c, 0.9), b = centre(l, 0.9)
                XCTAssertLessThan((a - b).length, 0.03 * b.length + 0.5, "end at \(u) m/s")
                XCTAssertEqual(c.members[0].length / l.members[0].length, 1, accuracy: 0.03, "length at \(u) m/s")
                XCTAssertGreaterThanOrEqual(c.members[0].flameLength, l.members[0].flameLength - 1e-6, "flame at \(u)")
                XCTAssertEqual(c.members[0].flameLength / l.members[0].flameLength, 1, accuracy: 0.03, "flame at \(u)")
            }
            last = c
        }
    }

    // AS-506's ascent, every half second from T+5 s (the pitch program,
    // max-Q, the winds aloft, the afterburning's fade) until CECO's
    // tail-off moves the S-IC's flow itself: the S-IC's plume, as the scene
    // gives it, bends, lengthens and is handed over to the trail
    // continuously. Each step moves its far end (90 % of its length), its
    // length and the trail's hand-over by under 5 % of themselves; through
    // the afterburning's end (T+120 to 128 s, 37 km, where P1's luminous
    // length fades by the cooling flame's luminance: M1) by under 25 %, a
    // shrink of under 1 % a frame over about 2 s.
    func testThroughThePitchProgram() throws {
        let scenario = try XCTUnwrap(Scenario.named("as506-pad"))
        let sim = scenario.build(Self.system)
        sim.paused = false
        sim.stepBudget = nil
        var camera = OrbitCamera()
        camera.target = .vessel(try XCTUnwrap(sim.focus).id)
        camera.distance = 200
        let extractor = SceneExtractor()
        sim.advance(by: 5)
        var last: (end: Vec3, length: Double, handover: Double?)?
        var worst = (end: 0.0, length: 0.0, handover: 0.0), worstFade = 0.0
        var largest = 0.0
        for k in 0..<270 {
            sim.advance(by: 0.5)
            let t = 5.5 + 0.5 * Double(k)
            camera.update(sim: sim)
            let scene = extractor.extract(sim: sim, camera: camera, viewport: RenderScene.Viewport(width: 64, height: 40),
                                          realTime: 0)
            let f1 = scene.emitters.filter { $0.name.hasPrefix("S-IC engine") }
            guard f1.count == 5, f1.allSatisfy({ $0.flowFraction > 0.99 }) else { break }
            let members = f1.compactMap { PlumeLook.member($0, settings: PlumeSettings()) }
            let c = PlumeClusters.cluster(members)
            let m = c.members[0]
            let end = m.centre(atX: 0.9 * m.length) - m.exit
            largest = max(largest, m.bend.largest)
            let handover = PlumeAirflow.trailHandover(f1)?.x
            if let l = last {
                let steps = [(end - l.end).length / max(l.end.length, 1), abs(m.length / l.length - 1),
                             handover.flatMap { h in l.handover.map { abs(h / $0 - 1) } } ?? 0]
                if (120...128).contains(t) {
                    worstFade = max(worstFade, steps.max() ?? 0)
                } else {
                    worst = (max(worst.end, steps[0]), max(worst.length, steps[1]), max(worst.handover, steps[2]))
                }
            }
            last = (end, m.length, handover)
        }
        print(String(format: "PlumeAirflowTests: through the ascent, the largest step per half second: far end %.1f %%, "
                     + "length %.1f %%, hand-over %.1f %%; through the afterburning's end %.1f %%; the largest bend %.1f m",
                     100 * worst.end, 100 * worst.length, 100 * worst.handover, 100 * worstFade, largest))
        XCTAssertLessThan(worst.end, 0.05)
        XCTAssertLessThan(worst.length, 0.05)
        XCTAssertLessThan(worst.handover, 0.05)
        XCTAssertLessThan(worstFade, 0.25)
        XCTAssertGreaterThan(largest, 0, "the plume bends at some point of the ascent")
    }

    // The film's dark band (the F-1's turbine exhaust) shortens with the
    // afterburning as it fades, rather than jumping from the flame front's
    // 0.75 De to 3 De where it ends (287.14 Pa): every 0.2 % of pressure
    // about it, under 3 % of its length.
    func testFilmBandContinuousAsTheAfterburningEnds() {
        let spec = ApolloExhaust.f1.spec
        var last: Double?
        for i in -20...20 {
            let p = 287.14 * pow(1.002, Double(i))
            let air = RenderScene.Emitter.air(pressureRatio: p / 101_325)
            let s = PlumeModel.state(spec, flowFraction: 1, ambient: air)
            let m = PlumeLook.member(spec, state: s, exit: .zero, axis: Vec3(1, 0, 0), exitRadius: spec.exitRadius,
                                     ambient: air)
            if let last { XCTAssertEqual(m.sheathLength / last, 1, accuracy: 0.03, "\(p) Pa") }
            last = m.sheathLength
        }
    }
}
