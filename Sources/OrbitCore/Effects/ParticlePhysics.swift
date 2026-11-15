import Foundation

/// The rest of a GPU particle's physics around P1's exact drag step
/// (`ParticleKinematics`): what it weighs and how it drags, Archimedes'
/// buoyancy, growth by entrainment, cooling, and ice sublimating (P3). The
/// GPU particles (OrbitRender's ParticleShaders) run `advance` in Float,
/// line by line; `goldenCases` are the vectors their self-test compares
/// against. Visual only: nothing here feeds back into the simulation.
///
/// A particle is a sphere of `radius`: a solid grain of the material's
/// density, or, for a material of density 0, a parcel of hot gas at the
/// air's pressure, whose density is the air's times Ta / Tp (an ideal gas).
public enum ParticlePhysics {
    /// What a particle is made of, as far as its motion goes.
    public struct Material: Equatable {
        /// kg/m³; 0 for a parcel of gas at its own temperature.
        public var density: Double
        /// Of a sphere: 0.47 subsonic (L for puffs and flakes).
        public var dragCoefficient: Double
        /// Archimedes' buoyancy, scaled: 1 is physical (a hot gas parcel
        /// rises at g (Tp − Ta) / Ta before drag), 0 none.
        public var buoyancy: Double
        /// The entrainment coefficient α: a puff's radius grows by α for
        /// every metre it moves through the air (Morton, Taylor and Turner
        /// 1956, α about 0.1 for plumes, 0.25 for thermals). 0 for grains.
        public var entrainment: Double
        /// Turbulent spreading, m/s: the radius grows at this rate even at
        /// rest in the air (L; 0 for grains).
        public var spreadRate: Double
        /// The time the temperature relaxes towards the air's in, s
        /// (radiation for sparks, mixing for puffs); infinite for none. An
        /// entraining puff's excess is diluted too, as (r0 / r)³.
        public var coolingTime: Double
        /// Water ice, sublimating (`IceSublimation`): the radius shrinks.
        public var sublimates: Bool

        public init(density: Double, dragCoefficient: Double = 0.47, buoyancy: Double = 1, entrainment: Double = 0,
                    spreadRate: Double = 0, coolingTime: Double = .infinity, sublimates: Bool = false) {
            self.density = density
            self.dragCoefficient = dragCoefficient
            self.buoyancy = buoyancy
            self.entrainment = entrainment
            self.spreadRate = spreadRate
            self.coolingTime = coolingTime
            self.sublimates = sublimates
        }
    }

    /// The air at a particle: its density (kg/m³), temperature (K) and
    /// pressure (Pa), and its velocity in the particle's frame (m/s).
    public struct Air: Equatable {
        public var density: Double
        public var temperature: Double
        public var pressure: Double
        public var velocity: Vec3

        public init(density: Double, temperature: Double, pressure: Double, velocity: Vec3 = .zero) {
            self.density = density
            self.temperature = temperature
            self.pressure = pressure
            self.velocity = velocity
        }

        /// No air; 3 K for anything that asks its temperature.
        public static let vacuum = Air(density: 0, temperature: 3, pressure: 0)

        public var isVacuum: Bool { density <= 0 }
    }

    /// A particle's state, in its anchor's frame.
    public struct State: Equatable {
        public var position: Vec3
        public var velocity: Vec3
        /// m; 0 once it has sublimated away.
        public var radius: Double
        /// K.
        public var temperature: Double

        public init(position: Vec3, velocity: Vec3, radius: Double, temperature: Double) {
            self.position = position
            self.velocity = velocity
            self.radius = radius
            self.temperature = temperature
        }
    }

