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
        let vacuumAngle = free ? tan(min(m.simonsAngle(fraction: m.extentFraction), 85 * Double.pi / 180)) : 0
        let particleAngle = m.particleExtinction > 0 && free ? tan(min(m.particleAngle, 85 * Double.pi / 180)) : 0
        return PlumeMemberGPU(
            exit: f4(m.exit, m.exitRadius), axis: f4(m.axis, m.length),
            shape: f4(m.radiusGrowth, m.shapeLength, m.farSpread, m.coreLength),
            simons: f4(m.vacuumBlend, m.simonsExponent, m.limitingAngle, m.sourceOffset),
            gas: f4(m.gasExtinction, m.gasAlbedo, m.coreTemperature, m.expansionCooling),
            flame: f4(m.flameTemperature, m.flameStart, m.ambientTemperature, m.afterburning),
            sheath: f4(m.sheathExtinction, m.sheathThickness, m.sheathLength, m.sootBurnout),
            sheathLight: f4(PlumeLook.blackbody(m.sheathTemperature), m.radiusOffset),
            particles: f4(m.particleExtinction, m.particleAlbedo, m.particleTemperature, m.particleCooling),
            particles2: f4(m.particleAngle, m.particleOffset, m.particleOnset, m.phaseG),
            structure: f4(m.shockCellLength, m.shockCellCount, m.shockStrength, m.upstream),
            base: f4(PlumeLook.blackbody(m.baseTemperature), m.baseExtinction),
            disk: f4(m.machDiskDistance, m.machDiskRadius, m.machDiskExtinction, m.confinement),
            diskLight: f4(PlumeLook.blackbody(m.machDiskTemperature), m.densityScale),
            noise: f4(m.noiseScale, noise.phase, turbulent ? m.turbulence : 0, noise.tile),
            glow: f4(m.glow, m.glowLength), extent: f4(vacuumAngle, particleAngle, m.flameLength, m.flameSpread),
            bendDirection: f4(m.bend.direction, m.handoverFade?.lowerBound ?? -1),
            bendSpan: f4(m.bend.length, m.fadeStart ?? -1, m.bend.largest, m.handoverFade?.upperBound ?? -1),
            bendNear: offsets(m.bend, 0), bendFar: offsets(m.bend, 4))
    }

    /// Four of a bend's offsets from `first` (zero without a bend).
    static func offsets(_ b: PlumeBend, _ first: Int) -> SIMD4<Float> {
        guard b.offsets.count == PlumeBend.stations else { return .zero }
        return SIMD4(Float(b.offsets[first]), Float(b.offsets[first + 1]), Float(b.offsets[first + 2]),
                     Float(b.offsets[first + 3]))
    }

    /// How far a marched cluster is for R6's back-to-front order: its
    /// proxy's middle on the axis, from the camera (m).
    static func drawDistance(_ c: PlumeCluster) -> Double {
        (c.origin + c.axis * (0.5 * (c.start + c.end))).length
    }

    /// `items` far to near by their clusters' `drawDistance`.
    static func farToNear<T>(_ items: [T], _ cluster: (T) -> PlumeCluster) -> [T] {
        items.map { ($0, drawDistance(cluster($0))) }.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// A cluster's header: its frame, proxy and light, its members at
    /// `memberStart` in the member buffer, marched in `steps` (0: the
    /// frame's).
    static func gpu(_ c: PlumeCluster, memberStart: Int, light: PlumeLight?, sunlit: Double,
                    steps: Int = 0) -> PlumeClusterGPU {
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
        g.reserved.0 = SIMD4(Float(min(near, c.end)), Float(c.merged == nil ? 0 : c.mergeX), Float(steps), 0)
        if let l = light {
            g.light = f4(l.centre, l.length)
            g.lightAxis = f4(l.axis, l.radius)
            g.lightColor = SIMD4(l.intensity.r, l.intensity.g, l.intensity.b, 0)
        }
        return g
    }

    /// Strips facing the camera along each member of an impostor cluster,
    /// shaded from the look: at each of `samples` stations its light and
    /// opacity seen through the axis from the camera's side (the reference
    /// march, lit by the Sun at the view ray's phase), and its response to
    /// the ambient, which the fragment lights as the march does (R3's SH9,
    /// or the stub), fading across; and, as M1.5's did, a disc over the exit
    /// facing the camera that carries the plume seen end on, weighted by how
    /// nearly it is.
    static func impostor(_ m: PlumeMember, sun: (direction: Vec3, illuminance: Photometry.RGB)?,
                         to out: inout [PlumeVertex]) {
        guard m.length > 0 else { return }
        let samples = 10
        let g = Float(m.phaseG)
        let middle = m.exit + m.axis * (0.5 * m.length)
        var side = m.axis.cross((-middle).normalized)
        if side.length < 1e-6 { side = PlumeLook.perpendicular(m.axis) }
        side = side.normalized
        // Across the strip through the axis, pointing at the camera.
        let towards = side.cross(m.axis).normalized
        func ring(_ i: Int) -> (PlumeVertex, PlumeVertex) {
            let t = Double(i) / Double(samples)
            let x = m.length * (t * t)
            let e = m.extent(atX: x)
            let w = max(min(1.1 * m.radius(atX: x), e), 0.5 * m.exitRadius)
            let c = m.centre(atX: x)
            let seen = PlumeLook.march([m], from: c + towards * e, direction: -towards, range: 0...(2 * e), steps: 24,
                                       sun: sun, phaseDirection: c.normalized, around: (e, 0.5 * m.denseRadius(atX: x)))
            let alpha = 1 - seen.transmittance
            let color = SIMD4(Float(seen.radiance.r), Float(seen.radiance.g), Float(seen.radiance.b), Float(alpha))
            let a = Float(seen.ambientResponse)
            return (PlumeVertex(position: f4(c - side * w, 1), color: color, shape: SIMD4(-1, Float(t), a, g)),
                    PlumeVertex(position: f4(c + side * w, 1), color: color, shape: SIMD4(1, Float(t), a, g)))
        }
        var previous = ring(0)
        for i in 1...samples {
            let next = ring(i)
            out += [previous.0, previous.1, next.1, previous.0, next.1, next.0]
            previous = next
        }
        // End on, the strip is seen edge on: the disc carries the plume,
        // as wide as the jet near its exit (at most two exit radii, as
        // M1.5's), and only near end on (from about 35° off the axis).
        let view = m.exit.length > 1e-9 ? m.exit.normalized : m.axis
        let endOn = PlumeMember.smoothstep(0.82, 0.97, abs(view.dot(m.axis)))
        guard endOn > 0 else { return }
        let near = min(m.exitDiameter, 0.25 * m.length)
        let disc = min(max(1.1 * m.radius(atX: near), m.exitRadius), 2 * m.exitRadius)
        let seen = PlumeLook.march([m], from: m.exit - view * m.length, direction: view, range: 0...(2 * m.length),
                                   steps: 48, sun: sun)
        let color = SIMD4(Float(seen.radiance.r * endOn), Float(seen.radiance.g * endOn),
                          Float(seen.radiance.b * endOn), Float((1 - seen.transmittance) * endOn))
        let a = Float(seen.ambientResponse * endOn)
        let u = PlumeLook.perpendicular(view), v = view.cross(u).normalized
        let centre = PlumeVertex(position: f4(m.exit, 1), color: color, shape: SIMD4(0, 0, a, g))
        let sides = 16
        func rim(_ k: Int) -> PlumeVertex {
            let a = 2 * Double.pi * Double(k) / Double(sides)
            return PlumeVertex(position: f4(m.exit + (u * cos(a) + v * sin(a)) * disc, 1), color: color,
                               shape: SIMD4(1, 0, Float(seen.ambientResponse * endOn), g))
        }
        for k in 0..<sides { out += [centre, rim(k), rim(k + 1)] }
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
    /// rgb: the ambient's mean radiance where R3's probe is not drawn
    /// (cd/m², not pre-exposed): A2's sky in air, the earthshine stand-in in
    /// vacuum.
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
    /// gives half its steps; y: where the merged member takes over (0:
    /// none; it follows the members in the buffer); z: the cluster's steps
    /// (0: the frame's).
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
    var sheathLight: SIMD4<Float> // rgb: the film's blackbody (cd/m²), w: the radius' offset (merged)
    var particles: SIMD4<Float>   // extinction, albedo, temperature, cooling length
    var particles2: SIMD4<Float>  // angle, source offset, onset, phase g
    var structure: SIMD4<Float>   // cell length, cells, strength, upstream
    var base: SIMD4<Float>        // rgb: the base's blackbody, w: its extinction
    var disk: SIMD4<Float>        // distance, radius, extinction, the air's confinement
    var diskLight: SIMD4<Float>   // rgb: the disk's blackbody, w: the density's scale (merged)
    var noise: SIMD4<Float>       // eddy size, phase (tiles), depth, tile (m)
    var glow: SIMD4<Float>        // rgb (cd/m²), w: length
    var extent: SIMD4<Float>      // x: tan of the 1 % Simons angle (0: none), y: the particles' (0: none),
                                  // z: the flame's length, w: its brush's spread
    var bendDirection: SIMD4<Float> // xyz: the bend's direction (unit, world; 0 none), w: the hand-over's
                                    // fade's start
    var bendSpan: SIMD4<Float>    // x: the x its stations span, y: where it fades out to its length (-1:
                                  // its last 30 %), z: its largest offset, w: the hand-over's fade's end
                                  // (-1: none)
    var bendNear: SIMD4<Float>    // the offsets at the first four stations, x = span (k/7)²
    var bendFar: SIMD4<Float>     // and the last four
}

/// A plume impostor's vertex (PlumeShaders).
struct PlumeVertex {
    /// Camera-relative world position, w = 1.
    var position: SIMD4<Float>
    /// rgb: radiance seen through the axis (cd/m², not pre-exposed), a: opacity.
    var color: SIMD4<Float>
    /// x: across (-1...1), y: along (0 exit ... 1 tail), z: the radiance
    /// added per cd/m² of the ambient's in-scatter, w: the phase's g.
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
    /// The last frame's pre-exposure (R1's, set in P0 after the graph has
    /// asked which passes run): the culling's.
    private var exposure: Double?
    /// The least pre-exposed light a plume must give to be drawn.
    static let faintest = 2e-3
    /// The frame `frame` was planned for, and whether P0 has lit it.
    private weak var planned: FrameContext?
    private var lit = false

    public init() {}

    /// The clusters drawn last frame and how, for tests.
    public var lastClusters: [(cluster: PlumeCluster, detail: PlumeCluster.Detail)] { frame.clusters }

    func setUp(device: MTLDevice, shaders: ShaderLibrary) throws {
        if noise == nil { noise = try VolumeNoise(device: device, library: try shaders.library(.particle)) }
    }

    /// The looks kept across frames, keyed by what each is made from,
    /// quantised (`key`): the members at a canonical pose, their trims at
    /// an exposure and Sun, and their lights' profiles. Cleared when large.
    private var templates: [String: PlumeMember?] = [:]
    private var trims: [String: PlumeMember?] = [:]
    private var extents: [String: (radii: [Double], length: Double)] = [:]
    private var profiles: [Int: PlumeLights.Profile?] = [:]
    static let cacheLimit = 512
    /// CPU time of the last frame's planning and lighting (s), for the cost
    /// report.
    public private(set) var cpuTime = (plan: 0.0, prepare: 0.0)
    /// The CPU time by stage since the system began (s): templates, trims,
    /// visible extents, clusters, lights, impostors.
    public private(set) var cpuStages: [String: Double] = [:]
    func timed<T>(_ stage: String, _ body: () -> T) -> T {
        let t0 = CFAbsoluteTimeGetCurrent()
        defer { cpuStages[stage, default: 0] += CFAbsoluteTimeGetCurrent() - t0 }
        return body()
    }

    /// `x` to steps of `step` (0.25 % for the logarithmic ones), for keys.
    static func q(_ x: Double, _ step: Double) -> Int { Int((x / step).rounded()) }
    static func qlog(_ x: Double, _ step: Double = 0.0025) -> Int { x > 0 ? q(log(x), step) : Int.min }

    /// An emitter's member: its look from the cache (built at the origin
    /// along +x the first time its quantised inputs are met), placed.
    /// The member, its template's key, the coarser key its visible extents
    /// are kept under (a 5 % change in the air or the stream does not move
    /// what can show visibly; the extents have 15 % to spare), and the key
    /// its light's profile is kept under (1-2 %).
    func member(_ e: RenderScene.Emitter, settings: PlumeSettings)
        -> (member: PlumeMember, key: (fine: String, coarse: String, light: String))? {
        let engine = settings.model == .physical ? ApolloExhaust.engine(thruster: e.name, part: e.part) : nil
        let what = engine.map { $0.spec.source } ?? "legacy \(e.style)"
        let a = e.ambient
        // The stream along the jet and across it (P1's flame), in the
        // canonical frame the template is built in.
        let along = e.relativeWind.dot(e.axis), across = (e.relativeWind - e.axis * along).length
        let key = "\(what)|\(e.exitRadius)|\(Self.q(e.flowFraction, 0.0025))|\(Self.q(e.thrustFraction, 0.0025))|"
            + "\(Self.qlog(a.pressure))|\(Self.qlog(a.density))|\(Self.q(a.temperature, 0.5))|"
            + "\(Self.qlog(e.pressureRatio))|\(e.isJet)|\(settings.readable)|\(settings.model)|"
            + "\(Self.qlog(along, 0.01))|\(Self.q(across, 2))"
        let template: PlumeMember?
        if let t = templates[key] {
            template = t
        } else {
            var canonical = e
            canonical.exit = .zero
            canonical.axis = .unitX
            canonical.relativeWind = Vec3(along, across, 0)
            template = timed("templates") { PlumeLook.member(canonical, settings: settings) }
            if templates.count > Self.cacheLimit { templates.removeAll() }
            templates[key] = template
        }
        guard var m = template else { return nil }
        m.exit = e.exit
        m.axis = e.axis
        m.vesselID = e.vesselID
        m.relativeWind = e.relativeWind
        return (m, (key, "\(what)|\(e.exitRadius)|\(Self.q(e.flowFraction, 0.02))|\(Self.qlog(a.pressure, 0.05))|"
            + "\(Self.q(a.temperature, 5))|\(e.isJet)|\(settings.readable)|\(settings.model)|"
            + "\(Self.qlog(along, 0.05))|\(Self.q(across, 10))",
            "\(what)|\(e.exitRadius)|\(Self.q(e.flowFraction, 0.01))|\(Self.qlog(a.pressure, 0.02))|"
            + "\(Self.q(a.temperature, 2))|\(e.isJet)|\(settings.readable)|\(settings.model)|"
            + "\(Self.qlog(along, 0.02))|\(Self.q(across, 5))"))
    }

    /// The frame's members, trimmed to what the frame's exposure can show
    /// in their vessels' sunlight: the look-dev engines when a shot gives
    /// them, else the emitters of the vessels drawn as meshes.
    func members(_ scene: RenderScene, settings: PlumeSettings, faintest: Double,
                 drawn: (UUID) -> Bool) -> [PlumeMember] {
        let sunlight = scene.sun.illuminance, toSun = scene.sun.direction
        func sunlit(_ id: UUID?) -> Double {
            id.flatMap { id in scene.vessels.first { $0.id == id }?.light.sunlit } ?? 1
        }
        if !settings.testEngines.isEmpty {
            let frame = EffectTargetFrame(scene: scene)
            return settings.testEngines.flatMap { PlumeLook.members($0, in: frame, settings: settings) }.compactMap {
                var m = $0
                return PlumeLook.trim(&m, faintest: faintest, sun: sunlight, sunDirection: toSun) ? m : nil
            }
        }
        var out: [PlumeMember] = []
        for e in scene.emitters where drawn(e.vesselID) {
            guard let (placed, keys) = member(e, settings: settings) else { continue }
            let key = keys.fine
            var m = placed
            // The trim's phase is towards the camera, from the Sun, at a
            // fourth of its length: quantised with the light and the Sun's.
            let sun = sunlight * sunlit(e.vesselID)
            let view = (m.exit + m.axis * (0.25 * m.length)).normalized
            let trimKey = key + "|\(Self.qlog(faintest, 0.01))|\(Self.qlog(sun, 0.01))|\(Self.q(view.dot(toSun), 0.01))"
            if let done = trims[trimKey] {
                guard let d = done else { continue }
                m.length = d.length
                m.extentFraction = d.extentFraction
                m.glowOnly = d.glowOnly
                m.visibleExtents = d.visibleExtents
                m.visibleExtentsLength = d.visibleExtentsLength
            } else {
                let visible = timed("trims") {
                    PlumeLook.trim(&m, faintest: faintest, sun: sun, sunDirection: toSun, extents: false)
                }
                if visible && !m.glowOnly {
                    // The visible extents, the costly part, under the coarse key.
                    let extentsKey = keys.coarse + "|\(Self.qlog(faintest, 0.1))|\(Self.qlog(sun, 0.1))|"
                        + "\(Self.q(view.dot(toSun), 0.1))"
                    if let x = extents[extentsKey] {
                        (m.visibleExtents, m.visibleExtentsLength) = x
                    } else {
                        let probe = m
                        m.visibleExtents = timed("extents") {
                            PlumeLook.visibleExtents(probe, faintest: faintest,
                                                     sun: PlumeLook.sunAtPhase(probe, sun: sun, sunDirection: toSun))
                        }
                        m.visibleExtentsLength = m.length
                        if extents.count > Self.cacheLimit { extents.removeAll() }
                        extents[extentsKey] = (m.visibleExtents, m.visibleExtentsLength)
                    }
                }
                if trims.count > Self.cacheLimit { trims.removeAll() }
                trims[trimKey] = visible ? m : nil
                guard visible else { continue }
            }
            // The light's profile under its own key (with the exposure and
            // the Sun at 5 %).
            m.tag = (keys.light + "|\(Self.qlog(faintest, 0.05))|\(Self.qlog(sun, 0.05))|"
                + "\(Self.q(view.dot(toSun), 0.05))").hashValue
            out.append(m)
        }
        return out
    }

    /// The light of cluster `c`, its members' profiles from the cache.
    func light(_ c: PlumeCluster) -> PlumeLight? {
        let list = c.members.map { m -> PlumeLights.Profile? in
            guard m.tag != 0 else { return PlumeLights.profile(m) }
            // With the cluster's hand-over, which sets the member's fade and
            // length (at 1 %).
            let tag = c.handover.map { "\(m.tag)|\(Self.qlog($0.x, 0.01))|\(Self.qlog($0.window, 0.01))".hashValue }
                ?? m.tag
            if let p = profiles[tag] { return p }
            let p = PlumeLights.profile(m)
            if profiles.count > Self.cacheLimit { profiles.removeAll() }
            profiles[tag] = p
            return p
        }
        return PlumeLights.light(c, profiles: list)
    }

    /// What the frame draws, from the scene alone: the members, clusters
    /// and their detail, the glowing nozzles. Once a frame, on the first
    /// question: the frame graph asks which passes run before P0 does.
    func plan(_ f: FrameContext) {
        guard planned !== f else { return }
        let started = CFAbsoluteTimeGetCurrent()
        defer { cpuTime.plan = CFAbsoluteTimeGetCurrent() - started }
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
        let drawn = settings.enabled && settings.quality != .off
        if settings.nozzleGlow && drawn {
            for v in scene.vessels where f.drawsMesh(v.id) {
                for part in v.geometry.parts {
                    for t in part.thrusters { if let h = heats[t.key] { data.glows.append((v.id, t.key, h)) } }
                }
            }
        }
        if drawn {
            // Each member trimmed to what this exposure can show in its
            // vessel's sunlight; those that cannot show at all are not drawn.
            let ev = f.settings.post.exposure.fixedEV100
            let p = ev.map { 1 / (1.2 * pow(2, $0)) } ?? exposure ?? 1 / (1.2 * pow(2, 15))
            let members = members(scene, settings: settings, faintest: Self.faintest / max(p, 1e-12),
                                  drawn: { f.drawsMesh($0) })
            let clusters = timed("clusters") { PlumeClusters.clusters(members) }
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
    /// (C2): the marched clusters' buffers, far to near, the impostors'
    /// strips, the uniforms, and the plume lights written into the frame's
    /// lighting, with the flag that P2 has written them (lightCount.y).
    func prepare(_ f: FrameContext) {
        plan(f)
        guard !lit else { return }
        let started = CFAbsoluteTimeGetCurrent()
        defer { cpuTime.prepare = CFAbsoluteTimeGetCurrent() - started }
        lit = true
        let scene = f.scene, settings = f.settings.plume
        exposure = Double(f.frame.exposure.x)
        var data = frame
        let sun = scene.sun
        // In the air: A2 runs and the camera is below the air's top.
        let a = f.atmosphere
        let air = a.radii.w > 0.5 && a.radii.z < a.radii.y - a.radii.x
        let sunLux = air && a.sunTransmitted.w > 0
            ? Photometry.RGB(Double(a.sunTransmitted.x * a.sunTransmitted.w),
                             Double(a.sunTransmitted.y * a.sunTransmitted.w),
                             Double(a.sunTransmitted.z * a.sunTransmitted.w))
            : Photometry.sunColor.scaled(by: sun.illuminance)
        // The ambient where R3's probe is not drawn (lighting.probe.w): A2's
        // sky in air, the earthshine of the focus vessel's stand-in in vacuum.
        let focus = scene.vessels.first { $0.isFocus } ?? scene.vessels.first
        let earth = focus.map { v in
            Photometry.RGB(Double(v.light.earthColor.r), Double(v.light.earthColor.g), Double(v.light.earthColor.b))
                .scaled(by: v.light.earthStrength * v.light.earthLit * sun.illuminance)
        } ?? Photometry.RGB(0, 0, 0)
        let sky = Photometry.RGB(Double(a.skyIrradiance.x), Double(a.skyIrradiance.y), Double(a.skyIrradiance.z))
        // The stub's mean radiance about the plumes (cd/m²): a sky above of
        // irradiance E is E/π, a darker ground below, about E/2π over the
        // sphere; the Earth's disc in vacuum about E/4π.
        let ambient = air ? sky.scaled(by: 1 / (2 * Double.pi)) : earth.scaled(by: 1 / (4 * Double.pi))
        let lights = timed("lights") { data.clusters.map { light($0.cluster) } }
        var marched: [(distance: Double, cluster: PlumeCluster, light: PlumeLight?, sunlit: Double)] = []
        for ((c, detail), light) in zip(data.clusters, lights) {
            let sunlit = c.vesselID.flatMap { id in scene.vessels.first { $0.id == id }?.light.sunlit } ?? 1
            switch detail {
            case .march:
                marched.append((Plumes.drawDistance(c), c, light, sunlit))
            case .impostor:
                let lit = sunlit > 0 ? (direction: sun.direction, illuminance: sunLux.scaled(by: sunlit)) : nil
                timed("impostors") { for m in c.members { Plumes.impostor(m, sun: lit, to: &data.impostors) } }
            case .none:
                break
            }
        }
        // Far to near: R6's volumes layer blends them in draw order. A
        // cluster only its glow shows (emission alone, smooth) takes a
        // quarter of the steps, at least 8.
        for e in Plumes.farToNear(marched, { $0.cluster }) {
            let c = e.cluster
            // (Half, at least 16, for several members.) Solid motors' small
            // dense cores, which the equiangular steps resolve, take half
            // the steps too (at least 16): at staging eight of them fire.
            let glowOnly = c.members.allSatisfy(\.glowOnly)
            let solid = c.members.allSatisfy { $0.family == .solid }
            let steps = glowOnly ? (c.members.count == 1 ? max(8, settings.quality.steps / 4)
                                                         : max(16, settings.quality.steps / 2))
                : solid ? max(16, settings.quality.steps / 2) : 0
            data.marched.append(Plumes.gpu(c, memberStart: data.members.count, light: e.light, sunlit: e.sunlit,
                                           steps: steps))
            data.members += (c.members + (c.merged.map { [$0] } ?? [])).map {
                Plumes.gpu($0, turbulenceTime: turbulence, turbulent: settings.turbulence)
            }
        }
        let w = PlumeLook.wien
        var u = PlumeFrameGPU()
        u.wienK = SIMD4(Float(w[0].0), Float(w[1].0), Float(w[2].0), Float(settings.quality.steps))
        u.wienA = SIMD4(Float(w[0].1), Float(w[1].1), Float(w[2].1), Float(turbulence))
        u.wienC = SIMD4(Float(w[0].2), Float(w[1].2), Float(w[2].2), 0)
        u.sun = Plumes.f4(sun.direction, f.textures[.cloudLayer] != nil ? 1 : 0)
        u.sunLight = Plumes.f4(sunLux, f.settings.shadow.enabled ? 1 : 0)
        u.ambient = Plumes.f4(ambient, 0)
        // z: the angle a half-resolution texel spans (rad), for the noise's
        // level of detail.
        u.params = SIMD4(Float(scene.clock.frameIndex % 1024), f.settings.atmosphere.enabled ? 1 : 0,
                         Float(2 / max(scene.camera.pixelsPerRadian, 1e-9)), 0)
        data.uniforms = u

        // The lights, the brightest at the camera first.
        let maximum = min(f.settings.shading.plumeLights, LightingUniforms.maxLocalLights)
        func weight(_ l: PlumeLight) -> Double { l.luminousIntensity / max(l.centre.lengthSquared, l.length * l.length) }
        data.lights = Array(lights.compactMap { $0 }.sorted { weight($0) > weight($1) }.prefix(max(maximum, 0)))
        var list = [LocalLight](repeating: LocalLight(), count: LightingUniforms.maxLocalLights)
        for (i, l) in data.lights.enumerated() {
            list[i].positionRadius = Plumes.f4(l.centre, l.radius)
            list[i].axisLength = Plumes.f4(l.axis, l.length)
            list[i].intensity = SIMD4(l.intensity.r, l.intensity.g, l.intensity.b, Float(l.range))
        }
        f.lighting.lightCount = SIMD4(Float(data.lights.count), 1, 0, 0)
        f.lighting.lights = (list[0], list[1], list[2], list[3], list[4], list[5], list[6], list[7])
        frame = data
    }

    /// Writes the noise's texels, once (P0).
    func encodeNoise(_ enc: MTLComputeCommandEncoder) { noise?.encodeIfNeeded(enc) }
}
