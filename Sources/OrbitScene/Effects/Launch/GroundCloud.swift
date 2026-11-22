import Foundation
import OrbitCore

/// The launch's ground cloud, sized from its physics: what the S-IC's
/// exhaust and the pad's water put into the air under the vehicle, the two
/// jets the flame deflector turns it into, north and south out of the flame
/// trench, and the buoyant cloud each jet feeds, rising and growing as it
/// entrains the air (`LaunchEffects` fills them with particles). Site frame
/// (`LC39A`): x north, y west, z up from the ML deck, m.
///
/// Sources, each instant, from the core: the F-1s' flow ṁ and thrust (the
/// terminal count's before first motion, the scene's after), the shares of
/// the exhaust that reach the ground down the opening and onto the deck
/// with the climb (`PadExhaust.shares`), and the deluge's water.
///
/// - Heat: each kilogram of exhaust brings its stagnation enthalpy above
///   the air's, c_p (T_c − T_a) at the chamber's temperature (CEA: c_p from
///   the exit's γ and molar mass, `ApolloExhaust.f1`), and the heat of
///   burning its CO and H2 in the air it mixes with (CEA's exit fractions:
///   the trench's afterburning flames), 11.7 MJ/kg in all. The sooty flames
///   radiate a share away (`radiantFraction`, L); the water takes what heats
///   it to boiling and boils it. The rest is the clouds' heat Q, and their
///   buoyancy flux F = g Q / (ρ_a c_pa T_a) (Boussinesq): about 3 × 10⁶
///   m⁴/s³ at full thrust, a large wildfire's hundred-fold.
/// - Momentum: the deflector turns the trench's share of the thrust into two
///   horizontal jets, each keeping what an inviscid jet keeps on striking the
///   wedge's face and turning along the trench's floor (`deflectorMomentum`).
/// - The jets are round momentum jets from the deflector (Fischer et al.
///   1979, Table 9.1): centreline speed 7.0 √(M/ρ) / x, half-width 0.107 x,
///   volume flux 0.25 √(M/ρ) x, x from the deflector. The trench's half
///   length (68.6 m) then leaves them 7.3 m in half-width at the exits, the
///   exits' own size, at about 270 m/s. Their fronts run at half the
///   centreline speed (a starting jet, Turner 1962) along the ground, out to
///   where buoyancy lifts them, `jetRunout` jet lengths l_M = (M/ρ)^¾ / F^½
///   (the length over which a buoyant jet forgets its momentum).
/// - The deck: once the plume outgrows the ML's opening, what strikes the
///   deck turns into a radial wall jet with all its momentum (a jet on a
///   plate), at the same law from the pad's axis: a third cloud, over the
///   pad, fed as the vehicle climbs.
/// - The clouds: one Morton-Taylor-Turner (1956) thermal per jet, fed at
///   its jet's end with the jet's volume and buoyancy (the deck's centred
///   on the pad, its wall jet all round it): dV/dt = 4π R² α |w| +
///   Q_jet, d(V w)/dt = B, dB/dt = F − N² V w, α the thermal's 0.25 and N²
///   the sounding's stability, drifting on the wind at its height. Resting
///   on the ground until it lifts: its centre no lower than its radius.
///
/// Apollo 10's and 16's clouds are the plausibility check, not a fit
/// (NASA CR-61326, Fig. E-9; TM X-2935, Figs. 3 and 4): two lobes from the
/// trench, the cloud some 750 m across at 15 s and 1.2 km at 30 s, its top
/// near 0.5 km at 30 s and 1 km at 60 s, stabilising near 2 km
/// (`GroundCloudTests`).
///
/// The state is integrated on a fixed grid from the first engine's start
/// command (`step`), so frames and a rebuilt history agree.
public struct GroundCloud: Equatable {
    // MARK: Constants

