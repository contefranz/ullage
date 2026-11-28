import Foundation
import XCTest
import OrbitCore
@testable import OrbitScene

/// LR5 PR2's trail column on the CPU: its closed forms against the models
/// they are derived from.
final class TrailColumnTests: XCTestCase {
    /// The coflow's closed form against `JetPath.path` (read-only, its
    /// second-order Runge-Kutta within 0.1 %) in a pure coflow: an F-1's
    /// momentum-equivalent jet into still air and coflows of 50, 265 and
    /// 1,200 m/s, from the source and from a station part way (a hand-over):
    /// the half-width and the distance travelled at each station's age
    /// (∫ ds / u along the stations) within 0.5 %.
    func testCoflowIsJetPaths() {
        let d = 1.0, uj = 2_600.0
        for stream in [0.0, 50, 265, 1_200] {
            let path = JetPath.path(diameter: d, speed: uj, direction: .unitX, stream: Vec3(stream, 0, 0),
                                    length: 600 * d)
            XCTAssertGreaterThan(path.count, 100)
            var ages = [0.0]
            for k in 1..<path.count {
                let a = path[k - 1], b = path[k]
                ages.append(ages[k - 1] + (b.distance - a.distance) * 0.5 * (1 / a.velocity.length + 1 / b.velocity.length))
            }
            for start in [0, path.count / 3] {
                let s0 = path[start]
                let c = TrailColumn.Coflow(halfWidth: s0.halfWidth, excess: s0.velocity.length - stream, stream: stream)
                var worst = (width: 0.0, distance: 0.0)
                for k in stride(from: start + 1, to: path.count, by: 7) {
                    let t = ages[k] - ages[start], s = c.state(age: t)
                    let travelled = s.drift + stream * t, want = path[k].distance - s0.distance
                    worst.width = max(worst.width, abs(s.halfWidth / path[k].halfWidth - 1))
                    worst.distance = max(worst.distance, abs(travelled / want - 1))
                    XCTAssertEqual(s.excess, path[k].velocity.length - stream, accuracy: 0.005 * (path[k].velocity.length - stream))
                }
                print(String(format: "TrailColumnTests: coflow %4.0f m/s from station %d: width within %.4f %%, distance within %.4f %%",
                             stream, start, 100 * worst.width, 100 * worst.distance))
                XCTAssertLessThan(worst.width, 0.005, "\(stream) m/s from \(start)")
                XCTAssertLessThan(worst.distance, 0.005, "\(stream) m/s from \(start)")
            }
        }
    }

    /// The closed form's limits: still air's b² = (y0² + 4 α1 m^(3/2) t) / m,
    /// and in a strong coflow b³ growing linearly in t at 3 α1 m / U
    /// (b³ ≈ b0³ + 3 α1 (m / U) t once Δ ≪ U).
    func testCoflowLimits() {
        let still = TrailColumn.Coflow(halfWidth: 2, excess: 100, stream: 0)
        let m = still.excessMomentum, y0 = still.flux
        for t in [0.0, 0.1, 1, 10, 100] {
            let b2 = (y0 * y0 + 4 * JetPath.shearEntrainment * pow(m, 1.5) * t) / m
            XCTAssertEqual(still.state(age: t).halfWidth, b2.squareRoot(), accuracy: 1e-9 * b2.squareRoot())
        }
        let weak = TrailColumn.Coflow(halfWidth: 20, excess: 1, stream: 400)
        let s1 = weak.state(age: 100), s2 = weak.state(age: 200)
        let rate = 3 * JetPath.shearEntrainment * weak.excessMomentum / 400
        let slope = (pow(s2.halfWidth, 3) - pow(s1.halfWidth, 3)) / 100
        XCTAssertEqual(slope, rate, accuracy: 0.01 * rate)
        XCTAssertEqual(weak.state(age: 0).halfWidth, 20, accuracy: 1e-12)
        XCTAssertEqual(weak.state(age: 0).drift, 0, accuracy: 1e-12)
    }

