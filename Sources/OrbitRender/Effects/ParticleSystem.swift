import Foundation
import Metal
import simd
import OrbitCore
import OrbitScene

// The GPU particle core (P3). Particles live in one buffer of the tier's
// capacity; a stack of free slots and two alive lists (ping-ponged) are
// kept with atomic counters. Each frame, on the frame's command buffer:
//   reset (on a reset)  every slot free;
//   begin               the next lists' counters cleared;
//   simulate            each alive particle advanced by dt (ParticlePhysics,
//                       the air from its anchor's profile), killed or kept:
//                       freed, or appended to the next alive list and its
//                       class's draw list; dispatched indirectly by last
//                       frame's count;
//   emit                each requested particle sampled (EmitSampler), aged
//                       to the frame through the same advance, given a free
//                       slot and appended;
//   compact             the next simulate's dispatch and this frame's three
//                       indirect draws.
// The draws (streaks, smoke, chunks) read the draw lists. Nothing runs on a
// frame with nothing alive and nothing asked for.

/// ParticleShaders' Particle (48 bytes).
struct ParticleGPU {
    var positionRadius: SIMD4<Float>
    var velocityAge: SIMD4<Float>
    /// Lifetime, temperature, spawn radius, and the packed ids.
    var state: (Float, Float, Float, UInt32)

    var material: Int { Int(state.3 & 63) }
    var anchor: Int { Int((state.3 >> 6) & 255) }
    var framesShown: Int { Int((state.3 >> 14) & 3) }
}

/// ParticleShaders' ParticleMaterial.
struct ParticleMaterialGPU {
    var albedo: SIMD4<Float>
    var emission: SIMD4<Float>
    var look: SIMD4<Float>
    var motion: SIMD4<Float>
    var thermal: SIMD4<Float>
    var shape: SIMD4<Float>

    init(_ m: ParticleMaterial) {
        albedo = SIMD4(Float(m.albedo.r), Float(m.albedo.g), Float(m.albedo.b), Float(m.renderClass.index))
        emission = SIMD4(Float(m.emission.r), Float(m.emission.g), Float(m.emission.b), Float(m.emissionTemperature))
        look = SIMD4(Float(m.opticalDepth), Float(m.phaseG), Float(m.fadeIn), Float(m.fadeOut))
        motion = SIMD4(Float(m.density), Float(m.dragCoefficient), Float(m.buoyancy), Float(m.entrainment))
        let flags = (m.isFlash ? 1 : 0) | (m.killedAtGround ? 2 : 0)
        thermal = SIMD4(Float(m.spreadRate), m.coolingTime.isFinite ? Float(m.coolingTime) : -1,
                        m.sublimates ? 1 : 0, Float(flags))
        shape = SIMD4(Float(m.streakTime), Float(m.chunkShape.index), Float(m.chunkAspect), Float(m.spin))
    }
}

/// ParticleShaders' ParticleRequest.
struct ParticleRequestGPU {
    var origin: SIMD4<Float>
    var axis: SIMD4<Float>
    var shape: SIMD4<Float>
    var speed: SIMD4<Float>
    var velocity: SIMD4<Float>
    var sourceVelocity: SIMD4<Float>
    var sourceAcceleration: SIMD4<Float>
    var ages: SIMD4<Float>
    var ids: SIMD4<UInt32>

