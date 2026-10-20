import Foundation
import Metal
import MetalKit
import QuartzCore
import simd
import OrbitCore

/// Draws the scene with camera-relative coordinates: every position is
/// computed in double precision relative to the camera and only then converted
/// to float, because Apple GPUs have no 64-bit floating point.
@MainActor
final class Renderer: NSObject, MTKViewDelegate {
    /// Multisample anti-aliasing: 4 samples, which every Apple GPU supports.
    nonisolated static let defaultSampleCount = 4
    /// Frames the CPU may write ahead of the GPU: one per-frame buffer each.
    nonisolated static let framesInFlight = 3

    let device: MTLDevice
    let queue: MTLCommandQueue
    let sampleCount: Int
    weak var model: AppModel?

    private var planetPipeline: MTLRenderPipelineState!
    private var meshPipeline: MTLRenderPipelineState!
    private var pointPipeline: MTLRenderPipelineState!
    private var linePipeline: MTLRenderPipelineState!
    private var plumePipeline: MTLRenderPipelineState!
    private var spritePipeline: MTLRenderPipelineState!
    private var depthWrite: MTLDepthStencilState!
    private var depthReadOnly: MTLDepthStencilState!
    private var noDepth: MTLDepthStencilState!
    private var sampler: MTLSamplerState!
    private var spriteSampler: MTLSamplerState!

    private var starBuffer: MTLBuffer?
    private var starCount = 0
    private var meshes: [UUID: VesselMesh] = [:]
    private var drogueCanopy: CanopyMesh?
    private var mainCanopy: CanopyMesh?
    private var atlas: SpriteAtlas?
    private var textures: [Int: MTLTexture] = [:]
    private var fallbackTexture: MTLTexture!

    /// Vertex data written each frame (orbit line, points, plumes, risers,
    /// sprites), one buffer per frame in flight, reused.
    private var arenas: [FrameArena] = []
    private var arenaIndex = 0
    private let inFlight = DispatchSemaphore(value: Renderer.framesInFlight)
    /// CPU encoding and GPU times, smoothed (s).
    let times = FrameTimes()

    /// Each vessel's heat flux through the heat shield's thermal lag, and
    /// the simulation time it is for.
    private var thermal: [UUID: (flux: Double, time: Epoch)] = [:]
    /// First-order lag of the glow behind the heat flux, s of simulation time
    /// (a visual choice: the ablator's surface follows the heating in seconds).
    static let thermalLag = 6.0

    private var lastTime = CACurrentMediaTime()
    let near: Float = 0.25

    init?(view: MTKView, sampleCount: Int = Renderer.defaultSampleCount) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.sampleCount = device.supportsTextureSampleCount(sampleCount) ? sampleCount : 1
        super.init()

        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = self.sampleCount
        view.clearDepth = 0
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = 60