    /// The line thermal against Briggs (1975): in neutral air the bent-over
    /// rise 1.6 F^(1/3) x^(2/3) / U, F = B U / π, within 1 %; in stable air
    /// the final rise 2.6 (F / (U s))^(1/3), s = N², within 2 %, reached at
    /// N t = π and held; and against its own equations, d(π β² z² ż)/dt = B,
    /// dB/dt = −N² π β² z² ż, in 100,000 small steps, within 1e-4.
    func testLineThermalIsBriggs() {
        let b = 2_000.0, u = 300.0, f = b * u / Double.pi
        let neutral = TrailColumn.LineThermal(buoyancy: b, frequency: 0)
        for t in [1.0, 10, 100] {
            let briggs = 1.6 * cbrt(f) * pow(u * t, 2.0 / 3) / u
            XCTAssertEqual(neutral.rise(age: t), briggs, accuracy: 0.01 * briggs, "\(t) s")
        }
        let n = 0.012
        let stable = TrailColumn.LineThermal(buoyancy: b, frequency: n)
        let final = 2.6 * cbrt(f / (u * n * n))
        XCTAssertEqual(stable.rise(age: Double.pi / n), final, accuracy: 0.02 * final)
        XCTAssertEqual(stable.rise(age: 3 * Double.pi / n), stable.rise(age: Double.pi / n), "held at its peak")
        // The equations, stepped.
        let beta2 = TrailColumn.LineThermal.entrainment * TrailColumn.LineThermal.entrainment
        var p = 0.0, buoy = b, t = 0.0
        let end = 0.9 * Double.pi / n, steps = 100_000, dt = end / Double(steps)
        for _ in 0..<steps {
            // Midpoint.
            let pm = p + 0.5 * dt * buoy, bm = buoy - 0.5 * dt * n * n * p
            p += dt * bm
            buoy -= dt * n * n * pm
            t += dt
        }
        // π β² z³ / 3 = ∫ p dt = (B / N²)(1 − cos N t), here the stepped p's integral.
        let z = cbrt(3 * (b - buoy) / (n * n) / (Double.pi * beta2))
        XCTAssertEqual(stable.rise(age: t), z, accuracy: 1e-4 * z)
        XCTAssertEqual(stable.speed(age: t), p / (Double.pi * beta2 * z * z), accuracy: 1e-4 * stable.speed(age: t))
    }

    /// Konopka's covariance against its equations, dΣ/dt = A Σ + Σ Aᵀ + 2D,
    /// stepped 1,000 times (fourth-order Runge-Kutta), to 1e-6 relative,
    /// for a sheared, tilted start over ten minutes.
    func testKonopkaAgainstSmallSteps() {
        let start = TrailColumn.Spread(yy: 400, yz: 120, zz: 250)
        let s = 0.004, dh = 15.0, dv = 0.15, ds = 0.4, t = 600.0
        let closed = start.sheared(after: t, shear: s, horizontal: dh, vertical: dv, cross: ds)
        func rate(_ x: TrailColumn.Spread) -> TrailColumn.Spread {
            TrailColumn.Spread(yy: 2 * s * x.yz + 2 * dh, yz: s * x.zz + 2 * ds, zz: 2 * dv)
        }
        func add(_ a: TrailColumn.Spread, _ b: TrailColumn.Spread, _ h: Double) -> TrailColumn.Spread {
            TrailColumn.Spread(yy: a.yy + h * b.yy, yz: a.yz + h * b.yz, zz: a.zz + h * b.zz)
        }
        var x = start
        let h = t / 1_000
        for _ in 0..<1_000 {
            let k1 = rate(x), k2 = rate(add(x, k1, h / 2)), k3 = rate(add(x, k2, h / 2)), k4 = rate(add(x, k3, h))
            x = TrailColumn.Spread(yy: x.yy + h / 6 * (k1.yy + 2 * k2.yy + 2 * k3.yy + k4.yy),
                                   yz: x.yz + h / 6 * (k1.yz + 2 * k2.yz + 2 * k3.yz + k4.yz),
                                   zz: x.zz + h / 6 * (k1.zz + 2 * k2.zz + 2 * k3.zz + k4.zz))
        }
        XCTAssertEqual(closed.yy, x.yy, accuracy: 1e-6 * x.yy)
        XCTAssertEqual(closed.yz, x.yz, accuracy: 1e-6 * abs(x.yz))
        XCTAssertEqual(closed.zz, x.zz, accuracy: 1e-6 * x.zz)
        // A round start in no shear grows by 2 D t each way.
        let round = TrailColumn.Spread(sigma: 20).sheared(after: 100, shear: 0, horizontal: 5, vertical: 5)
        XCTAssertEqual(round.principal.major, (400.0 + 1_000).squareRoot(), accuracy: 1e-9)
    }

