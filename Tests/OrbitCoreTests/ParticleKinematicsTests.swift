import XCTest
@testable import OrbitCore

/// The exact linear-drag step against the analytic solution and RK4, its
/// ballistic limit, re-linearised quadratic drag, and the golden vectors
/// the GPU self-test uses.
final class ParticleKinematicsTests: XCTestCase {
    typealias K = ParticleKinematics

    /// The closed form from t = 0, per axis: x0 + v∞ t + (v0 - v∞) τ (1 - e^(-t/τ)).
    func analytic(_ x0: Vec3, _ v0: Vec3, air: Vec3, g: Vec3, tau: Double, t: Double) -> (Vec3, Vec3) {
        let vInf = air + g * tau, e = exp(-t / tau), oneMinus = -expm1(-t / tau)
        return (x0 + vInf * t + (v0 - vInf) * (tau * oneMinus), vInf + (v0 - vInf) * e)
    }

    /// Classical RK4 on dv/dt = g + (v_air - v)/τ with a fixed step.
    func rk4(_ x0: Vec3, _ v0: Vec3, air: Vec3, g: Vec3, tau: (Vec3) -> Double, t: Double, h: Double) -> (Vec3, Vec3) {
        func accel(_ v: Vec3) -> Vec3 {
            let k = tau(v)
            return k.isFinite ? g + (air - v) / k : g
        }
        var x = x0, v = v0
        let n = Int((t / h).rounded())
        for _ in 0..<n {
            let a1 = accel(v), v1 = v
            let a2 = accel(v + a1 * (h / 2)), v2 = v + a1 * (h / 2)
            let a3 = accel(v + a2 * (h / 2)), v3 = v + a2 * (h / 2)
            let a4 = accel(v + a3 * h), v4 = v + a3 * h
            x = x + (v1 + v2 * 2 + v3 * 2 + v4) * (h / 6)
            v = v + (a1 + a2 * 2 + a3 * 2 + a4) * (h / 6)
        }
        return (x, v)
    }

    func assertClose(_ a: Vec3, _ b: Vec3, _ tol: Double, _ message: String = "", line: UInt = #line) {
        XCTAssertLessThan((a - b).length, tol, "\(message): \(a) vs \(b)", line: line)
    }

    // One step of any length is the analytic solution, and so are many
    // steps: 1 step of 60 s, 60 of 1 s and 6,000 of 0.01 s agree to rounding.
    func testExactForAnyStep() {
        let x0 = Vec3(10, -4, 300), v0 = Vec3(40, 3, 25), air = Vec3(6, -3, 0), g = Vec3(0, 0, -9.80665)
        for tau in [0.01, 0.3, 4.0, 90.0] {
            let (xa, va) = analytic(x0, v0, air: air, g: g, tau: tau, t: 60)
            for n in [1, 60, 6_000] {
                var x = x0, v = v0
                for _ in 0..<n {
                    (x, v) = K.step(position: x, velocity: v, airVelocity: air, gravity: g, relaxationTime: tau,
                                    dt: 60 / Double(n))
                }
                assertClose(x, xa, 1e-9 * max(1, xa.length), "τ \(tau), \(n) steps")
                assertClose(v, va, 1e-10 * max(1, va.length), "τ \(tau), \(n) steps")
            }
        }
    }

    // Against RK4 at a step 1/1,000 of τ: the same trajectory.
    func testAgainstRK4() {
        let x0 = Vec3(0, 0, 50), v0 = Vec3(20, 0, 15), air = Vec3(3, 4, 0), g = Vec3(0, 0, -9.80665)
        for tau in [0.5, 2.0, 20.0] {
            let (xr, vr) = rk4(x0, v0, air: air, g: g, tau: { _ in tau }, t: 10, h: tau / 1_000)
            let (x, v) = K.step(position: x0, velocity: v0, airVelocity: air, gravity: g, relaxationTime: tau, dt: 10)
            assertClose(x, xr, 1e-8 * max(1, xr.length), "τ \(tau)")
            assertClose(v, vr, 1e-9 * max(1, vr.length), "τ \(tau)")
        }
    }