        do {
            try buildPipelines(view: view)
        } catch {
            NSLog("OrbitSim: pipeline creation failed: \(error)")
            return nil
        }
        let orange = (0.89, 0.17, 0.012), white = (0.9, 0.9, 0.88)
        mainCanopy = CanopyMesh.build(device: device, gores: 12, colours: [orange, white])
        drogueCanopy = CanopyMesh.build(device: device, gores: 8, colours: [white, orange])
        atlas = SpriteAtlas(device: device)
        if atlas == nil { NSLog("OrbitSim: the sprite atlas could not be drawn; no orbit markers") }
        arenas = (0..<Self.framesInFlight).compactMap { _ in FrameArena(device: device, capacity: 1 << 18) }
        loadTextures()
    }

    // MARK: Setup

    private func buildPipelines(view: MTKView) throws {
        let library = try device.makeLibrary(source: shaderSource, options: nil)

        enum Blend { case opaque, alpha, premultiplied, additive }
        func pipeline(_ vfn: String, _ ffn: String, _ blend: Blend) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vfn)
            d.fragmentFunction = library.makeFunction(name: ffn)
            d.colorAttachments[0].pixelFormat = view.colorPixelFormat
            d.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            d.rasterSampleCount = sampleCount
            if blend != .opaque {
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.rgbBlendOperation = .add
                c.alphaBlendOperation = .add
                switch blend {
                case .additive:
                    c.sourceRGBBlendFactor = .one
                    c.destinationRGBBlendFactor = .one
                    c.sourceAlphaBlendFactor = .zero
                    c.destinationAlphaBlendFactor = .one
                default:
                    c.sourceRGBBlendFactor = blend == .premultiplied ? .one : .sourceAlpha
                    c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    c.sourceAlphaBlendFactor = .one
                    c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        planetPipeline = try pipeline("planet_vertex", "planet_fragment", .premultiplied)
        meshPipeline = try pipeline("mesh_vertex", "mesh_fragment", .opaque)
        pointPipeline = try pipeline("point_vertex", "point_fragment", .alpha)
        linePipeline = try pipeline("line_vertex", "line_fragment", .alpha)
        plumePipeline = try pipeline("plume_vertex", "plume_fragment", .additive)
        spritePipeline = try pipeline("sprite_vertex", "sprite_fragment", .premultiplied)

        let dw = MTLDepthStencilDescriptor()
        dw.depthCompareFunction = .greaterEqual
        dw.isDepthWriteEnabled = true
        depthWrite = device.makeDepthStencilState(descriptor: dw)

        let dr = MTLDepthStencilDescriptor()
        dr.depthCompareFunction = .greaterEqual
        dr.isDepthWriteEnabled = false
        depthReadOnly = device.makeDepthStencilState(descriptor: dr)

        let dn = MTLDepthStencilDescriptor()
        dn.depthCompareFunction = .always
        dn.isDepthWriteEnabled = false
        noDepth = device.makeDepthStencilState(descriptor: dn)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.mipFilter = .linear
        sd.sAddressMode = .repeat
        sd.tAddressMode = .clampToEdge
        sd.maxAnisotropy = 8
        sampler = device.makeSamplerState(descriptor: sd)

        let ss = MTLSamplerDescriptor()
        ss.minFilter = .linear
        ss.magFilter = .linear
        ss.sAddressMode = .clampToEdge
        ss.tAddressMode = .clampToEdge
        spriteSampler = device.makeSamplerState(descriptor: ss)

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        fallbackTexture = device.makeTexture(descriptor: td)
        var white: [UInt8] = [255, 255, 255, 255]
        fallbackTexture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &white, bytesPerRow: 4)
    }

    /// Optional equirectangular textures: ~/Library/Application Support/OrbitSim/Textures/{earth,moon}.jpg
    private func loadTextures() {
        let loader = MTKTextureLoader(device: device)
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = support.appendingPathComponent("OrbitSim/Textures", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: true,
            .generateMipmaps: true,
            .origin: MTKTextureLoader.Origin.topLeft,
        ]
        for (id, name) in [(399, "earth"), (301, "moon")] {
            for ext in ["jpg", "jpeg", "png", "tif"] {
                let url = dir.appendingPathComponent("\(name).\(ext)")
                guard fm.fileExists(atPath: url.path) else { continue }
                do {
                    textures[id] = try loader.newTexture(URL: url, options: options)
                    NSLog("OrbitSim: loaded texture \(url.path)")
                } catch {
                    NSLog("OrbitSim: could not load \(url.path): \(error)")
                }
                break
            }
        }
    }

    func setStars(_ stars: [Star]) {
        var pts: [PointVertex] = []
        pts.reserveCapacity(stars.count)
        for s in stars {
            let brightness = Float(pow(10, -0.4 * (s.magnitude - 1.0)))
            let size = Float(max(1.5, min(5.0, 4.5 - 0.5 * s.magnitude)))
            let c = Self.starColor(bv: s.colorIndex)
            pts.append(PointVertex(position: SIMD4(s.direction, 0),
                                   color: SIMD4(c.x, c.y, c.z, min(1, 0.25 + brightness)),
                                   size: SIMD4(size, 0, 0, 0)))
        }
        starCount = pts.count
        starBuffer = pts.isEmpty ? nil : device.makeBuffer(bytes: pts, length: pts.count * MemoryLayout<PointVertex>.stride,
                                                          options: .storageModeShared)
    }

    static func starColor(bv: Double) -> SIMD3<Float> {
        // Rough B-V -> linear RGB.
        let t = Float(max(-0.4, min(2.0, bv)))
        let r: Float = t < 0.4 ? 0.75 + 0.6 * t : 1.0
        let g: Float = t < 0.0 ? 0.82 + 0.3 * t : 0.98 - 0.25 * t
        let b: Float = t < 0.4 ? 1.0 : max(0.35, 1.0 - 0.6 * (t - 0.4))
        return SIMD3(r, g, b)
    }

    // MARK: MTKViewDelegate

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    // MTKView calls its delegate on the main thread.
    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { render(in: view) }
    }

    private func render(in view: MTKView) {
        let now = CACurrentMediaTime()
        // The real interval, uncapped: the simulation caps what it makes up
        // for and reports the shortfall as limited warp.
        let dt = now - lastTime
        lastTime = now
        guard let model else { return }
        model.tick(dt: dt)
        guard let sim = model.sim,
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              !arenas.isEmpty else { return }
        // Wait for the GPU to finish with the oldest frame's buffer.
        inFlight.wait()
        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else {
            inFlight.signal()
            return
        }
        let encodeStart = CACurrentMediaTime()
        let semaphore = inFlight, times = self.times
        cmd.addCompletedHandler { cb in
            times.addGPU(cb.gpuEndTime - cb.gpuStartTime)
            semaphore.signal()
        }
        let arena = arenas[arenaIndex]
        arenaIndex = (arenaIndex + 1) % arenas.count
        arena.reset()

        let size = view.drawableSize
        let aspect = Float(size.width / max(size.height, 1))
        let cam = model.camera
        let proj = simd_float4x4.reversedInfinitePerspective(fovY: Float(cam.fovY), aspect: aspect, near: near)
        let view4 = simd_float4x4(rotation: cam.worldToView)
        let viewProj = proj * view4
        let pointScale = Float(view.window?.backingScaleFactor ?? 2)
        let pointParams = SIMD4<Float>(pointScale, 0, 0, 0)
        let snap = sim.snapshot
        let sunPos = snap.position(sim.system.sun)

        // 1. Stars (directions at infinity).
        if let starBuffer {
            enc.setRenderPipelineState(pointPipeline)
            enc.setDepthStencilState(noDepth)
            var u = PointUniforms(viewProjection: viewProj, params: pointParams)
            enc.setVertexBuffer(starBuffer, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<PointUniforms>.stride, index: 1)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: starCount)
        }

        // 2. Bodies, farthest first. Small ones become points.
        let tanY = tan(cam.fovY / 2)
        let pixelsPerRadian = Double(size.height) / (2 * tanY)
        var farPoints: [PointVertex] = []
        let ordered = sim.system.bodies.sorted {
            (snap.position($0) - cam.position).length > (snap.position($1) - cam.position).length
        }
        enc.setRenderPipelineState(planetPipeline)
        enc.setDepthStencilState(depthWrite)
        enc.setFragmentSamplerState(sampler, index: 0)
        for body in ordered {
            let rel = snap.position(body) - cam.position
            let dist = rel.length
            let angularRadius = asin(min(1, body.radius / dist))
            let style = Self.style(for: body)
            if angularRadius * pixelsPerRadian < 1.5 {
                let isSun = body === sim.system.sun
                farPoints.append(PointVertex(position: SIMD4(rel.normalized, 0),
                                             color: SIMD4(style.color.x, style.color.y, style.color.z, 1),
                                             size: SIMD4(isSun ? 24 : 4, 0, 0, 0)))
                continue
            }
            let toSun = (sunPos - snap.position(body)).normalized
            // The camera in figure coordinates (body axes stretched along z
            // by a/b, where the figure is the sphere of radius a) and |o|^2 -
            // a^2, both in double: in float the latter would lose the
            // camera's height near the surface.
            let orientation = snap.orientation(body), figure = body.figure
            let a = figure.equatorialRadius, stretch = a / figure.polarRadius
            let cameraBody = orientation.toBody(-rel)
            let origin = Vec3(cameraBody.x, cameraBody.y, cameraBody.z * stretch)
            let c = (origin.length - a) * (origin.length + a)
            let altitude = figure.geodetic(cameraBody).height
            let worldToBody = orientation.icrfToBody
            let texture = textures[body.id]
            var u = PlanetUniforms(
                viewToWorld: simd_float4x4(rotation: cam.worldToView.transposed),
                worldToBody: simd_float4x4(rotation: worldToBody),
                centerRadius: SIMD4(rel, Float(a)),
                params: SIMD4(Float(altitude), Float(tanY) * aspect, Float(tanY), near),
                sunDir: SIMD4(toSun, body === sim.system.sun ? 1 : 0),
                baseColor: SIMD4(style.color.x, style.color.y, style.color.z, texture == nil ? 0 : 1),
                atmosphere: SIMD4(style.sky.x, style.sky.y, style.sky.z, style.scaleHeight),
                options: SIMD4(texture == nil ? 1 : 0, 0.015, 0, 0),
                origin: SIMD4(origin, Float(c)),
                figure: SIMD4(Float(stretch), 0, 0, 0))
            enc.setFragmentBytes(&u, length: MemoryLayout<PlanetUniforms>.stride, index: 0)
            enc.setFragmentTexture(texture ?? fallbackTexture, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        // 3. Vessels: their meshes, gimballed nozzles and canopies; the
        // plumes and risers are collected for passes 5 and 6.
        enc.setRenderPipelineState(meshPipeline)
        enc.setDepthStencilState(depthWrite)
        enc.setFrontFacing(.counterClockwise)
        var plumes: [PlumeVertex] = []
        var risers: [LineVertex] = []
        var liveIDs = Set<UUID>()
        for v in sim.vessels {
            liveIDs.insert(v.id)
            let sig = VesselMesh.signature(of: v)
            if meshes[v.id]?.signature != sig { meshes[v.id] = VesselMesh.build(for: v, device: device) }
            let rel = snap.position(v.reference) + v.position - cam.position
            let light = vesselLight(v, snapshot: snap, system: sim.system, sun: sunPos)
            let glow = heatShieldGlow(v, time: snap.time)
            guard let mesh = meshes[v.id] else { continue }
            let pixelSize = v.boundingRadius / max(rel.length, 1e-3) * pixelsPerRadian
            if pixelSize < 0.5 {
                farPoints.append(farPoint(of: v, at: rel, sunlit: light.light.x))
                continue
            }
            // Mesh vertices are in the construction frame; v.position is the CoM.
            let attitude = v.attitude.matrix
            let translation = rel + v.attitude.rotate(v.structureOrigin)
            var u = MeshUniforms(modelViewProjection: viewProj, model: matrix_identity_float4x4,
                                 normalMatrix: matrix_identity_float4x4, sunDir: light.sunDir, light: light.light,
                                 earthDir: light.earthDir, earthColor: light.earthColor,
                                 glow: SIMD4(glow, 0), flowDir: flowDirection(v, snapshot: snap))
            enc.setVertexBuffer(mesh.buffer, offset: 0, index: 0)
            for g in mesh.groups {
                var rotation = attitude, shift = translation
                if let t = g.thruster {
                    // The nozzle turns about its gimbal point with the thrust.
                    let r = Mat3.rotation(from: t.direction, to: t.thrustDirection)
                    rotation = attitude * r
                    shift = translation + attitude * (g.pivot - r * g.pivot)
                }
                let m = simd_float4x4(rotation: rotation, translation: shift)
                u.model = m
                u.normalMatrix = simd_float4x4(rotation: rotation)
                u.modelViewProjection = viewProj * m
                enc.setCullMode(g.culled ? .back : .none)
                enc.setVertexBytes(&u, length: MemoryLayout<MeshUniforms>.stride, index: 1)
                enc.setFragmentBytes(&u, length: MemoryLayout<MeshUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: g.range.lowerBound, vertexCount: g.range.count)
            }
            enc.setCullMode(.none)
            drawCanopies(of: v, at: rel, snapshot: snap, uniforms: u, viewProjection: viewProj, encoder: enc,
                         risers: &risers)
            appendPlumes(of: v, mesh: mesh, at: rel, to: &plumes)
        }
        if meshes.keys.contains(where: { !liveIDs.contains($0) }) { meshes = meshes.filter { liveIDs.contains($0.key) } }
        if thermal.keys.contains(where: { !liveIDs.contains($0) }) { thermal = thermal.filter { liveIDs.contains($0.key) } }

        // 4. Orbit of the focus vessel, and its markers.
        var sprites: [SpriteVertex] = []
        var lines: [LineVertex] = []
        var orbitStrips: [Int] = []
        if model.showOrbit, let focus = sim.focus, focus.landed == nil {
            let center = snap.position(focus.reference) - cam.position
            let el = focus.elements(snapshot: snap)
            for strip in Self.orbitStrips(elements: el, body: focus.reference, center: center) {
                orbitStrips.append(strip.count)
                lines += strip
            }
            if let atlas {
                let occulters = sim.system.bodies.map { (snap.position($0) - cam.position, $0.figure.polarRadius) }
                for marker in Self.orbitMarkers(elements: el, body: focus.reference) {
                    let p = center + marker.position
                    // Whole or not at all: hidden when a body is in the way
                    // of its anchor, then drawn over everything.
                    if occulters.contains(where: { Self.segmentHits(to: p, sphere: $0.0, radius: $0.1) }) { continue }
                    let width = atlas.append(.orbit(marker.kind), at: p, pointScale: pointScale, to: &sprites)
                    if let text = marker.text, let cell = atlas.cell(.orbit(marker.kind)) {
                        atlas.appendText(text, at: p, offset: SIMD2(width - cell.anchor.x + 1, -4), pointScale: pointScale,
                                         tint: SIMD4(0.9, 0.95, 1, 1), to: &sprites)
                    }
                }
            }
        }

        // 5. Lines: the orbit's strips, then the risers as segments.
        lines += risers
        if let b = arena.push(lines) {
            enc.setRenderPipelineState(linePipeline)
            enc.setDepthStencilState(depthReadOnly)
            var u = PointUniforms(viewProjection: viewProj, params: pointParams)
            enc.setVertexBuffer(b.buffer, offset: b.offset, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<PointUniforms>.stride, index: 1)
            var start = 0
            for count in orbitStrips {
                enc.drawPrimitives(type: .lineStrip, vertexStart: start, vertexCount: count)
                start += count
            }
            if lines.count > start {
                enc.drawPrimitives(type: .line, vertexStart: start, vertexCount: lines.count - start)
            }
        }

        // 6. Plumes, added over everything opaque, tested against it.
        if let b = arena.push(plumes) {
            enc.setRenderPipelineState(plumePipeline)
            enc.setDepthStencilState(depthReadOnly)
            var u = PointUniforms(viewProjection: viewProj, params: pointParams)
            enc.setVertexBuffer(b.buffer, offset: b.offset, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<PointUniforms>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: plumes.count)
        }

        // 7. Distant bodies and vessels as points (Sun glare included).
        if let b = arena.push(farPoints) {
            enc.setRenderPipelineState(pointPipeline)
            enc.setDepthStencilState(depthReadOnly)
            var u = PointUniforms(viewProjection: viewProj, params: pointParams)
            enc.setVertexBuffer(b.buffer, offset: b.offset, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<PointUniforms>.stride, index: 1)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: farPoints.count)
        }

        // 8. Markers, a fixed size on screen (occluded anchors were left out).
        if let atlas, let b = arena.push(sprites) {
            enc.setRenderPipelineState(spritePipeline)
            enc.setDepthStencilState(noDepth)
            var u = SpriteUniforms(viewProjection: viewProj,
                                   params: SIMD4(2 / Float(max(size.width, 1)), 2 / Float(max(size.height, 1)), 0, 0))
            enc.setVertexBuffer(b.buffer, offset: b.offset, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<SpriteUniforms>.stride, index: 1)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.setFragmentSamplerState(spriteSampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: sprites.count)
        }

        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
        times.addEncode(CACurrentMediaTime() - encodeStart)
    }

    // MARK: Light

    struct VesselLight {
        var sunDir: SIMD4<Float>
        var light: SIMD4<Float>
        var earthDir: SIMD4<Float>
        var earthColor: SIMD4<Float>
    }

    /// Ambient light: a floor that keeps an unlit side from going black.
    static let ambientFloor: Float = 0.02
    /// Skylight at sea level with the Sun well up, falling with the square
    /// root of the air's density and fading out as the Sun sets.
    static let skylight = 0.25

    /// The Sun's direction and share (`Eclipse`: Earth and Moon as
    /// occulters), the ambient (a floor, plus the sky's light in air), and
    /// the light the reference body reflects onto the vessel:
    /// its albedo over the share of the sky it fills, (R/r)², times the lit
    /// part of the cap the vessel sees (a cap of half-angle acos(R/r) about
    /// the nadir, the terminator crossing it as the vessel's Sun-centre-vessel
    /// angle passes 90°). Visual approximations, like earthshine's colour.
    func vesselLight(_ v: Vessel, snapshot snap: SystemSnapshot, system: SolarSystem, sun: Vec3) -> VesselLight {
        let position = snap.position(v.reference) + v.position
        let toSun = (sun - position).normalized
        let sunlit = Eclipse.sunlitFraction(at: v.position, relativeTo: v.reference, in: system, snapshot: snap)
        var earth = SIMD4<Float>.zero, strength: Float = 0, colour = SIMD4<Float>.zero
        let body = v.reference, r = v.position.length
        if body !== system.sun, r > 0 {
            let reflect = Self.reflectance(of: body)
            let bodyToSun = (sun - snap.position(body)).normalized
            let phase = acos(max(-1, min(1, bodyToSun.dot(v.position / r))))
            let cap = max(acos(min(1, body.radius / r)), 0.02)
            let lit = max(0, min(1, (Double.pi / 2 - phase + cap) / (2 * cap)))
            earth = SIMD4((-v.position / r), Float(lit))
            strength = Float(reflect.albedo * min(1, (body.radius / r) * (body.radius / r)))
            colour = SIMD4(reflect.color, 0)
        }
        // In air, the daylit sky lights the shaded side too.
        var sky = 0.0
        if v.atmosphere.density > 0, r > 0 {
            let elevation = toSun.dot(v.position / r)
            let t = max(0, min(1, (elevation + 0.1) / 0.35))
            sky = Self.skylight * min(1, v.atmosphere.density / 1.225).squareRoot() * t * t * (3 - 2 * t) * sunlit
        }
        return VesselLight(sunDir: SIMD4(toSun, 0),
                           light: SIMD4(Float(sunlit), Self.ambientFloor + Float(sky), strength, 0),
                           earthDir: earth, earthColor: colour)
    }

    /// Bond albedo (rounded) and the reflected light's colour.
    static func reflectance(of body: CelestialBody) -> (albedo: Double, color: SIMD3<Float>) {
        switch body.id {
        case 399: return (0.30, SIMD3(0.78, 0.88, 1.0))
        case 301: return (0.12, SIMD3(1.0, 0.97, 0.93))
        case 499: return (0.25, SIMD3(1.0, 0.72, 0.52))
        default: return (0.25, SIMD3(1, 1, 1))
        }
    }

    /// The vessel's velocity through the air (world, unit), zero in vacuum.
    func flowDirection(_ v: Vessel, snapshot: SystemSnapshot) -> SIMD4<Float> {
        guard v.atmosphere.density > 0 else { return .zero }
        let air = v.surfaceVelocity(snapshot: snapshot)
        return air.length > 1 ? SIMD4(air.normalized, 0) : .zero
    }

    // MARK: Heat-shield glow

    /// The heat shield's glow, linear RGB: the heat flux through a
    /// first-order lag (`thermalLag`, in simulation time, so it neither
    /// flickers at warp nor freezes when paused), as the radiative-equilibrium
    /// temperature of an ablator of emissivity 0.85, coloured as a blackbody
    /// and brightening from the Draper point (about 800 K).
    func heatShieldGlow(_ v: Vessel, time: Epoch) -> SIMD3<Float> {
        var state = thermal[v.id] ?? (v.heatFlux, time)
        let dt = time - state.time
        if dt < 0 || dt > 600 {
            state = (v.heatFlux, time)     // a reload or a long jump: no history
        } else if dt > 0 {
            state.flux += (v.heatFlux - state.flux) * (1 - exp(-dt / Self.thermalLag))
            state.time = time
        }
        thermal[v.id] = state
        return Self.glowColor(heatFlux: state.flux)
    }

    static func glowColor(heatFlux q: Double) -> SIMD3<Float> {
        let stefanBoltzmann = 5.670374419e-8, emissivity = 0.85
        let temperature = pow(max(q, 0) / (emissivity * stefanBoltzmann), 0.25)
        guard temperature > 800 else { return .zero }
        let brightness = pow(min((temperature - 800) / 1_200, 1.25), 1.5)
        return blackbody(temperature) * Float(brightness)
    }

    /// Linear RGB of a blackbody at `kelvin` (Tanner Helland's fit to the
    /// Planckian locus in sRGB, 1,000-40,000 K), red normalised to 1 below
    /// 6,600 K.
    static func blackbody(_ kelvin: Double) -> SIMD3<Float> {
        let t = max(10, min(400, kelvin / 100))
        let r = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
        let g = t <= 66 ? 99.4708025861 * log(t) - 161.1195681661 : 288.1221695283 * pow(t - 60, -0.0755148492)
        let b = t >= 66 ? 255 : (t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307)
        func linear(_ c: Double) -> Float { Float(pow(max(0, min(255, c)) / 255, 2.2)) }
        return SIMD3(linear(r), linear(g), linear(b))
    }

    // MARK: Plumes

    func appendPlumes(of v: Vessel, mesh: VesselMesh, at rel: Vec3, to out: inout [PlumeVertex]) {
        let pressure = v.atmosphere.pressure
        for part in v.parts {
            for t in part.thrusters where t.isDelivering {
                let rating = t.currentRating.thrustVacuum
                guard rating > 0 else { continue }
                let fraction = t.thrust(ambientPressure: pressure, seaLevelPressure: standardAtmosphere) / rating
                let r = t.gimbal.isEmpty ? Mat3.identity : Mat3.rotation(from: t.direction, to: t.thrustDirection)
                let exit: Vec3, radius: Double
                if let n = mesh.nozzles[ObjectIdentifier(t)] {
                    exit = n.pivot + r * (n.exit - n.pivot)
                    radius = n.radius
                } else {
                    exit = t.position + part.offset - v.structureOrigin
                    radius = Plumes.nominalExitRadius(thrust: rating, solid: t.isSolid)
                }
                Plumes.append(exit: rel + v.attitude.rotate(v.structureOrigin + exit),
                              axis: v.attitude.rotate(-t.thrustDirection), radius: radius, style: Plumes.style(of: t),
                              fraction: fraction, pressureRatio: pressure / standardAtmosphere,
                              jet: !t.isSolid && !t.groups.contains(.main), to: &out)
            }
        }
    }

    /// A vessel too small to draw: a point, tinted by its plume while a main
    /// engine or a solid fires, dimmed in the shadow otherwise.
    func farPoint(of v: Vessel, at rel: Vec3, sunlit: Float) -> PointVertex {
        if let t = v.thrusters.first(where: { $0.isDelivering && ($0.groups.contains(.main) || $0.isSolid) }) {
            let c = Plumes.pointColor(Plumes.style(of: t))
            return PointVertex(position: SIMD4(rel, 1), color: SIMD4(c.x, c.y, c.z, 1), size: SIMD4(5, 0, 0, 0))
        }
        let b = 0.9 * max(sunlit, 0.2)
        return PointVertex(position: SIMD4(rel, 1), color: SIMD4(1, 1, 1, b), size: SIMD4(3, 0, 0, 0))
    }

    // MARK: Parachutes

    /// The deployed canopies of `v`, each along the air flow from its
    /// cluster's riser confluence (straight up without air speed), spread
    /// apart for a cluster, sized by its inflation (diameter as the square
    /// root of the drag-area share, deeper while reefed). Their risers go to
    /// `risers`. Visual only: the riser length and the spread are guesses.
    func drawCanopies(of v: Vessel, at rel: Vec3, snapshot: SystemSnapshot, uniforms: MeshUniforms,
                      viewProjection: simd_float4x4, encoder enc: MTLRenderCommandEncoder,
                      risers: inout [LineVertex]) {
        let chutes = v.parts.flatMap { part in part.parachutes.map { (part, $0) } }
            .filter { $0.1.isDeployed && $0.1.currentDragArea > 0 }
        guard !chutes.isEmpty else { return }
        let air = v.surfaceVelocity(snapshot: snapshot)
        let up = v.reference.vertical(at: v.position, orientation: snapshot.orientation(v.reference))
        let trail = air.length > 1 ? -air.normalized : up
        let u0 = VisualShape.defaultReference(for: trail), w0 = trail.cross(u0)
        var u = uniforms
        u.glow = .zero
        u.flowDir = .zero
        let riserColor = SIMD4<Float>(0.82, 0.8, 0.74, 0.85)
        for (part, chute) in chutes {
            let main = chute.diameter > 10
            guard let mesh = main ? mainCanopy : drogueCanopy else { continue }
            let efficiency = chute.clusterEfficiency[chute.count] ?? 1
            let share = chute.currentDragArea / (Double(chute.count) * efficiency * chute.dragArea)
            let open = max(0.12, min(1, share).squareRoot())
            let radius = 0.5 * 0.72 * chute.diameter * open    // an inflated canopy spans ~0.72 of its nominal diameter
            let height = 2 * radius * CanopyMesh.depth * (1 + 0.8 * (1 - open))
            let riser = chute.diameter * (main ? 1.15 : 2.0)
            let confluence = rel + v.attitude.rotate(part.offset + chute.attachPoint)
            let spread = chute.count > 1 ? (main ? 0.32 : 0.2) * (0.6 + 0.4 * open) : 0
            for k in 0..<chute.count {
                let az = 2 * Double.pi * Double(k) / Double(chute.count) + 0.4
                let lean = u0 * cos(az) + w0 * sin(az)
                let axis = (trail * cos(spread) + lean * sin(spread)).normalized
                let side = VisualShape.defaultReference(for: axis), other = axis.cross(side)
                let skirt = confluence + axis * riser
                let sx = height / CanopyMesh.depth, sr = 2 * radius
                let m = simd_float4x4(columns: (SIMD4(axis * sx, 0), SIMD4(side * sr, 0), SIMD4(other * sr, 0),
                                                SIMD4(skirt, 1)))
                u.model = m
                u.normalMatrix = simd_float4x4(columns: (SIMD4(axis / sx, 0), SIMD4(side / sr, 0),
                                                         SIMD4(other / sr, 0), SIMD4(0, 0, 0, 1)))
                u.modelViewProjection = viewProjection * m
                enc.setVertexBuffer(mesh.buffer, offset: 0, index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<MeshUniforms>.stride, index: 1)
                enc.setFragmentBytes(&u, length: MemoryLayout<MeshUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.vertexCount)
                for i in 0..<8 {
                    let a = 2 * Double.pi * Double(i) / 8
                    risers.append(LineVertex(position: SIMD4(confluence, 1), color: riserColor))
                    risers.append(LineVertex(position: SIMD4(skirt + (side * cos(a) + other * sin(a)) * radius, 1),
                                             color: riserColor))
                }
            }
        }
    }

    // MARK: Helpers

    struct BodyStyle {
        var color: SIMD3<Float>
        var sky: SIMD3<Float> = .zero
        var scaleHeight: Float = 0
    }

    static func style(for body: CelestialBody) -> BodyStyle {
        switch body.id {
        case 10: return BodyStyle(color: SIMD3(1.0, 0.95, 0.85))
        case 399: return BodyStyle(color: SIMD3(0.05, 0.16, 0.45), sky: SIMD3(0.30, 0.55, 1.0), scaleHeight: 9_000)
        case 301: return BodyStyle(color: SIMD3(0.35, 0.34, 0.32))
        case 499: return BodyStyle(color: SIMD3(0.7, 0.35, 0.2))
        case 299: return BodyStyle(color: SIMD3(0.9, 0.85, 0.7))
        case 5: return BodyStyle(color: SIMD3(0.85, 0.75, 0.6))
        case 6: return BodyStyle(color: SIMD3(0.9, 0.8, 0.6))
        default: return BodyStyle(color: SIMD3(0.6, 0.6, 0.6))
        }
    }

    /// The osculating conic `el` about `body` as line strips, camera-relative
    /// with the body's centre at `center`: the whole ellipse, or the arc
    /// through periapsis inside the sphere of influence.
    static func orbitStrips(elements el: OrbitalElements, body: CelestialBody, center: Vec3) -> [[LineVertex]] {
        let color = SIMD4<Float>(0.3, 1.0, 0.45, 0.8)
        let points = el.conicPoints(512, maxRadius: min(body.soiRadius, 5e9))
        guard points.count > 1 else { return [] }
        return [points.map { LineVertex(position: SIMD4(center + $0, 1), color: color) }]
    }

    /// Whether the segment from the camera (the origin) to `p` passes
    /// through the sphere at `c` of radius `r` (all camera-relative, m).
    static func segmentHits(to p: Vec3, sphere c: Vec3, radius r: Double) -> Bool {
        let t = max(0, min(1, c.dot(p) / max(p.lengthSquared, 1e-12)))
        return (c - p * t).length < r
    }

    struct OrbitMarkerPlacement {
        let kind: SpriteAtlas.OrbitMarker
        /// From the body's centre, ICRF (m).
        let position: Vec3
        let text: String?
    }

    /// Where the markers sit on the conic: Pe at ν = 0 and Ap at ν = π (an
    /// ellipse inside the sphere of influence), with their heights above the
    /// equatorial radius as the HUD gives them; AN and DN on the body's
    /// equator; EI where the orbit comes down through 400,000 ft over the
    /// equatorial radius (`EntryInterface.standardHeight`).
    static func orbitMarkers(elements el: OrbitalElements, body: CelestialBody) -> [OrbitMarkerPlacement] {
        let a = body.figure.equatorialRadius, limit = min(body.soiRadius, 5e9)
        func height(_ r: Double) -> String {
            let km = (r - a) / 1_000
            return abs(km) < 10_000 ? String(format: "%.1f km", km) : String(format: "%.0f km", km)
        }
        var out: [OrbitMarkerPlacement] = []
        guard el.semiLatusRectum > 0 else { return out }
        if el.periapsisRadius < limit {
            out.append(.init(kind: .periapsis, position: el.position(atTrueAnomaly: 0), text: height(el.periapsisRadius)))
        }
        if el.isBound, el.apoapsisRadius < limit {
            out.append(.init(kind: .apoapsis, position: el.position(atTrueAnomaly: Double.pi),
                             text: height(el.apoapsisRadius)))
        }
        if let p = el.ascendingNode, p.length < limit { out.append(.init(kind: .ascendingNode, position: p, text: nil)) }
        if let p = el.descendingNode, p.length < limit { out.append(.init(kind: .descendingNode, position: p, text: nil)) }
        if let nus = el.trueAnomalies(atRadius: a + EntryInterface.standardHeight) {
            out.append(.init(kind: .entryInterface, position: el.position(atTrueAnomaly: nus.inbound), text: nil))
        }
        return out
    }
}

