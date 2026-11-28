import Foundation
import XCTest
import OrbitCore
@testable import OrbitScene

/// The launch cloud's turbulence (`LaunchTurbulence`): a Kolmogorov
/// cascade of flow noise down to the pixel, displacing the primitives'
/// boundaries as a fractal surface of dimension 7/3.
final class LaunchTurbulenceTests: XCTestCase {
    static let field: GroundCloudField = {
        let c = GroundCloudFieldTests.cloud(to: 15)
        return GroundCloudFieldTests.field(c, at: 15)
    }()

    static var thermal: GroundCloudField.Primitive { field.primitives.first { $0.shape == .thermal && $0.lobe == .trench(1) }! }

    // The cascade: octave k displaces the boundary by 2^(−k(3 − D)) of the
    // largest's, D = 7/3 (a level set's height, not the spectrum's 2^(−k/3)
    // increments); the whole cascade's rms is √(1/(1 − 2^(−4/3))) of the
    // largest octave's. Its cells and lifetimes are LR3's spectrum's: the
    // largest 0.45 of the flow's size, living its size over its speed.
    func testCascade() {
        XCTAssertEqual(LaunchTurbulence.gain(3), pow(2, -2.0), accuracy: 1e-12)
        let sum = (0..<200).reduce(0.0) { $0 + pow(LaunchTurbulence.gain($1), 2) }
        XCTAssertEqual(LaunchTurbulence.cascade, sum.squareRoot(), accuracy: 1e-12)
        let s = LaunchTurbulence.spectrum(size: 100, speed: 10)
        XCTAssertEqual(s.cell(octave: 0), 45, accuracy: 1e-12)
        XCTAssertEqual(s.lifetime(octave: 3), 10 * 0.25, accuracy: 1e-12)
        XCTAssertEqual(LaunchTurbulence.spectrum(size: 100, speed: 0).largestLifetime,
                       100 / LaunchTurbulence.convectiveVelocity, "a stalled cloud: w*")
    }

    // The octaves drawn follow the pixel (the spectrum's cut-off): eddies
    // of 0.45 of the flow's size, halving, in full from 4 footprints, none
    // below 1.5; a cloud 100 m across at a 1 m footprint has four in full
    // and a fifth fading in.
    func testOctavesFollowTheFootprint() {
        let s = LaunchTurbulence.spectrum(size: 100, speed: 10)
        let w = LaunchTurbulence.weights(s, footprint: 1)
        XCTAssertEqual(w.count, 5)
        XCTAssertEqual(w.prefix(4), [1, 1, 1, 1])
        XCTAssertEqual(w[4], TurbulenceSpectrum.footprintWeight(cell: 45 / 16, footprint: 1), accuracy: 1e-12)
        XCTAssertEqual(LaunchTurbulence.weights(s, footprint: 0.001).count, LaunchTurbulence.maximumOctaves)
        XCTAssertEqual(LaunchTurbulence.weights(s, footprint: 100), [], "sub-pixel: smooth")
    }

    // The volume noise's spread about its mean, which normalises each
    // octave to unit variance: measured on P3's texels.
    func testNoiseDeviation() {
        var sum = 0.0, sum2 = 0.0, n = 0.0
        for x in stride(from: 0, to: 128, by: 3) {
            for y in stride(from: 1, to: 128, by: 5) {
                for z in stride(from: 2, to: 128, by: 7) {
                    let v = VolumeNoiseField.value(x, y, z, channel: (x + y) % 2)
                    sum += v
                    sum2 += v * v
                    n += 1
                }
            }
        }
        let mean = sum / n, sd = (sum2 / n - mean * mean).squareRoot()
        XCTAssertEqual(mean, 0.5, accuracy: 0.01)
        XCTAssertEqual(LaunchTurbulence.noiseDeviation, sd, accuracy: 0.03 * sd, "measured \(sd)")
    }

    /// The displacement along a horizontal line through `p`'s core at time
    /// `t`, every `step` m for `count` steps.
    static func line(_ p: GroundCloudField.Primitive, time t: Double, step: Double, count: Int,
                     footprint: Double = 0.01,
                     noise: @escaping (Vec3, Int) -> Double = LaunchTurbulence.volumeNoise) -> [Double] {
        let bands = PlumeTurbulence.bands(time: t)
        return (0..<count).map { i in
            let x = p.origin + Vec3(-p.radius + Double(i) * step, 0.3 * p.radius, 0.1 * p.radius)
            return LaunchTurbulence.displacement(p, at: x, bands: bands, footprint: footprint, noise: noise)
        }
    }

