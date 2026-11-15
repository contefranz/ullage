import Foundation
import Metal
import OrbitCore
import OrbitScene

/// `OrbitSim --selftest effects` (P3): compiles the effect shader modules
/// (particles, plumes, entry), runs the particle kernels on the core's
/// golden vectors (P1's drag step, P3's advance) and the volume noise
/// against its CPU field, then whole frames of the particle system: spawning
/// and ageing against `EmitSampler` and `ParticlePhysics` in Double, every
/// slot accounted for, flashes held at warp, the budget kept. The app exits
/// non-zero if any check fails; OrbitRenderTests runs the same.
@MainActor
public enum EffectsSelfTest {
    public struct Check: Equatable {
        public var name: String
        public var passed: Bool
        public var detail: String
    }

    public struct Report {
        public var checks: [Check]
        public var passed: Bool { !checks.isEmpty && checks.allSatisfy(\.passed) }

        /// One line a check, then a summary.
        public var text: String {
            let lines = checks.map { "\($0.passed ? "PASS" : "FAIL") \($0.name): \($0.detail)" }
            let failed = checks.filter { !$0.passed }.count
            return (lines + ["effects self-test: \(checks.count) checks, \(failed) failed"]).joined(separator: "\n")
        }
    }

    /// Runs every check on `device` (the system's by default).
    public static func run(device: MTLDevice? = nil) -> Report {
        guard let device = device ?? MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            return Report(checks: [Check(name: "device", passed: false, detail: "no Metal device")])
        }
        var checks: [Check] = []
        let shaders = ShaderLibrary(device: device)
        for module in [ShaderModule.particle, .plume, .entry] {
            do {
                _ = try shaders.library(module)
                checks.append(Check(name: "module \(module.name)", passed: true, detail: "compiles"))
            } catch {
                checks.append(Check(name: "module \(module.name)", passed: false, detail: "\(error)"))
            }
        }
        guard let library = try? shaders.library(.particle) else { return Report(checks: checks) }
        let t = Runner(device: device, queue: queue, library: library)
        checks.append(t.sizes())
        checks.append(t.goldenSteps())
        checks.append(t.goldenAdvances())
        checks.append(t.noise())
        let system = ParticleSystem(director: EffectDirector(producers: []))
        do {
            try system.setUp(device: device, shaders: shaders)
            checks += t.frames(system)
        } catch {
            checks.append(Check(name: "particle system", passed: false, detail: "\(error)"))
        }
        return Report(checks: checks)
    }

    /// `--selftest effects` on the command line: runs, prints the report and
    /// exits with its status. Any other `--selftest` exits 2.
    public static func runIfAsked(_ arguments: [String] = CommandLine.arguments) {
        guard let i = arguments.firstIndex(of: "--selftest") else { return }
        let what = i + 1 < arguments.count ? arguments[i + 1] : ""
        guard what == "effects" else {
            print("usage: OrbitSim --selftest effects")
            exit(2)
        }
        let report = run()
        print(report.text)
        exit(report.passed ? 0 : 1)
    }
}

/// Buffers made afresh, for frames run outside the renderer.
final class SelfTestUploads: ParticleUploads {
    let device: MTLDevice
    init(device: MTLDevice) { self.device = device }

    func upload<T>(_ items: [T]) -> (buffer: MTLBuffer, offset: Int)? {
        guard !items.isEmpty else { return nil }
        return items.withUnsafeBytes { bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared).map { ($0, 0) }
        }
    }
}

extension EffectsSelfTest {
    @MainActor
    struct Runner {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let library: MTLLibrary

        typealias Check = EffectsSelfTest.Check

        /// Runs `name` over `count` threads with `buffers` bound in order, and waits.
        func dispatch(_ name: String, count: Int, buffers: [MTLBuffer]) -> Bool {
            guard let fn = library.makeFunction(name: name), let pipeline = try? device.makeComputePipelineState(function: fn),
                  let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return false }
            enc.setComputePipelineState(pipeline)
            for (i, b) in buffers.enumerated() { enc.setBuffer(b, offset: 0, index: i) }
            enc.dispatchThreads(MTLSize(width: max(count, 1), height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
            enc.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            return cb.status == .completed
        }

        func buffer<T>(_ items: [T]) -> MTLBuffer? {
            items.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: max($0.count, 16), options: .storageModeShared) }
        }

