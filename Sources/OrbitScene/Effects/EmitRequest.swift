import Foundation
import OrbitCore

// What an effect asks the GPU particles for: `count` particles of one
// material in one anchor, from a shape, with a velocity distribution and a
// spread of spawn ages. The emit kernel (ParticleShaders' particle_emit)
// samples each particle exactly as `EmitSampler.sample` does here, then
// ages it to the frame with `ParticlePhysics.advance`. Frozen API: see
// docs/m16/design-plumes-particles.md, "P3 API (frozen)".

/// Where in the anchor particles start, about the request's `origin`,
/// across or along its `axis`.
public enum EmitShape: Equatable {
    /// All at the origin.
    case point
    /// Uniform within a ball.
    case ball(radius: Double)
    /// Uniform over a sphere's surface.
    case sphere(radius: Double)
    /// Uniform over a disc across the axis.
    case disc(radius: Double)
    /// Uniform over an annulus across the axis, `width` wide about `radius`:
    /// a pyro ring, a separation plane.
    case ring(radius: Double, width: Double)
    /// Uniform over a cylinder's surface about the axis, `height` long and
    /// centred on the origin: a vent band, a tank's frost.
    case band(radius: Double, height: Double)
    /// Uniform along a segment from the origin along the axis.
    case line(length: Double)

    /// The kernel's code and two parameters.
    public var code: (kind: Int, a: Double, b: Double) {
        switch self {
        case .point: (0, 0, 0)
        case .ball(let r): (1, r, 0)
        case .sphere(let r): (2, r, 0)
        case .disc(let r): (3, r, 0)
        case .ring(let r, let w): (4, r, w)
        case .band(let r, let h): (5, r, h)
        case .line(let l): (6, l, 0)
        }
    }
}

/// Which way particles leave.
public enum EmitDirection: Equatable {
    /// Within a cone of half-angle `spread` (rad) about the axis: π for
    /// every direction.
    case axis(spread: Double)
    /// Outward from the shape: from the origin for a point, ball or
    /// sphere, from the axis for a disc, ring, band or line; within a cone
    /// of half-angle `spread` about that.
    case radial(spread: Double)

    public var code: (radial: Bool, spread: Double) {
        switch self {
        case .axis(let s): (false, s)
        case .radial(let s): (true, s)
        }
    }
}

/// One batch of particles. Positions and velocities are in the anchor's
/// axes (`EffectAnchor`), relative to the anchor.
public struct EmitRequest: Equatable {
    public var anchor: EffectAnchorID
    public var material: ParticleMaterialID
    public var count: Int
    /// The source now, m from the anchor's origin.
    public var origin = Vec3.zero
    /// Unit: the shape's axis and the `.axis` direction's.
    public var axis = Vec3.unitZ
    public var shape = EmitShape.point
    public var direction = EmitDirection.axis(spread: .pi)
    /// Each particle's speed along its direction, m/s, uniform in the range.
    public var speed: ClosedRange<Double> = 0...0
    /// Added to every particle, m/s, relative to the source.
    public var velocity = Vec3.zero
    /// The source's velocity and acceleration relative to the anchor now. A
    /// particle of age a started at origin − v a + ½ A a², moving at v − A a
    /// plus its own velocity: continuous emitters on a moving vessel leave
    /// a trail at any warp.
    public var sourceVelocity = Vec3.zero
    public var sourceAcceleration = Vec3.zero
    /// m and s, uniform in the ranges.
    public var radius: ClosedRange<Double> = 0.1...0.1
    public var lifetime: ClosedRange<Double> = 1...1
    /// K at spawn; 0 for the air's there (3 K in vacuum).
    public var temperature = 0.0
    /// Each particle's age at the frame, s: particle i of n is at
    /// lower + (i + u)/n × (upper − lower), u uniform in [0, 1)
    /// (stratified). A particle as old as its lifetime is not spawned,
    /// unless it is a held flash (`FlashHold`).
    public var ages: ClosedRange<Double> = 0...0
    public var seed: UInt32 = 0

    public init(anchor: EffectAnchorID, material: ParticleMaterialID, count: Int) {
        self.anchor = anchor
        self.material = material
        self.count = count
    }
}

/// The emit kernel's random numbers: Jarzynski and Olano's PCG hash (JCGT
/// 9(3), 2020), so the CPU and the GPU draw the same integers.
public enum ParticleRandom {
    public static func pcg(_ v: UInt32) -> UInt32 {
        let state = v &* 747_796_405 &+ 2_891_336_453
        let word = ((state >> ((state >> 28) &+ 4)) ^ state) &* 277_803_737
        return (word >> 22) ^ word
    }

    /// A particle's first state: its request's seed and its index.
    public static func seed(_ seed: UInt32, index: UInt32) -> UInt32 { pcg(seed ^ pcg(index &+ 0x9E37_79B9)) }

