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
}