        func floats(_ b: MTLBuffer, _ n: Int) -> [SIMD4<Float>] {
            Array(UnsafeBufferPointer(start: b.contents().bindMemory(to: SIMD4<Float>.self, capacity: n), count: n))
        }

        // MARK: Structs and goldens

        func sizes() -> Check {
            guard let out = device.makeBuffer(length: 64, options: .storageModeShared),
                  dispatch("particle_sizes", count: 1, buffers: [out]) else {
                return Check(name: "struct sizes", passed: false, detail: "kernel failed")
            }
            let v = Array(UnsafeBufferPointer(start: out.contents().bindMemory(to: UInt32.self, capacity: 7), count: 7)).map(Int.init)
            let swift = [MemoryLayout<ParticleGPU>.stride, MemoryLayout<ParticleMaterialGPU>.stride,
                         MemoryLayout<ParticleAnchorGPU>.stride, MemoryLayout<ParticleRequestGPU>.stride,
                         MemoryLayout<ParticleFrameGPU>.stride, MemoryLayout<GoldenStepGPU>.stride,
                         MemoryLayout<GoldenAdvanceGPU>.stride]
            return Check(name: "struct sizes", passed: v == swift && v[0] == 48, detail: "MSL \(v), Swift \(swift)")
        }

        /// ParticleShaders' ParticleGoldenStep and ParticleGoldenAdvance.
        struct GoldenStepGPU {
            var position, velocity, air, gravity, params: SIMD4<Float>
        }

        struct GoldenAdvanceGPU {
            var positionRadius, velocityTemperature, air, airVelocity, gravity, frameAcceleration, airAcceleration,
                params: SIMD4<Float>
        }

        static func tau(_ t: Double) -> Float { t.isFinite ? Float(t) : 1e30 }

        /// P1's exact step on its golden vectors.
        func goldenSteps() -> Check {
            let cases = ParticleKinematics.goldenCases
            let input = cases.map {
                GoldenStepGPU(position: SIMD4($0.position, 0), velocity: SIMD4($0.velocity, 0), air: SIMD4($0.airVelocity, 0),
                              gravity: SIMD4($0.gravity, 0), params: SIMD4(Self.tau($0.relaxationTime), Float($0.dt), 0, 0))
            }
            var count = UInt32(cases.count)
            guard let inB = buffer(input), let out = device.makeBuffer(length: cases.count * 32, options: .storageModeShared),
                  let n = device.makeBuffer(bytes: &count, length: 4, options: .storageModeShared),
                  dispatch("particle_golden_step", count: cases.count, buffers: [inB, out, n]) else {
                return Check(name: "drag step goldens (P1)", passed: false, detail: "kernel failed")
            }
            let o = floats(out, 2 * cases.count)
            var worst = 0.0, worstName = ""
            for (i, c) in cases.enumerated() {
                let scale = max(1, c.expectedPosition.length, c.velocity.length * c.dt, c.gravity.length * c.dt * c.dt)
                let vScale = max(1, c.expectedVelocity.length, c.velocity.length, c.gravity.length * c.dt)
                let e = max(Self.distance(o[2 * i], c.expectedPosition) / scale, Self.distance(o[2 * i + 1], c.expectedVelocity) / vScale)
                if e > worst { (worst, worstName) = (e, c.name) }
            }
            return Check(name: "drag step goldens (P1)", passed: worst < 1e-5,
                         detail: String(format: "%d cases, worst relative error %.2e (%@)", cases.count, worst, worstName))
        }

