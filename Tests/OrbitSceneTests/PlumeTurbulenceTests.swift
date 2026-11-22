import XCTest
import OrbitCore
@testable import OrbitScene

/// The plumes' turbulence (`PlumeTurbulence`), procedural and never
/// repeating: eddies growing with the jet's mixing layer (the Langley
/// curve, Brown and Roshko), carried at the local mean speed, decaying over
/// their turnover time, averaged over the shutter; deterministic in the
/// turbulence clock and the cluster's seed, and never matching itself after
/// any period (M1.6's first noise's loop, the tile's, the bands').
final class PlumeTurbulenceTests: XCTestCase {
    let us76 = USStandardAtmosphere1976()

    func member(_ engine: ApolloExhaust.Engine, altitude: Double? = nil, flow: Double = 1,
                stream: Double = 0) -> PlumeMember {
        let a = altitude.map { us76.state(altitude: $0) } ?? .vacuum
        let s = PlumeModel.state(engine.spec, flowFraction: flow, ambient: a, streamAlong: stream)
        var m = PlumeLook.member(engine.spec, state: s, exit: Vec3(0, 0, 0), axis: Vec3(1, 0, 0),
                                 exitRadius: engine.spec.exitRadius, ambient: a, streamAlong: stream)
        m.relativeWind = Vec3(stream, 0, 0)
        return m
    }

    func value(_ m: PlumeMember, _ p: Vec3, _ t: Double, seed: UInt32 = 7) -> Double {
        PlumeTurbulence.value([m], at: p, bands: PlumeTurbulence.bands(time: t), seed: seed,
                              noise: PlumeTurbulence.continuousNoise)
    }

    /// Points spread through the F-1's plume at the pad from 60 to 160 m
    /// (its far field: eddies 5-12 m, turnover 0.03-0.2 s), on and off the
    /// axis, at least a few eddies apart.
    func farField(_ m: PlumeMember, count: Int = 48) -> [Vec3] {
        (0..<count).map { i in
            let x = 60 + 100 * Double(i) / Double(count - 1)
            let r = 0.6 * m.radius(atX: x) * Double(i % 3) / 2
            let a = 2.4 * Double(i)
            return Vec3(x, r * cos(a), r * sin(a))
        }
    }

    /// Where the mean flow carries a parcel at x, r over dt (fine steps).
    func carried(_ m: PlumeMember, x: Double, r: Double, dt: Double) -> Double {
        let g = PlumeTurbulence.profile(m, atX: x, r: r)
        var y = x
        for _ in 0..<400 { y += dt / 400 * (m.coflow + PlumeTurbulence.excessSpeed(m, atX: y) * g) }
        return y
    }

    /// The ensemble correlation of n(p, t) and n(p', t') over pairs.
    func correlation(_ pairs: [(Double, Double)]) -> Double {
        var ab = 0.0, aa = 0.0, bb = 0.0
        for (a, b) in pairs {
            ab += a * b
            aa += a * a
            bb += b * b
        }
        return ab / max((aa * bb).squareRoot(), 1e-30)
    }

    // MARK: The mixing layer

