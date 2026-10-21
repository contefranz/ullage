import XCTest
@testable import OrbitCore

/// The plume model against its references: Schmucker's criterion, the
/// F-1's exit pressure matching the air on AS-506's sounding, the F-1's and
/// J-2's published exit states, Lewis and Carlson's Mach disk against
/// Ashkenas and Sherman's, the shock cells, Simons' mass flux, afterburning
/// and the transients.
final class PlumeModelTests: XCTestCase {
    let deg = Double.pi / 180
    let psi = 6_894.757293168
    let day = AS506.launchDayAtmosphere()

    // At the pad the F-1 is overexpanded (n about 0.41) but attached:
    // Schmucker's limit is about 0.32. The J-2, a vacuum engine, would
    // separate at sea level.
    func testF1AttachedAtSeaLevelBySchmucker() {
        let air = day.state(altitude: 0)
        let f1 = PlumeModel.state(ApolloExhaust.f1.spec, flowFraction: 1, ambient: air)
        XCTAssertEqual(f1.regime, .overexpanded)
        XCTAssertEqual(f1.pressureRatio, 0.41, accuracy: 0.02)
        XCTAssertEqual(f1.separationLimit, 0.317, accuracy: 0.005)
        XCTAssertGreaterThan(f1.pressureRatio, f1.separationLimit)
        let j2 = PlumeModel.state(ApolloExhaust.j2.spec, flowFraction: 1, ambient: air)
        XCTAssertEqual(j2.regime, .separated)
        XCTAssertEqual(j2.pressureRatio, 0.15, accuracy: 0.005)
        XCTAssertEqual(j2.separationLimit, 0.293, accuracy: 0.0005)
        // A start or a shutdown at the pad passes through separation.
        let low = PlumeModel.state(ApolloExhaust.f1.spec, flowFraction: 0.6, ambient: air)
        XCTAssertEqual(low.regime, .separated)
    }

