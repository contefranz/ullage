import Foundation
import Metal
import simd
import OrbitCore
import OrbitScene

/// Exhaust plumes (track P2): each frame the scene's emitters become
/// `PlumeMember`s from P1's plume model (`PlumeLook`), clustered by vessel
/// and engine family into convex proxies (`PlumeClusters`). Clusters large
/// on screen are ray-marched at R6's half resolution (`PlumeMarchEffect`,
/// PlumeShaders); small ones are camera-facing impostors shaded from the
/// same look, far ones are left to the vessel's far point. The clusters
/// light the vessels and the pad (`PlumeLights`, through the lighting
/// uniforms), and the SPS's nozzle extension glows on its drawn bell
/// (`NozzleGlow`). Everything here is a visual approximation that never
/// feeds back into the physics.
enum Plumes {
    /// Colour of a distant vessel's point while its engines fire (R1's far
    /// points): the family's colour.
    static func pointColor(_ style: PlumeStyle) -> SIMD3<Float> {
        let c = PlumeLook.color(PlumeFamily(style))
        return SIMD3(Float(c.r), Float(c.g), Float(c.b))
    }

    /// Sides of a proxy's polygon (circumscribed about its rings).
    static let proxySides = 24
    /// Vertices a proxy draws: every edge's sides and both caps, the edges
    /// past a cluster's last ring collapsed.
    static let proxyVertices = (PlumeClusters.maximumRings - 1) * proxySides * 6 + 2 * proxySides * 3

    /// A member's noise phase along its axis now, in noise tiles: the
    /// eddies move downstream at `eddySpeed`, rounded to whole tiles an
    /// hour so the drift is the same either side of the turbulence clock's
    /// wrap.
    static func noisePhase(_ m: PlumeMember, time: Double) -> (phase: Double, tile: Double) {
        let tile = 16 * max(m.noiseScale, 1e-3)
        let perHour = (m.eddySpeed * EffectTimeRules.turbulencePeriod / tile).rounded()
        let x = perHour * time / EffectTimeRules.turbulencePeriod
        return (x - x.rounded(.down), tile)
    }