        /// P3's advance on its golden vectors.
        func goldenAdvances() -> Check {
            let cases = ParticlePhysics.goldenCases
            let input = cases.map { c in
                GoldenAdvanceGPU(positionRadius: SIMD4(c.state.position, Float(c.state.radius)),
                                 velocityTemperature: SIMD4(c.state.velocity, Float(c.state.temperature)),
                                 air: SIMD4(Float(c.air.density), Float(c.air.temperature), Float(c.air.pressure), 0),
                                 airVelocity: SIMD4(c.air.velocity, 0),
                                 gravity: SIMD4(c.environment.gravity, Float(c.environment.vacuumIceTemperature)),
                                 frameAcceleration: SIMD4(c.environment.frameAcceleration, 0),
                                 airAcceleration: SIMD4(c.environment.airAcceleration, 0),
                                 params: SIMD4(Float(c.dt), Float(ParticlePhysics.maxSubsteps), 0, 0))
            }
            let materials = cases.map { c -> ParticleMaterialGPU in
                var m = ParticleMaterial(name: c.name, renderClass: .smoke)
                let p = c.material
                m.density = p.density
                m.dragCoefficient = p.dragCoefficient
                m.buoyancy = p.buoyancy
                m.entrainment = p.entrainment
                m.spreadRate = p.spreadRate
                m.coolingTime = p.coolingTime
                m.sublimates = p.sublimates
                return ParticleMaterialGPU(m)
            }
            var count = UInt32(cases.count)
            guard let inB = buffer(input), let mB = buffer(materials),
                  let out = device.makeBuffer(length: cases.count * 32, options: .storageModeShared),
                  let n = device.makeBuffer(bytes: &count, length: 4, options: .storageModeShared),
                  dispatch("particle_golden_advance", count: cases.count, buffers: [inB, mB, out, n]) else {
                return Check(name: "particle physics goldens (P3)", passed: false, detail: "kernel failed")
            }
            let o = floats(out, 2 * cases.count)
            var worst = 0.0, worstName = ""
            for (i, c) in cases.enumerated() {
                let e = Self.error(gpu: (o[2 * i], o[2 * i + 1]), expected: c.expected, from: c.state, dt: c.dt)
                if e > worst { (worst, worstName) = (e, c.name) }
            }
            return Check(name: "particle physics goldens (P3)", passed: worst < 2e-4,
                         detail: String(format: "%d cases, worst relative error %.2e (%@)", cases.count, worst, worstName))
        }

        static func distance(_ a: SIMD4<Float>, _ b: Vec3) -> Double {
            (Vec3(Double(a.x), Double(a.y), Double(a.z)) - b).length
        }

        /// The largest of the position, velocity, radius and temperature
        /// errors, each relative to its own scale.
        static func error(gpu: (SIMD4<Float>, SIMD4<Float>), expected e: ParticlePhysics.State,
                          from s: ParticlePhysics.State, dt: Double) -> Double {
            let travel = max(1, (e.position - s.position).length, e.position.length * 1e-2)
            let speed = max(1, e.velocity.length, s.velocity.length)
            let dx = distance(gpu.0, e.position) / travel, dv = distance(gpu.1, e.velocity) / speed
            let dr = abs(Double(gpu.0.w) - e.radius) / max(e.radius, s.radius * 1e-3, 1e-9)
            let dT = abs(Double(gpu.1.w) - e.temperature) / max(e.temperature, 1)
            return max(dx, dv, dr, dT)
        }

        // MARK: Noise