    /// The displacement's rms and its structure function's log-slope
    /// between lags r0 and r1 (m), sampled every `step` m.
    static func spectrum(_ eta: [Double], step: Double, from r0: Double, to r1: Double) -> (rms: Double, slope: Double) {
        let mean = eta.reduce(0, +) / Double(eta.count)
        let rms = (eta.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(eta.count)).squareRoot()
        func s2(_ lag: Int) -> Double {
            var s = 0.0
            for i in 0..<(eta.count - lag) { s += (eta[i + lag] - eta[i]) * (eta[i + lag] - eta[i]) }
            return s / Double(eta.count - lag)
        }
        let l0 = max(1, Int((r0 / step).rounded())), l1 = max(l0 + 1, Int((r1 / step).rounded()))
        return (rms, log(s2(l1) / s2(l0)) / log(Double(l1) / Double(l0)))
    }

    // The boundary is fractal: the displacement's structure function rises
    // as r^(2(3 − D)) = r^(4/3) through the eddies drawn (a level set's
    // height under Kolmogorov's 2/3 law), its rms about `interfaceSpread` of
    // the flow's size. Measured from twice the finest eddies drawn to a
    // tenth of the largest (beyond, the largest eddies saturate it), on
    // the field P3's noise texture holds and through its trilinear texels,
    // as the GPU samples it.
    func testBoundaryIsFractal() {
        let p = Self.thermal
        let step = 0.25, l0 = LaunchTurbulence.integralScale * p.radius
        let (r0, r1) = (2 * l0 / 128, 0.1 * l0)
        let smooth = Self.spectrum(Self.line(p, time: 3.7, step: step, count: 4_000, noise: LaunchTurbulence.smoothNoise),
                                   step: step, from: r0, to: r1)
        let texels = Self.spectrum(Self.line(p, time: 3.7, step: step, count: 4_000), step: step, from: r0, to: r1)
        print(String(format: "R %.0f m: rms %.1f m (%.2f R); structure function slope %.2f from %.1f to %.1f m (through the texels %.2f, rms %.2f R)",
                     p.radius, smooth.rms, smooth.rms / p.radius, smooth.slope, r0, r1, texels.slope,
                     texels.rms / p.radius))
        XCTAssertEqual(smooth.slope, 4.0 / 3, accuracy: 0.15)
        XCTAssertEqual(texels.slope, 4.0 / 3, accuracy: 0.15)
        XCTAssertEqual(smooth.rms / p.radius, LaunchTurbulence.interfaceSpread, accuracy: 0.5 * LaunchTurbulence.interfaceSpread)
    }

    // Deterministic, and continuous in time: a frame later (1/60 s) the
    // boundary of a cloud rising at metres a second has hardly moved, its
    // change a small part of its rms; a rebuilt field's turbulence is the
    // frames'.
    func testTurbulenceIsDeterministicAndContinuous() {
        let p = Self.thermal
        let a = Self.line(p, time: 3.7, step: 2, count: 200)
        XCTAssertEqual(a, Self.line(p, time: 3.7, step: 2, count: 200))
        let b = Self.line(p, time: 3.7 + 1.0 / 60, step: 2, count: 200)
        let rms = (a.map { $0 * $0 }.reduce(0, +) / Double(a.count)).squareRoot()
        let change = (zip(a, b).map { ($0 - $1) * ($0 - $1) }.reduce(0, +) / Double(a.count)).squareRoot()
        print(String(format: "a frame's change %.3f m against rms %.2f m", change, rms))
        XCTAssertLessThan(change, 0.05 * rms)
        // The rebuilt field's primitives are the same, so is their turbulence.
        let c = GroundCloudFieldTests.cloud(to: 15, every: 0.1)
        let rebuilt = GroundCloudFieldTests.field(c, at: 15).primitives.first { $0.shape == .thermal && $0.lobe == .trench(1) }!
        XCTAssertEqual(Self.line(rebuilt, time: 3.7, step: 2, count: 200), a)
    }

    // The displaced density: the core keeps its density, the boundary
    // moves out where the displacement is positive and in where negative.
    func testDisplacementMovesTheBoundary() {
        let p = Self.thermal
        let core = p.origin + Vec3(GroundCloudField.ringRadius * p.radius, 0, 0)
        XCTAssertEqual(p.density(at: core, displacement: 10), p.density(at: core), accuracy: 1e-12)
        let edge = p.origin + Vec3((GroundCloudField.ringRadius + 1.5 * GroundCloudField.coreRadius) * p.radius, 0, 0)
        XCTAssertGreaterThan(p.density(at: edge, displacement: 10), p.density(at: edge))
        XCTAssertLessThan(p.density(at: edge, displacement: -10), p.density(at: edge))
    }

