import Foundation
import OrbitCore

// P3's material table: what a particle looks like and how it moves. Effect
// tracks (P4-P6) define their particles here, as data, and never edit the
// particle shaders. Frozen API: see docs/m16/design-plumes-particles.md,
// "P3 API (frozen)".

/// How a particle is drawn.
public enum ParticleRenderClass: String, Codable, CaseIterable {
    /// Additive at full resolution after the effect composite (P3, order
    /// 40): sparks, glints, flashes. Velocity-stretched quads, emissive plus
    /// a sunlit glint; order-independent.
    case streak
    /// Lit soft billboards through R6's weighted-blended OIT layer at half
    /// resolution: smoke, steam, spray, frost clouds. Off at the Low tier.
    case smoke
    /// Instanced tumbling plates or tetrahedra in the opaque pass (P1):
    /// ice slabs, cork, pyro debris, char. At most `ParticleBudget.chunks`.
    case chunk

    /// Its index on the GPU (the draw lists').
    public var index: Int { Self.allCases.firstIndex(of: self)! }
}

/// A chunk's mesh.
public enum ChunkShape: String, Codable, CaseIterable {
    /// A thin box: `chunkAspect` is its thickness over its width.
    case plate
    case tetrahedron

    public var index: Int { Self.allCases.firstIndex(of: self)! }
}

/// Linear Rec. 709, in the units its member says.
public struct ParticleColor: Codable, Equatable {
    public var r: Double, g: Double, b: Double

    public init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    public init(gray: Double) { self.init(gray, gray, gray) }

    public static let black = ParticleColor(gray: 0)

    public static func * (c: ParticleColor, s: Double) -> ParticleColor { ParticleColor(c.r * s, c.g * s, c.b * s) }

    public var maximum: Double { max(r, max(g, b)) }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        r = try c.decode(Double.self)
        g = try c.decode(Double.self)
        b = try c.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(r)
        try c.encode(g)
        try c.encode(b)
    }
}

/// A particle material: its look and its motion (`ParticlePhysics`).
/// In JSON (a look-dev shot's custom material) every member but `name`
/// may be left out.
public struct ParticleMaterial: Codable, Equatable {
    public var name: String
    public var renderClass: ParticleRenderClass

    // MARK: Look

    /// Smoke, chunks and streaks' glint: single-scattering albedo. Soot
    /// about 0.2, steam and ice 0.95; black for a spark that only glows.
    public var albedo = ParticleColor(gray: 0.9)
    /// Luminance at spawn, cd/m² in linear Rec. 709: what a spark, a flash
    /// or an incandescent puff emits (before the frame's pre-exposure).
    public var emission = ParticleColor.black
    /// The temperature `emission` is given at, K: the emission follows
    /// (T / this)⁴ as the particle cools. 0: it does not follow the
    /// temperature (a fluorescent glow, a flash's fixed brightness).
    public var emissionTemperature = 0.0
    /// Smoke: optical depth through a puff's centre at its spawn radius. It
    /// falls as (r0 / r)² as the puff grows: the soot or water it carries is
    /// conserved.
    public var opticalDepth = 1.0
    /// Henyey-Greenstein asymmetry: 0.7 ice and water, 0.4 smoke.
    public var phaseG = 0.5
    /// The fractions of its lifetime it fades in over and out over.
    public var fadeIn = 0.05
    public var fadeOut = 0.3
    /// Streaks: the exposure their length is drawn over, s (the length is
    /// the speed times this, plus the width).
    public var streakTime = 1.0 / 60
    /// Chunks: the mesh, a plate's thickness over its width, and the spin
    /// rate (rad/s; each chunk turns at up to this, about its own axis).
    public var chunkShape = ChunkShape.plate
    public var chunkAspect = 0.2
    public var spin = 3.0

    // MARK: Motion (ParticlePhysics.Material)

    /// kg/m³; 0 for a parcel of gas at its own temperature.
    public var density = 0.0
    public var dragCoefficient = 0.47
    /// Archimedes' buoyancy, scaled: 1 physical, 0 none.
    public var buoyancy = 1.0
    /// α: the radius grows by this per metre moved through the air.
    public var entrainment = 0.0
    /// m/s: the radius grows at this even at rest in the air.
    public var spreadRate = 0.0
    /// s: the temperature relaxes to the air's over this; infinite for none.
    public var coolingTime = Double.infinity
    /// Water ice: the radius shrinks by sublimation.
    public var sublimates = false

    // MARK: Time and ground

    /// A short luminous event (a retro's flash, a pyro, the J-2 start):
    /// above 10× warp it is kept on screen for at least 3 frames
    /// (`FlashHold`), so staging is seen at any warp.
    public var isFlash = false
    /// Killed where it meets the ground or the water.
    public var killedAtGround = true

    public init(name: String, renderClass: ParticleRenderClass) {
        self.name = name
        self.renderClass = renderClass
    }

