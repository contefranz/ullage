import XCTest
import OrbitCore
@testable import OrbitScene

/// The plumes' fluctuations about their mean field (`JetFluctuations`):
/// Dowling and Dimotakis's measured r.m.s. as transcribed, the rectified
/// Gaussian that draws it and keeps the mean, its intermittent front against
/// Corrsin and Kistler's, nothing in the potential core or a ballooned
/// plume's interior, the mean column through the fluctuating field, the heat
/// on its excess, and the billowing boundary.
final class JetFluctuationsTests: XCTestCase {
    let us76 = USStandardAtmosphere1976()
    static let toolsData = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("tools/data")

    func member(_ engine: ApolloExhaust.Engine, altitude: Double, flow: Double = 1) -> PlumeMember {
        let a = us76.state(altitude: altitude)
        let s = PlumeModel.state(engine.spec, flowFraction: flow, ambient: a)
        return PlumeLook.member(engine.spec, state: s, exit: Vec3(0, 0, 0), axis: Vec3(1, 0, 0),
                                exitRadius: engine.spec.exitRadius, ambient: a)
    }

    /// Rows of a tools/data CSV (comment lines and the header skipped).
    func rows(_ file: String) throws -> [[Double?]] {
        let text = try String(contentsOf: Self.toolsData.appendingPathComponent(file), encoding: .utf8)
        return text.split(separator: "\n").filter { !$0.hasPrefix("#") }.dropFirst()
            .map { $0.split(separator: ",", omittingEmptySubsequences: false).map { Double($0) } }
    }

    /// The tables here are the transcriptions in tools/data.
    func testTablesAreToolsData() throws {
        let dd = try rows("dowling_dimotakis_1990_jet_concentration.csv")
        for (i, eta) in JetFluctuations.similarity.enumerated() {
            let row = try XCTUnwrap(dd.first { abs(($0[0] ?? -1) - eta) < 1e-9 }, "η \(eta)")
            XCTAssertEqual(row[1], JetFluctuations.meanProfile[i], "mean at η \(eta)")
            XCTAssertEqual(row[3], JetFluctuations.rmsProfile[i], "r.m.s. at η \(eta)")
        }
        // The fitted curves meet the centreline values printed in the text:
        // 0.230 ± 0.007 at Re0 5,000, 0.237 ± 0.005 at 16,000.
        XCTAssertEqual(try XCTUnwrap(dd[0][2]), 0.230, accuracy: 0.007)
        XCTAssertEqual(try XCTUnwrap(dd[0][3]), 0.237, accuracy: 0.005)
        XCTAssertEqual(JetFluctuations.relativeRMS(meanShare: 1), JetFluctuations.centrelineUnmixedness, accuracy: 1e-12)
        // The mean's half-value radius, η 0.11.
        let half = zip(JetFluctuations.similarity, JetFluctuations.meanProfile).first { $0.1 < 0.5 }
        XCTAssertEqual(try XCTUnwrap(half).0, 0.12)
        // Corrsin and Kistler's front at x/d = 60, from x0 = 3 d.
        let ck = try rows("corrsin_kistler_1955_round_jet_front.csv")
        let at60 = try XCTUnwrap(ck.first { $0[0] == 60 })
        let span = 60.0 - 3
        XCTAssertEqual(try XCTUnwrap(at60[1]) / 2 / span, JetFluctuations.frontPosition, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(at60[3]) / 2 / span, JetFluctuations.frontWidth, accuracy: 0.001)
        // Its half-velocity radius is the round jet's 0.094 (the far field's
        // spread, Hussein et al.).
        XCTAssertEqual(try XCTUnwrap(at60[2]) / 2 / span, PlumeLook.Optics.farSpread, accuracy: 0.002)
    }

