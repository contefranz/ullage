import Foundation

/// A particle in air under gravity and linear drag, advanced exactly: with
/// dv/dt = g + (v_air - v)/τ the velocity relaxes towards the terminal
/// velocity v∞ = v_air + g τ, so over a step Δ, with s = Δ/τ,
///
///     v(Δ) = v∞ + (v - v∞) e^-s
///     x(Δ) = x + v∞ Δ + (v - v∞) τ (1 - e^-s)
///
/// (written below in a form that stays exact as τ grows without bound, the
/// ballistic limit in vacuum). It is stable for any step, so time warp needs
/// no substeps. Quadratic drag is re-linearised each step: τ = m / (½ ρ Cd A
/// |v_rel|), about a predicted mean speed (`dragStep`). The GPU particles
/// (P3) run the same step in Float; `goldenCases` are the vectors their
/// self-test compares against.
public enum ParticleKinematics {
    /// (1 - e^-s)/s and (s - 1 + e^-s)/s², their series where s is small.
    static func phi(_ s: Double) -> (one: Double, two: Double) {
        if s < 1e-4 {
            return (1 - s / 2 + s * s / 6, 0.5 - s / 6 + s * s / 24)
        }
        let one = -expm1(-s) / s
        return (one, (1 - one) / s)
    }

    /// The position and velocity after `dt` s from `position` and
    /// `velocity`, in air moving at `airVelocity`, under `gravity` (m/s²),
    /// with drag relaxation time `relaxationTime` (s; infinite: no drag;
    /// zero: carried with the air).
    public static func step(position x: Vec3, velocity v: Vec3, airVelocity air: Vec3, gravity g: Vec3,
                            relaxationTime tau: Double, dt: Double) -> (position: Vec3, velocity: Vec3) {
        // τ = 0: the particle moves with the air at once.
        let s = tau > 0 ? (tau.isFinite ? dt / tau : 0) : .infinity
        let (p1, p2) = phi(s)
        let decay = exp(-s)
        let slip = v - air
        let velocity = air + slip * decay + g * (dt * p1)
        let position = x + air * dt + slip * (dt * p1) + g * (dt * dt * p2)
        return (position, velocity)
    }

    /// A step under quadratic drag (`mass` kg, `dragArea` Cd A m²,
    /// `airDensity` kg/m³), re-linearised about the mean of the relative
    /// speeds at the start and at the end the start's τ predicts: second
    /// order in the step. A step longer than twice the shorter of the
    /// start's τ and the terminal one (v_t/g) is split into as many equal
    /// substeps, at most 64, so a long one still lands on the terminal
    /// velocity, where a single linearisation would swing between v_t²/v
    /// and v.
    public static func dragStep(position x: Vec3, velocity v: Vec3, airVelocity air: Vec3, gravity g: Vec3,
                                mass: Double, dragArea: Double, airDensity: Double,
                                dt: Double) -> (position: Vec3, velocity: Vec3) {
        let k = 0.5 * airDensity * dragArea
        guard k > 0, mass > 0 else {
            return step(position: x, velocity: v, airVelocity: air, gravity: g, relaxationTime: .infinity, dt: dt)
        }
        let tau0 = relaxationTime(mass: mass, dragArea: dragArea, density: airDensity, relativeSpeed: (v - air).length)
        let terminalTau = g.length > 0 ? (mass / (k * g.length)).squareRoot() : Double.infinity
        let shortest = min(tau0, terminalTau)
        let n = shortest.isFinite ? max(1, min(64, Int((dt / (2 * shortest)).rounded(.up)))) : 1
        let h = dt / Double(n)
        var state = (position: x, velocity: v)
        for _ in 0..<n {
            let start = (state.velocity - air).length
            let tau = relaxationTime(mass: mass, dragArea: dragArea, density: airDensity, relativeSpeed: start)
            let predicted = step(position: state.position, velocity: state.velocity, airVelocity: air, gravity: g,
                                 relaxationTime: tau, dt: h)
            let mean = 0.5 * (start + (predicted.velocity - air).length)
            state = step(position: state.position, velocity: state.velocity, airVelocity: air, gravity: g,
                         relaxationTime: relaxationTime(mass: mass, dragArea: dragArea, density: airDensity,
                                                        relativeSpeed: mean), dt: h)
        }
        return state
    }

    /// The relaxation time of a particle of mass `mass` (kg) and drag area
    /// `dragArea` (Cd A, m²) at `relativeSpeed` (m/s) through air of
    /// `density` (kg/m³): m / (½ ρ Cd A |v_rel|). Infinite in vacuum or at
    /// rest relative to the air.
    public static func relaxationTime(mass: Double, dragArea: Double, density: Double,
                                      relativeSpeed: Double) -> Double {
        let k = 0.5 * density * dragArea * relativeSpeed
        return k > 0 ? mass / k : .infinity
    }

    /// The same for a sphere of `diameter` (m) and `materialDensity`
    /// (kg/m³) with drag coefficient `dragCoefficient`.
    public static func sphereRelaxationTime(diameter d: Double, materialDensity rho: Double, dragCoefficient cd: Double,
                                            airDensity: Double, relativeSpeed: Double) -> Double {
        let mass = rho * Double.pi * d * d * d / 6
        return relaxationTime(mass: mass, dragArea: cd * Double.pi * d * d / 4, density: airDensity,
                              relativeSpeed: relativeSpeed)
    }

    /// A step's inputs and the double-precision result, for the GPU
    /// integrator's self-test.
    public struct GoldenCase: Equatable {
        public var name: String
        public var position: Vec3
        public var velocity: Vec3
        public var airVelocity: Vec3
        public var gravity: Vec3
        public var relaxationTime: Double
        public var dt: Double
        public var expectedPosition: Vec3
        public var expectedVelocity: Vec3
    }

    /// Steps across the regimes the effects use: a frost flake falling
    /// through the pad's wind, a slab tossed at max q, a spark in vacuum
    /// (ballistic), smoke relaxing in one step of a 1,000× frame, a step far
    /// shorter than τ and a body-fixed anchor's particle at rest.
    public static let goldenCases: [GoldenCase] = {
        let g = Vec3(0, 0, -9.80665)
        let inputs: [(String, Vec3, Vec3, Vec3, Vec3, Double, Double)] = [
            ("frost flake, pad wind", Vec3(0, 0, 100), Vec3(0, 0, 0), Vec3(5, -2, 0), g, 0.2, 1.0 / 60),
            ("slab at max q", Vec3(0, 0, 13_000), Vec3(400, 0, 50), Vec3(10, 0, 0), g * 0.998, 8.0, 0.5),
            ("spark in vacuum", Vec3(1, 2, 3), Vec3(-30, 120, 7), .zero, Vec3(0, -8.9, 0), .infinity, 2.0),
            ("smoke, 1000x frame", Vec3(0, 0, 50), Vec3(20, 0, 15), Vec3(3, 4, 0), g, 1.5, 16.7),
            ("short step", Vec3(-5, 0, 0), Vec3(1, 1, 1), Vec3(0, 0, 0), g, 1e6, 1e-3),
            ("at rest in the anchor", .zero, .zero, .zero, .zero, 0.5, 0.25),
        ]
        return inputs.map { name, x, v, air, gravity, tau, dt in
            let r = step(position: x, velocity: v, airVelocity: air, gravity: gravity, relaxationTime: tau, dt: dt)
            return GoldenCase(name: name, position: x, velocity: v, airVelocity: air, gravity: gravity,
                              relaxationTime: tau, dt: dt, expectedPosition: r.position, expectedVelocity: r.velocity)
        }
    }()
}