    /// Where it moves, in its anchor's axes: the body's gravity at the
    /// anchor (m/s²), the anchor's own acceleration, and the temperature ice
    /// takes in vacuum there (`IceSublimation.radiativeEquilibriumTemperature`).
    /// A body-fixed anchor stands still (`frameAcceleration` zero); a
    /// free-fall one falls at `gravity` with its particles. In a falling
    /// frame a particle's weight is gone, but not Archimedes' buoyancy (the
    /// static air's pressure gradient), and the air itself accelerates at
    /// −`frameAcceleration`: the slip through the air is the same in either
    /// frame.
    public struct Environment: Equatable {
        public var gravity: Vec3
        public var frameAcceleration: Vec3
        /// The anchor's velocity relative to the body at the frame's epoch,
        /// in its axes (zero for a body-fixed one): a moving anchor was
        /// elsewhere earlier in the step, so the air a particle met then is
        /// looked up where the particle was, not where the anchor is now.
        public var frameVelocity: Vec3
        public var vacuumIceTemperature: Double

        public init(gravity: Vec3, frameAcceleration: Vec3 = .zero, frameVelocity: Vec3 = .zero,
                    vacuumIceTemperature: Double = 200) {
            self.gravity = gravity
            self.frameAcceleration = frameAcceleration
            self.frameVelocity = frameVelocity
            self.vacuumIceTemperature = vacuumIceTemperature
        }

        /// A free-fall anchor's: it falls at the body's gravity, moving at
        /// `velocity` at the frame's epoch.
        public static func freeFall(gravity: Vec3, velocity: Vec3 = .zero, vacuumIceTemperature: Double = 200)
            -> Environment {
            Environment(gravity: gravity, frameAcceleration: gravity, frameVelocity: velocity,
                        vacuumIceTemperature: vacuumIceTemperature)
        }

        /// Where the anchor was at time `t` (s from the frame's epoch,
        /// negative before it), relative to where it is then, in its axes.
        public func frameDisplacement(at t: Double) -> Vec3 {
            frameVelocity * t + frameAcceleration * (0.5 * t * t)
        }
    }

    /// R / cp of dry air: a parcel lifted at the air's pressure cools as
    /// (p' / p)^κ, the dry adiabat's 9.8 K/km.
    public static let adiabaticExponent = 0.2857
    /// γ − 1 for a gas cloud spreading into vacuum, which cools adiabatically
    /// as its volume grows: T ∝ V^−(γ−1).
    public static let expansionExponent = 0.4

    /// The most substeps one advance takes (the GPU's loop bound).
    public static let maxSubsteps = 32

    // MARK: Mass and drag

    /// The particle's density, kg/m³: the material's, or a gas parcel's at
    /// the air's pressure, ρa Ta / Tp.
    public static func density(_ m: Material, temperature: Double, air: Air) -> Double {
        m.density > 0 ? m.density : air.density * air.temperature / max(temperature, 1)
    }

    /// The drag relaxation time, s (`ParticleKinematics.relaxationTime` for
    /// a sphere): (8/3) ρp r / (ρa Cd |v_rel|), written so that a gas parcel
    /// keeps a finite τ as both densities scale together. Infinite in vacuum.
    public static func relaxationTime(_ m: Material, radius r: Double, temperature: Double, air: Air,
                                      relativeSpeed: Double) -> Double {
        guard air.density > 0, relativeSpeed > 0, m.dragCoefficient > 0 else { return .infinity }
        let ratio = m.density > 0 ? m.density / air.density : air.temperature / max(temperature, 1)
        return 8 * ratio * r / (3 * m.dragCoefficient * relativeSpeed)
    }

    /// The time over which a particle falling at its terminal speed relaxes,
    /// v_t / g = sqrt((8/3) ρp r / (ρa Cd g)): with the start's τ, the step
    /// length's scale (`ParticleKinematics.dragStep`).
    static func terminalTime(_ m: Material, radius r: Double, temperature: Double, air: Air, gravity g: Double) -> Double {
        guard air.density > 0, g > 0, m.dragCoefficient > 0 else { return .infinity }
        let ratio = m.density > 0 ? m.density / air.density : air.temperature / max(temperature, 1)
        return (8 * ratio * r / (3 * m.dragCoefficient * g)).squareRoot()
    }

    // MARK: Buoyancy