    /// The rectified Gaussian's mean and r.m.s. against a numerical
    /// integral; the threshold's inverse; the factor's mean is 1 and its
    /// r.m.s. the measured one at every station of the table.
    func testRectifiedGaussian() {
        func integral(_ f: (Double) -> Double) -> Double {
            var s = 0.0
            let h = 0.001
            for i in -10_000..<10_000 {
                let z = (Double(i) + 0.5) * h
                s += f(z) * JetFluctuations.normalDensity(z) * h
            }
            return s
        }
        XCTAssertEqual(JetFluctuations.normalCDF(0), 0.5, accuracy: 1e-7)
        XCTAssertEqual(JetFluctuations.normalCDF(1.959964), 0.975, accuracy: 2e-7)
        for t in [-4.2, -2.0, -0.7, 0.0, 0.6, 1.5] {
            XCTAssertEqual(JetFluctuations.positivePart(threshold: t), integral { max($0 - t, 0) }, accuracy: 1e-6)
            let m1 = integral { max($0 - t, 0) }, m2 = integral { pow(max($0 - t, 0), 2) }
            let rms = (m2 / (m1 * m1) - 1).squareRoot()
            XCTAssertEqual(JetFluctuations.rectifiedRMS(threshold: t), rms, accuracy: 1e-5 * max(rms, 1))
            XCTAssertEqual(JetFluctuations.threshold(relativeRMS: JetFluctuations.rectifiedRMS(threshold: t)), t,
                           accuracy: 1e-6)
        }
        for (j, t) in JetFluctuations.thresholds.enumerated() {
            let g = Double(j) / 15
            let mean = integral { JetFluctuations.factor(noise: $0, threshold: t, strength: 1) }
            let rms = (integral { pow(JetFluctuations.factor(noise: $0, threshold: t, strength: 1) - 1, 2) }).squareRoot()
            XCTAssertEqual(mean, 1, accuracy: 1e-5, "mean share \(g)")
            XCTAssertEqual(rms, JetFluctuations.relativeRMS(meanShare: g), accuracy: 1e-4, "mean share \(g)")
            // Weighted, the mean still holds and the r.m.s. scales.
            XCTAssertEqual(integral { JetFluctuations.factor(noise: $0, threshold: t, strength: 0.4) }, 1, accuracy: 1e-5)
        }
        // On the axis the factor is linear: 1 + 0.237 n down to 4.2 σ.
        XCTAssertEqual(JetFluctuations.thresholds[15], -1 / 0.237, accuracy: 0.05)
        XCTAssertEqual(JetFluctuations.factor(noise: 1, threshold: JetFluctuations.thresholds[15], strength: 1), 1.237,
                       accuracy: 0.003)
    }

    /// The intermittent front the measured r.m.s. implies: the exhaust is
    /// always there within the jet (η ≤ 0.10), less towards its edge, half
    /// the time within half of Corrsin and Kistler's front width of their
    /// mean front.
    func testIntermittentFrontAgainstCorrsinAndKistler() {
        var last = 1.0, half: Double?
        var presences: [String] = []
        for i in 0..<JetFluctuations.similarity.count {
            let eta = JetFluctuations.similarity[i], g = JetFluctuations.meanProfile[i]
            let t = JetFluctuations.threshold(relativeRMS: JetFluctuations.relativeRMS(meanShare: g))
            let gamma = JetFluctuations.presence(threshold: t)
            presences.append(String(format: "%.2f:%.2f", eta, gamma))
            XCTAssertLessThanOrEqual(gamma, last + 1e-9, "η \(eta)")
            if eta <= 0.10 { XCTAssertGreaterThan(gamma, 0.97, "η \(eta)") }
            if half == nil && gamma < 0.5 && i > 0 {
                // Between the stations, linearly.
                let e0 = JetFluctuations.similarity[i - 1]
                half = e0 + (eta - e0) * (last - 0.5) / (last - gamma)
            }
            last = gamma
        }
        let front = try? XCTUnwrap(half)
        print("JetFluctuationsTests: presence by η", presences.joined(separator: " "),
              String(format: "; half the time at η %.3f (Corrsin and Kistler %.3f ± %.3f)", front ?? -1,
                     JetFluctuations.frontPosition, JetFluctuations.frontWidth))
        XCTAssertEqual(front ?? 0, JetFluctuations.frontPosition, accuracy: 0.5 * JetFluctuations.frontWidth)
    }

