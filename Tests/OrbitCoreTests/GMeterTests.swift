import XCTest
@testable import OrbitCore

/// The HUD's G-meter (`GMeter`) and LV engine lights (`LVEngineLights`):
/// 1 g on the pad, AS-506's sensed acceleration through the ascent (its
/// postflight trajectory), about 0 in orbit, an Apollo entry's peak, and the
/// lights through staging and Apollo 13's engine out; on a wreck, a blank
/// meter and dark lights.
final class GMeterTests: XCTestCase {
    let g0 = standardGravity

    // MARK: The meter

    // The reading and the dial: the axial component and the magnitude, in
    // standard g; the dial as the CM's (AOH Fig. 3-1, SA-506 Flight Manual
    // Fig. 3-1): -1 to +15 g, 15° per g, 0 g at 9 o'clock, 6 g at 12, 12 g at
    // 3, 15 g at half past 4, the pointer held at the stops.
    func testReadingAndDial() {
        let m = GMeter(sensedAcceleration: Vec3(3 * g0, 4 * g0, 0))
        XCTAssertEqual(m.axial, 3, accuracy: 1e-12)
        XCTAssertEqual(m.total, 5, accuracy: 1e-12)
        XCTAssertEqual(GMeter().axial, 0)
        XCTAssertEqual(GMeter(vessel: VesselLibrary.capsule())?.total, 0)
        let deg = Double.pi / 180
        for (g, clock) in [(0.0, 180.0), (6, 90), (12, 0), (15, -45), (-1, 195), (3.94, 120.9)] {
            XCTAssertEqual(GMeter.dialAngle(g) / deg, clock, accuracy: 1e-9, "\(g) g")
        }
        XCTAssertEqual(GMeter(sensedAcceleration: Vec3(20 * g0, 0, 0)).pointer, 15)
        XCTAssertEqual(GMeter(sensedAcceleration: Vec3(-3 * g0, 0, 0)).pointer, -1)
        XCTAssertEqual(GMeter.dialAngle(20), GMeter.dialAngle(15))
        XCTAssertEqual(GMeter.dialAngle(-3), GMeter.dialAngle(-1))
    }

    // On the pad, held, the meter reads the support against gravity in the
    // rotating frame: WGS-84 normal gravity at LC-39A (Somigliana's formula,
    // NIMA TR8350.2 eq. 4-1, 9.7922 m/s^2 at 28.608° N, 0.9985 g), along the
    // vehicle's axis, with or without its engines (the arms hold it), and
    // the lights all lit before ignition.
    func testPadReadsOneG() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let stack = VesselLibrary.apollo11OnPad(in: sim)
        sim.updateTelemetry(stack, snapshot: sim.snapshot)
        let phi = 28.608422 * Double.pi / 180, s2 = sin(phi) * sin(phi)
        let normal = 9.7803253359 * (1 + 0.00193185265241 * s2) / (1 - 0.00669437999013 * s2).squareRoot()
        var m = try XCTUnwrap(GMeter(vessel: stack))
        XCTAssertEqual(m.axial, normal / g0, accuracy: 0.001)
        XCTAssertEqual(m.total, normal / g0, accuracy: 0.001)
        XCTAssertEqual(m.axial, 1, accuracy: 0.002)
        let lights = try XCTUnwrap(LVEngineLights(vessel: stack))
        XCTAssertEqual(lights.stage, .sIC)
        XCTAssertEqual(lights.lit, [true, true, true, true, true])

