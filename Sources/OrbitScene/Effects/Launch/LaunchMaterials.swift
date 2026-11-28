import Foundation
import OrbitCore

/// P4's particle materials, every name prefixed "p4 " (the table is keyed by
/// name across the effect tracks). The motion is P3's physics with
/// physical densities; the pad's jets and clouds ride their flows'
/// similarity solutions (`eddy`), sized by `GroundCloud`. Colours and
/// optical depths are the look (L) where they say so: P4 tuned them against
/// the AS-506 and AS-503 liftoff photographs (S69-39961, S68-56050), a
/// photographic fit, flagged; the ground cloud's albedo follows its water
/// and soot.
public enum LaunchMaterials {
    /// An eddy of a jet or a cloud, of `share` of the flow's own radius,
    /// riding the flow's similarity solution: it grows by `share` of the
    /// flow's spreading rate α per metre through the air, and its drag
    /// coefficient, (8/3) share α, slows it as the flow's entrainment slows
    /// the flow (u ∝ 1/x for a round jet or a thermal at the air's density;
    /// a hot, light one faster, as a light jet's near field does). Derived
    /// from P3's drag on a parcel, (3 C_d / 8)(ρ_a / ρ_p) u² / r.
    static func eddy(_ m: inout ParticleMaterial, share: Double, spreading alpha: Double) {
        m.entrainment = share * alpha
        m.dragCoefficient = 8.0 / 3.0 * share * alpha
    }

    /// The exhaust out of the flame trench and across the deck: kerosene
    /// combustion products and the deluge's steam mixed, a warm grey with a
    /// little of the soot's brown (L), hot from the trench's afterburning,
    /// glowing orange while it is (L, the look). Eddies of half the jets'
    /// half-width (`GroundCloud`, `LaunchEffects.jetEddy`).
    public static var padExhaust: ParticleMaterial {
        var m = ParticleMaterial(name: "p4 pad exhaust", renderClass: .smoke)
        m.albedo = ParticleColor(0.62, 0.57, 0.51)
        m.emission = ParticleColor(1, 0.5, 0.18) * 4e4
        m.emissionTemperature = 1_400
        m.opticalDepth = jetOpticalDepth
        m.phaseG = 0.45
        m.fadeIn = 0.02
        m.fadeOut = 0.4
        eddy(&m, share: LaunchEffects.jetEddy, spreading: GroundCloud.jetSpread)
        m.spreadRate = 0.35
        return m
    }

    /// The water and soot a cloud carries, as an extinction cross-section
    /// (m²): the water condensed (the exhaust's own, 0.34 kg a kilogram with
    /// its afterburnt hydrogen's, CEA, and the deluge's it boiled, all of it
    /// condensed: L) on 10 µm droplets (3 Q / (4 ρ r), Q = 2: 150 m²/kg, M
    /// for the law, L for the size), and the kerosene's soot (0.5 % of the
    /// exhaust, L) at 7.5 m²/g (M).
    public static let exhaustWater = (GroundCloud.exhaustH2 + GroundCloud.exhaustH2O) * 0.018015
        / ApolloExhaust.f1.spec.molarMass
    public static let dropletExtinction = 150.0
    public static let sootYield = 0.005, sootExtinction = 7_500.0
    public static func cloudExtinction(exhaust: Double, water: Double) -> Double {
        dropletExtinction * (water + exhaustWater * exhaust) + sootExtinction * sootYield * exhaust
    }

    /// Optical depths through an eddy's centre at its spawn, from what it
    /// carries (the soot's and water's extinction, `cloudExtinction`):
    /// - a trench jet's, out of the exit at full thrust: half the exhaust
    ///   in the jet's 0.25 √(M/ρ) x of volume a second, across an eddy's
    ///   diameter: about 130;
    /// - a cloud eddy's: the water and soot in a cloud of the model's at
    ///   T+15 s through a fifth of its radius, about 30: optically thick, as
    ///   steam clouds are (fewer eddies as the cloud thins, `LaunchEffects`);
    /// - the start smoke's: the gas generator's fuel-rich gas at 887 K, its
    ///   soot 2 % of it (L), across 3 m: about 140.
    /// Each falls as (r0 / r)² as the eddy grows (P3).
    public static var jetOpticalDepth: Double {
        let s = GroundCloud.Sources(exhaust: LiftoffRise.flow, thrust: LiftoffRise.thrust, trench: 1, deck: 0,
                                    trenchWater: 0, deckWater: 0)
        let f = GroundCloud.side(s, density: 1.17, ambient: 300)
        let x = GroundCloud.exitDistance
        let volume = GroundCloud.jetVolume * f.momentum.squareRoot() * x
        let eddy = LaunchEffects.jetEddy * GroundCloud.jetSpread * x
        return cloudExtinction(exhaust: f.exhaust, water: 0) / volume * 2 * eddy
    }
    public static let cloudOpticalDepth = 30.0
    public static let generatorSootYield = 0.02
    public static var startSmokeOpticalDepth: Double {
        let gas = 101_325 / (8.314462618 / ApolloExhaust.f1.spec.molarMass * 887)
        return sootExtinction * generatorSootYield * gas * 2 * LaunchEffects.startSmokeEddy
    }