    /// How mixed the F-1's jet is: not at all in its potential core, fully
    /// past the self-similar distance and at the mixing layer's middle.
    func testMixedness() {
        let m = member(ApolloExhaust.f1, altitude: 0)
        let core = m.coreLength
        XCTAssertGreaterThan(core, 3 * m.exitDiameter)
        for x in [0.0, 0.3 * core, 0.7 * core] {
            let rc = m.exitRadius * (1 - x / core), big = m.radius(atX: x)
            XCTAssertEqual(JetFluctuations.mixedness(m, x: x, r: 0.95 * rc, radius: big), 0, "the core at \(x) m")
            XCTAssertEqual(JetFluctuations.mixedness(m, x: x, r: 1.4 * big, radius: big), 1, "outside at \(x) m")
        }
        XCTAssertEqual(JetFluctuations.mixedness(m, x: core, r: 0, radius: m.radius(atX: core)), 0, accuracy: 1e-9)
        XCTAssertEqual(JetFluctuations.mixedness(m, x: 2.5 * core, r: 0, radius: m.radius(atX: 2.5 * core)), 0.5,
                       accuracy: 1e-9)
        XCTAssertEqual(JetFluctuations.mixedness(m, x: 4 * core, r: 0, radius: m.radius(atX: 4 * core)), 1)
    }

    /// Plan's test: the potential core does not fluctuate (r.m.s. under
    /// 1e-3; exactly none), nor a ballooned plume's free expansion within its
    /// boundary, whatever the noise.
    func testCoreAndBallooningInteriorAreStill() throws {
        func rms(_ m: PlumeMember, _ points: [(Double, Double)]) -> Double {
            var sum = 0.0, n = 0
            for (x, r) in points {
                let mean = m.sample(x: x, r: r)
                for k in 0..<41 {
                    let z = -4 + 0.2 * Double(k)
                    let s = m.sample(x: x, r: r, noise: JetFluctuations.Noise(value: z))
                    for (a, b) in [(s.extinction, mean.extinction), (s.emission.luminance, mean.emission.luminance)]
                    where b > 0 {
                        sum += pow(a / b - 1, 2)
                        n += 1
                    }
                }
            }
            return n > 0 ? (sum / Double(n)).squareRoot() : 0
        }
        let f1 = member(ApolloExhaust.f1, altitude: 0)
        let core = f1.coreLength
        let corePoints = (0..<12).map { i -> (Double, Double) in
            let x = 0.9 * core * Double(i) / 11, rc = f1.exitRadius * (1 - x / core)
            return (x, 0.9 * rc * Double(i % 4) / 3)
        }
        let still = rms(f1, corePoints)
        // And the shear layer about it does fluctuate.
        let layer = rms(f1, (1..<12).map { i in
            let x = 0.9 * core * Double(i) / 11
            return (x, f1.radius(atX: x))
        })
        print(String(format: "JetFluctuationsTests: the F-1's core r.m.s. %.1e, its shear layer's %.3f", still, layer))
        XCTAssertLessThan(still, 1e-3)
        XCTAssertGreaterThan(layer, 0.05)
        // A ballooned F-1 high up: its free expansion within the boundary.
        // (At S-IC burnout, 65 km, wholly the free expansion, cut where the
        // air bounds it.)
        let high = try XCTUnwrap([60_000.0, 65_000, 70_000].lazy.map { self.member(ApolloExhaust.f1, altitude: $0) }
            .first { $0.vacuumBlend > 0.99 && $0.confinement > 0.05 }, "a ballooned F-1 the air still bounds")
        let interior = (0..<12).map { i -> (Double, Double) in
            let x = high.length * 0.05 * Double(i + 1)
            return (x, 0.9 * high.radius(atX: x) * Double(i % 4) / 3)
        }
        let balloon = rms(high, interior)
        let boundary = rms(high, (0..<12).map { i in
            let x = high.length * 0.05 * Double(i + 1)
            return (x, 1.25 * high.radius(atX: x))
        })
        print(String(format: "JetFluctuationsTests: ballooned (v %.2f, confinement %.2f): interior r.m.s. %.1e, "
                     + "boundary %.3f", high.vacuumBlend, high.confinement, balloon, boundary))
        XCTAssertLessThan(balloon, 1e-3 + 2 * (1 - high.vacuumBlend))
        XCTAssertGreaterThan(boundary, 0.02, "the boundary billows")
    }

    /// The turbulence's noise as it is drawn (unit variance, nearly a
    /// Gaussian): its values through the F-1's plume at many moments and
    /// seeds.
    func noiseValues(_ m: PlumeMember, count: Int) -> [Double] {
        var state: UInt32 = 9
        var values: [Double] = []
        while values.count < count {
            let x = 5 + 200 * ParticleRandom.uniform(&state), r = 1.2 * m.radius(atX: x) * ParticleRandom.uniform(&state)
            let a = 2 * Double.pi * ParticleRandom.uniform(&state)
            let bands = PlumeTurbulence.bands(time: 1_000 * ParticleRandom.uniform(&state))
            if let f = PlumeTurbulence.field([m], at: Vec3(x, r * cos(a), r * sin(a)), bands: bands,
                                             seed: state, noise: PlumeTurbulence.texel) {
                values.append(f.noise)
            }
        }
        return values
    }