    // The datasheet's sea-level numbers (docs/exhaust-datasheet.md §3.1)
    // are the model's, to the digits it prints: the F-1's n and Schmucker
    // limit at the pad, the J-2's n against its limit.
    func testDatasheetSeaLevelNumbersAreTheModels() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/exhaust-datasheet.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("docs/exhaust-datasheet.md not found")
        }
        /// The number printed after `markers`, each found after the one
        /// before it, up to `end`; and half its last digit.
        func printed(after markers: [String], before end: String) throws -> (value: Double, half: Double) {
            var start = text.startIndex
            for m in markers {
                start = try XCTUnwrap(text.range(of: m, range: start..<text.endIndex), m).upperBound
            }
            let stop = try XCTUnwrap(text.range(of: end, range: start..<text.endIndex), end).lowerBound
            let digits = String(text[start..<stop])
            let decimals = digits.split(separator: ".").dropFirst().first?.count ?? 0
            return (try XCTUnwrap(Double(digits), digits), 0.5 * pow(10, -Double(decimals)) + 1e-12)
        }
        let air = day.state(altitude: 0)
        let f1 = PlumeModel.state(ApolloExhaust.f1.spec, flowFraction: 1, ambient: air)
        let j2 = PlumeModel.state(ApolloExhaust.j2.spec, flowFraction: 1, ambient: air)
        let pad = "| pad | 101.6 kPa | ", j2Sentence = "At sea level the J-2 would separate (n = "
        let checks: [([String], String, Double)] = [
            ([pad], " |", f1.pressureRatio),
            ([pad, "Schmucker's limit "], ")", f1.separationLimit),
            ([j2Sentence], " against", j2.pressureRatio),
            ([j2Sentence, " against "], ")", j2.separationLimit),
        ]
        for (markers, end, model) in checks {
            let p = try printed(after: markers, before: end)
            XCTAssertEqual(p.value, model, accuracy: p.half, markers.joined(separator: "..."))
        }
    }

    // The F-1's exit pressure equals the air's between 5 and 8 km on the
    // launch day's sounding, at its rated flow.
    func testF1PressureMatchedBetween5And8km() {
        func ratio(_ h: Double) -> Double {
            PlumeModel.state(ApolloExhaust.f1.spec, flowFraction: 1, ambient: day.state(altitude: h)).pressureRatio
        }
        var lo = 0.0, hi = 20_000.0
        for _ in 0..<60 {
            let mid = 0.5 * (lo + hi)
            if ratio(mid) < 1 { lo = mid } else { hi = mid }
        }
        XCTAssertGreaterThan(lo, 5_000)
        XCTAssertLessThan(lo, 8_000)
    }

    // The exit states against published values and CEA: the F-1's 5.8 psia
    // at 16:1 (the 1993 F-1 combustion review's table, M) within 5 %; each
    // engine's vacuum thrust coefficient, (ṁ ue + pe Ae)/(pc At), against
    // its rated thrust, chamber pressure and throat (F-1: Betts' 1,748,200
    // lbf at 982 psia on R-3896-1's 961.4 in² throat, the drawn nozzle's,
    // 4.4 % above the model; J-2: 230,000 lbf at 763 psia on SP-8120's 14.7
    // in throat) within 5 %, the turbine film's thrust and the nozzles'
    // losses between; and the one-gamma exit Mach number within 2 % of
    // CEA's frozen one (tools/data/cea_apollo_exhaust.csv).
    func testF1AndJ2ExitStates() throws {
        let rows = try toolsData("cea_apollo_exhaust.csv")
        func row(_ name: String) -> [String: String] { rows.first { $0["row"] == name }! }
        let f1Throat: Double = ApolloShapeData.f1ThroatArea * AS506.inch * AS506.inch
        let cases: [(name: String, engine: ApolloExhaust.Engine, thrust: Double, pc: Double, throat: Double)] = [
            ("F-1", ApolloExhaust.f1, 1_748_200, 982, f1Throat),
            ("J-2", ApolloExhaust.j2, 230_000, 763, Double.pi / 4 * pow(14.7 * AS506.inch, 2)),
        ]
        for c in cases {
            let s = PlumeModel.state(c.engine.spec, flowFraction: 1, ambient: .vacuum)
            let exitArea = Double.pi * pow(c.engine.spec.exitRadius, 2)
            let cf = (s.massFlow * s.exitVelocity + s.exitPressure * exitArea) / (s.chamberPressure * exitArea
                                                                                    / c.engine.spec.areaRatio)
            let published = c.thrust * AS506.poundForce / (c.pc * psi * c.throat)
            XCTAssertEqual(cf / published, 1, accuracy: 0.05, c.name)
            XCTAssertEqual(s.exitMach / row(c.name).number("mach_exit")!, 1, accuracy: 0.02, c.name)
            XCTAssertEqual(s.exitPressure / row(c.name).number("pe_pa")!, 1, accuracy: 1e-3, c.name)
        }
        let f1 = PlumeModel.state(ApolloExhaust.f1.spec, flowFraction: 1, ambient: .vacuum)
        XCTAssertEqual(f1.exitPressure / (5.8 * psi), 1, accuracy: 0.05)
        XCTAssertEqual(f1.exitMach, 3.7, accuracy: 0.05)
    }

    // At 30 km the F-1's boundary leaves at about 40-45° and its Mach disk
    // stands about 60 m downstream (Lewis and Carlson); Ashkenas and
    // Sherman's sonic estimate for the same chamber and throat lies within
    // 30 % of it. By the S-IC's cutoff (67 km) the boundary nears its
    // vacuum limit and the plume balloons.
    func testF1BoundaryAndMachDiskAloft() throws {
        let s = PlumeModel.state(ApolloExhaust.f1.spec, flowFraction: 1, ambient: day.state(altitude: 30_000))
        XCTAssertEqual(s.regime, .underexpanded)
        XCTAssertEqual(s.boundaryAngle / deg, 42, accuracy: 4)
        let disk = try XCTUnwrap(s.machDisk)
        XCTAssertEqual(disk.distance, 60, accuracy: 8)
        XCTAssertEqual(disk.sonicEstimate / disk.distance, 1, accuracy: 0.3)
        let cutoff = PlumeModel.state(ApolloExhaust.f1.spec, flowFraction: 1, ambient: day.state(altitude: 67_000))
        XCTAssertGreaterThan(cutoff.boundaryAngle, 65 * deg)
        XCTAssertLessThan(cutoff.boundaryAngle, cutoff.limitingAngle)
        XCTAssertGreaterThan(cutoff.boundaryAngle, s.boundaryAngle)
    }

    // In the sonic limit (Me = 1) Lewis and Carlson's 0.69 De Me √(γ n)
    // reduces to 0.69 √(γ (2/(γ+1))^(γ/(γ-1))) D* √(p0/pa): 0.593 D* √(p0/pa)
    // at γ = 1.4, 11.5 % under Ashkenas and Sherman's 0.67, at every
    // pressure ratio. The boundary angle is the Prandtl-Meyer turn from Me
    // to the ambient pressure.
    func testMachDiskSonicLimitAndBoundaryAngle() {
        let g = 1.4, star = pow(2 / (g + 1), g / (g - 1))
        for ratio in [10.0, 100, 1_000, 10_000] {
            let lc = PlumeModel.machDiskDistance(exitDiameter: 1, exitMach: 1, gamma: g, pressureRatio: star * ratio)
            let ash = PlumeModel.ashkenasSherman(throatDiameter: 1, pressureRatio: ratio)
            XCTAssertEqual(lc / ash, 0.885, accuracy: 0.002)
            XCTAssertEqual(lc / ratio.squareRoot(), 0.593, accuracy: 0.001)
        }
        // A γ = 1.4 jet at Me = 2 expanding to Mj = 3 turns by ν(3) - ν(2),
        // 49.76° - 26.38° (NACA 1135), plus the lip.
        let spec = ExhaustSpec(family: .coldGas, chamberPressure: 1e6, areaRatio: 1.6875, exitRadius: 0.1,
                               lipHalfAngle: 5 * deg, exitGamma: 1.4, molarMass: 0.029, chamberTemperature: 300,
                               exitTemperature: 300 / 1.8, source: "test", grade: "L")
        let air = AtmosphereState(temperature: 250, pressure: 1e6 * 0.02722, density: 0.38, speedOfSound: 317)
        let s = PlumeModel.state(spec, flowFraction: 1, ambient: air)
        XCTAssertEqual(s.exitMach, 2, accuracy: 1e-4)
        XCTAssertEqual(s.jetMach, 3, accuracy: 1e-3)
        XCTAssertEqual(s.boundaryAngle / deg, 49.76 - 26.38 + 5, accuracy: 0.02)
        XCTAssertEqual(s.limitingAngle / deg, 130.45 - 26.38 + 5, accuracy: 0.02)
    }

    // A perfectly expanded jet (n = 1) keeps the exit's diameter and Mach
    // number, and its shock cells are Pack's 1.306 Dj √(Mj² - 1) long; a
    // moderately underexpanded one's cells are longer and its jet wider.
    func testShockCells() {
        let spec = ExhaustSpec(family: .coldGas, chamberPressure: 1e6, areaRatio: 1.6875, exitRadius: 0.1,
                               lipHalfAngle: 0, exitGamma: 1.4, molarMass: 0.029, chamberTemperature: 300,
                               exitTemperature: 300 / 1.8, source: "test", grade: "L")
        let pe = 1e6 * NozzleFlow.pressureRatio(mach: 2, gamma: 1.4)
        let matched = PlumeModel.state(spec, flowFraction: 1,
                                       ambient: AtmosphereState(temperature: 200, pressure: pe, density: 2.2,
                                                                speedOfSound: 283))
        XCTAssertEqual(matched.pressureRatio, 1, accuracy: 1e-9)
        XCTAssertEqual(matched.jetDiameter, 0.2, accuracy: 1e-6)
        XCTAssertEqual(matched.shockCellLength, 1.306 * 0.2 * 3.squareRoot(), accuracy: 1e-5)
        XCTAssertNil(matched.machDisk)
        let under = PlumeModel.state(spec, flowFraction: 1,
                                     ambient: AtmosphereState(temperature: 200, pressure: pe / 3, density: 0.73,
                                                              speedOfSound: 283))
        XCTAssertGreaterThan(under.jetDiameter, matched.jetDiameter)
        XCTAssertGreaterThan(under.shockCellLength, matched.shockCellLength)
        XCTAssertNotNil(under.machDisk)
        XCTAssertGreaterThan(under.shockCellCount, 0)
    }

    // Simons' far field carries the exit's mass flow: through a sphere far
    // downstream, ∫ ρ u_lim dA equals ṁ within 1 %, for limiting angles
    // below and at 180°.
    func testSimonsMassFlux() {
        for engine in [ApolloExhaust.f1, ApolloExhaust.j2, ApolloExhaust.sps, ApolloExhaust.smRCS,
                       ApolloExhaust.sICRetro] {
            let s = PlumeModel.state(engine.spec, flowFraction: 1, ambient: .vacuum)
            let r = 100 * s.throatRadius, n = 20_000, h = s.limitingAngle / Double(n)
            var flux = 0.0
            for i in 0..<n {
                let theta = (Double(i) + 0.5) * h
                flux += s.density(atDistance: r, angle: theta) * s.limitingVelocity * 2 * Double.pi * r * r
                    * sin(theta) * h
            }
            XCTAssertEqual(flux / s.massFlow, 1, accuracy: 0.01, engine.spec.source)
            XCTAssertEqual(s.density(atDistance: r, angle: s.limitingAngle + 0.01), 0)
            XCTAssertEqual(s.regime, .freeMolecular)
            XCTAssertNil(s.machDisk)
        }
    }

    // The F-1's afterburning holds to 28 km, greys out to 40 km and is gone
    // above, as AS-501 to 503's films showed; in air the turbine film's
    // flame front stands three-fourths of an exit diameter downstream.
    func testAfterburningFadesWithAltitude() {
        let us = USStandardAtmosphere1976(), spec = ApolloExhaust.f1.spec
        var last = 1.0
        for km in stride(from: 0.0, through: 50, by: 2) {
            let s = PlumeModel.state(spec, flowFraction: 1, ambient: us.state(altitude: km * 1_000))
            let a = s.afterburning / spec.fuelRichFraction
            if km <= 28 { XCTAssertEqual(a, 1, accuracy: 1e-3, "\(km) km") }
            if km >= 40 { XCTAssertEqual(a, 0, accuracy: 1e-4, "\(km) km") }
            XCTAssertLessThanOrEqual(a, last + 1e-12)
            last = a
        }
        let pad = PlumeModel.state(spec, flowFraction: 1, ambient: day.state(altitude: 0))
        XCTAssertEqual(pad.flameFrontDistance ?? 0, 0.75 * 2 * spec.exitRadius, accuracy: 1e-9)
        XCTAssertNil(PlumeModel.state(ApolloExhaust.j2.spec, flowFraction: 1,
                                      ambient: day.state(altitude: 0)).flameFrontDistance)
        XCTAssertGreaterThan(pad.luminousLength, pad.potentialCoreLength)
    }

    // The regimes along the flight: the J-2 at S-II ignition (67 km) is a
    // continuum jet whose Mach disk, about 300 m downstream, is too faint to
    // see; at S-IVB ignition (185 km) and the SPS in orbit the flow is free
    // molecular, with no shock structure; the SPS's cool exhaust does not
    // glow. A thruster with no flow has no plume.
    func testRegimesAlongTheFlight() throws {
        let us = USStandardAtmosphere1976()
        let ignition = PlumeModel.state(ApolloExhaust.j2.spec, flowFraction: 1, ambient: us.state(altitude: 67_000))
        XCTAssertEqual(ignition.regime, .underexpanded)
        let disk = try XCTUnwrap(ignition.machDisk)
        XCTAssertEqual(disk.distance, 300, accuracy: 60)
        XCTAssertLessThan(disk.luminosity, 0.02)
        for (engine, h) in [(ApolloExhaust.j2, 185_000.0), (ApolloExhaust.sps, 185_000)] {
            let s = PlumeModel.state(engine.spec, flowFraction: 1, ambient: us.state(altitude: h))
            XCTAssertEqual(s.regime, .freeMolecular)
            XCTAssertEqual(s.structureVisibility, 0)
            XCTAssertNil(s.machDisk)
            XCTAssertEqual(s.shockCellLength, 0)
        }
        XCTAssertEqual(PlumeModel.state(ApolloExhaust.sps.spec, flowFraction: 1, ambient: .vacuum).luminousLength, 0)
        let off = PlumeModel.state(ApolloExhaust.f1.spec, flowFraction: 0, ambient: day.state(altitude: 0))
        XCTAssertEqual(off.regime, .off)
        XCTAssertEqual(off.massFlow, 0)
        XCTAssertNil(off.machDisk)
    }

    // The chamber pressure follows the flow, so the F-1's shutdown ramp
    // shrinks its plume: aloft, the pressure ratio, the boundary angle and
    // the Mach disk's distance all fall as the ramp runs. At first motion
    // AS-506's F-1s ran about 1 % above the rated 5,737 lb/s.
    func testShutdownShrinksThePlume() throws {
        let stack = VesselLibrary.saturnV()
        let sIC = try XCTUnwrap(stack.parts.first { $0.name == "S-IC" })
        let engine = try XCTUnwrap(sIC.thrusters.first { $0.name == "S-IC engine 1" })
        let air = day.state(altitude: 60_000)
        engine.level = 1
        engine.advanceTransients(dt: 0.02)
        let full = try XCTUnwrap(PlumeModel.state(of: engine, in: sIC, ambient: air))
        XCTAssertEqual(full.flowFraction, 1.012, accuracy: 0.005)
        engine.isEnabled = false
        var last = full
        for _ in 0..<25 {
            let s = try XCTUnwrap(PlumeModel.state(of: engine, in: sIC, ambient: air))
            XCTAssertLessThan(s.chamberPressure, last.chamberPressure)
            XCTAssertLessThan(s.boundaryAngle, last.boundaryAngle)
            XCTAssertLessThan(try XCTUnwrap(s.machDisk).distance, try XCTUnwrap(last.machDisk).distance)
            last = s
            engine.advanceTransients(dt: 0.02)
        }
        XCTAssertLessThan(last.flowFraction, 0.4)
    }
}