    init(_ r: EmitRequest, first: Int) {
        let s = r.shape.code, d = r.direction.code
        let axis = r.axis.length > 0 ? r.axis.normalized : Vec3.unitZ
        origin = SIMD4(r.origin, Float(s.kind))
        self.axis = SIMD4(axis, Float(s.a))
        shape = SIMD4(Float(s.b), d.radial ? 1 : 0, Float(d.spread), Float(r.temperature))
        speed = SIMD4(Float(r.speed.lowerBound), Float(r.speed.upperBound), Float(r.radius.lowerBound),
                      Float(r.radius.upperBound))
        velocity = SIMD4(r.velocity, Float(r.lifetime.lowerBound))
        sourceVelocity = SIMD4(r.sourceVelocity, Float(r.lifetime.upperBound))
        sourceAcceleration = SIMD4(r.sourceAcceleration, Float(r.ages.lowerBound))
        ages = SIMD4(Float(r.ages.upperBound), Float(r.count), 0, 0)
        ids = SIMD4(UInt32(r.material.index), UInt32(r.anchor.slot), r.seed, UInt32(first))
    }
}

/// ParticleShaders' ParticleFrame.
struct ParticleFrameGPU {
    /// dt, turbulence time, 1 holding flashes, 1 advancing.
    var time = SIMD4<Float>.zero
    /// Capacity, particles to emit, requests, the current alive list.
    var counts = SIMD4<UInt32>.zero
    /// Chunks drawn at most, substeps at most, anchors.
    var limits = SIMD4<UInt32>.zero
    /// x: 1 culling against the frame's view.
    var view = SIMD4<Float>.zero
    /// The volume noise's drift, tiles (`EffectTimeRules.noiseDrift`).
    var noise = SIMD4<Float>.zero
}

/// Where a frame's small buffers go: the frame's arena, or the self-test's own.
protocol ParticleUploads: AnyObject {
    func upload<T>(_ items: [T]) -> (buffer: MTLBuffer, offset: Int)?
}

extension FrameArena: ParticleUploads {
    func upload<T>(_ items: [T]) -> (buffer: MTLBuffer, offset: Int)? { push(items) }
}

/// The GPU particles and the director that feeds them. One per renderer;
/// its passes (ParticlePass.swift) share it.
@MainActor
public final class ParticleSystem {
    public let director: EffectDirector
    /// Particles alive at once (the tier's).
    public private(set) var capacity = 0
    /// The latest frame's director output.
    public var output: EffectFrameOutput? { plan?.output }
    /// The latest frame's volume noise, once made.
    public private(set) var noise: VolumeNoise?

    /// One frame's decision: the director's output, whether the GPU works,
    /// whether it clears first.
    struct Plan {
        var output: EffectFrameOutput
        var works: Bool
        var resets: Bool
        var settings: ParticleSettings
    }

    private weak var plannedFor: FrameContext?
    private var plan: Plan?
    private var device: MTLDevice?
    private(set) var library: MTLLibrary?
    private var pipelines: [String: MTLComputePipelineState] = [:]

    // Buffers.
    private(set) var particles: MTLBuffer?
    private(set) var freeList: MTLBuffer?
    private(set) var alive: [MTLBuffer] = []
    private(set) var drawLists: MTLBuffer?
    /// The counters (ParticleShaders' PARTICLE_COUNTER_*), shared so the CPU reads them back.
    private(set) var counters: MTLBuffer?
    /// The indirect arguments: the simulate dispatch, then the three draws.
    private(set) var arguments: MTLBuffer?
    /// The alive list this frame read (0 or 1); the next is the other.
    private(set) var current = 0
    /// The GPU may still hold particles.
    private var holdsParticles = false
    private var needsReset = true

    /// This frame's bindings, for the draw passes.
    struct Bindings {
        var frame: (buffer: MTLBuffer, offset: Int)
        var materials: (buffer: MTLBuffer, offset: Int)
        var anchors: (buffer: MTLBuffer, offset: Int)
    }

    private(set) var bindings: Bindings?

    /// The counters' slots.
    enum Counter: Int {
        case free = 0, aliveA, aliveB, drawStreak, drawSmoke, drawChunk, emitted, dropped
    }

    static let counterCount = 8
    /// The indirect draws' offsets in `arguments`, by render class.
    static func drawArgumentsOffset(_ c: ParticleRenderClass) -> Int { 16 + 16 * c.index }