    // The displaced shapes keep their mass. Moving a convex profile's level
    // sets by a zero-mean amount raises its integral on average (a ring
    // thermal by a third with every octave drawn); the expected gain
    // (`DisplacementGain`, tabled in each shape's level-set measure) is
    // checked here by an independent quadrature in space: the thermal's
    // (s, z) half-plane, the jet's disc, the wall jet's layer.
    func testDisplacementGainsAreTheShapes() {
        func expected(_ sigma: Double, _ profile: (Double) -> Double, _ points: [(q: Double, w: Double)]) -> Double {
            let m = 41, span = 6 * sigma, dx = 2 * span / Double(m - 1)
            var total = 0.0, weights = 0.0
            for k in 0..<m {
                let x = -span + Double(k) * dx, w = exp(-0.5 * x * x / (sigma * sigma))
                weights += w
                total += w * points.reduce(0.0) { $0 + $1.w * profile(max($1.q - PlumeMember.smoothstep(0, 1, $1.q) * x, 0)) }
            }
            return total / weights / points.reduce(0.0) { $0 + $1.w * profile($1.q) }
        }
        let gauss: (Double) -> Double = { exp(-$0 * $0) }
        // The thermal (R = 1): its ring coordinate over the (s, z) half-plane.
        var ring: [(q: Double, w: Double)] = []
        let a = GroundCloudField.ringRadius, sc = GroundCloudField.coreRadius, e = GroundCloudField.capStretch
        for i in 0..<150 {
            let sr = (Double(i) + 0.5) * 0.02
            for j in 0..<360 {
                let z = -3.6 + (Double(j) + 0.5) * 0.02
                let q = (((sr - a) * (sr - a) + (z / e) * (z / e)).squareRoot()) / sc
                ring.append((q, 2 * .pi * sr * 0.02 * 0.02))
            }
        }
        XCTAssertEqual(ring.reduce(0.0) { $0 + $1.w * gauss($1.q) }, GroundCloudField.ringVolume(1), accuracy: 1e-3,
                       "the ring's volume")
        // The jet's disc on a Cartesian grid, the wall jet's layer.
        var disc: [(q: Double, w: Double)] = []
        for i in 0..<250 {
            for j in 0..<250 {
                let y = -5 + (Double(i) + 0.5) * 0.04, z = -5 + (Double(j) + 0.5) * 0.04
                disc.append(((y * y + z * z).squareRoot(), 0.04 * 0.04))
            }
        }
        let layer = (0..<1_000).map { (q: (Double($0) + 0.5) * 0.004, w: 0.004) }
        for sigma in [0.1, 0.25, 0.5, 0.8] {
            let t = expected(sigma, gauss, ring), r = expected(sigma, gauss, disc)
            let w = expected(sigma, GroundCloudField.wallProfile, layer)
            XCTAssertEqual(GroundCloudField.DisplacementGain.gain(.thermal, spread: sigma), t, accuracy: 0.005 * t, "σ \(sigma)")
            XCTAssertEqual(GroundCloudField.DisplacementGain.gain(.roundJet, spread: sigma), r, accuracy: 0.005 * r, "σ \(sigma)")
            XCTAssertEqual(GroundCloudField.DisplacementGain.gain(.wallJet, spread: sigma), w, accuracy: 0.005 * w, "σ \(sigma)")
            print(String(format: "σ %.2f: gains thermal %.3f, jet %.3f, wall %.3f", sigma, t, r, w))
        }
        XCTAssertGreaterThan(GroundCloudField.DisplacementGain.gain(.thermal, spread: 0.5), 1.25, "a third more uncorrected")
    }

