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

    /// Where it moves: the anchor's gravity (m/s²; zero in a free-fall
    /// anchor, which falls with its particles), and the temperature ice
    /// takes in vacuum there (`IceSublimation.radiativeEquilibriumTemperature`).
    public struct Environment: Equatable {
        public var gravity: Vec3
        public var vacuumIceTemperature: Double

        public init(gravity: Vec3, vacuumIceTemperature: Double = 200) {
            self.gravity = gravity
            self.vacuumIceTemperature = vacuumIceTemperature
        }
    }

    /// The most substeps one advance takes (the GPU's loop bound).
    public static let maxSubsteps = 16

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

    /// Gravity less Archimedes' buoyancy, m/s²: g (1 − b ρa / ρp). A gas
    /// parcel at the air's temperature floats (b = 1); a hot one rises at
    /// g (Tp − Ta) / Ta before drag; in vacuum, or in a free-fall anchor
    /// (g = 0), there is none.
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

    /// The particle after `dt` s, through air given by `air` at a position
    /// (the GPU looks it up in the anchor's altitude table), in
    /// `substeps(...)` equal pieces, each:
    /// 1. drag and buoyancy, with P1's exact linear step, τ re-linearised
    ///    about the mean of the relative speeds at the start and at the end
    ///    the start's τ predicts (as `ParticleKinematics.dragStep`);
    /// 2. growth by entrainment over the path through the air, plus the
    ///    spreading;
    /// 3. the temperature's excess diluted by the growth, (r / r')³, and
    ///    relaxed over `coolingTime`;
    /// 4. sublimation, for ice.
    public static func advance(_ s: State, material m: Material, environment e: Environment, dt: Double,
                               air: (Vec3) -> Air) -> State {
        guard dt > 0 else { return s }
        let n = substeps(s, material: m, environment: e, dt: dt, air: air(s.position))
        let h = dt / Double(n)
        var state = s
        for _ in 0..<n {
            guard state.radius > 0 else { break }
            state = substep(state, material: m, environment: e, dt: h, air: air(state.position))
        }
        return state
    }

    /// How many pieces an advance of `dt` takes: one, or as many as make
    /// each at most twice the shorter of the start's τ and the terminal
    /// time, up to `maxSubsteps`.
    public static func substeps(_ s: State, material m: Material, environment e: Environment, dt: Double,
                                air a: Air) -> Int {
        let g = effectiveGravity(m, temperature: s.temperature, air: a, gravity: e.gravity).length
        let tau = relaxationTime(m, radius: s.radius, temperature: s.temperature, air: a,
                                 relativeSpeed: (s.velocity - a.velocity).length)
        let shortest = min(tau, terminalTime(m, radius: s.radius, temperature: s.temperature, air: a, gravity: g))
        guard shortest.isFinite, shortest > 0 else { return 1 }
        return max(1, min(maxSubsteps, Int((dt / (2 * shortest)).rounded(.up))))
    }

    /// One piece of `advance`, in air `a` taken at its start: a predictor
    /// with the start's τ, buoyancy, radius and temperature, then the step
    /// with each taken at the mean of the start and the prediction's end, so
    /// a hot puff that dilutes fast as it entrains is second order too.
    public static func substep(_ s: State, material m: Material, environment e: Environment, dt h: Double,
                               air a: Air) -> State {
        let start = (s.velocity - a.velocity).length
        let g0 = effectiveGravity(m, temperature: s.temperature, air: a, gravity: e.gravity)
        let tau0 = relaxationTime(m, radius: s.radius, temperature: s.temperature, air: a, relativeSpeed: start)
        let predicted = ParticleKinematics.step(position: s.position, velocity: s.velocity, airVelocity: a.velocity,
                                                gravity: g0, relaxationTime: tau0, dt: h)
        let predictedSpeed = (predicted.velocity - a.velocity).length
        let guess = grown(s, material: m, air: a, dt: h, path: h * 0.5 * (start + predictedSpeed))
        let radius = 0.5 * (s.radius + guess.radius), temperature = 0.5 * (s.temperature + guess.temperature)
        let g = effectiveGravity(m, temperature: temperature, air: a, gravity: e.gravity)
        let tau = relaxationTime(m, radius: radius, temperature: temperature, air: a,
                                 relativeSpeed: 0.5 * (start + predictedSpeed))
        let moved = ParticleKinematics.step(position: s.position, velocity: s.velocity, airVelocity: a.velocity,
                                            gravity: g, relaxationTime: tau, dt: h)
        let after = grown(s, material: m, air: a, dt: h, path: h * 0.5 * (start + (moved.velocity - a.velocity).length))
        var next = State(position: moved.position, velocity: moved.velocity, radius: after.radius,
                         temperature: after.temperature)
        if m.sublimates {
            next.radius = sublimatedRadius(next.radius, dt: h, iceTemperature: iceTemperature(air: a, environment: e),
                                           air: a)
        }
        return next
    }

    /// The radius and temperature after `dt` s and `path` m through the air:
    /// grown by entrainment (none in vacuum) and spreading, the excess
    /// temperature diluted by the growth, (r / r')³, and relaxed.
    static func grown(_ s: State, material m: Material, air a: Air, dt h: Double,
                      path: Double) -> (radius: Double, temperature: Double) {
        let radius = s.radius + (a.isVacuum ? 0 : m.entrainment * path) + m.spreadRate * h
        let ambient = a.isVacuum ? Air.vacuum.temperature : a.temperature
        var excess = s.temperature - ambient
        if radius > s.radius, s.radius > 0 {
            let q = s.radius / radius
            excess *= q * q * q
        }
        if m.coolingTime.isFinite { excess *= m.coolingTime > 0 ? exp(-h / m.coolingTime) : 0 }
        return (radius, ambient + excess)
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
    /// vacuum, a hot puff over one 1,000× frame (substeps), and a slab
    /// tossed at max q.
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
             flake, Environment(gravity: .zero, vacuumIceTemperature: 205), .vacuum, 600),
            ("spark in vacuum", State(position: .zero, velocity: Vec3(-40, 90, 5), radius: 2e-4, temperature: 2_600),
             spark, Environment(gravity: .zero), .vacuum, 0.8),
            ("hot puff, 1000x frame", State(position: Vec3(0, 0, 50), velocity: Vec3(0, 0, 40), radius: 6,
                                            temperature: 1_200),
             puff, Environment(gravity: g), seaLevel, 16.7),
            ("slab at max q", State(position: Vec3(0, 0, 13_000), velocity: Vec3(-400, 0, 50), radius: 0.08,
                                    temperature: 90),
             slab, Environment(gravity: g * 0.998), Air(density: 0.25, temperature: 217, pressure: 17_000), 0.5),
        ]
        return inputs.map { name, s, m, e, a, dt in
            GoldenCase(name: name, state: s, material: m, environment: e, air: a, dt: dt,
                       expected: advance(s, material: m, environment: e, dt: dt) { _ in a })
        }
    }()
}