    /// Gravity less Archimedes' buoyancy, m/s²: g (1 − b ρa / ρp), the
    /// acceleration of the slip through the air whatever the frame. A gas
    /// parcel at the air's temperature floats (b = 1); a hot one rises at
    /// g (Tp − Ta) / Ta before drag; in vacuum there is no buoyancy.
    public static func effectiveGravity(_ m: Material, temperature: Double, air: Air, gravity g: Vec3) -> Vec3 {
        guard air.density > 0, m.buoyancy != 0 else { return g }
        let rho = density(m, temperature: temperature, air: air)
        return g * (1 - m.buoyancy * air.density / max(rho, 1e-12))
    }

    // MARK: Sublimation

    /// A sphere of ice's radius after `dt` s sublimating at `iceTemperature`
    /// into dry air (`IceSublimation.massFlux`), m, exactly: with the flux
    /// E / (1/k + r/D), r/k + r²/(2D) falls at E / ρ_ice, so r is that
    /// quadratic's root. 0 once it is gone. In vacuum (D infinite) the
    /// radius falls at a steady rate.
    public static func sublimatedRadius(_ r: Double, dt: Double, iceTemperature ts: Double, air: Air) -> Double {
        guard r > 0 else { return 0 }
        let r0 = IceSublimation.gasConstant / IceSublimation.molarMass
        let excess = IceSublimation.vaporPressure(temperature: ts) / (r0 * ts)
        let k = (r0 * ts / (2 * Double.pi)).squareRoot()
        let d = IceSublimation.diffusivity(temperature: max(air.temperature, 1), pressure: air.pressure)
        let invK = 1 / k, invD = d.isFinite ? 1 / d : 0
        // F(r) = r/k + r²/(2D); its value after the step, and its root.
        let f = r * invK + 0.5 * r * r * invD - excess * dt / IceSublimation.iceDensity
        guard f > 0 else { return 0 }
        return 2 * f / (invK + (invK * invK + 2 * f * invD).squareRoot())
    }

    /// The temperature the ice is at: the air's in air, its radiative
    /// equilibrium in vacuum.
    static func iceTemperature(air: Air, environment e: Environment) -> Double {
        air.isVacuum ? e.vacuumIceTemperature : air.temperature
    }

    // MARK: The step

    /// The particle after `dt` s. `air` gives the air at a position at the
    /// end of the advance (the frame's epoch: the GPU looks it up in the
    /// anchor's altitude table). The air a particle meets at time t before
    /// then is looked up where it then was, `frameDisplacement(at: t)` from
    /// its position in the anchor (which moved since), and in a falling
    /// frame its velocity was that plus `frameAcceleration` × t. The advance
    /// takes the pieces `schedule` gives, each:
    /// 1. drag and buoyancy on the slip through the air, P1's exact linear
    ///    step, re-linearised about the mean of the slip speeds at the start
    ///    and at the end the start's τ predicts, its radius and temperature
    ///    the means of the start's and the prediction's;
    /// 2. growth by entrainment over the path through the air (the slip's
    ///    own displacement), plus the spreading; the gas mixed as an ideal
    ///    gas at the air's pressure, r³ (1 − Ta/T) kept, and relaxed over
    ///    `coolingTime`;
    /// 3. sublimation, for ice;
    /// 4. between pieces, a gas parcel's adiabatic cooling or warming with
    ///    the air's pressure as it rises or sinks.
    public static func advance(_ s: State, material m: Material, environment e: Environment, dt: Double,
                               air: (Vec3) -> Air) -> State {
        guard dt > 0 else { return s }
        func look(_ p: Vec3, _ t: Double) -> Air { air(p + e.frameDisplacement(at: t)) }
        var a = look(s.position, -dt)
        let plan = schedule(dt: dt, shortest: shortestTime(s, material: m, environment: e, air: a, at: -dt))
        var state = s, elapsed = 0.0, h = plan.first
        for k in 0..<plan.count {
            guard state.radius > 0 else { break }
            let step = k == plan.count - 1 ? dt - elapsed : h
            state = substep(state, material: m, environment: e, dt: step, air: a, at: elapsed - dt)
            elapsed += step
            h *= plan.ratio
            let next = look(state.position, elapsed - dt)
            if m.density <= 0, !a.isVacuum, !next.isVacuum, a.pressure > 0, next.pressure > 0 {
                state.temperature *= pow(next.pressure / a.pressure, adiabaticExponent)
            }
            a = next
        }
        return state
    }