    /// The particles fed by `director`, or by one with the default producers.
    public init(director: EffectDirector? = nil) {
        self.director = director ?? EffectDirector()
    }

    // MARK: Set-up

    /// Builds the kernels (once; every particle pass calls it).
    func setUp(device: MTLDevice, shaders: ShaderLibrary) throws {
        if library != nil { return }
        let library = try shaders.library(.particle)
        for name in ["particle_reset", "particle_begin", "particle_simulate", "particle_emit", "particle_compact"] {
            guard let fn = library.makeFunction(name: name) else { throw ShaderLibrary.Failure.missingFunction(name) }
            pipelines[name] = try device.makeComputePipelineState(function: fn)
        }
        noise = try VolumeNoise(device: device, library: library)
        self.device = device
        self.library = library
    }

    /// Allocates the buffers for `capacity` particles; everything is reset.
    func allocate(_ capacity: Int) -> Bool {
        guard let device else { return false }
        self.capacity = capacity
        let n = max(capacity, 1)
        let lists = 2 * n + ParticleBudget.chunks
        guard let p = device.makeBuffer(length: n * MemoryLayout<ParticleGPU>.stride, options: .storageModePrivate),
              let f = device.makeBuffer(length: n * 4, options: .storageModePrivate),
              let a0 = device.makeBuffer(length: n * 4, options: .storageModePrivate),
              let a1 = device.makeBuffer(length: n * 4, options: .storageModePrivate),
              let d = device.makeBuffer(length: lists * 4, options: .storageModePrivate),
              let c = device.makeBuffer(length: Self.counterCount * 4, options: .storageModeShared),
              let g = device.makeBuffer(length: 64 * 4, options: .storageModeShared) else {
            self.capacity = 0
            return false
        }
        p.label = "Particles"
        memset(c.contents(), 0, c.length)
        memset(g.contents(), 0, g.length)
        // A first dispatch of one group, which finds nothing alive.
        let args = g.contents().bindMemory(to: UInt32.self, capacity: 64)
        args[0] = 1
        args[1] = 1
        args[2] = 1
        particles = p
        freeList = f
        alive = [a0, a1]
        drawLists = d
        counters = c
        arguments = g
        current = 0
        needsReset = true
        holdsParticles = false
        return true
    }

    // MARK: The frame

    /// The frame's plan, made once per frame by whichever particle pass asks
    /// first (the graph asks every pass whether it runs before any encodes).
    func plan(for f: FrameContext) -> Plan? {
        if let p = plan, plannedFor === f { return p }
        plannedFor = f
        plan = nil
        guard library != nil else { return nil }
        let settings = f.settings.particle
        // Off: nothing runs, and the particles wait as they are.
        let want = settings.quality.capacity
        if want == 0 { return nil }
        if want != capacity || particles == nil { guard allocate(want) else { return nil } }
        plan = makePlan(director.frame(f.scene, settings: settings), settings: settings)
        return plan
    }

    /// Whether the GPU works this frame, and whether it clears first: when
    /// the director resets, and once more when all it spawned has died, so
    /// nothing stale waits in the lists for the next spawn.
    func makePlan(_ out: EffectFrameOutput, settings: ParticleSettings) -> Plan {
        var resets = needsReset || out.resets && holdsParticles
        let idle = out.requests.isEmpty && out.drawn.isEmpty
        if idle && holdsParticles { resets = true }
        return Plan(output: out, works: !idle || resets, resets: resets, settings: settings)
    }

    /// Whether `c`'s particles are drawn this frame.
    func draws(_ c: ParticleRenderClass, in f: FrameContext) -> Bool {
        guard let p = plan(for: f), p.works else { return false }
        if c == .smoke && !p.settings.quality.drawsSmoke { return false }
        return p.output.drawn.contains(c)
    }