    /// Plan's test: the mean column through the fluctuating field is the
    /// mean field's within 2 %: the F-1 at the pad side-on through its near
    /// field, its flame and its far field.
    /// - By day, the column's optical depth and its light (its own and the
    ///   Sun's), averaged over the turbulence's field at many moments and
    ///   seeds (the mean's standard error reported, under 1 %).
    /// - At night its light is its own, through columns thin enough beyond
    ///   the flame that it is the sum of each point's: each point's mean
    ///   over the noise's values as drawn (a few hot eddies carry much of it,
    ///   so whole columns would need thousands of moments).
    func testMeanColumnWithinTwoPercent() {
        let m = member(ApolloExhaust.f1, altitude: 0)
        let sun = (direction: Vec3(0.2, 0.3, 0.93).normalized, illuminance: Photometry.sunColor.scaled(by: 1e5))
        var worst = 0.0
        var report: [String] = []
        let steps = 200
        func column(_ x: Double) -> (from: Vec3, dir: Vec3, length: Double) {
            let e = m.extent(atX: x)
            return (Vec3(x, -1.2 * e, 0.3 * m.radius(atX: x)), Vec3(0, 1, 0), 2.4 * e)
        }
        for x in [6.0, 20, 45, 90, 160] {
            let (from, dir, length) = column(x)
            let mean = PlumeLook.march([m], from: from, direction: dir, range: 0...length, steps: steps, sun: sun)
            func depth(_ noise: ((Vec3) -> JetFluctuations.Noise?)?) -> Double {
                (0..<steps).reduce(0.0) { s, i in
                    let p = from + dir * ((Double(i) + 0.5) / Double(steps) * length)
                    return s + m.sample(at: p, noise: noise?(p)).extinction * length / Double(steps)
                }
            }
            let meanTau = depth(nil)
            var lights: [Double] = [], tau = 0.0
            let n = 384
            for k in 0..<n {
                let bands = PlumeTurbulence.bands(time: 3 + 0.731 * Double(k))
                let seed = UInt32(k % 11 + 1)
                let noise = { (p: Vec3) -> JetFluctuations.Noise? in
                    PlumeTurbulence.field([m], at: p, bands: bands, seed: seed, noise: PlumeTurbulence.texel)
                        .map { JetFluctuations.Noise(value: $0.noise, depth: $0.depth) }
                }
                lights.append(PlumeLook.march([m], from: from, direction: dir, range: 0...length, steps: steps,
                                              sun: sun, noise: noise).radiance.luminance / mean.radiance.luminance)
                tau += depth(noise)
            }
            let light = lights.reduce(0, +) / Double(n)
            let error = (lights.reduce(0) { $0 + ($1 - light) * ($1 - light) } / Double(n * (n - 1))).squareRoot()
            tau /= Double(n)
            report.append(String(format: "%.0f m: light %+.2f ± %.2f %%, depth %+.2f %% (depth %.2f)", x,
                                 100 * (light - 1), 100 * error, 100 * (tau / meanTau - 1), meanTau))
            worst = max(worst, abs(light - 1), abs(tau / meanTau - 1))
            XCTAssertLessThan(error, 0.01, "the mean is known well enough at \(x) m")
        }
        // At night, beyond the flame (thin: its depth under 0.8).
        let values = noiseValues(m, count: 2_000)
        for x in [90.0, 130, 160] {
            let (from, dir, length) = column(x)
            var light = 0.0, meanLight = 0.0
            for i in 0..<steps {
                let p = from + dir * ((Double(i) + 0.5) / Double(steps) * length)
                guard let f = PlumeTurbulence.field([m], at: p, bands: PlumeTurbulence.bands(time: 5), seed: 1,
                                                    noise: PlumeTurbulence.texel) else { continue }
                meanLight += m.sample(at: p).emission.luminance
                light += values.reduce(0.0) {
                    $0 + m.sample(at: p, noise: JetFluctuations.Noise(value: $1, depth: f.depth)).emission.luminance
                } / Double(values.count)
            }
            report.append(String(format: "%.0f m at night: light %+.2f %%", x, 100 * (light / meanLight - 1)))
            worst = max(worst, abs(light / meanLight - 1))
        }
        print("JetFluctuationsTests: mean column against the mean field:", report.joined(separator: "; "))
        XCTAssertLessThan(worst, 0.02)
    }

