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
    let device: MTLDevice
    let queue: MTLCommandQueue
    weak var model: AppModel?

    private var planetPipeline: MTLRenderPipelineState!
    private var meshPipeline: MTLRenderPipelineState!
    private var pointPipeline: MTLRenderPipelineState!
    private var linePipeline: MTLRenderPipelineState!
    private var depthWrite: MTLDepthStencilState!
    private var depthReadOnly: MTLDepthStencilState!
    private var noDepth: MTLDepthStencilState!
    private var sampler: MTLSamplerState!

    private var starBuffer: MTLBuffer?
    private var starCount = 0
    private var meshes: [UUID: VesselMesh] = [:]
    private var textures: [Int: MTLTexture] = [:]
    private var fallbackTexture: MTLTexture!

    private var lastTime = CACurrentMediaTime()
    let near: Float = 0.25

    init?(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        super.init()

        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.clearDepth = 0
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = 60

        do {
            try buildPipelines(view: view)
        } catch {
            NSLog("OrbitSim: pipeline creation failed: \(error)")
            return nil
        }
        loadTextures()
    }

    // MARK: Setup

    private func buildPipelines(view: MTKView) throws {
        let library = try device.makeLibrary(source: shaderSource, options: nil)

        func pipeline(_ vfn: String, _ ffn: String, blending: Bool, premultiplied: Bool = false) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vfn)
            d.fragmentFunction = library.makeFunction(name: ffn)
            d.colorAttachments[0].pixelFormat = view.colorPixelFormat
            d.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            if blending {
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.rgbBlendOperation = .add
                c.alphaBlendOperation = .add
                c.sourceRGBBlendFactor = premultiplied ? .one : .sourceAlpha
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one
                c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        planetPipeline = try pipeline("planet_vertex", "planet_fragment", blending: true, premultiplied: true)
        meshPipeline = try pipeline("mesh_vertex", "mesh_fragment", blending: false)
        pointPipeline = try pipeline("point_vertex", "point_fragment", blending: true)
        linePipeline = try pipeline("line_vertex", "line_fragment", blending: true)

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
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }

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
            let altitude = dist - body.radius
            let worldToBody = snap.orientation(body).icrfToBody
            let texture = textures[body.id]
            var u = PlanetUniforms(
                viewToWorld: simd_float4x4(rotation: cam.worldToView.transposed),
                worldToBody: simd_float4x4(rotation: worldToBody),
                centerRadius: SIMD4(rel, Float(body.radius)),
                params: SIMD4(Float(altitude), Float(tanY) * aspect, Float(tanY), near),
                sunDir: SIMD4(toSun, body === sim.system.sun ? 1 : 0),
                baseColor: SIMD4(style.color.x, style.color.y, style.color.z, texture == nil ? 0 : 1),
                atmosphere: SIMD4(style.sky.x, style.sky.y, style.sky.z, style.scaleHeight),
                options: SIMD4(texture == nil ? 1 : 0, 0.015, 0, 0))
            enc.setFragmentBytes(&u, length: MemoryLayout<PlanetUniforms>.stride, index: 0)
            enc.setFragmentTexture(texture ?? fallbackTexture, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        // 3. Vessels.
        enc.setRenderPipelineState(meshPipeline)
        enc.setDepthStencilState(depthWrite)
        var liveIDs = Set<UUID>()
        for v in sim.vessels {
            liveIDs.insert(v.id)
            let sig = VesselMesh.signature(of: v)
            if meshes[v.id]?.signature != sig { meshes[v.id] = VesselMesh.build(for: v, device: device) }
            guard let mesh = meshes[v.id] else { continue }
            let rel = snap.position(v.reference) + v.position - cam.position
            let pixelSize = v.boundingRadius / max(rel.length, 1e-3) * pixelsPerRadian
            if pixelSize < 0.5 {
                farPoints.append(PointVertex(position: SIMD4(rel, 1), color: SIMD4(1, 1, 1, 0.9), size: SIMD4(3, 0, 0, 0)))
                continue
            }
            // Mesh vertices are in the construction frame; v.position is the CoM.
            let modelMatrix = simd_float4x4(rotation: v.attitude.matrix,
                                            translation: rel + v.attitude.rotate(v.structureOrigin))
            let toSun = (sunPos - (snap.position(v.reference) + v.position)).normalized
            var u = MeshUniforms(modelViewProjection: viewProj * modelMatrix, model: modelMatrix,
                                 sunDir: SIMD4(toSun, 0.08))
            enc.setVertexBuffer(mesh.buffer, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<MeshUniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<MeshUniforms>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.vertexCount)
        }
        meshes = meshes.filter { liveIDs.contains($0.key) }

        // 4. Orbit of the focus vessel.
        if model.showOrbit, let focus = sim.focus, focus.landed == nil {
            let strips = Self.orbitStrips(vessel: focus, snapshot: snap, cameraPosition: cam.position)
            let pts = strips.flatMap { $0 }
            if pts.count > 1, let buf = device.makeBuffer(bytes: pts, length: pts.count * MemoryLayout<LineVertex>.stride,
                                                           options: .storageModeShared) {
                enc.setRenderPipelineState(linePipeline)
                enc.setDepthStencilState(depthReadOnly)
                var u = PointUniforms(viewProjection: viewProj, params: pointParams)
                enc.setVertexBuffer(buf, offset: 0, index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<PointUniforms>.stride, index: 1)
                var start = 0
                for strip in strips {
                    if strip.count > 1 {
                        enc.drawPrimitives(type: .lineStrip, vertexStart: start, vertexCount: strip.count)
                    }
                    start += strip.count
                }
            }
        }

        // 5. Distant bodies and vessels as points (Sun glare included).
        if !farPoints.isEmpty,
           let buf = device.makeBuffer(bytes: farPoints, length: farPoints.count * MemoryLayout<PointVertex>.stride,
                                       options: .storageModeShared) {
            enc.setRenderPipelineState(pointPipeline)
            enc.setDepthStencilState(depthReadOnly)
            var u = PointUniforms(viewProjection: viewProj, params: pointParams)
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<PointUniforms>.stride, index: 1)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: farPoints.count)
        }

        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
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

    /// Osculating Kepler orbit of `vessel` as line strips (split where the
    /// orbit leaves the sphere of influence), camera-relative.
    static func orbitStrips(vessel: Vessel, snapshot: SystemSnapshot, cameraPosition: Vec3) -> [[LineVertex]] {
        let mu = vessel.reference.gm
        let r = vessel.position, v = vessel.velocity
        let el = OrbitalElements(position: r, velocity: v, mu: mu)
        let h = r.cross(v)
        guard h.length > 0 else { return [] }
        let e = el.eccentricity
        let p = h.lengthSquared / mu
        // Perifocal basis in the inertial frame.
        let eVec = v.cross(h) / mu - r.normalized
        let pHat = e > 1e-8 ? eVec.normalized : r.normalized
        let wHat = h.normalized
        let qHat = wHat.cross(pHat)
        let center = snapshot.position(vessel.reference) - cameraPosition
        let color = SIMD4<Float>(0.3, 1.0, 0.45, 0.8)
        var strips: [[LineVertex]] = [[]]
        let n = 512
        var maxNu = Double.pi
        if e >= 1 {
            maxNu = acos(-1 / e) - 0.02
        }
        let soi = vessel.reference.soiRadius
        for i in 0...n {
            let nu = e < 1 ? 2 * Double.pi * Double(i) / Double(n) : -maxNu + 2 * maxNu * Double(i) / Double(n)
            let radius = p / (1 + e * cos(nu))
            if radius <= 0 || radius > min(soi, 5e9) {
                if !(strips.last?.isEmpty ?? true) { strips.append([]) }
                continue
            }
            let pos = (pHat * cos(nu) + qHat * sin(nu)) * radius
            strips[strips.count - 1].append(LineVertex(position: SIMD4(center + pos, 1), color: color))
        }
        return strips.filter { $0.count > 1 }
    }
}