    /// Its motion, as `ParticlePhysics` takes it.
    public var physics: ParticlePhysics.Material {
        ParticlePhysics.Material(density: density, dragCoefficient: dragCoefficient, buoyancy: buoyancy,
                                 entrainment: entrainment, spreadRate: spreadRate, coolingTime: coolingTime,
                                 sublimates: sublimates)
    }

    private enum CodingKeys: String, CodingKey {
        case name, renderClass, albedo, emission, emissionTemperature, opticalDepth, phaseG, fadeIn, fadeOut
        case streakTime, chunkShape, chunkAspect, spin, density, dragCoefficient, buoyancy, entrainment
        case spreadRate, coolingTime, sublimates, isFlash, killedAtGround
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        renderClass = try c.decodeIfPresent(ParticleRenderClass.self, forKey: .renderClass) ?? .smoke
        let d = ParticleMaterial(name: name, renderClass: renderClass)
        albedo = try c.decodeIfPresent(ParticleColor.self, forKey: .albedo) ?? d.albedo
        emission = try c.decodeIfPresent(ParticleColor.self, forKey: .emission) ?? d.emission
        emissionTemperature = try c.decodeIfPresent(Double.self, forKey: .emissionTemperature) ?? d.emissionTemperature
        opticalDepth = try c.decodeIfPresent(Double.self, forKey: .opticalDepth) ?? d.opticalDepth
        phaseG = try c.decodeIfPresent(Double.self, forKey: .phaseG) ?? d.phaseG
        fadeIn = try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? d.fadeIn
        fadeOut = try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? d.fadeOut
        streakTime = try c.decodeIfPresent(Double.self, forKey: .streakTime) ?? d.streakTime
        chunkShape = try c.decodeIfPresent(ChunkShape.self, forKey: .chunkShape) ?? d.chunkShape
        chunkAspect = try c.decodeIfPresent(Double.self, forKey: .chunkAspect) ?? d.chunkAspect
        spin = try c.decodeIfPresent(Double.self, forKey: .spin) ?? d.spin
        density = try c.decodeIfPresent(Double.self, forKey: .density) ?? d.density
        dragCoefficient = try c.decodeIfPresent(Double.self, forKey: .dragCoefficient) ?? d.dragCoefficient
        buoyancy = try c.decodeIfPresent(Double.self, forKey: .buoyancy) ?? d.buoyancy
        entrainment = try c.decodeIfPresent(Double.self, forKey: .entrainment) ?? d.entrainment
        spreadRate = try c.decodeIfPresent(Double.self, forKey: .spreadRate) ?? d.spreadRate
        // JSON has no infinity: a cooling time left out or null is none.
        coolingTime = try c.decodeIfPresent(Double.self, forKey: .coolingTime) ?? .infinity
        sublimates = try c.decodeIfPresent(Bool.self, forKey: .sublimates) ?? d.sublimates
        isFlash = try c.decodeIfPresent(Bool.self, forKey: .isFlash) ?? d.isFlash
        killedAtGround = try c.decodeIfPresent(Bool.self, forKey: .killedAtGround) ?? d.killedAtGround
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(renderClass, forKey: .renderClass)
        try c.encode(albedo, forKey: .albedo)
        try c.encode(emission, forKey: .emission)
        try c.encode(emissionTemperature, forKey: .emissionTemperature)
        try c.encode(opticalDepth, forKey: .opticalDepth)
        try c.encode(phaseG, forKey: .phaseG)
        try c.encode(fadeIn, forKey: .fadeIn)
        try c.encode(fadeOut, forKey: .fadeOut)
        try c.encode(streakTime, forKey: .streakTime)
        try c.encode(chunkShape, forKey: .chunkShape)
        try c.encode(chunkAspect, forKey: .chunkAspect)
        try c.encode(spin, forKey: .spin)
        try c.encode(density, forKey: .density)
        try c.encode(dragCoefficient, forKey: .dragCoefficient)
        try c.encode(buoyancy, forKey: .buoyancy)
        try c.encode(entrainment, forKey: .entrainment)
        try c.encode(spreadRate, forKey: .spreadRate)
        if coolingTime.isFinite { try c.encode(coolingTime, forKey: .coolingTime) }
        try c.encode(sublimates, forKey: .sublimates)
        try c.encode(isFlash, forKey: .isFlash)
        try c.encode(killedAtGround, forKey: .killedAtGround)
    }
}

// MARK: - A starting library

extension ParticleMaterial {
    /// Generic materials, for look-dev, the self-test and a start for the
    /// effect tracks, which copy and tune their own. Luminances are L
    /// (visual), the motion is physical.
    public static let library: [ParticleMaterial] = [.spark, .flash, .smoke, .soot, .steam, .iceFlake, .debris, .iceSlab]

    /// The library's material named `name`.
    public static func named(_ name: String) -> ParticleMaterial? { library.first { $0.name == name } }

    /// Incandescent Al2O3 or metal, glowing at 2,600 K and cooling by
    /// radiation over 1.5 s.
    public static var spark: ParticleMaterial {
        var m = ParticleMaterial(name: "spark", renderClass: .streak)
        m.albedo = .black
        m.emission = ParticleColor(1, 0.55, 0.22) * 4e6
        m.emissionTemperature = 2_600
        m.fadeIn = 0
        m.fadeOut = 0.2
        m.density = 3_950
        m.coolingTime = 1.5
        return m
    }