    /// Round momentum jets (Fischer et al. 1979, Table 9.1; H for the law).
    public static let jetVelocity = 7.0
    public static let jetSpread = 0.107
    public static let jetVolume = 0.25
    /// A starting jet's front moves at about half its centreline speed
    /// (Turner 1962, M).
    public static let jetFront = 0.5
    /// The jets run along the ground for this many jet lengths before
    /// buoyancy lifts them into their clouds (L: a wall jet's lift-off).
    public static let jetRunout = 3.0
    /// The entrainment coefficient of a thermal (Morton, Taylor and Turner
    /// 1956; Scorer's laboratory thermals: 0.25, M).
    public static let thermalEntrainment = 0.25
    /// The flame deflector's two-way wedge, 12 m high over its 23 m length
    /// (LC39A datasheet §8, MOON p. 537): each face 46° from the horizontal.
    /// A vertical jet striking it keeps its momentum along the face, sin θ
    /// of it; turned along the trench's floor, cos θ of that (inviscid,
    /// derived, L): half of it.
    public static let deflectorFaceAngle = atan(12.0 / 11.5)
    public static var deflectorMomentum: Double { sin(deflectorFaceAngle) * cos(deflectorFaceAngle) }
    /// The share of the heat the sooty flames radiate away (L: a kerosene
    /// pool fire's 0.2-0.35).
    public static let radiantFraction = 0.25
    /// The F-1's exhaust at its exit (CEA row F-1, tools/data/
    /// cea_apollo_exhaust.csv, H for the run): mole fractions of CO and H2,
    /// and the heats of burning them to CO2 and water vapour, J/mol.
    public static let exhaustCO = 0.34563, exhaustH2 = 0.10308, exhaustH2O = 0.33704
    public static let combustionCO = 283_000.0, combustionH2 = 241_800.0
    /// Air's specific heat, J/(kg K); water's, its latent heat at 373 K.
    public static let airHeat = 1_005.0
    public static let waterHeat = 4_186.0, waterLatent = 2_257_000.0
    /// A US gallon of water, kg, and a minute, s: the deluge's gpm.
    public static let gallon = 3.785411784, minute = 60.0
    /// The cloud's grid step, s.
    public static let step = 0.05

    /// The heat a kilogram of F-1 exhaust brings to the air at `ambient` K,
    /// J/kg: its stagnation enthalpy above the air's and its afterburning.
    public static func exhaustHeat(ambient: Double) -> Double {
        let spec = ApolloExhaust.f1.spec
        let r = 8.314462618 / spec.molarMass
        let cp = spec.exitGamma * r / (spec.exitGamma - 1)
        let burning = (exhaustCO * combustionCO + exhaustH2 * combustionH2) / spec.molarMass
        return cp * (spec.chamberTemperature - ambient) + burning
    }

    // MARK: Sources

    /// What the pad puts into the air at an instant.
    public struct Sources: Equatable {
        /// The S-IC's exhaust, kg/s, and its thrust, N.
        public var exhaust: Double
        public var thrust: Double
        /// The shares of it reaching the trench and the deck.
        public var trench: Double
        public var deck: Double
        /// The deluge's water on the exhaust, kg/s: the trench's and the deck's.
        public var trenchWater: Double
        public var deckWater: Double

        public init(exhaust: Double, thrust: Double, trench: Double, deck: Double, trenchWater: Double,
                    deckWater: Double) {
            self.exhaust = exhaust
            self.thrust = thrust
            self.trench = trench
            self.deck = deck
            self.trenchWater = trenchWater
            self.deckWater = deckWater
        }

        public static let none = Sources(exhaust: 0, thrust: 0, trench: 0, deck: 0, trenchWater: 0, deckWater: 0)
    }

    /// One cloud's fluxes from `s`, in air of density `rho` at `ambient` K:
    /// its jet's kinematic momentum flux (m⁴/s²), its buoyancy flux (m⁴/s³)
    /// and heat (W), the exhaust it carries and the water it boils (kg/s).
    /// Each trench jet takes half the trench's share and its water; the deck
    /// lobe the deck's share, the plume striking the deck turned into a
    /// radial wall jet with all its momentum (a jet on a plate, inviscid),
    /// and the deck's water in that share. The water boils as far as the
    /// heat goes.
    public static func fluxes(_ s: Sources, lobe: Lobe.Kind, density rho: Double, ambient: Double)
        -> (momentum: Double, buoyancy: Double, heat: Double, exhaust: Double, water: Double) {
        let (share, water, momentum): (Double, Double, Double)
        switch lobe {
        case .trench:
            share = 0.5 * s.trench
            water = s.trench > 0 ? 0.5 * s.trenchWater : 0
            momentum = 0.5 * s.thrust * s.trench * deflectorMomentum / rho
        case .deck:
            share = s.deck
            water = s.deckWater * min(1, s.deck)
            momentum = s.thrust * s.deck / rho
        }
        guard share > 0, s.exhaust > 0 else { return (0, 0, 0, 0, 0) }
        let exhaust = s.exhaust * share
        let heat = exhaust * exhaustHeat(ambient: ambient) * (1 - radiantFraction)
        let perKg = waterHeat * max(0, 373.15 - ambient) + waterLatent
        let boiled = min(water, heat / perKg)
        let left = heat - boiled * perKg
        return (momentum, 9.80665 * left / (rho * airHeat * ambient), left, exhaust, boiled)
    }