        func noise() -> Check {
            guard let noise = try? VolumeNoise(device: device, library: library), let cb = queue.makeCommandBuffer(),
                  let enc = cb.makeComputeCommandEncoder() else {
                return Check(name: "volume noise", passed: false, detail: "no texture")
            }
            noise.encodeIfNeeded(enc)
            enc.endEncoding()
            let n = VolumeNoiseField.size
            guard let out = device.makeBuffer(length: n * n * n * 2, options: .storageModeShared),
                  let blit = cb.makeBlitCommandEncoder() else {
                return Check(name: "volume noise", passed: false, detail: "no buffer")
            }
            blit.copy(from: noise.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: n, height: n, depth: n), to: out, destinationOffset: 0,
                      destinationBytesPerRow: n * 2, destinationBytesPerImage: n * n * 2)
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            let texels = out.contents().bindMemory(to: UInt8.self, capacity: n * n * n * 2)
            var worst = 0.0, sum = 0.0
            var state: UInt32 = 7
            for _ in 0..<4_096 {
                let x = Int(ParticleRandom.uniform(&state) * Double(n)), y = Int(ParticleRandom.uniform(&state) * Double(n))
                let z = Int(ParticleRandom.uniform(&state) * Double(n))
                for c in 0..<2 {
                    let g = Double(texels[((z * n + y) * n + x) * 2 + c]) / 255
                    worst = max(worst, abs(g - VolumeNoiseField.value(x, y, z, channel: c)))
                    sum += g
                }
            }
            let mean = sum / 8_192
            return Check(name: "volume noise", passed: worst <= 1.5 / 255 && abs(mean - 0.5) < 0.05,
                         detail: String(format: "4,096 texels against the CPU field: worst %.4f, mean %.3f", worst, mean))
        }

        // MARK: Whole frames

        /// A studio anchor in constant sea-level air with a light wind, under gravity.
        static let air = ParticlePhysics.Air(density: 1.2, temperature: 290, pressure: 101_325, velocity: Vec3(3, -1, 0))

        /// US76 with a wind veering and growing with height.
        static let stratified: AirProfile = {
            var p = AirProfile(USStandardAtmosphere1976())
            for i in 0..<AirProfile.count {
                p.windEast[i] = 5 + AirProfile.altitude(i) / 1_000
                p.windNorth[i] = -3 + AirProfile.altitude(i) / 4_000
            }
            return p
        }()

        /// A free-fall anchor at 5 km climbing at 200 m/s, the body turning
        /// under it, in that air (profile 1).
        static let climbing = AnchorFrame(origin: Vec3(0, 0, -80), toWorld: .identity, up: .unitZ, east: .unitX,
                                          north: .unitY, altitude: 5_000, groundAltitude: -.infinity, radius: 6.376e6,
                                          gravity: Vec3(0, 0, -9.79), fallsFreely: true,
                                          airVelocity: Vec3(30, -10, -200), rotation: Vec3(0, 4.1e-5, 6.0e-5),
                                          airProfile: 1, sunlitFraction: 1, vacuumIceTemperature: 205)

        static func anchor(falling: Bool = false) -> AnchorFrame {
            AnchorFrame(origin: Vec3(0, 0, -50), toWorld: .identity, up: .unitZ, east: .unitX, north: .unitY,
                        altitude: 100, groundAltitude: -.infinity, radius: 6.371e6, gravity: Vec3(0, 0, -9.80665),
                        fallsFreely: falling, airVelocity: .zero, rotation: .zero, airProfile: 0, sunlitFraction: 1,
                        vacuumIceTemperature: 205)
        }

        func frames(_ system: ParticleSystem) -> [Check] {
            let capacity = 8_192
            guard system.allocate(capacity) else { return [Check(name: "particle system", passed: false, detail: "no buffers")] }
            let uploads = SelfTestUploads(device: device)
            let materials = ParticleMaterialTable()
            let steam = materials.register(.steam), spark = materials.register(.spark), flash = materials.register(.flash)
            let id = EffectAnchorID(slot: 0, generation: 1), falling = EffectAnchorID(slot: 1, generation: 1)
            let climbing = EffectAnchorID(slot: 2, generation: 1)
            let profile = AirProfile(constant: Self.air, windEast: Self.air.velocity.x, windNorth: Self.air.velocity.y)
            var epoch = Epoch(tdbSecondsPastJ2000: 0)

            func run(_ requests: [EmitRequest], dt: Double, warp: Double = 1, resets: Bool = false, anchored: Bool = true,
                     drawn: Set<ParticleRenderClass> = [.smoke, .streak]) -> (alive: Int, free: Int, emitted: Int, dropped: Int) {
                epoch = epoch + dt
                let clock = EffectClock(epoch: epoch, dt: dt, realDt: dt / warp, warp: warp)
                let out = EffectFrameOutput(clock: clock, resets: resets, requests: requests,
                                            anchors: anchored ? [(id, Self.anchor()), (falling, Self.anchor(falling: true)),
                                                                 (climbing, Self.climbing)] : [],
                                            airProfiles: [profile, Self.stratified], drawn: drawn, materials: materials)
                guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return (-1, -1, -1, -1) }
                // No view: every particle is drawn (ParticleFrame.view zero).
                var uniforms = FrameUniforms()
                enc.setBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: Binding.frameBuffer)
                system.encode(system.makePlan(out, settings: ParticleSettings()), uploads: uploads, encoder: enc)
                enc.endEncoding()
                cb.commit()
                cb.waitUntilCompleted()
                let c = system.readCounters()
                let alive = system.current == 0 ? c[.aliveA]! : c[.aliveB]!
                return (alive, c[.free]!, c[.emitted]!, c[.dropped]!)
            }

            var checks: [Check] = []
            // 1. Spawn and age: every particle where the CPU puts it.
            var puffs = EmitRequest(anchor: id, material: steam, count: 2_048)
            puffs.origin = Vec3(2, 3, 4)
            puffs.shape = .ball(radius: 5)
            puffs.direction = .axis(spread: 0.5)
            puffs.speed = 5...15
            puffs.ages = 0...4
            puffs.lifetime = 10...20
            puffs.radius = 1...3
            puffs.temperature = 400
            puffs.sourceVelocity = Vec3(1, 0, 0)
            puffs.seed = 11
            var sparks = EmitRequest(anchor: id, material: spark, count: 512)
            sparks.shape = .sphere(radius: 0.5)
            sparks.direction = .radial(spread: 0.2)
            sparks.speed = 20...60
            sparks.ages = 0...0.6
            sparks.lifetime = 1...2
            sparks.radius = 1e-3...3e-3
            sparks.temperature = 2_600
            sparks.seed = 12
            // The same puffs in a free-falling anchor (another material, to tell them apart).
            let fallingSteam = materials.register({ var m = ParticleMaterial.steam; m.name = "falling steam"; return m }())
            var fallingPuffs = puffs
            fallingPuffs.anchor = falling
            fallingPuffs.material = fallingSteam
            fallingPuffs.count = 1_024
            fallingPuffs.seed = 13
            let first = run([puffs, sparks, fallingPuffs], dt: 0, resets: true)
            let gpu = system.readAlive(queue: queue)
            var errors: [Double] = []
            for (r, mat) in [(puffs, ParticleMaterial.steam), (sparks, ParticleMaterial.spark),
                             (fallingPuffs, ParticleMaterial.steam)] {
                let mine = gpu.filter { $0.material == r.material.index }.sorted { $0.velocityAge.w < $1.velocityAge.w }
                let cpu = (0..<r.count).map { EmitSampler.sample(r, index: $0) }.sorted { $0.age < $1.age }
                guard mine.count == cpu.count else {
                    errors.append(.infinity)
                    continue
                }
                for (g, c) in zip(mine, cpu) {
                    let start = ParticlePhysics.State(position: c.position, velocity: c.velocity, radius: c.radius,
                                                      temperature: r.temperature)
                    let gravity = Vec3(0, 0, -9.80665)
                    let env = r.anchor == falling
                        ? ParticlePhysics.Environment.freeFall(gravity: gravity, vacuumIceTemperature: 205)
                        : ParticlePhysics.Environment(gravity: gravity, vacuumIceTemperature: 205)
                    let e = ParticlePhysics.advance(start, material: mat.physics, environment: env, dt: c.age) { _ in Self.air }
                    errors.append(Self.error(gpu: (g.positionRadius, SIMD4(g.velocityAge.x, g.velocityAge.y, g.velocityAge.z,
                                                                            g.state.1)), expected: e, from: start, dt: c.age))
                }
            }
            let sorted = errors.sorted()
            let p99 = sorted.isEmpty ? .infinity : sorted[Int(Double(sorted.count - 1) * 0.99)]
            checks.append(Check(name: "spawn and age", passed: first.alive == 3_584 && p99 < 1e-3 && (sorted.last ?? .infinity) < 0.03,
                                detail: String(format: "%d alive of 3,584 (1,024 in a falling anchor); against the CPU p99 %.2e, worst %.2e",
                                               first.alive, p99, sorted.last ?? .infinity)))

            // 1b. In stratified air with a wind shear, in a climbing anchor
            // over a turning body: the profile's levels, the adiabat, the
            // anchor's air (its velocity, ω × p, the wind) and its own
            // climb, against AnchorFrame.air and .environment.
            let rising = materials.register({ var m = ParticleMaterial.smoke; m.name = "rising smoke"; return m }())
            let flakes = materials.register(.iceFlake)
            var smokeUp = EmitRequest(anchor: climbing, material: rising, count: 512)
            smokeUp.shape = .ball(radius: 20)
            smokeUp.speed = 5...20
            smokeUp.ages = 0...6
            smokeUp.lifetime = 30...40
            smokeUp.radius = 2...4
            smokeUp.temperature = 420
            smokeUp.seed = 21
            var ice = EmitRequest(anchor: climbing, material: flakes, count: 256)
            ice.shape = .ball(radius: 10)
            ice.speed = 1...4
            ice.ages = 0...6
            ice.lifetime = 60...60
            ice.radius = 1e-3...3e-3
            ice.seed = 22
            let strat = run([smokeUp, ice], dt: 0, resets: true)
            let gpuStrat = system.readAlive(queue: queue)
            let frame = Self.climbing, env = frame.environment
            var stratErrors: [Double] = []
            for (r, mat) in [(smokeUp, materials[rising]), (ice, ParticleMaterial.iceFlake)] {
                let mine = gpuStrat.filter { $0.material == r.material.index }.sorted { $0.velocityAge.w < $1.velocityAge.w }
                let cpu = (0..<r.count).map { EmitSampler.sample(r, index: $0) }.sorted { $0.age < $1.age }
                guard mine.count == cpu.count else {
                    stratErrors.append(.infinity)
                    continue
                }
                for (g, c) in zip(mine, cpu) {
                    let t0 = r.temperature > 0 ? r.temperature
                        : frame.air(at: c.position + env.frameDisplacement(at: -c.age), profile: Self.stratified).temperature
                    let start = ParticlePhysics.State(position: c.position, velocity: c.velocity, radius: c.radius,
                                                      temperature: t0)
                    let e = ParticlePhysics.advance(start, material: mat.physics, environment: env, dt: c.age) {
                        frame.air(at: $0, profile: Self.stratified)
                    }
                    stratErrors.append(Self.error(gpu: (g.positionRadius, SIMD4(g.velocityAge.x, g.velocityAge.y,
                                                                                 g.velocityAge.z, g.state.1)),
                                                  expected: e, from: start, dt: c.age))
                }
            }
            let ss = stratErrors.sorted()
            let sp99 = ss.isEmpty ? .infinity : ss[Int(Double(ss.count - 1) * 0.99)]
            checks.append(Check(name: "stratified air", passed: strat.alive == 768 && sp99 < 1e-3 && (ss.last ?? .infinity) < 0.03,
                                detail: String(format: "%d alive of 768 in a climbing anchor through US76 and a wind shear; against the CPU p99 %.2e, worst %.2e",
                                               strat.alive, sp99, ss.last ?? .infinity)))

            // 2. Every slot accounted for as particles die.
            _ = run([puffs, sparks, fallingPuffs], dt: 0, resets: true)
            let half = run([], dt: 1.2)
            let none = run([], dt: 30)
            checks.append(Check(name: "slots", passed: first.alive + first.free == capacity && half.alive + half.free == capacity
                                    && half.alive < first.alive && none.alive == 0 && none.free == capacity,
                                detail: "alive + free: \(first.alive + first.free), \(half.alive + half.free), "
                                    + "\(none.alive + none.free) of \(capacity); alive \(first.alive) → \(half.alive) → \(none.alive)"))

            // 3. A flash that ended within a 100× frame is drawn on 3 frames; at 1× it is not spawned.
            var f = EmitRequest(anchor: id, material: flash, count: 10)
            f.ages = 0.5...0.5
            f.lifetime = 0.1...0.1
            f.radius = 0.5...0.5
            let held = [run([f], dt: 1.7, warp: 100, resets: true), run([], dt: 1.7, warp: 100), run([], dt: 1.7, warp: 100),
                        run([], dt: 1.7, warp: 100)].map(\.alive)
            let slow = run([f], dt: 1.0 / 60, warp: 1, resets: true).alive
            checks.append(Check(name: "flash hold", passed: held == [10, 10, 10, 0] && slow == 0,
                                detail: "alive over four 100× frames \(held); at 1× \(slow)"))

            // 4. The budget: past the capacity the newest are dropped.
            var flood = EmitRequest(anchor: id, material: steam, count: capacity + 1_000)
            flood.lifetime = 100...100
            flood.radius = 1...1
            let full = run([flood], dt: 0, resets: true)
            var more = flood
            more.count = 100
            let over = run([more], dt: 0.1)
            checks.append(Check(name: "budget", passed: full.alive == capacity && full.free == 0 && over.alive == capacity
                                    && over.dropped == 100,
                                detail: "\(full.alive) alive of \(capacity); 100 more: \(over.dropped) dropped"))

            // 5. Particles whose anchor is gone go with it.
            let kept = run([more], dt: 0.1, resets: true).alive
            let gone = run([], dt: 0.1, anchored: false).alive
            checks.append(Check(name: "anchor gone", passed: kept == 100 && gone == 0,
                                detail: "alive \(kept) with the anchor, \(gone) without"))
            _ = run([], dt: 0, resets: true)
            return checks
        }
    }
}