        // Held on the pad for 3 s more: still 1 g.
        for _ in 0..<150 {
            for v in sim.vessels { sim.prepareControls(v) }
            sim.step(0.02)
        }
        XCTAssertNotNil(stack.landed)
        m = try XCTUnwrap(GMeter(vessel: stack))
        XCTAssertEqual(m.axial, normal / g0, accuracy: 0.001)
    }

    // MARK: The ascent

    /// AS-506's sensed acceleration at range time `t` from the postflight
    /// trajectory (PFT Table B-II, H): its total inertial acceleration less
    /// the PFT's own J2 gravity at its position, in g.
    func asFlown(_ t: Double) throws -> Double {
        let row = try XCTUnwrap(AS506Postflight.row(at: t), "no PFT row at \(t) s")
        return (row.acceleration - AS506Postflight.gravity(at: row.position)).length / g0
    }

    /// The nominal flight's meter at range time `t` (its sample at or before
    /// it).
    func meter(_ t: Double) throws -> GMeter {
        let s = try XCTUnwrap(NominalFlight.shared.sample(at: t).vessels["Apollo 11"])
        return GMeter(sensedAcceleration: s.sensedAcceleration)
    }

    // Through the ascent, against AS-506 as flown (PFT Table B-II less its
    // gravity; Table 4-1's stage maxima are its 135.2, 161.63, 460.62 and
    // 699.33 s rows): the rise through the S-IC burn to 3.66 g before the
    // centre engine's cutoff, the drop to 2.97 g after it, 3.91 g before
    // OECO; the S-II's rise to 1.82 g before its centre engine's cutoff, the
    // drop to 1.47 g, the mixture-ratio shift from 1.65 to 1.33 g; the S-IVB
    // from 0.56 to 0.69 g; and the coasts between them under 0.1 g.
    //
    // Within 1.5 % (and 0.01 g), the model's thrust and masses being the
    // FER's (datasheet §9.4, §17) and the PFT's accelerations 0.01 m/s^2 in
    // a row. Samples stay 1-2 s clear of the events, whose times differ by
    // up to 0.5 s; not at 166-172 s, where the model's early S-II runs 3-6 %
    // above the PFT (datasheet §9.5 item 2), nor in the low-EMR phase's
    // first 10 s, where the PFT's acceleration itself is 1-4.5 % off its
    // neighbours' trend (§17, E2).
    //
    // Along the axis the meter reads within 0.5 % of the total: the thrust
    // runs along the axis, the gimbals within a degree or two of it.
    func testAscentFollowsAS506() throws {
        let points: [(t: Double, what: String)] = [
            (10, "S-IC early"), (60, "S-IC, Mach 1"), (100, "S-IC"), (134, "S-IC"),
            (135, "S-IC before CECO"), (137, "S-IC after CECO"), (150, "S-IC four engines"),
            (161, "S-IC before OECO"), (180, "S-II"), (300, "S-II"), (400, "S-II"), (458, "S-II"),
            (460, "S-II before CECO"), (464, "S-II after CECO"), (490, "S-II four engines"),
            (496, "S-II before the EMR shift"), (510, "S-II low EMR"), (530, "S-II low EMR"),
            (546, "S-II before OECO"), (560, "S-IVB"), (600, "S-IVB"), (650, "S-IVB"), (698, "S-IVB before cutoff"),
        ]
        for p in points {
            let m = try meter(p.t), flown = try asFlown(p.t)
            print(String(format: "G-meter %6.1f s %-26@ model %.3f g (axial %.3f), AS-506 %.3f g, %+.2f %%",
                         p.t, p.what as NSString, m.total, m.axial, flown, (m.total / flown - 1) * 100))
            XCTAssertEqual(m.total, flown, accuracy: max(0.01, 0.015 * flown), "\(p.what) at \(p.t) s")
            XCTAssertEqual(m.axial, m.total, accuracy: 0.005 * m.total, "\(p.what) at \(p.t) s: along the axis")
        }
        // The coasts: S-IC/S-II separation to S-II mainstage, and S-II/S-IVB
        // separation to S-IVB ignition (AS-506: 0.05 g at 164 s on the S-II's
        // ullage motors, 0.03 g at 552 s on the S-IVB's).
        for t in [164.0, 552.0] {
            let m = try meter(t)
            print(String(format: "G-meter %6.1f s coast: model %.3f g, AS-506 %.3f g", t, m.total, try asFlown(t)))
            XCTAssertLessThan(m.total, 0.1, "coast at \(t) s")
        }
    }

    // The highest reading of the ascent, over every sample (every step
    // around the S-IC's cutoff), is the S-IC's at OECO, 3.94 g (FER Table
    // 4-1: 38.61 m/s^2, the PFT's 161.63 s row); the lowest is just after
    // it, near zero (drag, before the S-II's ullage motors). From the pad to
    // 10 s after the S-IVB's cutoff; then in the parking orbit the meter
    // reads 0 (under 1e-4 g: drag at 185 km).
    func testAscentExtremesAndOrbit() throws {
        let n = NominalFlight.shared
        let cutoff = try XCTUnwrap(n.time(of: "S-IVB velocity cutoff (IGM)"))
        var peak = -Double.infinity, low = Double.infinity
        for s in n.samples where s.range <= cutoff + 10 {
            let m = GMeter(sensedAcceleration: try XCTUnwrap(s.vessels["Apollo 11"]).sensedAcceleration)
            peak = max(peak, m.axial)
            low = min(low, m.axial)
        }
        print(String(format: "G-meter ascent extremes: %.3f g, %.3f g", peak, low))
        XCTAssertEqual(peak, 38.61 / g0, accuracy: 0.015)
        XCTAssertEqual(peak, try asFlown(161.63), accuracy: 0.015)
        XCTAssertLessThan(low, 0.01)
        XCTAssertGreaterThan(low, -0.1)

        let orbit = try meter(1_000)
        XCTAssertEqual(try XCTUnwrap(n.sample(at: 1_000).vessels["Apollo 11"]).status, .flying)
        XCTAssertLessThan(abs(orbit.axial), 1e-4)
        XCTAssertLessThan(orbit.total, 1e-4)
    }

    // MARK: The entry

    // Apollo 7's CM from 68-FM-184 Table IX(b)'s entry interface on its
    // entry program at the 55° backup bank: the meter's highest reading is
    // the entry's peak, 3.3 ± 0.3 g (68-FM-184 §5.4.4, H), positive (the
    // heat shield's drag pushes the crew into their couches, along +X), and
    // within 2 % of the total (the trim tilts the resultant a few degrees
    // off the axis) and of the entry program's own peak; it never reads
    // below -0.05 g. Read every step, to the drogues.
    func testEntryPeak() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let v = VesselLibrary.commandModule(.apollo7)
        v.aerodynamics = [.apolloCommandModule(calibration: .operational)]
        sim.add(v)
        let ei = EntryTests.apollo7EntryInterface
        sim.place(v, geodeticLatitude: ei.latitude, longitude: ei.longitude, height: ei.height, inertialSpeed: ei.speed,
                  flightPathAngle: ei.flightPathAngle, azimuth: ei.azimuth)
        let program = CMEntryProgram(mode: .bankHold(-55 * Double.pi / 180))
        v.flightProgram = program
        v.attitude = try XCTUnwrap(CMEntryProgram.trimAttitude(of: v, capsule: try XCTUnwrap(v.activeAerodynamics?.capsule),
                                                               bank: -55 * Double.pi / 180, in: sim))
        sim.updateTelemetry(v, snapshot: sim.snapshot)
        var peak = 0.0, peakTotal = 0.0, low = 0.0
        let start = sim.time
        while program.els.droguesDeployed == nil, v.landed == nil, sim.time - start < 1_500 {
            for x in sim.vessels { sim.prepareControls(x) }
            sim.step(min(1, sim.maxStep()))
            let m = try XCTUnwrap(GMeter(vessel: v))
            peak = max(peak, m.axial)
            low = min(low, m.axial)
            peakTotal = max(peakTotal, m.total)
        }
        XCTAssertNotNil(program.els.droguesDeployed)
        print(String(format: "G-meter entry peak: %.3f g axial, %.3f g total, program %.3f g; low %.3f g",
                     peak, peakTotal, program.peakLoadFactor, low))
        XCTAssertEqual(peak, 3.3, accuracy: 0.3)
        XCTAssertEqual(peak, peakTotal, accuracy: 0.02 * peakTotal)
        XCTAssertEqual(peak, program.peakLoadFactor, accuracy: 0.02 * program.peakLoadFactor)
        XCTAssertGreaterThan(low, -0.05)
    }

    // MARK: A wreck

    // A Saturn flown into the ground under full S-IC thrust: the
    // simulation no longer steps a wreck, so its telemetry and its engines'
    // last outputs would hold the moment before the impact, the meter
    // frozen there and the lights out as if the F-1s still ran. The meter
    // blanks and the lights go dark instead, and stay so.
    func testWreckBlanksTheMeterAndTheLights() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let stack = VesselLibrary.saturnV()
        sim.add(stack)
        let clearance = min(stack.baseHeight, stack.boundingRadius)
        sim.place(stack, geodeticLatitude: 23, longitude: 13, height: clearance + 20, inertialSpeed: 30,
                  flightPathAngle: -90, azimuth: 0)
        // Falling at 30 m/s through still air, not the inertial frame.
        let o = sim.snapshot.orientation(stack.reference)
        let up = stack.reference.vertical(at: stack.position, orientation: o)
        stack.velocity = o.angularVelocity.cross(stack.position) - up * 30
        sim.updateTelemetry(stack, snapshot: sim.snapshot)
        stack.mainThrottle = 1
        var before: (meter: GMeter, lights: LVEngineLights)?
        let start = sim.time
        while stack.status == .flying, sim.time - start < 10 {
            before = (try XCTUnwrap(GMeter(vessel: stack)), try XCTUnwrap(LVEngineLights(vessel: stack)))
            for v in sim.vessels { sim.prepareControls(v) }
            sim.step(0.02)
        }
        XCTAssertEqual(stack.status, .crashed)
        let last = try XCTUnwrap(before)
        XCTAssertGreaterThan(last.meter.axial, 1)
        XCTAssertEqual(last.meter.total, last.meter.axial, accuracy: 0.05)
        XCTAssertEqual(last.lights.lit, [false, false, false, false, false])
        for _ in 0..<3 {
            XCTAssertNil(GMeter(vessel: stack))
            XCTAssertNil(LVEngineLights(vessel: stack))
            for v in sim.vessels { sim.prepareControls(v) }
            sim.step(0.02)
        }
    }

    // MARK: The engine lights

    /// The nominal flight's lights at range time `t` (its sample at or
    /// before it: up to 0.5 s before, outside its dense windows).
    func lights(_ t: Double) throws -> LVEngineLights? {
        try XCTUnwrap(NominalFlight.shared.sample(at: t).vessels["Apollo 11"]).engineLights
    }

    // Through AS-506's events (FER Table 2-2), as the SA-506 Flight Manual
    // gives the lights (pp. 3-1, 5-9, 5-13, 6-7, 6-10): out while the five
    // F-1s run; light 5 at the centre engine's cutoff (135.2 s); all five at
    // OECO (161.63 s), and through separation (162.3 s), now the S-II's,
    // until its J-2s come up after engine start (164.0 s); light 5 again at
    // the S-II's centre engine cutoff (460.62 s), and not at the
    // mixture-ratio shift, whose thrust stays well above the J-2's 65 %; all
    // five at its OECO (548.22 s); then the S-IVB on light 1 alone, the
    // other four out, lit from separation (549.0 s) until its J-2 comes up
    // (ignition 552.2 s) and again from its cutoff (699.33 s) into the
    // parking orbit (where the crew turned EDS power off, not modelled).
    func testLightsThroughTheAscent() throws {
        let none = [false, false, false, false, false], all = [true, true, true, true, true]
        let centre = [false, false, false, false, true], one = [true, false, false, false, false]
        let expected: [(t: Double, stage: LVEngineLights.Stage, lit: [Bool])] = [
            (1, .sIC, none), (60, .sIC, none), (135.0, .sIC, none), (136.0, .sIC, centre), (150, .sIC, centre),
            (161.5, .sIC, centre), (162.0, .sIC, all), (163.0, .sII, all), (164.5, .sII, all), (168, .sII, none),
            (300, .sII, none), (460, .sII, none), (461.5, .sII, centre), (510, .sII, centre), (547.5, .sII, centre),
            (548.6, .sII, all), (550, .sIVB, one), (556, .sIVB, none), (698, .sIVB, none), (700.5, .sIVB, one),
            (1_000, .sIVB, one),
        ]
        for e in expected {
            let l = try XCTUnwrap(try lights(e.t), "\(e.t) s")
            XCTAssertEqual(l.stage, e.stage, "\(e.t) s")
            XCTAssertEqual(l.lit, e.lit, "\(e.t) s")
        }
    }

    // When the lights change, on the nominal flight's every-step samples
    // around the two stagings, against AS-506's events (FER Table 2-2 and
    // §7.2): lights 1-4 within 0.1 s of OECO (161.63 s; an F-1 falls below
    // 90 % 0.07 s into its tail-off); all five S-II lights out together
    // between engine start (STDV open, 164.0 s) and mainstage (166.2 s), as
    // the J-2s pass 65 %; the S-IVB's light 1 out between its STDV open
    // (552.2 s) and mainstage (STDV + 2.5 s).
    func testLightsAtTheEngineTransitions() throws {
        let n = NominalFlight.shared
        func first(in range: ClosedRange<Double>, _ f: (LVEngineLights) -> Bool) -> Double? {
            n.samples(in: range).first { s in s.vessels["Apollo 11"]?.engineLights.map(f) ?? false }?.range
        }
        let oeco = try XCTUnwrap(first(in: 161...163) { $0.lit == [true, true, true, true, true] })
        XCTAssertEqual(oeco, AS506.sICOutboardCutoff, accuracy: 0.1)
        let sII = try XCTUnwrap(first(in: 163...170) { $0.stage == .sII && !$0.lit.contains(true) })
        XCTAssertGreaterThan(sII, AS506.sIIIgnition)
        XCTAssertLessThan(sII, 166.2)
        let partial = n.samples(in: 163...170).contains { s in
            guard let l = s.vessels["Apollo 11"]?.engineLights, l.stage == .sII else { return false }
            return l.lit.contains(true) && l.lit.contains(false)
        }
        XCTAssertFalse(partial, "the five J-2s come up together")
        let sIVB = try XCTUnwrap(first(in: 550...560) { $0.stage == .sIVB && !$0.lit[0] })
        XCTAssertGreaterThan(sIVB, AS506.sIVBIgnition)
        XCTAssertLessThan(sIVB, AS506.sIVBIgnition + 2.5)
        print(String(format: "LV ENGINES: S-IC OECO lit at %.2f s, S-II out at %.2f s, S-IVB out at %.2f s",
                     oeco, sII, sIVB))
    }

    // Apollo 13's S-II centre engine out (AS-508 FER Table 2-2: at T3 +
    // 167.0 s, 330.65 s, 132.36 s before its planned cutoff; Lovell called
    // "Inboard" at 000:05:32, Apollo 13 Flight Journal), on the AS-506
    // model: light 5 is lit within 1 s of the failure and stays lit, lights
    // 1-4 stay out, to the S-II's cutoff.
    func testApollo13CentreEngineLight() throws {
        let f = EngineOutFlight.apollo13
        let failure = f.range(try XCTUnwrap(f.iu.timeBases[.t3])) + 167.0
        let before = try XCTUnwrap(f.lights(at: failure - 0.5)), after = try XCTUnwrap(f.lights(at: failure + 1))
        XCTAssertEqual(before.stage, .sII)
        XCTAssertEqual(before.lit, [false, false, false, false, false])
        XCTAssertEqual(after.lit, [false, false, false, false, true])
        let oeco = f.range(try XCTUnwrap(f.iu.timeBases[.t4]))
        for t in stride(from: failure + 1, to: oeco - 0.5, by: 10) {
            XCTAssertEqual(try XCTUnwrap(f.lights(at: t)).lit, [false, false, false, false, true], "\(t) s")
        }
        // The spacecraft alone has none.
        XCTAssertNil(LVEngineLights(vessel: VesselLibrary.commandModule(.apollo7)))
    }
}