    /// The next uniform in [0, 1), 24 bits (exact in Float), advancing `state`.
    public static func uniform(_ state: inout UInt32) -> Double {
        state = pcg(state)
        return Double(state >> 8) / 16_777_216
    }

    /// A seed from a string and an integer (an emitter's key and a frame).
    public static func seed(_ key: String, _ n: Int) -> UInt32 {
        var h: UInt32 = 2_166_136_261
        for b in key.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return pcg(h ^ UInt32(truncatingIfNeeded: n))
    }
}

/// One particle as the emit kernel draws it, before it is aged.
public struct SpawnedParticle: Equatable {
    /// At its spawn, relative to the anchor, m and m/s.
    public var position: Vec3
    public var velocity: Vec3
    public var radius: Double
    public var lifetime: Double
    /// Its age at the frame, s.
    public var age: Double
    /// Its own seed (the look's noise, a chunk's spin).
    public var seed: UInt32
}

/// The emit kernel's sampling, in double precision: the GPU's
/// particle_emitSample does the same, uniform for uniform.
public enum EmitSampler {
    /// Two unit vectors across `axis`, (u, v, axis) right-handed (as R6's
    /// test emitters build theirs).
    public static func basis(_ axis: Vec3) -> (Vec3, Vec3) {
        let helper = abs(axis.z) < 0.9 ? Vec3.unitZ : Vec3.unitX
        let u = helper.cross(axis).normalized
        return (u, axis.cross(u))
    }

    /// A direction within a cone of half-angle `spread` about `axis`, from
    /// two uniforms (uniform over the cap's solid angle).
    public static func cone(_ axis: Vec3, spread: Double, _ u1: Double, _ u2: Double) -> Vec3 {
        let (u, v) = basis(axis)
        let c = 1 - u1 * (1 - cos(min(max(spread, 0), Double.pi)))
        let s = max(0, 1 - c * c).squareRoot(), phi = 2 * Double.pi * u2
        return (u * cos(phi) + v * sin(phi)) * s + axis * c
    }

    /// Particle `index` of `r`.
    public static func sample(_ r: EmitRequest, index i: Int) -> SpawnedParticle {
        var state = ParticleRandom.seed(r.seed, index: UInt32(truncatingIfNeeded: i))
        let own = state
        var x = [Double](repeating: 0, count: 10)
        for k in 0..<10 { x[k] = ParticleRandom.uniform(&state) }
        let axis = r.axis.length > 0 ? r.axis.normalized : Vec3.unitZ
        let (u, v) = basis(axis)
        let shape = r.shape.code
        let phi = 2 * Double.pi * x[1]
        let around = u * cos(phi) + v * sin(phi)
        var offset = Vec3.zero
        // Outward, for the radial direction: from the origin or the axis.
        var outward = axis
        switch shape.kind {
        case 1, 2:
            let z = 2 * x[0] - 1, s = max(0, 1 - z * z).squareRoot(), psi = 2 * Double.pi * x[2]
            let d = (u * cos(psi) + v * sin(psi)) * s + axis * z
            offset = d * (shape.kind == 1 ? shape.a * cbrt(x[3]) : shape.a)
            outward = d
        case 3:
            offset = around * (shape.a * x[0].squareRoot())
            outward = around
        case 4:
            let inner = max(0, shape.a - 0.5 * shape.b), outer = shape.a + 0.5 * shape.b
            offset = around * (inner * inner + x[0] * (outer * outer - inner * inner)).squareRoot()
            outward = around
        case 5:
            offset = around * shape.a + axis * ((x[0] - 0.5) * shape.b)
            outward = around
        case 6:
            offset = axis * (shape.a * x[0])
            outward = around
        default:
            let z = 2 * x[0] - 1, s = max(0, 1 - z * z).squareRoot(), psi = 2 * Double.pi * x[2]
            outward = (u * cos(psi) + v * sin(psi)) * s + axis * z
        }
        let dir = r.direction.code
        let heading = cone(dir.radial ? outward : axis, spread: dir.spread, x[4], x[5])
        let speed = r.speed.lowerBound + x[6] * (r.speed.upperBound - r.speed.lowerBound)
        let n = Double(max(r.count, 1))
        let age = r.ages.lowerBound + (Double(i) + x[7]) / n * (r.ages.upperBound - r.ages.lowerBound)
        let radius = r.radius.lowerBound + x[8] * (r.radius.upperBound - r.radius.lowerBound)
        let lifetime = r.lifetime.lowerBound + x[9] * (r.lifetime.upperBound - r.lifetime.lowerBound)
        let source = r.origin - r.sourceVelocity * age + r.sourceAcceleration * (0.5 * age * age)
        let sourceVelocity = r.sourceVelocity - r.sourceAcceleration * age
        return SpawnedParticle(position: source + offset, velocity: sourceVelocity + r.velocity + heading * speed,
                               radius: radius, lifetime: lifetime, age: age, seed: own)
    }
}