    /// A trench jet's fluxes (`fluxes(_:lobe:density:ambient:)`).
    public static func side(_ s: Sources, density rho: Double, ambient: Double)
        -> (momentum: Double, buoyancy: Double, heat: Double, exhaust: Double, water: Double) {
        fluxes(s, lobe: .trench(1), density: rho, ambient: ambient)
    }

    // MARK: State

    /// One jet and its cloud.
    public struct Lobe: Equatable {
        public enum Kind: Equatable {
            /// A trench jet: +1 north, −1 south, the exit it leaves by.
            case trench(Double)
            /// The deck's radial wall jet, under the vehicle once its plume
            /// outgrows the ML's opening.
            case deck
        }
        public var kind: Kind
        /// The jet's front, m from where it starts: the deflector (along
        /// x), or the pad's axis (radially).
        public var front: Double
        /// The cloud: its centre (site frame), volume (m³), V w (m⁴/s) and
        /// buoyancy V g′ (m⁴/s²); and the exhaust and water in it, kg.
        public var centre: Vec3
        public var volume = 0.0
        public var momentum = 0.0
        public var buoyancy = 0.0
        public var exhaust = 0.0
        public var water = 0.0
        /// The jet's last fluxes: its momentum flux and buoyancy flux.
        public var jet: (momentum: Double, buoyancy: Double) = (0, 0)
        /// How far the wind has carried it, site frame (horizontal).
        public var drift = Vec3.zero

        public var radius: Double { cbrt(3 * volume / (4 * .pi)) }
        public var rise: Double { volume > 0 ? momentum / volume : 0 }
        /// Its top, m above the deck.
        public var top: Double { centre.z + radius }

        public static func == (a: Lobe, b: Lobe) -> Bool {
            a.kind == b.kind && a.front == b.front && a.centre == b.centre && a.volume == b.volume
                && a.momentum == b.momentum && a.buoyancy == b.buoyancy && a.exhaust == b.exhaust
                && a.water == b.water && a.jet.momentum == b.jet.momentum && a.jet.buoyancy == b.jet.buoyancy
                && a.drift == b.drift
        }
    }

    /// The trench's half length: the jets' distance from the deflector at the exits.
    public static var exitDistance: Double { abs(PadExhaust.trenchExits[0].position.x) }

    public private(set) var lobes: [Lobe]
    /// The grid's origin and the time the state is at.
    public let origin: Epoch
    public private(set) var time: Epoch
    /// The lobes every `sampleInterval` s of the grid from the origin: what
    /// a rebuilt history fills the clouds by.
    public private(set) var samples: [[Lobe]] = []
    public static let sampleInterval = 0.5

    /// The lobes as they were at `epoch` (the last sample at or before it),
    /// the present ones after the last sample.
    public func lobes(at epoch: Epoch) -> [Lobe] {
        let k = Int(((epoch - origin) / Self.sampleInterval).rounded(.down))
        guard k >= 0 else { return samples.first ?? lobes }
        return k < samples.count ? samples[k] : lobes
    }

    /// Nothing out yet at `origin` (the first engine's start command).
    public init(origin: Epoch) {
        self.origin = origin
        time = origin
        let x = Self.exitDistance
        lobes = [1.0, -1.0].map { Lobe(kind: .trench($0), front: x, centre: Vec3($0 * x, 0, 0)) }
            + [Lobe(kind: .deck, front: PadExhaust.openingHalf, centre: .zero)]
    }