    /// The frame's kernels, on a compute encoder of the pass's own.
    func encodeSimulation(_ f: FrameContext) {
        guard let p = plan(for: f), p.works, let enc = f.makeComputeEncoder() else { return }
        f.bindFrameUniforms(enc)
        encode(p, uploads: f.arena, encoder: enc, view: Self.view(f, settings: p.settings))
        enc.endEncoding()
    }

    /// ParticleFrame's `view` for frame `f`: culling on unless the settings
    /// turn it off.
    static func view(_ f: FrameContext, settings: ParticleSettings) -> SIMD4<Float> {
        SIMD4(settings.culls ? 1 : 0, 0, 0, 0)
    }

    /// Encodes `plan` on `enc` with its small buffers from `uploads`. The
    /// frame uniforms must be bound (buffer 30); `view` zero draws every
    /// particle (the self-test).
    func encode(_ plan: Plan, uploads: ParticleUploads, encoder enc: MTLComputeCommandEncoder,
                view: SIMD4<Float> = .zero) {
        bindings = nil
        guard let particles, let freeList, let drawLists, let counters, let arguments, alive.count == 2,
              let reset = pipelines["particle_reset"], let begin = pipelines["particle_begin"],
              let simulate = pipelines["particle_simulate"], let emit = pipelines["particle_emit"],
              let compact = pipelines["particle_compact"] else { return }
        let out = plan.output
        // The requests, each with its first particle's index, no more in all
        // than the capacity.
        var requests: [ParticleRequestGPU] = [], total = 0
        for r in out.requests where r.count > 0 && total < capacity {
            var r = r
            r.count = min(r.count, capacity - total)
            requests.append(ParticleRequestGPU(r, first: total))
            total += r.count
        }
        let anchors = ParticleAnchorGPU.pack(out.anchors)
        let materials = out.materials.materials.map(ParticleMaterialGPU.init)
        var frame = ParticleFrameGPU()
        frame.time = SIMD4(Float(out.clock.dt), Float(out.clock.turbulenceTime), out.clock.holdsFlashes ? 1 : 0,
                           out.clock.advances ? 1 : 0)
        frame.counts = SIMD4(UInt32(capacity), UInt32(total), UInt32(requests.count), UInt32(current))
        frame.limits = SIMD4(UInt32(ParticleBudget.chunks), UInt32(ParticlePhysics.maxSubsteps), UInt32(anchors.count), 0)
        frame.view = view
        let drift = EffectTimeRules.noiseDrift(out.clock.turbulenceTime)
        frame.noise = SIMD4(Float(drift.x), Float(drift.y), Float(drift.z), 0)
        guard let fb = uploads.upload([frame]),
              let mb = uploads.upload(materials.isEmpty ? [ParticleMaterialGPU(.smoke)] : materials),
              let ab = uploads.upload(anchors), let pb = uploads.upload(AirProfilesGPU.pack(out.airProfiles)) else { return }
        let rb = requests.isEmpty ? nil : uploads.upload(requests)

        if let noise { noise.encodeIfNeeded(enc) }
        enc.setBuffer(particles, offset: 0, index: 0)
        enc.setBuffer(counters, offset: 0, index: 1)
        enc.setBuffer(fb.buffer, offset: fb.offset, index: 2)
        enc.setBuffer(alive[current], offset: 0, index: 3)
        enc.setBuffer(alive[1 - current], offset: 0, index: 4)
        enc.setBuffer(freeList, offset: 0, index: 5)
        enc.setBuffer(drawLists, offset: 0, index: 6)
        enc.setBuffer(mb.buffer, offset: mb.offset, index: 7)
        enc.setBuffer(ab.buffer, offset: ab.offset, index: 8)
        enc.setBuffer(pb.buffer, offset: pb.offset, index: 9)
        if let rb { enc.setBuffer(rb.buffer, offset: rb.offset, index: 10) }
        enc.setBuffer(arguments, offset: 0, index: 11)
        let one = MTLSize(width: 1, height: 1, depth: 1), group = MTLSize(width: 64, height: 1, depth: 1)
        if plan.resets {
            enc.setComputePipelineState(reset)
            enc.dispatchThreads(MTLSize(width: max(capacity, 1), height: 1, depth: 1), threadsPerThreadgroup: group)
            needsReset = false
            holdsParticles = false
        }
        enc.setComputePipelineState(begin)
        enc.dispatchThreads(one, threadsPerThreadgroup: one)
        enc.setComputePipelineState(simulate)
        enc.dispatchThreadgroups(indirectBuffer: arguments, indirectBufferOffset: 0, threadsPerThreadgroup: group)
        if total > 0, rb != nil {
            enc.setComputePipelineState(emit)
            enc.dispatchThreads(MTLSize(width: total, height: 1, depth: 1), threadsPerThreadgroup: group)
            holdsParticles = true
        }
        enc.setComputePipelineState(compact)
        enc.dispatchThreads(one, threadsPerThreadgroup: one)
        current = 1 - current
        bindings = Bindings(frame: fb, materials: mb, anchors: ab)
    }