    /// The air's velocity at time `t` (s, from the frame's epoch: negative
    /// before it) and its acceleration, in the anchor's frame; zero in vacuum.
    static func airMotion(_ a: Air, environment e: Environment, at t: Double) -> (velocity: Vec3, acceleration: Vec3) {
        a.isVacuum ? (.zero, .zero) : (a.velocity - e.frameAcceleration * t, -e.frameAcceleration)
    }

    /// The slip's own acceleration: gravity less buoyancy in air; in vacuum,
    /// where the slip is the velocity, gravity less the frame's fall.
    static func slipGravity(_ m: Material, temperature: Double, air a: Air, environment e: Environment) -> Vec3 {
        a.isVacuum ? e.gravity - e.frameAcceleration : effectiveGravity(m, temperature: temperature, air: a, gravity: e.gravity)
    }

    /// The shorter of the drag time and the terminal time at a substep's start.
    static func shortestTime(_ s: State, material m: Material, environment e: Environment, air a: Air,
                             at t: Double) -> Double {
        let u = airMotion(a, environment: e, at: t).velocity
        let g = slipGravity(m, temperature: s.temperature, air: a, environment: e).length
        let tau = relaxationTime(m, radius: s.radius, temperature: s.temperature, air: a,
                                 relativeSpeed: (s.velocity - u).length)
        return min(tau, terminalTime(m, radius: s.radius, temperature: s.temperature, air: a, gravity: g))
    }

    /// The pieces of an advance of `dt` given the start's shortest time:
    /// one when `dt` is at most twice it; equal pieces of at most twice it
    /// while `maxSubsteps` do; else `maxSubsteps` growing geometrically from
    /// it, by `ratio` (at most 2), to add up to `dt`. Quadratic drag's slip
    /// dies as 1/t, so its τ grows with the time since the throw: growing
    /// pieces keep up with it, and a 300 m/s pyro puff aged 1.7 s in one
    /// advance lands where 1/60 s frames take it.
    public static func schedule(dt: Double, shortest: Double) -> (first: Double, ratio: Double, count: Int) {
        guard shortest.isFinite, shortest > 0, dt > 2 * shortest else { return (dt, 1, 1) }
        let x = dt / shortest, n = Double(maxSubsteps)
        if x <= 2 * n {
            let count = Int((x / 2).rounded(.up))
            return (dt / Double(count), 1, count)
        }
        func sum(_ q: Double) -> Double { (pow(q, n) - 1) / (q - 1) }
        if sum(2) <= x { return (dt / sum(2), 2, maxSubsteps) }
        var lo = 1.0, hi = 2.0
        for _ in 0..<40 {
            let mid = 0.5 * (lo + hi)
            if sum(mid) < x { lo = mid } else { hi = mid }
        }
        let q = 0.5 * (lo + hi)
        return (dt / sum(q), q, maxSubsteps)
    }

    /// The exact linear step of the slip w = v − u through air moving at u0
    /// and accelerating at c (P1's `ParticleKinematics.step` on the slip):
    /// the particle's position and velocity, and the slip's displacement,
    /// its path through the air.
    static func slipStep(position x: Vec3, velocity v: Vec3, air u0: Vec3, airAcceleration c: Vec3, gravity g: Vec3,
                         relaxationTime tau: Double, dt h: Double) -> (position: Vec3, velocity: Vec3, slip: Vec3,
                                                                       slipVelocity: Vec3) {
        let w = ParticleKinematics.step(position: .zero, velocity: v - u0, airVelocity: .zero, gravity: g,
                                        relaxationTime: tau, dt: h)
        return (x + u0 * h + c * (0.5 * h * h) + w.position, u0 + c * h + w.velocity, w.position, w.velocity)
    }