    /// The eddies grow with the compressible mixing layer: Brown and
    /// Roshko's incompressible 0.181 in Brown's velocity and density ratio
    /// form, times Dimotakis's fit to the Langley curve (1 incompressible,
    /// 0.58 at Mc 0.5, 0.24 at Mc 1, 0.2 beyond).
    func testEddiesGrowWithTheMixingLayer() {
        XCTAssertEqual(PlumeTurbulence.compressibility(convectiveMach: 0), 1, accuracy: 1e-12)
        XCTAssertEqual(PlumeTurbulence.compressibility(convectiveMach: 0.5), 0.578, accuracy: 0.001)
        XCTAssertEqual(PlumeTurbulence.compressibility(convectiveMach: 1), 0.240, accuracy: 0.001)
        XCTAssertEqual(PlumeTurbulence.compressibility(convectiveMach: 3), 0.2, accuracy: 0.001)
        XCTAssertEqual(PlumeTurbulence.shearGrowth(velocityRatio: 0, densityRatio: 1, convectiveMach: 0), 0.181,
                       accuracy: 1e-12)
        // A coflow at half the jet's speed: (1 - r)/(1 + r) = 1/3.
        XCTAssertEqual(PlumeTurbulence.shearGrowth(velocityRatio: 0.5, densityRatio: 1, convectiveMach: 0), 0.181 / 3,
                       accuracy: 1e-12)
        // A light jet into dense air grows faster: (1 + √4)/2 = 1.5.
        XCTAssertEqual(PlumeTurbulence.shearGrowth(velocityRatio: 0, densityRatio: 4, convectiveMach: 0), 0.2715,
                       accuracy: 1e-12)

        // The F-1 at the pad: born at a quarter of its exit radius, growing
        // to the far field's size (about half the jet's radius) downstream.
        let m = member(ApolloExhaust.f1, altitude: 0)
        XCTAssertEqual(m.eddySize, 0.25 * m.exitRadius, accuracy: 1e-12)
        XCTAssertGreaterThan(m.eddyGrowth, 0.03)
        XCTAssertLessThan(m.eddyGrowth, 0.12)
        for x in [100.0, 150] {
            let ratio = PlumeTurbulence.eddySize(m, atX: x) / m.radius(atX: x)
            XCTAssertGreaterThan(ratio, 0.3, "x \(x)")
            XCTAssertLessThan(ratio, 1, "x \(x)")
        }
        // A coflow slows the layer's growth (the airspeed at max-Q).
        let still = member(ApolloExhaust.f1, altitude: 13_000), flying = member(ApolloExhaust.f1, altitude: 13_000,
                                                                                 stream: 480)
        XCTAssertLessThan(flying.eddyGrowth, still.eddyGrowth)
        // In vacuum, half the free expansion's cone.
        let j2 = member(ApolloExhaust.j2)
        let half = j2.simonsAngle(fraction: 0.5)
        XCTAssertEqual(j2.eddyGrowth, 0.5 * tan(half), accuracy: 1e-9)
    }

    /// The mean speed: the jet's on the axis through the potential core,
    /// falling as 1/x beyond it to the stream's, slower towards the edge
    /// (half at r = R/2 beyond the core); uniform in a free expansion.
    func testMeanSpeed() {
        let m = member(ApolloExhaust.f1, altitude: 0)
        let core = m.coreLength
        XCTAssertEqual(PlumeTurbulence.meanSpeed(m, atX: 0.5 * core, r: 0), m.exhaustSpeed, accuracy: 1e-9)
        XCTAssertEqual(PlumeTurbulence.meanSpeed(m, atX: 4 * core, r: 0), m.exhaustSpeed / 4, accuracy: 1e-6)
        let x = 4 * core, big = m.radius(atX: x)
        XCTAssertEqual(PlumeTurbulence.meanSpeed(m, atX: x, r: 0.5 * big) / PlumeTurbulence.meanSpeed(m, atX: x, r: 0),
                       0.5, accuracy: 1e-6)
        let flying = member(ApolloExhaust.f1, altitude: 13_000, stream: 480)
        XCTAssertEqual(PlumeTurbulence.meanSpeed(flying, atX: 1e5, r: 0), 480, accuracy: 15)
        let j2 = member(ApolloExhaust.j2)
        XCTAssertEqual(PlumeTurbulence.meanSpeed(j2, atX: 50, r: 0), PlumeTurbulence.meanSpeed(j2, atX: 50, r: 10),
                       accuracy: 1e-6)
    }

    // MARK: The field in time

    /// Deterministic in the clock and the seed; another seed, another
    /// field. At the clock's start every band's first layer is newborn
    /// (weight 0) and its second at full weight.
    func testDeterministicAndSeeded() {
        let m = member(ApolloExhaust.f1, altitude: 0)
        let p = Vec3(90, 3, -2)
        XCTAssertEqual(value(m, p, 12.345), value(m, p, 12.345))
        let pts = farField(m)
        let a = pts.map { value(m, $0, 3, seed: 1) }, b = pts.map { value(m, $0, 3, seed: 2) }
        XCTAssertLessThan(abs(correlation(Array(zip(a, b)))), 0.35)
        for band in PlumeTurbulence.bands(time: 0) {
            XCTAssertEqual(band.phase.0, 0)
            XCTAssertEqual(band.phase.1, 0.5)
        }
    }