    static func f4(_ v: Vec3, _ w: Double) -> SIMD4<Float> { SIMD4(Float(v.x), Float(v.y), Float(v.z), Float(w)) }
    static func f4(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> SIMD4<Float> {
        SIMD4(Float(a), Float(b), Float(c), Float(d))
    }
    static func f4(_ c: Photometry.RGB, _ w: Double) -> SIMD4<Float> {
        SIMD4(Float(c.r), Float(c.g), Float(c.b), Float(w))
    }

    /// A member as the shader reads it.
    static func gpu(_ m: PlumeMember, turbulenceTime: Double, turbulent: Bool = true) -> PlumeMemberGPU {
        let noise = noisePhase(m, time: turbulenceTime)
        let free = m.vacuumBlend > 0.02 && m.confinement < 0.98
        let vacuumAngle = free ? tan(min(m.simonsAngle(fraction: 0.01), 85 * Double.pi / 180)) : 0
        let particleAngle = m.particleExtinction > 0 && free ? tan(min(m.particleAngle, 85 * Double.pi / 180)) : 0
        return PlumeMemberGPU(
            exit: f4(m.exit, m.exitRadius), axis: f4(m.axis, m.length),
            shape: f4(m.radiusGrowth, m.shapeLength, m.farSpread, m.coreLength),
            simons: f4(m.vacuumBlend, m.simonsExponent, m.limitingAngle, m.sourceOffset),
            gas: f4(m.gasExtinction, m.gasAlbedo, m.coreTemperature, m.expansionCooling),
            flame: f4(m.flameTemperature, m.flameStart, m.ambientTemperature, m.afterburning),
            sheath: f4(m.sheathExtinction, m.sheathThickness, m.sheathLength, m.sootBurnout),
            sheathLight: f4(PlumeLook.blackbody(m.sheathTemperature), 0),
            particles: f4(m.particleExtinction, m.particleAlbedo, m.particleTemperature, m.particleCooling),
            particles2: f4(m.particleAngle, m.particleOffset, m.particleOnset, m.phaseG),
            structure: f4(m.shockCellLength, m.shockCellCount, m.shockStrength, m.upstream),
            base: f4(PlumeLook.blackbody(m.baseTemperature), m.baseExtinction),
            disk: f4(m.machDiskDistance, m.machDiskRadius, m.machDiskExtinction, m.confinement),
            diskLight: f4(PlumeLook.blackbody(m.machDiskTemperature), 0),
            noise: f4(m.noiseScale, noise.phase, turbulent ? m.turbulence : 0, noise.tile),
            glow: f4(m.glow, m.glowLength), extent: f4(vacuumAngle, particleAngle, m.flameHold, m.flameSpread))
    }

    /// A cluster's header: its frame, proxy and light, its members at
    /// `memberStart` in the member buffer.
    static func gpu(_ c: PlumeCluster, memberStart: Int, light: PlumeLight?, sunlit: Double) -> PlumeClusterGPU {
        var rings = [SIMD4<Float>](repeating: .zero, count: 4)
        for (i, r) in c.rings.prefix(PlumeClusters.maximumRings).enumerated() {
            if i % 2 == 0 {
                rings[i / 2].x = Float(r.x)
                rings[i / 2].y = Float(r.r)
            } else {
                rings[i / 2].z = Float(r.x)
                rings[i / 2].w = Float(r.r)
            }
        }
        var g = PlumeClusterGPU()
        g.origin = f4(c.origin, Double(min(c.rings.count, PlumeClusters.maximumRings)))
        g.axis = f4(c.axis, Double(memberStart))
        g.u = f4(c.u, Double(c.members.count))
        g.v = f4(c.v, sunlit)
        g.rings = (rings[0], rings[1], rings[2], rings[3])
        // The near field's end along the axis: ten exit diameters of the
        // member reaching furthest, within the cluster.
        let near = c.members.map { m in
            (m.exit - c.origin).dot(c.axis) + min(m.length, max(10 * m.exitDiameter, m.glowLength))
        }.max() ?? c.end
        g.reserved.0 = SIMD4(Float(min(near, c.end)), 0, 0, 0)
        if let l = light {
            g.light = f4(l.centre, l.length)
            g.lightAxis = f4(l.axis, l.radius)
            g.lightColor = SIMD4(l.intensity.r, l.intensity.g, l.intensity.b, 0)
        }
        return g
    }

    /// Strips facing the camera along each member of an impostor cluster,
    /// shaded from the look: at each of `samples` stations its light and
    /// opacity seen through the axis (the reference march, lit by the Sun
    /// and the ambient), fading across.
    static func impostor(_ m: PlumeMember, sun: (direction: Vec3, illuminance: Photometry.RGB)?,
                         ambient: Photometry.RGB, to out: inout [PlumeVertex]) {
        guard m.length > 0 else { return }
        let samples = 10
        let middle = m.exit + m.axis * (0.5 * m.length)
        var side = m.axis.cross((-middle).normalized)
        if side.length < 1e-6 { side = PlumeLook.perpendicular(m.axis) }
        side = side.normalized
        // A ray through the axis across the strip, towards the camera's side.
        let towards = side.cross(m.axis).normalized
        func ring(_ i: Int) -> (PlumeVertex, PlumeVertex) {
            let t = Double(i) / Double(samples)
            let x = m.length * (t * t)
            let e = m.extent(atX: x)
            let w = max(min(1.1 * m.radius(atX: x), e), 0.5 * m.exitRadius)
            let c = m.exit + m.axis * x
            let seen = PlumeLook.march([m], from: c - towards * e, direction: towards, range: 0...(2 * e), steps: 24,
                                       sun: sun, ambient: ambient)
            let alpha = 1 - seen.transmittance
            let color = SIMD4(Float(seen.radiance.r), Float(seen.radiance.g), Float(seen.radiance.b), Float(alpha))
            return (PlumeVertex(position: f4(c - side * w, 1), color: color, shape: SIMD4(-1, Float(t), 0, 0)),
                    PlumeVertex(position: f4(c + side * w, 1), color: color, shape: SIMD4(1, Float(t), 0, 0)))
        }
        var previous = ring(0)
        for i in 1...samples {
            let next = ring(i)
            out += [previous.0, previous.1, next.1, previous.0, next.1, next.0]
            previous = next
        }
    }
}

// MARK: GPU mirrors (PlumeShaders)

/// The frame's plume uniforms (PlumeShaders' PlumeFrame).
struct PlumeFrameGPU {
    /// The blackbody per channel, exp(c0 + c1/T + c2/T²) cd/m²
    /// (`PlumeLook.wien`): rgb c0, w: march steps.
    var wienK = SIMD4<Float>.zero
    /// rgb: c1 (K), w: the turbulence clock (s).
    var wienA = SIMD4<Float>.zero
    /// xyz: unit to the Sun (world), w: 1 when the clouds' layer is bound.
    var sun = SIMD4<Float>.zero
    /// rgb: the Sun's illuminance at the plumes (lux), w: 1 to shadow it (R4).
    var sunLight = SIMD4<Float>.zero
    /// rgb: the ambient irradiance in vacuum (lux, earthshine), w: 1 to
    /// take A2's sky instead (in air).
    var ambient = SIMD4<Float>.zero
    /// x: frame index (the jitter), y: 1 with aerial perspective.
    var params = SIMD4<Float>.zero
    /// rgb: c2 (K²).
    var wienC = SIMD4<Float>.zero
}

/// A cluster's header (PlumeShaders' PlumeCluster), 15 float4.
struct PlumeClusterGPU {
    /// xyz: camera-relative origin on the exits' plane, w: rings.
    var origin = SIMD4<Float>.zero
    /// xyz: unit axis, w: the first member's index.
    var axis = SIMD4<Float>.zero
    /// xyz: unit across, w: members.
    var u = SIMD4<Float>.zero
    /// xyz: unit across (u × v = axis), w: the vessel's sunlit share.
    var v = SIMD4<Float>.zero
    /// The rings (x, r) two to a float4.
    var rings = (SIMD4<Float>.zero, SIMD4<Float>.zero, SIMD4<Float>.zero, SIMD4<Float>.zero)
    /// The cluster's own light, which lights its smoke: xyz centre, w length.
    var light = SIMD4<Float>.zero
    /// xyz: axis, w: radius.
    var lightAxis = SIMD4<Float>.zero
    /// rgb: intensity (cd).
    var lightColor = SIMD4<Float>.zero
    /// x: where the near field ends along the axis (m), which the march
    /// gives half its steps.
    var reserved = (SIMD4<Float>.zero, SIMD4<Float>.zero, SIMD4<Float>.zero, SIMD4<Float>.zero)
}

/// A member (PlumeShaders' PlumeMember): `PlumeMember`, field by field.
struct PlumeMemberGPU {
    var exit: SIMD4<Float>        // xyz camera-relative, w: exit radius
    var axis: SIMD4<Float>        // xyz unit, w: length
    var shape: SIMD4<Float>       // growth, shape length, far spread, core length
    var simons: SIMD4<Float>      // vacuum blend, exponent, limiting angle, source offset
    var gas: SIMD4<Float>         // extinction, albedo, core temperature, expansion cooling
    var flame: SIMD4<Float>       // temperature, start, ambient temperature, afterburning
    var sheath: SIMD4<Float>      // extinction, thickness, length, soot burn-out
    var sheathLight: SIMD4<Float> // rgb: the film's blackbody (cd/m²)
    var particles: SIMD4<Float>   // extinction, albedo, temperature, cooling length
    var particles2: SIMD4<Float>  // angle, source offset, onset, phase g
    var structure: SIMD4<Float>   // cell length, cells, strength, upstream
    var base: SIMD4<Float>        // rgb: the base's blackbody, w: its extinction
    var disk: SIMD4<Float>        // distance, radius, extinction, the air's confinement
    var diskLight: SIMD4<Float>   // rgb: the disk's blackbody
    var noise: SIMD4<Float>       // eddy size, phase (tiles), depth, tile (m)
    var glow: SIMD4<Float>        // rgb (cd/m²), w: length
    var extent: SIMD4<Float>      // x: tan of the 1 % Simons angle (0: none), y: the particles' (0: none),
                                  // z: the flame's hold length, w: its brush's spread
}

/// A plume impostor's vertex (PlumeShaders).
struct PlumeVertex {
    /// Camera-relative world position, w = 1.
    var position: SIMD4<Float>
    /// rgb: radiance seen through the axis (cd/m², not pre-exposed), a: opacity.
    var color: SIMD4<Float>
    /// x: across (-1...1), y: along (0 exit ... 1 tail).
    var shape: SIMD4<Float>
}

/// One glowing nozzle draw (PlumeShaders' PlumeGlowDraw).
struct PlumeGlowGPU {
    var model: simd_float4x4
    /// xyz: the nozzle's pivot (part frame), w: the extension's top radius (m).
    var pivot: SIMD4<Float>
    /// xyz: the nozzle's axis (part frame, unit), w: the heat fraction.
    var direction: SIMD4<Float>
}

// MARK: The frame's plumes

/// What one frame draws of the plumes, made in P0 (`PlumePreparePass`) and
/// drawn in P3.
struct PlumeFrameData {
    var marched: [PlumeClusterGPU] = []
    var members: [PlumeMemberGPU] = []
    var impostors: [PlumeVertex] = []
    /// The glowing nozzles: vessel, thruster, heat.
    var glows: [(vessel: UUID, thruster: RenderScene.ThrusterKey, heat: Double)] = []
    var uniforms = PlumeFrameGPU()
    var lights: [PlumeLight] = []
    /// Every cluster with its detail, for tests and the timings' report.
    var clusters: [(cluster: PlumeCluster, detail: PlumeCluster.Detail)] = []
}

/// The plumes' state across frames and the frame's plumes (P2): the
/// turbulence clock, the nozzle glow's heat, the noise volume.
@MainActor
public final class PlumeSystem {
    private(set) var frame = PlumeFrameData()
    private let glow = NozzleGlowTracker()
    private(set) var noise: VolumeNoise?
    private var turbulence = 0.0
    private var last: (frame: Int, time: Epoch)?
    /// The frame `frame` was planned for, and whether P0 has lit it.
    private weak var planned: FrameContext?
    private var lit = false