    /// One piece of `advance`, starting at time `t` (s from the frame's
    /// epoch), in air `a` looked up at its start: a predictor with the
    /// start's τ, buoyancy, radius and temperature, then the step with each
    /// taken at the mean of the start and the prediction's end.
    public static func substep(_ s: State, material m: Material, environment e: Environment, dt h: Double,
                               air a: Air, at t: Double = 0) -> State {
        let air = airMotion(a, environment: e, at: t)
        let start = (s.velocity - air.velocity).length
        let g0 = slipGravity(m, temperature: s.temperature, air: a, environment: e)
        let tau0 = relaxationTime(m, radius: s.radius, temperature: s.temperature, air: a, relativeSpeed: start)
        let predicted = slipStep(position: s.position, velocity: s.velocity, air: air.velocity,
                                 airAcceleration: air.acceleration, gravity: g0, relaxationTime: tau0, dt: h)
        let guess = grown(s, material: m, air: a, dt: h, path: predicted.slip.length)
        let radius = 0.5 * (s.radius + guess.radius), temperature = 0.5 * (s.temperature + guess.temperature)
        let g = slipGravity(m, temperature: temperature, air: a, environment: e)
        let tau = relaxationTime(m, radius: radius, temperature: temperature, air: a,
                                 relativeSpeed: 0.5 * (start + predicted.slipVelocity.length))
        let moved = slipStep(position: s.position, velocity: s.velocity, air: air.velocity,
                             airAcceleration: air.acceleration, gravity: g, relaxationTime: tau, dt: h)
        let after = grown(s, material: m, air: a, dt: h, path: moved.slip.length)
        var next = State(position: moved.position, velocity: moved.velocity, radius: after.radius,
                         temperature: after.temperature)
        if m.sublimates {
            next.radius = sublimatedRadius(next.radius, dt: h, iceTemperature: iceTemperature(air: a, environment: e),
                                           air: a)
        }
        return next
    }

    /// The radius and temperature after `dt` s and `path` m through the air.
    /// The radius grows by entrainment (none in vacuum) and spreading. In
    /// air the parcel mixes as an ideal gas at the air's pressure: volumes
    /// add and enthalpy is kept, so r³ (1 − Ta/T) is conserved and
    /// T' = Ta / (1 − (r/r')³ (1 − Ta/T)) (Boussinesq's (T − Ta) r³ only
    /// while T is near Ta). Spreading into vacuum cools it adiabatically,
    /// T ∝ V^−(γ−1). Then the temperature relaxes to the air's over
    /// `coolingTime`.
    static func grown(_ s: State, material m: Material, air a: Air, dt h: Double,
                      path: Double) -> (radius: Double, temperature: Double) {
        let vacuum = a.isVacuum
        let radius = s.radius + (vacuum ? 0 : m.entrainment * path) + m.spreadRate * h
        let ambient = vacuum ? Air.vacuum.temperature : a.temperature
        var t = s.temperature
        if radius > s.radius, s.radius > 0, t > 0 {
            let q = s.radius / radius, q3 = q * q * q
            t = vacuum ? t * pow(q3, expansionExponent) : ambient / (1 - q3 * (1 - ambient / t))
        }
        if m.coolingTime.isFinite { t = ambient + (t - ambient) * (m.coolingTime > 0 ? exp(-h / m.coolingTime) : 0) }
        return (radius, t)
    }

    // MARK: Golden vectors

    /// An advance's inputs and the double-precision result, for the GPU's
    /// self-test.
    public struct GoldenCase: Equatable {
        public var name: String
        public var state: State
        public var material: Material
        public var environment: Environment
        public var air: Air
        public var dt: Double
        public var expected: State
    }

