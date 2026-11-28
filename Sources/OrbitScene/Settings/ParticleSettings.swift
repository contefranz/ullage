import Foundation
import OrbitCore

/// Track P3's render settings: the particle budget, and the look-dev
/// bursts that shots draw in the studio. P3 owns this file; `RenderSettings`
/// holds one.
public struct ParticleSettings: Codable, Equatable {
    /// The particle budget and render classes (R7's tiers set it).
    public var quality = ParticleQuality.high
    /// Look-dev: bursts spawned afresh every frame in the studio anchor at
    /// the camera's target, at their ages, in place of the effects. A shot
    /// with them is the same every frame and in every scenario.
    public var testBursts: [ParticleTestBurst] = []
    /// Look-dev: LR5's trail in the studio anchor, drawn as the launch's is
    /// (TrailPass), in place of the effects (`TrailStudio`).
    public var testTrail: ParticleTestTrail?
    /// The studio's gravity and air.
    public var studio = ParticleStudio()
    /// Particles outside the view, or streaks too faint to see, are not
    /// drawn (they still move). Off only to check that this changes nothing.
    public var culls = true
    /// LR5's trail is drawn (TrailPass); off only to time it.
    public var trail = true

    public init() {}

    private enum CodingKeys: String, CodingKey { case quality, testBursts, testTrail, studio, culls, trail }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        quality = try c.decodeIfPresent(ParticleQuality.self, forKey: .quality) ?? .high
        testBursts = try c.decodeIfPresent([ParticleTestBurst].self, forKey: .testBursts) ?? []
        testTrail = try c.decodeIfPresent(ParticleTestTrail.self, forKey: .testTrail)
        studio = try c.decodeIfPresent(ParticleStudio.self, forKey: .studio) ?? ParticleStudio()
        culls = try c.decodeIfPresent(Bool.self, forKey: .culls) ?? true
        trail = try c.decodeIfPresent(Bool.self, forKey: .trail) ?? true
    }
}

/// A look-dev trail (`TrailStudio`): a straight tube of nodes of a given
/// column, or the chain the plume's test engines (`PlumeSettings
/// .testEngines`) hand their exhaust over to, laid in their stream.
public struct ParticleTestTrail: Codable, Equatable {
    public enum Kind: String, Codable { case tube, plume }
    public var kind = Kind.tube
    /// The tube's start (m east, north and up of the camera's target) and
    /// direction.
    public var start = [0.0, 0.0, 0.0]
    public var direction = [1.0, 0.0, 0.0]
    /// Its length, or the plume's trail's behind its hand-over window, m.
    public var length = 1_000.0
    /// The tube's column: its optical depth through the axis, its Gaussian
    /// width σ (m), its albedo and asymmetry.
    public var depth = 1.0
    public var width = 20.0
    public var albedo = 0.58
    public var asymmetry = 0.35

    public init() {}

    private enum CodingKeys: String, CodingKey { case kind, start, direction, length, depth, width, albedo, asymmetry }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .tube
        start = try c.decodeIfPresent([Double].self, forKey: .start) ?? [0, 0, 0]
        direction = try c.decodeIfPresent([Double].self, forKey: .direction) ?? [1, 0, 0]
        length = try c.decodeIfPresent(Double.self, forKey: .length) ?? 1_000
        depth = try c.decodeIfPresent(Double.self, forKey: .depth) ?? 1
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 20
        albedo = try c.decodeIfPresent(Double.self, forKey: .albedo) ?? 0.58
        asymmetry = try c.decodeIfPresent(Double.self, forKey: .asymmetry) ?? 0.35
    }
}

/// The particle tiers (the design's quality presets).
public enum ParticleQuality: String, Codable, CaseIterable, Comparable {
    case off, low, medium, high, ultra

    /// Particles alive at once.
    public var capacity: Int {
        switch self {
        case .off: 0
        case .low: 8_192
        case .medium: 32_768
        case .high: 131_072
        case .ultra: 262_144
        }
    }

    /// Smoke through the OIT layer: not at Low, which draws additive streaks
    /// and chunks only.
    public var drawsSmoke: Bool { self >= .medium }

    public static func < (a: ParticleQuality, b: ParticleQuality) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// Fixed limits of the particle system.
public enum ParticleBudget {
    /// Chunks drawn at most (the rest live but are not drawn).
    public static let chunks = 2_048
    /// Anchors alive at once.
    public static let anchors = 256
    /// Emit requests a frame (the rest are dropped and counted).
    public static let requests = 1_024
}

/// The studio's gravity (m/s², down) and its air, the same at every height.
public struct ParticleStudio: Codable, Equatable {
    public var gravity = 0.0
    /// kg/m³ (0: vacuum), K, Pa.
    public var airDensity = 0.0
    public var airTemperature = 288.15
    public var airPressure = 0.0
    /// East and north, m/s.
    public var wind = [0.0, 0.0]

    public init() {}

    /// Sea level on a calm day.
    public static var seaLevel: ParticleStudio {
        var s = ParticleStudio()
        s.gravity = 9.80665
        s.airDensity = 1.225
        s.airPressure = 101_325
        return s
    }