    // MARK: Drawing

    /// Binds the particles, the draw lists and the frame's anchors,
    /// materials and uniforms (buffers 0-4) on a render encoder.
    func bindDraw(_ enc: MTLRenderCommandEncoder) -> Bool {
        guard let particles, let drawLists, let b = bindings else { return false }
        enc.setVertexBuffer(particles, offset: 0, index: 0)
        enc.setVertexBuffer(drawLists, offset: 0, index: 1)
        enc.setVertexBuffer(b.anchors.buffer, offset: b.anchors.offset, index: 2)
        enc.setVertexBuffer(b.materials.buffer, offset: b.materials.offset, index: 3)
        enc.setVertexBuffer(b.frame.buffer, offset: b.frame.offset, index: 4)
        enc.setFragmentBuffer(b.frame.buffer, offset: b.frame.offset, index: 4)
        return true
    }

    /// Draws `c`'s list, its count from the GPU.
    func draw(_ c: ParticleRenderClass, on enc: MTLRenderCommandEncoder) {
        guard let arguments else { return }
        enc.drawPrimitives(type: c == .chunk ? .triangle : .triangleStrip, indirectBuffer: arguments,
                           indirectBufferOffset: Self.drawArgumentsOffset(c))
    }

    // MARK: Reading back (self-test, tests)

    /// The counters as the GPU last left them (after the command buffer completed).
    func readCounters() -> [Counter: Int] {
        guard let counters else { return [:] }
        let p = counters.contents().bindMemory(to: UInt32.self, capacity: Self.counterCount)
        var out: [Counter: Int] = [:]
        for k in 0..<Self.counterCount { out[Counter(rawValue: k)!] = Int(p[k]) }
        return out
    }

    /// The particles in the alive list the next frame reads, copied out on
    /// `queue` (it waits).
    func readAlive(queue: MTLCommandQueue) -> [ParticleGPU] {
        guard let device, let particles, alive.count == 2, let counters else { return [] }
        let p = counters.contents().bindMemory(to: UInt32.self, capacity: Self.counterCount)
        let count = Int(p[1 + current])
        guard count > 0, let all = device.makeBuffer(length: particles.length, options: .storageModeShared),
              let list = device.makeBuffer(length: count * 4, options: .storageModeShared),
              let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return [] }
        blit.copy(from: particles, sourceOffset: 0, to: all, destinationOffset: 0, size: particles.length)
        blit.copy(from: alive[current], sourceOffset: 0, to: list, destinationOffset: 0, size: count * 4)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let indices = list.contents().bindMemory(to: UInt32.self, capacity: count)
        let ps = all.contents().bindMemory(to: ParticleGPU.self, capacity: capacity)
        return (0..<count).map { ps[Int(indices[$0])] }
    }
}