    /// Advances across the regimes the effects use, each in air that does
    /// not change along the way: a hot pad puff rising and entraining, a
    /// steam puff drifting in the wind, a frost flake falling and
    /// sublimating, a flake sublimating in sunlit vacuum, a spark cooling in
    /// vacuum, a hot puff over one 1,000× frame, a slab tossed at max q, a
    /// steam puff in a free-falling anchor, a pyro puff thrown at 300 m/s
    /// aged through a 100× frame, and the F-1's exhaust aged 8.9 s.
    public static let goldenCases: [GoldenCase] = {
        let g = Vec3(0, 0, -9.80665)
        let seaLevel = Air(density: 1.2, temperature: 300, pressure: 101_325, velocity: Vec3(4, -1, 0))
        let puff = Material(density: 0, dragCoefficient: 0.5, entrainment: 0.1, spreadRate: 0.2, coolingTime: 30)
        let steam = Material(density: 0, dragCoefficient: 0.5, entrainment: 0.1, spreadRate: 0.5, coolingTime: 8)
        let flake = Material(density: 917, dragCoefficient: 1.2, buoyancy: 1, sublimates: true)
        let spark = Material(density: 3_950, dragCoefficient: 0.47, coolingTime: 1.5)
        let slab = Material(density: 917, dragCoefficient: 1.1)
        let inputs: [(String, State, Material, Environment, Air, Double)] = [
            ("hot pad puff", State(position: Vec3(0, 0, 5), velocity: Vec3(30, 0, 10), radius: 4, temperature: 900),
             puff, Environment(gravity: g), seaLevel, 1.0 / 60),
            ("steam in the wind", State(position: Vec3(10, 0, 20), velocity: .zero, radius: 8, temperature: 330),
             steam, Environment(gravity: g), seaLevel, 0.5),
            ("frost flake in air", State(position: Vec3(0, 0, 300), velocity: Vec3(0, 0, -2), radius: 1.5e-3,
                                         temperature: 300),
             flake, Environment(gravity: g), Air(density: 0.9, temperature: 270, pressure: 70_000), 2.0),
            ("flake in sunlit vacuum", State(position: Vec3(1, 2, 3), velocity: Vec3(0.5, 0, 0), radius: 1e-3,
                                             temperature: 200),
             flake, .freeFall(gravity: g * 0.9, vacuumIceTemperature: 205), .vacuum, 600),
            ("spark in vacuum", State(position: .zero, velocity: Vec3(-40, 90, 5), radius: 2e-4, temperature: 2_600),
             spark, .freeFall(gravity: g * 0.9), .vacuum, 0.8),
            ("hot puff, 1000x frame", State(position: Vec3(0, 0, 50), velocity: Vec3(0, 0, 40), radius: 6,
                                            temperature: 1_200),
             puff, Environment(gravity: g), seaLevel, 16.7),
            ("slab at max q", State(position: Vec3(0, 0, 13_000), velocity: Vec3(-400, 0, 50), radius: 0.08,
                                    temperature: 90),
             slab, Environment(gravity: g * 0.998), Air(density: 0.25, temperature: 217, pressure: 17_000), 0.5),
            ("steam in free fall", State(position: Vec3(3, 0, -2), velocity: Vec3(1, 0, 4), radius: 5, temperature: 400),
             steam, .freeFall(gravity: g), Air(density: 1.1, temperature: 290, pressure: 95_000, velocity: Vec3(2, 0, 30)),
             2.0),
            ("pyro puff at 300 m/s, 100x", State(position: .zero, velocity: Vec3(300, 0, 0), radius: 0.5,
                                                 temperature: 1_500),
             puff, Environment(gravity: g), seaLevel, 1.67),
            ("F-1 exhaust aged 8.9 s", State(position: Vec3(0, 0, 10), velocity: Vec3(1_000, 0, -50), radius: 2,
                                             temperature: 2_000),
             puff, Environment(gravity: g), seaLevel, 8.9),
        ]
        return inputs.map { name, s, m, e, a, dt in
            GoldenCase(name: name, state: s, material: m, environment: e, air: a, dt: dt,
                       expected: advance(s, material: m, environment: e, dt: dt) { _ in a })
        }
    }()
}