    // In vacuum (τ infinite) and as τ grows without bound the step is the
    // ballistic parabola, without cancellation.
    func testBallisticLimit() {
        let x0 = Vec3(1, 2, 3), v0 = Vec3(-30, 120, 7), g = Vec3(0, -8.9, 0), t = 2.0
        let parabola = x0 + v0 * t + g * (t * t / 2)
        for tau in [Double.infinity, 1e12] {
            let (x, v) = K.step(position: x0, velocity: v0, airVelocity: Vec3(5, 5, 5), gravity: g,
                                relaxationTime: tau, dt: t)
            assertClose(x, parabola, 1e-5, "τ \(tau)")
            assertClose(v, v0 + g * t, 1e-5, "τ \(tau)")
        }
        XCTAssertEqual(K.relaxationTime(mass: 1, dragArea: 1, density: 0, relativeSpeed: 10), .infinity)
        XCTAssertEqual(K.relaxationTime(mass: 1, dragArea: 1, density: 1.2, relativeSpeed: 0), .infinity)
    }

    // Quadratic drag re-linearised each step follows RK4 on the true
    // quadratic law within 0.5 % at 0.05 s steps (a third of τ), and reaches
    // the terminal velocity √(2 m g / (ρ Cd A)) whatever the step, from
    // above or from rest: a 2 mm ice flake's at sea level, about 6.5 m/s.
    func testQuadraticDragRelinearised() {
        let d = 0.002, rhoIce = 917.0, cd = 0.47, rho = 1.225, g = Vec3(0, 0, -9.80665)
        let mass = rhoIce * Double.pi * d * d * d / 6, area = cd * Double.pi * d * d / 4
        func tau(_ v: Vec3) -> Double { K.relaxationTime(mass: mass, dragArea: area, density: rho, relativeSpeed: v.length) }
        let x0 = Vec3(0, 0, 0), v0 = Vec3(30, 0, 10)
        let (xr, vr) = rk4(x0, v0, air: .zero, g: g, tau: tau, t: 5, h: 1e-4)
        var x = x0, v = v0
        for _ in 0..<100 {
            (x, v) = K.dragStep(position: x, velocity: v, airVelocity: .zero, gravity: g, mass: mass, dragArea: area,
                                airDensity: rho, dt: 0.05)
        }
        XCTAssertLessThan((x - xr).length / xr.length, 0.005)
        XCTAssertLessThan((v - vr).length / vr.length, 0.005)
        let terminal = (2 * mass * 9.80665 / (rho * area)).squareRoot()
        XCTAssertEqual(terminal, 6.5, accuracy: 0.2)
        XCTAssertEqual(K.sphereRelaxationTime(diameter: d, materialDensity: rhoIce, dragCoefficient: cd, airDensity: rho,
                                              relativeSpeed: 10), tau(Vec3(10, 0, 0)), accuracy: 1e-12)
        for start in [v0, Vec3.zero] {
            for dt in [0.01, 1.0, 100.0] {
                var x = x0, v = start
                for _ in 0..<Int(200 / dt) {
                    (x, v) = K.dragStep(position: x, velocity: v, airVelocity: .zero, gravity: g, mass: mass,
                                        dragArea: area, airDensity: rho, dt: dt)
                }
                XCTAssertEqual(v.length, terminal, accuracy: 1e-3 * terminal, "from \(start), Δt \(dt)")
                XCTAssertEqual(v.z, -terminal, accuracy: 1e-3 * terminal, "from \(start), Δt \(dt)")
            }
        }
        // In vacuum the drag step is the ballistic one.
        let (xb, vb) = K.dragStep(position: x0, velocity: v0, airVelocity: .zero, gravity: g, mass: mass,
                                  dragArea: area, airDensity: 0, dt: 3)
        assertClose(xb, x0 + v0 * 3 + g * 4.5, 1e-12)
        assertClose(vb, v0 + g * 3, 1e-12)
    }

    // The golden vectors are the double-precision step, and that step is
    // the analytic solution (or the parabola) for each.
    func testGoldenCases() {
        XCTAssertEqual(K.goldenCases.count, 6)
        for c in K.goldenCases {
            let (x, v) = c.relaxationTime.isFinite
                ? analytic(c.position, c.velocity, air: c.airVelocity, g: c.gravity, tau: c.relaxationTime, t: c.dt)
                : (c.position + c.velocity * c.dt + c.gravity * (c.dt * c.dt / 2), c.velocity + c.gravity * c.dt)
            assertClose(c.expectedPosition, x, 1e-9 * max(1, x.length), c.name)
            assertClose(c.expectedVelocity, v, 1e-9 * max(1, v.length), c.name)
        }
    }
}