    /// Troen and Mahrt's profile: zero at the ground and at z_i, its
    /// largest κ w* z_i (4/27) at z_i/3.
    func testMixedLayerDiffusivity() {
        let zi = 1_200.0, w = 1.8
        XCTAssertEqual(TrailColumn.mixedLayerDiffusivity(height: 0, top: zi, convective: w), 0)
        XCTAssertEqual(TrailColumn.mixedLayerDiffusivity(height: zi, top: zi, convective: w), 0)
        XCTAssertEqual(TrailColumn.mixedLayerDiffusivity(height: zi / 3, top: zi, convective: w), 0.4 * w * zi * 4 / 27,
                       accuracy: 1e-9)
        XCTAssertEqual(TrailColumn.mixedLayerDiffusivity(height: 2 * zi, top: zi, convective: w), 0)
    }

    /// Schumann's (2012) plume above the mixed layer against his equations
    /// stepped 1,000 times, D_H following the plume's depth (D² = 8 σzz) as
    /// it grows: to 1e-6 over twenty minutes.
    func testSchumannAgainstSmallSteps() {
        let start = TrailColumn.Spread(yy: 900, yz: -50, zz: 300)
        let s = 0.006, st = 0.008, n = 0.012, w = 0.1, t = 1_200.0
        let closed = start.schumann(after: t, normalShear: s, totalShear: st, frequency: n, turbulence: w)
        let dv = 0.2 * w * w / n
        func rate(_ x: TrailColumn.Spread) -> TrailColumn.Spread {
            let dh = 0.1 * 8 * x.zz * st
            return TrailColumn.Spread(yy: 2 * s * x.yz + 2 * dh, yz: s * x.zz, zz: 2 * dv)
        }
        func add(_ a: TrailColumn.Spread, _ b: TrailColumn.Spread, _ h: Double) -> TrailColumn.Spread {
            TrailColumn.Spread(yy: a.yy + h * b.yy, yz: a.yz + h * b.yz, zz: a.zz + h * b.zz)
        }
        var x = start
        let h = t / 1_000
        for _ in 0..<1_000 {
            let k1 = rate(x), k2 = rate(add(x, k1, h / 2)), k3 = rate(add(x, k2, h / 2)), k4 = rate(add(x, k3, h))
            x = TrailColumn.Spread(yy: x.yy + h / 6 * (k1.yy + 2 * k2.yy + 2 * k3.yy + k4.yy),
                                   yz: x.yz + h / 6 * (k1.yz + 2 * k2.yz + 2 * k3.yz + k4.yz),
                                   zz: x.zz + h / 6 * (k1.zz + 2 * k2.zz + 2 * k3.zz + k4.zz))
        }
        XCTAssertEqual(closed.yy, x.yy, accuracy: 1e-6 * x.yy)
        XCTAssertEqual(closed.yz, x.yz, accuracy: 1e-6 * abs(x.yz))
        XCTAssertEqual(closed.zz, x.zz, accuracy: 1e-6 * x.zz)
        // Schumann's typical values (his §2.10): N 0.01-0.03 1/s give D_V
        // 0.07-0.2 m²/s; D_H 1-10 m²/s for S 1e-3-1e-2 1/s at D 100 m.
        XCTAssertEqual(0.2 * 0.01 / 0.01, 0.2, accuracy: 1e-12)
        let d2 = 100.0 * 100.0
        XCTAssertEqual(0.1 * d2 * 0.001, 1, accuracy: 1e-12)
        XCTAssertEqual(0.1 * d2 * 0.01, 10, accuracy: 1e-12)
    }