/// One frame's vertex data in a buffer reused every `framesInFlight` frames,
/// grown when a frame needs more.
final class FrameArena {
    private let device: MTLDevice
    private var buffer: MTLBuffer
    private var offset = 0

    init?(device: MTLDevice, capacity: Int) {
        guard let b = device.makeBuffer(length: capacity, options: .storageModeShared) else { return nil }
        self.device = device
        buffer = b
    }

    func reset() { offset = 0 }

    /// Copies `items` in, 256-byte aligned; the buffer and offset to bind,
    /// nil when there is nothing to draw.
    func push<T>(_ items: [T]) -> (buffer: MTLBuffer, offset: Int)? {
        guard !items.isEmpty else { return nil }
        let length = items.count * MemoryLayout<T>.stride
        var start = (offset + 255) & ~255
        if start + length > buffer.length {
            // The frame's earlier draws keep the old buffer alive.
            guard let b = device.makeBuffer(length: max(2 * buffer.length, 2 * length), options: .storageModeShared)
            else { return nil }
            buffer = b
            start = 0
        }
        items.withUnsafeBytes { bytes in
            buffer.contents().advanced(by: start).copyMemory(from: bytes.baseAddress!, byteCount: length)
        }
        offset = start + length
        return (buffer, start)
    }
}

/// Smoothed frame timings (s), written from Metal's completion thread.
final class FrameTimes: @unchecked Sendable {
    private let lock = NSLock()
    private var gpuTime = 0.0, encodeTime = 0.0

    var gpu: Double { lock.withLock { gpuTime } }
    var encode: Double { lock.withLock { encodeTime } }

    func addGPU(_ t: Double) { lock.withLock { gpuTime = gpuTime == 0 ? t : gpuTime + 0.05 * (t - gpuTime) } }
    func addEncode(_ t: Double) { lock.withLock { encodeTime = encodeTime == 0 ? t : encodeTime + 0.05 * (t - encodeTime) } }
}
