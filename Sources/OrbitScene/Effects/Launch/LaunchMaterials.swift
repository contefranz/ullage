import Foundation
import OrbitCore

/// P4's particle materials, every name prefixed "p4 " (the table is keyed by
/// name across the effect tracks). The motion is P3's physics with
/// physical densities; colours, optical depths, sizes and lifetimes are
/// the look (L), tuned against the AS-506 and AS-503 liftoff photographs
/// (S69-39961, S68-56050).
public enum LaunchMaterials {
    /// The exhaust out of the flame trench and across the deck: kerosene
    /// combustion products and the deluge's steam mixed, a warm grey with a
    /// little of the soot's brown, hot enough to rise. It glows faintly
    /// orange while it is still hot from the deflector.
    public static var padExhaust: ParticleMaterial {
        var m = ParticleMaterial(name: "p4 pad exhaust", renderClass: .smoke)
        m.albedo = ParticleColor(0.62, 0.57, 0.51)
        m.emission = ParticleColor(1, 0.5, 0.18) * 4e4
        m.emissionTemperature = 1_400
        m.opticalDepth = 5.5
        m.phaseG = 0.45
        m.fadeIn = 0.01
        m.fadeOut = 0.45
        m.dragCoefficient = 0.5
        m.entrainment = 0.12
        m.spreadRate = 0.35
        m.coolingTime = 30
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
    /// the wind and spreading over minutes. Three bands, thinner with height
    /// as the vehicle spreads the same flow over more metres a second
    /// (`ExhaustTrail.band`): dense and brownish grey near the ground,
    /// whiter condensate above.
    public static func trail(_ band: Int) -> ParticleMaterial {
        var m = ParticleMaterial(name: "p4 trail \(["low", "mid", "high"][band])", renderClass: .smoke)
        m.albedo = [ParticleColor(0.6, 0.56, 0.52), ParticleColor(0.8, 0.78, 0.76), ParticleColor(gray: 0.88)][band]
        m.opticalDepth = [1.4, 0.9, 0.4][band]
        m.phaseG = [0.5, 0.6, 0.7][band]
        // Of a life of minutes: a puff appears within a tenth of a second,
        // where P2's plume hands the exhaust over (its fade window there is
        // tens of metres; at 400 m/s a slower fade-in leaves a gap).
        m.fadeIn = 0.0002
        m.fadeOut = 0.5
        m.dragCoefficient = 0.5
        m.spreadRate = 0.25
        m.coolingTime = 10
        return m
    }

    /// Every P4 material, in the order `LaunchEffects` registers them.
    public static var all: [ParticleMaterial] {
        [padExhaust, deluge, coldVapour, iceFlake, iceSlab, trail(0), trail(1), trail(2)]
    }
}