    /// Carried at the local mean speed: the pattern a moment later matches
    /// itself best shifted downstream as far as the mean flow carries it,
    /// on the axis and, slower, half-way out, where a parcel keeps its
    /// share of the spreading jet's radius (over independent seeds, the
    /// peak refined by a parabola).
    func testCarriedAtTheLocalMeanSpeed() {
        let m = member(ApolloExhaust.f1, altitude: 0)
        let x0 = 110.0
        var shifts: [Double] = []
        for rFraction in [0.0, 0.5] {
            let r = rFraction * m.radius(atX: x0)
            func at(_ x: Double) -> Vec3 { Vec3(x, rFraction * m.radius(atX: x), 0) }
            let dt = 0.04 * PlumeTurbulence.turnover(m, atX: x0)
            let expected = carried(m, x: x0, r: r, dt: dt) - x0
            let seeds: [UInt32] = [1, 2, 3, 4, 5, 6, 7, 8]
            let line = (0..<100).map { x0 - 10 + 0.2 * Double($0) }
            let before = seeds.map { seed in line.map { value(m, at($0), 40, seed: seed) } }
            let step = 0.1
            let rhos = (0...40).map { k -> Double in
                var pairs: [(Double, Double)] = []
                for (i, seed) in seeds.enumerated() {
                    for (j, x) in line.enumerated() {
                        pairs.append((before[i][j], value(m, at(x + step * Double(k)), 40 + dt, seed: seed)))
                    }
                }
                return correlation(pairs)
            }
            let k = rhos.indices.max { rhos[$0] < rhos[$1] }!
            var shift = step * Double(k)
            if k > 0 && k < rhos.count - 1 {
                let a = rhos[k - 1], b = rhos[k], c = rhos[k + 1]
                shift += step * 0.5 * (a - c) / (a - 2 * b + c)
            }
            print(String(format: "PlumeTurbulenceTests: r %.1f R at x %.0f m: carried %.2f m in %.4f s (the flow's %.2f m), "
                         + "correlation %.2f", rFraction, x0, shift, dt, expected, rhos[k]))
            XCTAssertEqual(shift, expected, accuracy: 0.15 * expected + 0.1, "r \(rFraction) R")
            XCTAssertGreaterThan(rhos[k], 0.6)
            shifts.append(shift)
        }
        XCTAssertLessThan(shifts[1], 0.75 * shifts[0], "the edge slower than the axis")
    }

    /// Decays as a jet's turbulence does: following the mean flow, its
    /// correlation's integral to its first zero, the Lagrangian integral
    /// time, is the cross-fade's of the point's two bands as the blend
    /// weighs them, within 35 % at each of three points on the axis (the
    /// blend's normalisation couples the bands, and the parcel moves to
    /// longer lives as it goes); and a
    /// layer lives so that this is 0.55 L/u' (Viggiano et al. 2021), L the
    /// noise's integral length, where its turnover falls on a band (the
    /// bands' lives are octaves). Two turnovers on it has forgotten itself.
    func testDecaysAsAJetsTurbulence() {
        let m = member(ApolloExhaust.f1, altitude: 0)
        XCTAssertEqual(PlumeTurbulence.lifeOverTurnover * PlumeTurbulence.fadeIntegral,
                       PlumeTurbulence.lagrangianTime * PlumeTurbulence.integralLength, accuracy: 1e-12)
        for x in [70.0, 110, 150] {
            let tau = PlumeTurbulence.turnover(m, atX: x)
            let b = PlumeTurbulence.band(turnover: tau), j = Int(b), beta = PlumeTurbulence.blend(b - Double(j))
            let w0 = (1 - beta) * (1 - beta), w1 = beta * beta
            let life = (w0 * PlumeTurbulence.life(band: j) + w1 * PlumeTurbulence.life(band: j + 1)) / (w0 + w1)
            let expected = PlumeTurbulence.fadeIntegral * life / tau
            func lagrangian(_ turnovers: Double) -> Double {
                let dt = turnovers * tau
                let q = Vec3(carried(m, x: x, r: 0, dt: dt), 0, 0)
                return correlation((0..<200).map { k in
                    let t0 = 3 + 0.37 * Double(k)
                    return (value(m, Vec3(x, 0, 0), t0, seed: UInt32(k)), value(m, q, t0 + dt, seed: UInt32(k)))
                })
            }
            let step = 0.02
            var integral = 0.0, previous = 1.0
            for k in 1..<50 {
                let rho = lagrangian(Double(k) * step)
                if rho <= 0 {
                    integral += 0.5 * previous * step * previous / max(previous - rho, 1e-9)
                    break
                }
                integral += 0.5 * (previous + rho) * step
                previous = rho
            }
            let later = lagrangian(2)
            print(String(format: "PlumeTurbulenceTests: x %.0f m: Lagrangian integral time %.3f ℓ/u' (its bands' %.3f, "
                         + "0.55 L/u' %.3f), correlation %.2f at 2 τ", x, integral, expected,
                         PlumeTurbulence.lagrangianTime * PlumeTurbulence.integralLength, later))
            XCTAssertEqual(integral, expected, accuracy: 0.35 * expected, "x \(x)")
            XCTAssertLessThan(abs(later), 0.2)
        }
    }