    public var anchor: StudioAnchor {
        let w = Vec3(wind.count > 0 ? wind[0] : 0, wind.count > 1 ? wind[1] : 0, 0)
        return StudioAnchor(gravity: Vec3(0, 0, -gravity),
                            air: ParticlePhysics.Air(density: airDensity, temperature: airTemperature,
                                                     pressure: airPressure, velocity: w))
    }

    private enum CodingKeys: String, CodingKey { case gravity, airDensity, airTemperature, airPressure, wind }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gravity = try c.decodeIfPresent(Double.self, forKey: .gravity) ?? 0
        airDensity = try c.decodeIfPresent(Double.self, forKey: .airDensity) ?? 0
        airTemperature = try c.decodeIfPresent(Double.self, forKey: .airTemperature) ?? 288.15
        airPressure = try c.decodeIfPresent(Double.self, forKey: .airPressure) ?? 0
        wind = try c.decodeIfPresent([Double].self, forKey: .wind) ?? [0, 0]
    }
}

/// A look-dev burst: an `EmitRequest` in the studio, written in the camera
/// target's east, north and up (m, m/s, degrees).
public struct ParticleTestBurst: Codable, Equatable {
    /// A library material's name (`ParticleMaterial.library`), or the name of
    /// `custom`; left out, `custom`'s, or the library's smoke without one.
    public var material = "smoke"
    /// A material of the shot's own.
    public var custom: ParticleMaterial?
    public var count = 100
    public var position = [0.0, 0.0, 0.0]
    public var axis = [0.0, 0.0, 1.0]
    /// point, ball, sphere, disc, ring, band or line; `size` its radius or
    /// length, `width` a ring's width or a band's height.
    public var shape = "point"
    public var size = 0.0
    public var width = 0.0
    /// Outward from the shape rather than about the axis; within `spread` degrees.
    public var radial = false
    public var spread = 180.0
    public var speed = [0.0, 0.0]
    public var velocity = [0.0, 0.0, 0.0]
    public var radius = [0.1, 0.1]
    public var lifetime = [1.0, 1.0]
    public var ages = [0.0, 0.0]
    /// K; 0 for the air's.
    public var temperature = 0.0
    public var seed = 1

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case material, custom, count, position, axis, shape, size, width, radial, spread, speed, velocity, radius
        case lifetime, ages, temperature, seed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ParticleTestBurst()
        custom = try c.decodeIfPresent(ParticleMaterial.self, forKey: .custom)
        // A burst that gives only its own material draws it.
        material = try c.decodeIfPresent(String.self, forKey: .material) ?? custom?.name ?? d.material
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? d.count
        position = try c.decodeIfPresent([Double].self, forKey: .position) ?? d.position
        axis = try c.decodeIfPresent([Double].self, forKey: .axis) ?? d.axis
        shape = try c.decodeIfPresent(String.self, forKey: .shape) ?? d.shape
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? d.size
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? d.width
        radial = try c.decodeIfPresent(Bool.self, forKey: .radial) ?? d.radial
        spread = try c.decodeIfPresent(Double.self, forKey: .spread) ?? d.spread
        speed = try c.decodeIfPresent([Double].self, forKey: .speed) ?? d.speed
        velocity = try c.decodeIfPresent([Double].self, forKey: .velocity) ?? d.velocity
        radius = try c.decodeIfPresent([Double].self, forKey: .radius) ?? d.radius
        lifetime = try c.decodeIfPresent([Double].self, forKey: .lifetime) ?? d.lifetime
        ages = try c.decodeIfPresent([Double].self, forKey: .ages) ?? d.ages
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? d.temperature
        seed = try c.decodeIfPresent(Int.self, forKey: .seed) ?? d.seed
    }

    /// The material it names.
    public var resolvedMaterial: ParticleMaterial? {
        if let custom, custom.name == material || material.isEmpty { return custom }
        return ParticleMaterial.named(material) ?? custom
    }

    /// Its request in `anchor` (studio axes: east, north, up).
    public func request(anchor: EffectAnchorID, material id: ParticleMaterialID) -> EmitRequest {
        func vec(_ a: [Double], _ fallback: Vec3 = .zero) -> Vec3 {
            a.count >= 3 ? Vec3(a[0], a[1], a[2]) : fallback
        }
        func range(_ a: [Double]) -> ClosedRange<Double> {
            guard let lo = a.first else { return 0...0 }
            let hi = a.count > 1 ? a[1] : lo
            return min(lo, hi)...max(lo, hi)
        }
        var r = EmitRequest(anchor: anchor, material: id, count: max(0, count))
        r.origin = vec(position)
        let ax = vec(axis, .unitZ)
        r.axis = ax.length > 0 ? ax.normalized : .unitZ
        switch shape {
        case "ball": r.shape = .ball(radius: size)
        case "sphere": r.shape = .sphere(radius: size)
        case "disc": r.shape = .disc(radius: size)
        case "ring": r.shape = .ring(radius: size, width: width)
        case "band": r.shape = .band(radius: size, height: width)
        case "line": r.shape = .line(length: size)
        default: r.shape = .point
        }
        let s = spread * Double.pi / 180
        r.direction = radial ? .radial(spread: s) : .axis(spread: s)
        r.speed = range(speed)
        r.velocity = vec(velocity)
        r.radius = range(radius)
        r.lifetime = range(lifetime)
        r.ages = range(ages)
        r.temperature = temperature
        r.seed = UInt32(truncatingIfNeeded: seed)
        return r
    }
}