    public init() {}

    /// The clusters drawn last frame and how, for tests.
    public var lastClusters: [(cluster: PlumeCluster, detail: PlumeCluster.Detail)] { frame.clusters }

    func setUp(device: MTLDevice, shaders: ShaderLibrary) throws {
        if noise == nil { noise = try VolumeNoise(device: device, library: try shaders.library(.particle)) }
    }

    /// The frame's members: the look-dev engines when a shot gives them,
    /// else the emitters of the vessels drawn as meshes.
    static func members(_ scene: RenderScene, settings: PlumeSettings,
                        drawn: (UUID) -> Bool) -> [PlumeMember] {
        if !settings.testEngines.isEmpty {
            let frame = EffectTargetFrame(scene: scene)
            return settings.testEngines.flatMap { PlumeLook.members($0, in: frame, settings: settings) }
        }
        return scene.emitters.filter { drawn($0.vesselID) }.compactMap { PlumeLook.member($0, settings: settings) }
    }

    /// What the frame draws, from the scene alone: the members, clusters
    /// and their detail, the glowing nozzles. Once a frame, on the first
    /// question: the frame graph asks which passes run before P0 does.
    func plan(_ f: FrameContext) {
        guard planned !== f else { return }
        planned = f
        lit = false
        let scene = f.scene, settings = f.settings.plume
        // The turbulence clock: real dt × min(warp, 4), reset with the scene.
        let clock = scene.clock
        if let last, clock.frameIndex >= last.frame, !EffectTimeRules.isTimeJump(clock.simTime - last.time) {
            if clock.frameIndex > last.frame {
                turbulence += EffectTimeRules.turbulenceDt(realDt: clock.realDt, warp: clock.warp, paused: clock.paused)
                turbulence = turbulence.truncatingRemainder(dividingBy: EffectTimeRules.turbulencePeriod)
            }
        } else {
            turbulence = 0
        }
        last = (clock.frameIndex, clock.simTime)

        var data = PlumeFrameData()
        let heats = glow.update(scene)
        if settings.nozzleGlow && settings.quality != .off {
            for v in scene.vessels where f.drawsMesh(v.id) {
                for part in v.geometry.parts {
                    for t in part.thrusters { if let h = heats[t.key] { data.glows.append((v.id, t.key, h)) } }
                }
            }
        }
        if settings.quality != .off {
            let clusters = PlumeClusters.clusters(Self.members(scene, settings: settings) { f.drawsMesh($0) })
            data.clusters = clusters.map { ($0, PlumeClusters.detail($0, camera: scene.camera, settings: settings)) }
        }
        frame = data
    }