    /// The constants the life is built on: two triangles half a life
    /// apart, normalised, correlate for 0.389 of a life (the integral of
    /// their overlap), and the volume noise's integral length (to its
    /// correlation's first zero) is `integralLength` of its coarsest cell.
    func testFadeIntegralAndIntegralLength() {
        func w(_ p: Double) -> Double { 1 - abs(2 * p - 1) }
        let n = 400, dl = 0.005
        var fade = 0.0
        for k in 0..<Int(1.2 / dl) {
            let lag = Double(k) * dl
            var sum = 0.0
            for i in 0..<n {
                let t = (Double(i) + 0.5) / Double(n)
                var acc = 0.0, na = 0.0, nb = 0.0
                for off in [0.0, 0.5] {
                    let u0 = t + off, u1 = t + lag + off
                    let a = w(u0 - u0.rounded(.down)), b = w(u1 - u1.rounded(.down))
                    na += a * a
                    nb += b * b
                    if u0.rounded(.down) == u1.rounded(.down) { acc += a * b }
                }
                sum += acc / (na * nb).squareRoot()
            }
            fade += sum / Double(n) * dl
        }
        XCTAssertEqual(fade, PlumeTurbulence.fadeIntegral, accuracy: 0.01)

        // The noise's integral length, to its correlation's first zero, over
        // 3,000 random starts along the three axes and both channels.
        var state: UInt32 = 3
        let starts = (0..<3_000).map { _ in
            Vec3(ParticleRandom.uniform(&state), ParticleRandom.uniform(&state), ParticleRandom.uniform(&state))
        }
        let base = starts.enumerated().map { 2 * PlumeTurbulence.continuousNoise($0.element, channel: $0.offset % 2) - 1 }
        var length = 0.0, previous = 1.0
        let step = 0.05
        for k in 1..<40 {
            let d = Double(k) * step / PlumeTurbulence.eddiesPerTile
            var pairs: [(Double, Double)] = []
            for (i, c) in starts.enumerated() {
                let dir = [Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)][i % 3]
                pairs.append((base[i], 2 * PlumeTurbulence.continuousNoise(c + dir * d, channel: i % 2) - 1))
            }
            let rho = correlation(pairs)
            if rho <= 0 {
                length += 0.5 * previous * step * previous / max(previous - rho, 1e-9)
                break
            }
            length += 0.5 * (previous + rho) * step
            previous = rho
        }
        print(String(format: "PlumeTurbulenceTests: fade integral %.3f of a life, integral length %.3f of a cell",
                     fade, length))
        XCTAssertEqual(length, PlumeTurbulence.integralLength, accuracy: 0.02)
    }

    /// Never matches itself: at points through the far field, the field's
    /// correlation with itself later stays near zero at every lag tried
    /// beyond a few turnovers, up to ten minutes: whole numbers of M1.6's
    /// first noise's loop (its tile over its eddy speed, 1.28 s for the
    /// F-1), of the tile carried at the flow's speed, of every band's
    /// life, and lags spread at random. A moment later it is still itself.
    func testNeverMatchesItself() {
        let m = member(ApolloExhaust.f1, altitude: 0)
        let pts = farField(m, count: 40)
        let starts = [3.0, 11.7, 29.1, 64.3, 101.9, 133.3]
        let seeds: [UInt32] = [7, 8, 9]
        let base = seeds.map { seed in starts.map { t in pts.map { value(m, $0, t, seed: seed) } } }
        func rho(_ lag: Double) -> Double {
            var pairs: [(Double, Double)] = []
            for (s, seed) in seeds.enumerated() {
                for (i, t) in starts.enumerated() {
                    for (k, p) in pts.enumerated() { pairs.append((base[s][i][k], value(m, p, t + lag, seed: seed))) }
                }
            }
            return correlation(pairs)
        }
        let longest = pts.map { PlumeTurbulence.turnover(m, atX: $0.x) }.max() ?? 1
        var lags: [Double] = []
        let oldLoop = 16 * 0.8 * m.exitRadius / min(max(10 * m.exitRadius, 2), 40)
        lags += (1...60).map { Double($0) * oldLoop }
        let tile = PlumeTurbulence.eddiesPerTile * PlumeTurbulence.eddySize(m, atX: 110)
            / PlumeTurbulence.meanSpeed(m, atX: 110, r: 0)
        lags += (1...40).map { Double($0) * tile }
        for j in 8..<PlumeTurbulence.bandCount {
            lags += [1, 2, 3, 5, 8].map { Double($0) * PlumeTurbulence.life(band: j) }
        }
        var state: UInt32 = 99
        lags += (0..<120).map { _ in 600 * ParticleRandom.uniform(&state) }
        lags = lags.filter { $0 > 4 * longest && $0 <= 600 }
        var worst = (lag: 0.0, rho: 0.0)
        for lag in lags {
            let r = rho(lag)
            if abs(r) > abs(worst.rho) { worst = (lag, r) }
        }
        print(String(format: "PlumeTurbulenceTests: %d lags to 10 min, worst correlation %.3f at %.2f s "
                     + "(longest turnover %.2f s)", lags.count, worst.rho, worst.lag, longest))
        XCTAssertGreaterThan(lags.count, 200)
        XCTAssertLessThan(abs(worst.rho), 0.2, "lag \(worst.lag) s")
        let shortest = pts.map { PlumeTurbulence.turnover(m, atX: $0.x) }.min() ?? 1
        XCTAssertGreaterThan(rho(0.01 * shortest), 0.95, "continuous in time")
    }

    /// No pulsing: the field's spread is the same through its layers'
    /// lives (the blend keeps the variance), within 10 % (over ten
    /// independent seeds).
    func testSpreadDoesNotPulse() {
        let m = member(ApolloExhaust.f1, altitude: 0)
        let pts = farField(m, count: 60)
        let b = PlumeTurbulence.band(turnover: PlumeTurbulence.turnover(m, atX: 110))
        let life = PlumeTurbulence.life(band: Int(b))
        let spreads = (0..<12).map { i -> Double in
            let t = 50 + life * Double(i) / 12
            let v = (1...10).flatMap { seed in pts.map { value(m, $0, t, seed: UInt32(seed)) } }
            return (v.reduce(0) { $0 + $1 * $1 } / Double(v.count)).squareRoot()
        }
        let mean = spreads.reduce(0, +) / Double(spreads.count)
        for s in spreads { XCTAssertEqual(s / mean, 1, accuracy: 0.1, "\(spreads)") }
    }

    /// The shutter: near the F-1's exit the field is swept past and renewed
    /// many times in a 180° shutter, and the camera sees the average,
    /// shallower as 1/√(1 + Δ/2T_E); the slow far field is smoothed less,
    /// and so is the slow edge of the jet.
    func testShutterAveragesTheFastNearField() {
        let m = member(ApolloExhaust.f1, altitude: 0)
        func spread(atX x: Double, eta: Double) -> Double {
            let v = (0..<400).map { i -> Double in
                let a = 2.4 * Double(i), r = eta * m.radius(atX: x)
                return value(m, Vec3(x + 0.005 * Double(i), r * cos(a), r * sin(a)), 7 + 0.013 * Double(i),
                             seed: UInt32(i))
            }
            return (v.reduce(0) { $0 + $1 * $1 } / Double(v.count)).squareRoot()
        }
        // The two bands' depths, as the blend weighs them (by their weights
        // squared, the layers' triangles alike).
        func expected(atX x: Double, eta: Double) -> Double {
            let b = PlumeTurbulence.band(turnover: PlumeTurbulence.turnover(m, atX: x))
            let j = Int(b), beta = PlumeTurbulence.blend(b - Double(j))
            let u = PlumeTurbulence.meanSpeed(m, atX: x, r: eta * m.radius(atX: x))
            let sweep = u / (PlumeTurbulence.integralLength * PlumeTurbulence.eddySize(m, atX: x))
            func depth(_ band: Int) -> Double {
                PlumeTurbulence.shutterAverage(life: PlumeTurbulence.life(band: band), sweep: sweep).depth
            }
            let w0 = (1 - beta) * (1 - beta), w1 = beta * beta
            return ((w0 * depth(j) * depth(j) + w1 * depth(j + 1) * depth(j + 1)) / (w0 + w1)).squareRoot()
        }
        let near = spread(atX: 10, eta: 0.3), far = spread(atX: 140, eta: 0.3), edge = spread(atX: 10, eta: 0.9)
        print(String(format: "PlumeTurbulenceTests: spread at 10 m %.3f (edge %.3f), at 140 m %.3f "
                     + "(shutter %.2f, %.2f, %.2f)", near, edge, far, expected(atX: 10, eta: 0.3),
                     expected(atX: 10, eta: 0.9), expected(atX: 140, eta: 0.3)))
        let ratio = expected(atX: 10, eta: 0.3) / expected(atX: 140, eta: 0.3)
        XCTAssertEqual(near / far, ratio, accuracy: 0.2 * ratio)
        XCTAssertLessThan(near, 0.6 * far)
        XCTAssertGreaterThan(edge, 1.3 * near, "the slow edge is smoothed less")
    }

    /// The noise's scale keeps M1.6's first noise's spread (its two octaves
    /// at c and 2c), so the depth's calibration holds: within 10 %.
    func testAmplitudeKeepsTheDepthCalibration() {
        var state: UInt32 = 5
        var old = 0.0, new = 0.0
        let n = 4_000
        for _ in 0..<n {
            let c = Vec3(ParticleRandom.uniform(&state), ParticleRandom.uniform(&state), ParticleRandom.uniform(&state))
            let n1 = PlumeTurbulence.continuousNoise(c, channel: 0)
            let n2 = PlumeTurbulence.continuousNoise(c * 2 + Vec3(0.37, 0.37, 0.37), channel: 1)
            let o = 2 * (0.65 * n1 + 0.35 * n2) - 1
            let v = PlumeTurbulence.amplitude * (2 * PlumeTurbulence.continuousNoise(c, channel: 0) - 1)
            old += o * o
            new += v * v
        }
        XCTAssertEqual((new / old).squareRoot(), 1, accuracy: 0.1)
    }

    /// The texture's sample is the noise's value at its texels: the
    /// trilinear reference meets the continuous noise there.
    func testTexelMatchesTheField() {
        let n = Double(VolumeNoiseField.size)
        for (x, y, z) in [(3, 7, 11), (100, 2, 64), (127, 127, 0)] {
            let c = Vec3((Double(x) + 0.5) / n, (Double(y) + 0.5) / n, (Double(z) + 0.5) / n)
            XCTAssertEqual(PlumeTurbulence.texel(c, channel: 1), VolumeNoiseField.value(x, y, z, channel: 1),
                           accuracy: 1e-9)
            XCTAssertEqual(PlumeTurbulence.texel(c, channel: 0), PlumeTurbulence.continuousNoise(c, channel: 0),
                           accuracy: 1e-9)
        }
    }
}