    /// A pyrotechnic or ignition flash: bright, brief, held at time warp.
    public static var flash: ParticleMaterial {
        var m = ParticleMaterial(name: "flash", renderClass: .streak)
        m.albedo = .black
        m.emission = ParticleColor(1, 0.85, 0.6) * 2e7
        m.fadeIn = 0
        m.fadeOut = 0.7
        m.density = 0
        m.buoyancy = 0
        m.isFlash = true
        m.killedAtGround = false
        return m
    }

    /// Grey combustion smoke: a hot gas parcel that rises, entrains and cools.
    public static var smoke: ParticleMaterial {
        var m = ParticleMaterial(name: "smoke", renderClass: .smoke)
        m.albedo = ParticleColor(gray: 0.45)
        m.opticalDepth = 3
        m.phaseG = 0.4
        m.fadeIn = 0.03
        m.fadeOut = 0.4
        m.dragCoefficient = 0.5
        m.entrainment = 0.1
        m.spreadRate = 0.3
        m.coolingTime = 20
        return m
    }

    /// Kerosene soot: dark, optically thick.
    public static var soot: ParticleMaterial {
        var m = smoke
        m.name = "soot"
        m.albedo = ParticleColor(gray: 0.12)
        m.opticalDepth = 5
        return m
    }

    /// Steam and condensate: bright, forward-scattering, short-lived as it mixes.
    public static var steam: ParticleMaterial {
        var m = ParticleMaterial(name: "steam", renderClass: .smoke)
        m.albedo = ParticleColor(gray: 0.95)
        m.opticalDepth = 2
        m.phaseG = 0.7
        m.fadeIn = 0.05
        m.fadeOut = 0.5
        m.dragCoefficient = 0.5
        m.entrainment = 0.1
        m.spreadRate = 0.6
        m.coolingTime = 8
        return m
    }

    /// A frost flake (1-5 mm): drag-dominated, sublimating, glinting in the
    /// Sun. Drawn as a streak: lit, it is a "firefly".
    public static var iceFlake: ParticleMaterial {
        var m = ParticleMaterial(name: "ice flake", renderClass: .streak)
        m.albedo = ParticleColor(0.9, 0.95, 1)
        m.phaseG = 0.7
        m.fadeIn = 0
        m.fadeOut = 0.1
        m.density = 917
        m.dragCoefficient = 1.2
        m.sublimates = true
        return m
    }

    /// Pyro and structural debris: a tumbling aluminium plate.
    public static var debris: ParticleMaterial {
        var m = ParticleMaterial(name: "debris", renderClass: .chunk)
        m.albedo = ParticleColor(gray: 0.55)
        m.fadeIn = 0
        m.fadeOut = 0
        m.chunkShape = .plate
        m.chunkAspect = 0.08
        m.spin = 6
        m.density = 2_700
        m.dragCoefficient = 1.2
        return m
    }

    /// An ice slab (2-30 cm) shed from a tank: tumbling, bluish white.
    public static var iceSlab: ParticleMaterial {
        var m = ParticleMaterial(name: "ice slab", renderClass: .chunk)
        m.albedo = ParticleColor(0.8, 0.86, 0.92)
        m.fadeIn = 0
        m.fadeOut = 0
        m.chunkShape = .plate
        m.chunkAspect = 0.25
        m.spin = 4
        m.density = 917
        m.dragCoefficient = 1.1
        return m
    }
}

// MARK: - The table

/// A material's place in the table, which the GPU indexes.
public struct ParticleMaterialID: Hashable, Comparable {
    public let index: Int

    public init(_ index: Int) { self.index = index }

    public static func < (a: ParticleMaterialID, b: ParticleMaterialID) -> Bool { a.index < b.index }
}

/// The frame's materials, by name: what the GPU's material buffer holds.
/// Registering a name twice keeps its place and takes the new values.
public final class ParticleMaterialTable {
    public static let capacity = 64

    public private(set) var materials: [ParticleMaterial] = []
    /// Bumped whenever a material is added or changed: the GPU re-uploads.
    public private(set) var revision = 0

    public init() {}

    /// The material's id, registering it (or updating the one of its name).
    @discardableResult
    public func register(_ m: ParticleMaterial) -> ParticleMaterialID {
        if let i = materials.firstIndex(where: { $0.name == m.name }) {
            if materials[i] != m {
                materials[i] = m
                revision += 1
            }
            return ParticleMaterialID(i)
        }
        precondition(materials.count < Self.capacity, "more than \(Self.capacity) particle materials")
        materials.append(m)
        revision += 1
        return ParticleMaterialID(materials.count - 1)
    }

    public func id(named name: String) -> ParticleMaterialID? {
        materials.firstIndex { $0.name == name }.map(ParticleMaterialID.init)
    }

    public subscript(id: ParticleMaterialID) -> ParticleMaterial { materials[id.index] }

    public var count: Int { materials.count }
}