    /// Whether anything of the plumes draws in the half-resolution march,
    /// and at full resolution (impostors, glows).
    func marches(_ f: FrameContext) -> Bool {
        plan(f)
        return frame.clusters.contains { $0.detail == .march }
    }

    func drawsFullResolution(_ f: FrameContext) -> Bool {
        plan(f)
        return !frame.glows.isEmpty || frame.clusters.contains { $0.detail == .impostor }
    }

    /// Lights the frame's plumes once P0 has the air (A2) and the clouds
    /// (C2): the marched clusters' buffers, the impostors' strips, the
    /// uniforms, and the plume lights written into the frame's lighting.
    func prepare(_ f: FrameContext) {
        plan(f)
        guard !lit else { return }
        lit = true
        let scene = f.scene, settings = f.settings.plume
        var data = frame
        let sun = scene.sun
        let air = f.atmosphere.radii.w > 0.5 && f.atmosphere.sunTransmitted.w > 0
        let sunLux = air ? Photometry.RGB(Double(f.atmosphere.sunTransmitted.x * f.atmosphere.sunTransmitted.w),
                                          Double(f.atmosphere.sunTransmitted.y * f.atmosphere.sunTransmitted.w),
                                          Double(f.atmosphere.sunTransmitted.z * f.atmosphere.sunTransmitted.w))
            : Photometry.sunColor.scaled(by: sun.illuminance)
        // The ambient stub until R3's probe: A2's sky in air, the
        // earthshine of the focus vessel's stand-in in vacuum.
        let focus = scene.vessels.first { $0.isFocus } ?? scene.vessels.first
        let earth = focus.map { v in
            Photometry.RGB(Double(v.light.earthColor.r), Double(v.light.earthColor.g), Double(v.light.earthColor.b))
                .scaled(by: v.light.earthStrength * v.light.earthLit * sun.illuminance)
        } ?? Photometry.RGB(0, 0, 0)
        let sky = air ? Photometry.RGB(Double(f.atmosphere.skyIrradiance.x), Double(f.atmosphere.skyIrradiance.y),
                                       Double(f.atmosphere.skyIrradiance.z)) : earth
        let lights = data.clusters.map { PlumeLights.light($0.cluster) }
        for ((c, detail), light) in zip(data.clusters, lights) {
            let sunlit = c.vesselID.flatMap { id in scene.vessels.first { $0.id == id }?.light.sunlit } ?? 1
            switch detail {
            case .march:
                data.marched.append(Plumes.gpu(c, memberStart: data.members.count, light: light, sunlit: sunlit))
                data.members += c.members.map {
                    Plumes.gpu($0, turbulenceTime: turbulence, turbulent: settings.turbulence)
                }
            case .impostor:
                let lit = sunlit > 0 ? (direction: sun.direction, illuminance: sunLux.scaled(by: sunlit)) : nil
                for m in c.members { Plumes.impostor(m, sun: lit, ambient: sky, to: &data.impostors) }
            case .none:
                break
            }
        }
        let w = PlumeLook.wien
        var u = PlumeFrameGPU()
        u.wienK = SIMD4(Float(w[0].0), Float(w[1].0), Float(w[2].0), Float(settings.quality.steps))
        u.wienA = SIMD4(Float(w[0].1), Float(w[1].1), Float(w[2].1), Float(turbulence))
        u.wienC = SIMD4(Float(w[0].2), Float(w[1].2), Float(w[2].2), 0)
        u.sun = Plumes.f4(sun.direction, f.textures[.cloudLayer] != nil ? 1 : 0)
        u.sunLight = Plumes.f4(sunLux, f.settings.shadow.enabled ? 1 : 0)
        u.ambient = Plumes.f4(earth, air ? 1 : 0)
        u.params = SIMD4(Float(scene.clock.frameIndex % 1024), f.settings.atmosphere.enabled ? 1 : 0, 0, 0)
        data.uniforms = u

        // The lights, the brightest at the camera first.
        let maximum = min(f.settings.shading.plumeLights, LightingUniforms.maxLocalLights)
        func weight(_ l: PlumeLight) -> Double { l.luminousIntensity / max(l.centre.lengthSquared, l.length * l.length) }
        data.lights = Array(lights.compactMap { $0 }.sorted { weight($0) > weight($1) }.prefix(max(maximum, 0)))
        if !data.lights.isEmpty {
            var list = [LocalLight](repeating: LocalLight(), count: LightingUniforms.maxLocalLights)
            for (i, l) in data.lights.enumerated() {
                list[i].positionRadius = Plumes.f4(l.centre, l.radius)
                list[i].axisLength = Plumes.f4(l.axis, l.length)
                list[i].intensity = SIMD4(l.intensity.r, l.intensity.g, l.intensity.b, Float(l.range))
            }
            f.lighting.lightCount = SIMD4(Float(data.lights.count), 0, 0, 0)
            f.lighting.lights = (list[0], list[1], list[2], list[3], list[4], list[5], list[6], list[7])
        }
        frame = data
    }

    /// Writes the noise's texels, once (P0).
    func encodeNoise(_ enc: MTLComputeCommandEncoder) { noise?.encodeIfNeeded(enc) }
}