    /// The heat fluctuates on its excess over the air where the jet is
    /// mixed: a sample whose mean is the air's temperature stays there, none
    /// is drawn hotter than the hottest gas, and the light's mean over a
    /// Gaussian noise is the mean field's within 2 % beyond the flame (inert,
    /// its heat fluctuating) and in it (its soot) where the exhaust is always
    /// there; at the intermittent edge within 10 % (the light's mean is
    /// reckoned for a Gaussian fluctuation, the edge's is skewed; the columns
    /// through it hold, `testMeanColumnWithinTwoPercent`).
    func testHeatOnItsExcess() {
        let m = member(ApolloExhaust.f1, altitude: 0)
        func meanLight(x: Double, r: Double) -> (Double, Double) {
            var sum = 0.0, weight = 0.0
            for k in 0..<161 {
                let z = -8 + 0.1 * Double(k), w = JetFluctuations.normalDensity(z) * 0.1
                sum += w * m.sample(x: x, r: r, noise: JetFluctuations.Noise(value: z)).emission.luminance
                weight += w
            }
            return (sum / weight, m.sample(x: x, r: r).emission.luminance)
        }
        var report: [String] = []
        for (x, q) in [(0.5 * m.flameLength, 0.9), (1.5 * m.flameLength, 0.3), (2.5 * m.flameLength, 0.6),
                       (2.5 * m.flameLength, 1.1)] {
            let r = q * m.radius(atX: x)
            let (fluctuating, mean) = meanLight(x: x, r: r)
            let w = min(max(0.06 + 0.45 * x / (x + 6 * m.exitDiameter), 0.06), 0.5)
            let pc = 1 - PlumeMember.smoothstep(1 - w, 1 + w, q)
            let presence = JetFluctuations.presence(threshold: JetFluctuations.threshold(meanShare: pc))
            report.append(String(format: "x %.0f m q %.1f (there %.0f %%): %+.2f %%", x, q, 100 * presence,
                                 100 * (fluctuating / mean - 1)))
            XCTAssertEqual(fluctuating / mean, 1, accuracy: presence > 0.95 ? 0.02 : 0.1, "x \(x) m, q \(q)")
        }
        print("JetFluctuationsTests: the light's mean over the noise:", report.joined(separator: "; "))
        // The heat never passes the hottest gas, and ambient stays ambient.
        var cold = m
        cold.coreTemperature = cold.ambientTemperature
        cold.afterburning = 0
        for z in [-3.0, 0, 3] {
            XCTAssertEqual(cold.sample(x: 200, r: 3, noise: JetFluctuations.Noise(value: z)).emission.luminance,
                           cold.sample(x: 200, r: 3).emission.luminance, accuracy: 1e-12)
        }
    }

    /// A ballooned plume's boundary billows: its free expansion's gas is
    /// there the boundary's share of the time, the mean kept, and only where
    /// the air bounds it (its confinement).
    func testBillowingBoundaryKeepsTheMean() throws {
        let high = try XCTUnwrap([60_000.0, 65_000, 70_000].lazy.map { self.member(ApolloExhaust.f1, altitude: $0) }
            .first { $0.vacuumBlend > 0.99 && $0.confinement > 0.05 })
        let x = 0.3 * high.length, big = high.radius(atX: x)
        for q in [1.1, 1.25, 1.4] {
            var sum = 0.0, weight = 0.0, zero = 0.0
            let mean = high.sample(x: x, r: q * big).extinction
            for k in 0..<161 {
                let z = -8 + 0.1 * Double(k), w = JetFluctuations.normalDensity(z) * 0.1
                let s = high.sample(x: x, r: q * big, noise: JetFluctuations.Noise(value: z)).extinction
                sum += w * s
                weight += w
                if s < 0.999 * mean { zero += w }
            }
            XCTAssertEqual(sum / weight / mean, 1, accuracy: 0.01, "q \(q)")
            XCTAssertGreaterThan(zero, 0.05, "q \(q): it billows")
        }
    }
}