    /// Integrates on to the last grid point at or before `epoch`, with the
    /// sources at each step's middle and the air of `air` (the sounding,
    /// nil for the standard 288 K at the deck) at `deckHeight` above sea
    /// level, its winds turned into the site frame by `siteFromEastNorth`.
    public mutating func advance(to epoch: Epoch, sources: (Epoch) -> Sources, air: AirProfile?,
                                 deckHeight: Double, siteFromEastNorth: (Double, Double) -> Vec3) {
        let n = Int(((epoch - origin) / Self.step + 1e-9).rounded(.down))
        var k = Int(((time - origin) / Self.step).rounded())
        let every = Int((Self.sampleInterval / Self.step).rounded())
        while k < n {
            if k % every == 0, samples.count == k / every { samples.append(lobes) }
            let mid = origin + (Double(k) + 0.5) * Self.step
            step(sources(mid), air: air, deckHeight: deckHeight, wind: siteFromEastNorth)
            k += 1
            time = origin + Double(k) * Self.step
        }
    }

    /// The air at `z` m above the deck: density, temperature, stability N²
    /// (s⁻²) and wind (site frame).
    static func air(_ profile: AirProfile?, at z: Double, deckHeight: Double, wind: (Double, Double) -> Vec3)
        -> (rho: Double, temperature: Double, n2: Double, wind: Vec3) {
        guard let p = profile else { return (1.225, 288.15, 0, .zero) }
        let h = deckHeight + max(0, z)
        let a = p.sample(altitude: h), above = p.sample(altitude: h + 50)
        // The potential temperature's gradient: N² = (g / θ) dθ/dz.
        let theta = a.temperature * pow(100_000 / a.pressure, ParticlePhysics.adiabaticExponent)
        let thetaAbove = above.temperature * pow(100_000 / above.pressure, ParticlePhysics.adiabaticExponent)
        let n2 = 9.80665 / theta * (thetaAbove - theta) / 50
        return (a.density, a.temperature, n2, wind(a.windEast, a.windNorth))
    }

    mutating func step(_ s: Sources, air profile: AirProfile?, deckHeight: Double, wind: (Double, Double) -> Vec3) {
        let h = Self.step, alpha = Self.thermalEntrainment
        let ground = Self.air(profile, at: 0, deckHeight: deckHeight, wind: wind)
        for k in lobes.indices {
            var l = lobes[k]
            let f = Self.fluxes(s, lobe: l.kind, density: ground.rho, ambient: ground.temperature)
            l.jet = (f.momentum, f.buoyancy)
            // The jet's front, at half its centreline speed, out to its runout.
            let m = f.momentum.squareRoot()
            let runout = f.buoyancy > 0 ? Self.jetRunout * pow(f.momentum, 0.75) / f.buoyancy.squareRoot() : .infinity
            let start = l.kind == .deck ? PadExhaust.openingHalf : Self.exitDistance
            let end = max(start, min(runout, 1e5))
            if m > 0, l.front < end {
                l.front = min(end, l.front + Self.jetFront * Self.jetVelocity * m / l.front * h)
            }
            // The cloud, fed at the jet's end with the jet's volume flux.
            let feed = m > 0 ? Self.jetVolume * m * l.front : 0
            let air = Self.air(profile, at: l.centre.z, deckHeight: deckHeight, wind: wind)
            let r = l.radius, w = l.rise
            l.volume += (4 * .pi * r * r * alpha * abs(w) + feed) * h
            l.buoyancy += (f.buoyancy - air.n2 * l.volume * w) * h
            l.momentum += l.buoyancy * h
            l.exhaust += f.exhaust * h
            l.water += f.water * h
            // Over the jet's end, drifting on the wind; resting on the ground
            // (it cannot sink) until it lifts.
            l.drift += Vec3(air.wind.x, air.wind.y, 0) * h
            var z = l.centre.z + l.rise * h
            let radius = l.radius
            if z < radius {
                z = radius
                if l.momentum < 0 { l.momentum = 0 }
            }
            switch l.kind {
            case .trench(let side): l.centre = Vec3(side * l.front + l.drift.x, l.drift.y, z)
            case .deck: l.centre = Vec3(l.drift.x, l.drift.y, z)
            }
            lobes[k] = l
        }
    }
}