    /// A node like AS-506's at T+60 s (P2's column: depth 1.24, cross-section
    /// 74 m, albedo 0.58; the jet 15 m in half-width, 47 m/s over a 265 m/s
    /// airspeed; 13 t/s of exhaust at 11.7 MJ/kg less a quarter radiated),
    /// in air at 7 km, above the mixed layer.
    func node(laidAt t: Double = 0, position: Vec3 = .zero) -> TrailColumn.Node {
        let column = PlumeAirflow.Column(depth: 1.24, crossSection: 74, sootCrossSection: 30, scatteringCrossSection: 42.9,
                                         asymmetry: 0.35, lineDensity: 49.8)
        let air = TrailColumn.Air(height: 7_000, mixedLayerTop: 1_000, convective: 1.5, frequency: 0.011, normalShear: 0.004,
                                  totalShear: 0.006, density: 0.59, temperature: 242)
        return TrailColumn.Node(laid: Epoch(tdbSecondsPastJ2000: t), position: position, tangent: Vec3(0.6, 0, 0.8),
                                up: .unitZ, wind: Vec3(0, 12, 0), spacing: 25, column: column,
                                coflow: TrailColumn.Coflow(halfWidth: 15, excess: 47, stream: 265),
                                heat: 49.8 * 11.7e6 * 0.75, air: air, window: 2 * 42)
    }

    /// A line of nodes 25 m apart carries P2's column on: just laid (a
    /// twentieth of the way through its fade, divided by the fade), its depth
    /// side-on within 1 % of the column's and its extinction per metre the
    /// column's; by the fade's end, a quarter of a second on, the jet's
    /// coflow growth (its excess still 18 % of the airspeed) and the thermal
    /// have widened it some 7 %, and it is as deep as that width gives; a node's
    /// extinction is conserved as it spreads, and fades in linearly.
    func testNodesCarryTheColumn() {
        let n0 = node()
        func line(age: Double) -> [GaussianMedium] {
            (-20...20).map { k -> GaussianMedium in
                var n = node()
                n.position = n0.tangent * (25 * Double(k))
                return n.medium(age: age)
            }
        }
        // Side-on through the middle node's centre (risen and drifted with
        // the rest), across the line (horizontal), over its fade.
        let across = n0.tangent.cross(n0.up).normalized
        func depth(age: Double) -> Double {
            let l = line(age: age), middle = l[20].centre
            return l.reduce(0.0) { $0 + $1.ray(origin: middle - across * 2_000, direction: across).total } / n0.fade(age: age)
        }
        XCTAssertEqual(depth(age: 0.05 * n0.fadeIn), 1.24, accuracy: 0.01 * 1.24)
        // Once faded in, the column's 74 m² a metre over its grown width
        // (horizontal, side-on), about 7 % less deep.
        let grown = 74 / ((2 * Double.pi).squareRoot() * n0.spread(age: n0.fadeIn).yy.squareRoot())
        XCTAssertEqual(depth(age: n0.fadeIn), grown, accuracy: 0.01 * grown)
        XCTAssertLessThan(grown, 0.95 * 1.24)
        XCTAssertEqual(line(age: n0.fadeIn)[20].extinctionCrossSection, 74 * 25, accuracy: 1e-9 * 74 * 25)
        for a in [0.0, 0.5 * n0.fadeIn, 60, 600] {
            XCTAssertEqual(n0.medium(age: a).extinctionCrossSection, 74 * 25 * n0.fade(age: a), accuracy: 1e-6 * 74 * 25,
                           "conserved at \(a) s")
        }
        XCTAssertEqual(n0.fade(age: n0.fadeIn), 1, accuracy: 1e-9)
        XCTAssertLessThan(n0.fadeIn, 84 / 265.0, "the jet's drift carries it across sooner")
        XCTAssertEqual(n0.fade(age: 0.1), n0.travelled(age: 0.1) / 84, accuracy: 1e-12)
    }

    /// Over minutes a node spreads (the coflow first, then the thermal and
    /// the sheared turbulence), rises with its heat and drifts on the wind;
    /// its line stays smooth: nodes 0.6 of their spacing wide along it.
    func testNodesGrowRiseAndDrift() {
        let n = node()
        var previous = 0.0
        for a in [0.0, 1, 10, 60, 300] {
            let p = n.spread(age: a).principal
            XCTAssertGreaterThanOrEqual(p.major, previous)
            previous = p.major
        }
        let late = n.medium(age: 300)
        XCTAssertGreaterThan(late.sigma.y, 3 * n.startWidth)
        XCTAssertGreaterThan(n.thermal.rise(age: 300), 50)
        XCTAssertEqual((n.centre(age: 300) - n.centre(age: 0)).dot(Vec3(0, 1, 0)), 12 * 300, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(n.medium(age: 0).sigma.x, 0.6 * 25)
    }
}