    /// The ground cloud's eddies (`LaunchEffects.groundCloud`): its water
    /// and soot, whose single-scattering albedo, water's 1 and soot's 0.2
    /// weighted by their extinction, is about 0.72 with the trench's water
    /// (`cloudAlbedo`), a light warm grey; at the air's temperature, for
    /// they follow the cloud's own rise (`GroundCloud`): eddies of a quarter
    /// of its radius riding its thermal.
    public static var cloudAlbedo: Double {
        let water = dropletExtinction * (exhaustWater + 0.13), soot = sootExtinction * sootYield
        return (water + 0.2 * soot) / (water + soot)
    }
    public static var groundCloud: ParticleMaterial {
        var m = ParticleMaterial(name: "p4 ground cloud", renderClass: .smoke)
        let a = cloudAlbedo
        m.albedo = ParticleColor(a * 1.02, a, a * 0.95)
        m.opticalDepth = cloudOpticalDepth
        m.phaseG = 0.6
        m.fadeIn = 0.15
        m.fadeOut = 0.4
        eddy(&m, share: LaunchEffects.cloudEddy, spreading: GroundCloud.thermalEntrainment)
        m.spreadRate = 0.3
        return m
    }

    /// The F-1's start: its gas generator's fuel-rich turbine exhaust,
    /// kerosene soot (albedo 0.15) at 887 K, before the chamber lights.
    public static var startSmoke: ParticleMaterial {
        var m = ParticleMaterial(name: "p4 start smoke", renderClass: .smoke)
        m.albedo = ParticleColor(0.16, 0.15, 0.14)
        m.opticalDepth = startSmokeOpticalDepth
        m.phaseG = 0.4
        m.fadeIn = 0.05
        m.fadeOut = 0.45
        m.dragCoefficient = 0.5
        m.entrainment = 0.1
        m.spreadRate = 0.3
        return m
    }

    /// The TEA-TEB igniter's green flash: boron burning (BO₂'s bands about
    /// 545 nm: chromaticity about (0.27, 0.70), green in Rec. 709), bright
    /// for the fraction of a second it burns, held at time warp.
    public static var ignitionFlash: ParticleMaterial {
        var m = ParticleMaterial(name: "p4 ignition flash", renderClass: .smoke)
        m.albedo = .black
        m.emission = ParticleColor(0.15, 1, 0.2) * 3e6
        m.opticalDepth = 0.6
        m.fadeIn = 0
        m.fadeOut = 0.6
        m.density = 0
        m.buoyancy = 0
        m.dragCoefficient = 0.5
        m.isFlash = true
        m.killedAtGround = false
        return m
    }

    /// The deluge's steam: white, forward-scattering, mixing away over a
    /// minute or two.
    public static var deluge: ParticleMaterial {
        var m = ParticleMaterial(name: "p4 deluge steam", renderClass: .smoke)
        m.albedo = ParticleColor(gray: 0.93)
        m.opticalDepth = 4.5
        m.phaseG = 0.7
        m.fadeIn = 0.02
        m.fadeOut = 0.5
        m.dragCoefficient = 0.5
        m.entrainment = 0.1
        m.spreadRate = 0.5
        m.coolingTime = 15
        return m
    }

    /// Fog off the frosted LOX tank and out of the umbilicals: air chilled
    /// by the cryogenic skin and lines (and the vented vapour), denser than
    /// the air round it, so it sinks along the vehicle and evaporates within
    /// seconds.
    public static var coldVapour: ParticleMaterial {
        var m = ParticleMaterial(name: "p4 cold vapour", renderClass: .smoke)
        m.albedo = ParticleColor(gray: 0.95)
        m.opticalDepth = 1.2
        m.phaseG = 0.7
        m.fadeIn = 0.1
        m.fadeOut = 0.6
        m.dragCoefficient = 0.6
        m.entrainment = 0.08
        m.spreadRate = 0.3
        m.coolingTime = 6
        return m
    }

    /// A frost flake (1-5 mm, FrostShedding's): P3's, glinting in the Sun
    /// above 40 km as a "firefly".
    public static var iceFlake: ParticleMaterial {
        var m = ParticleMaterial.iceFlake
        m.name = "p4 ice flake"
        return m
    }

    /// An ice slab (2-30 cm): P3's tumbling plate.
    public static var iceSlab: ParticleMaterial {
        var m = ParticleMaterial.iceSlab
        m.name = "p4 ice slab"
        return m
    }

    /// The exhaust trail: soot and condensate left in the air, drifting on
    /// the wind and spreading over minutes. A palette (`ExhaustTrail.palette`,
    /// row-major): rows of optical depth through a puff's centre
    /// (`ExhaustTrail.depthLevels`), columns of albedo
    /// (`ExhaustTrail.albedoLevels`), so a piece of trail takes the column
    /// P2's far field hands over, its depth by spacing and its albedo
    /// between two columns (`ExhaustTrail.puffs`); grey, P2's kerosene
    /// smoke's g. Of a life of minutes: a puff fades in over the plume's
    /// fade past the joint at the airspeed (`ExhaustTrail.fadeIn`, set each
    /// frame).
    public static func trail(_ index: Int) -> ParticleMaterial {
        let k = ExhaustTrail.albedoLevels.count
        let depth = ExhaustTrail.depthLevels[index / k], albedo = ExhaustTrail.albedoLevels[index % k]
        var m = ParticleMaterial(name: String(format: "p4 trail %.1f %.2f", depth, albedo), renderClass: .smoke)
        m.albedo = ParticleColor(gray: albedo)
        m.opticalDepth = depth
        m.phaseG = PlumeLook.Optics.phaseG(.kerosene)
        m.fadeIn = 0.0002
        m.fadeOut = 0.55
        m.dragCoefficient = 0.5
        m.spreadRate = 0.25
        m.coolingTime = 10
        return m
    }

    /// Every P4 material, in the order `LaunchEffects` registers them.
    public static var all: [ParticleMaterial] {
        [padExhaust, deluge, coldVapour, iceFlake, iceSlab] + (0..<ExhaustTrail.palette).map(trail)
            + [groundCloud, startSmoke, ignitionFlash]
    }
}