    // A drawn field keeps its mass: a thermal's displaced density over space,
    // every octave close up and the largest few far away, averaged over a
    // few turbulence times, is its undisplaced integral within 3 %; close up,
    // without the gain, it is about a third more (far away about 1 %).
    func testDrawnTurbulenceKeepsTheMass() {
        let p = Self.thermal
        let r = p.radius * 2.6, cell = p.radius / 5
        let lo = p.origin - Vec3(r, r, r * 1.2)
        let n = [Int((2 * r / cell).rounded(.up)), Int((2 * r / cell).rounded(.up)), Int((2.4 * r / cell).rounded(.up))]
        let d = Vec3(2 * r / Double(n[0]), 2 * r / Double(n[1]), 2.4 * r / Double(n[2]))
        for (label, footprint) in [("close", 0.05), ("far", 0.2 * p.radius)] {
            var kept = 0.0, raw = 0.0
            let times = [3.7, 11.3, 19.9, 27.1]
            for t in times {
                let bands = PlumeTurbulence.bands(time: t)
                for i in 0..<n[0] {
                    for j in 0..<n[1] {
                        for k in 0..<n[2] {
                            let x = lo + Vec3((Double(i) + 0.5) * d.x, (Double(j) + 0.5) * d.y, (Double(k) + 0.5) * d.z)
                            let e = LaunchTurbulence.displacementAndSpread(p, at: x, bands: bands, footprint: footprint,
                                                                         noise: LaunchTurbulence.smoothNoise)
                            kept += p.density(at: x, displacement: e.eta, spread: e.spread)
                            raw += p.density(at: x, displacement: e.eta)
                        }
                    }
                }
            }
            let volume = d.x * d.y * d.z / Double(times.count)
            print(String(format: "%@: displaced and kept %.3f, uncorrected %.3f", label, kept * volume, raw * volume))
            XCTAssertEqual(kept * volume, 1, accuracy: 0.03, label)
            if label == "close" { XCTAssertGreaterThan(raw * volume, 1.2, "the bias the gain removes") }
        }
    }

    // The wall jet's noise is laid out in local eddies every way: a metre
    // out along the deck, round it and up moves the noise as far, within a
    // quarter (near the layer's start, where its thickness is far from
    // proportional to the radius, the circle's own growth adds to the
    // radial rate), in units free of the metre.
    func testWallJetNoiseIsIsotropic() throws {
        let f = GroundCloudFieldTests.field(GroundCloudFieldTests.cloud(to: 10), at: 10)
        let wall = try XCTUnwrap(f.primitives.first { $0.shape == .wallJet })
        for rho in [wall.start + 5, 0.5 * (wall.start + wall.end), wall.end - 5] {
            let z = 0.5 * wall.thickness(rho), h = 0.05
            let at = Vec3(rho, 0, z)
            let c = LaunchTurbulence.carried(wall, at: at, age: 0, octave: 0)
            let radial = (LaunchTurbulence.carried(wall, at: Vec3(rho + h, 0, z), age: 0, octave: 0) - c).length / h
            let around = (LaunchTurbulence.carried(wall, at: Vec3(rho * cos(h / rho), rho * sin(h / rho), z), age: 0,
                                                   octave: 0) - c).length / h
            let up = (LaunchTurbulence.carried(wall, at: Vec3(rho, 0, z + h), age: 0, octave: 0) - c).length / h
            let local = 1 / (LaunchTurbulence.integralScale * wall.thickness(rho))
            for (name, rate) in [("radial", radial), ("around", around), ("up", up)] {
                XCTAssertEqual(rate, local, accuracy: 0.25 * local, "\(name) at \(rho) m")
            }
        }
    }

    // The exposure averages each octave as P2 averages its plume's: the flow
    // sweeps u/L integral lengths a second past the point, L the noise's
    // integral length in its cell (P2's `Flow.sweep`, 0.39 of the cell). A
    // trench jet's fifth octave 30 m from its exit keeps about a quarter of
    // its depth, as P2's would.
    func testShutterIsP2s() throws {
        let f = GroundCloudFieldTests.field(GroundCloudFieldTests.cloud(to: 3), at: 3)
        let jet = try XCTUnwrap(f.primitives.first { $0.shape == .roundJet })
        let x = jet.origin + jet.axis * (jet.start + 30)
        let u = jet.speed(at: x), size = jet.size(at: x)
        let spectrum = LaunchTurbulence.spectrum(size: size, speed: u)
        for k in [0, 3, 5] {
            let cell = spectrum.cell(octave: k), life = spectrum.lifetime(octave: k)
            let p2 = PlumeTurbulence.shutterAverage(life: life, sweep: u / (PlumeTurbulence.integralLength * cell)).depth
            XCTAssertEqual(LaunchTurbulence.shutterDepth(speed: u, cell: cell, life: life), p2, accuracy: 1e-12)
            XCTAssertNotEqual(PlumeTurbulence.shutterAverage(life: life, sweep: u / cell).depth, p2, "not u/cell")
        }
        print(String(format: "a trench jet %.0f m from its exit: u %.0f m/s, octave 5 keeps %.2f of its depth", 30.0, u,
                     LaunchTurbulence.shutterDepth(speed: u, cell: spectrum.cell(octave: 5), life: spectrum.lifetime(octave: 5))))
    }
}
