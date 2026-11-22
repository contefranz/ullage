import Foundation
import Metal
import MetalKit
import simd
import OrbitCore
import OrbitScene

/// The bodies, farthest first, ray-traced on a full-screen triangle each
/// (P1), in photometric units: Lambert grounds under the Sun, the Earth's
/// lit and hazed through A2's atmosphere when it is drawn (its sky is A2's
/// composite, P2). Small ones are left to the far points, and the Sun to
/// R1's star pass.
/// Track E2 owns this pass and the planet module.
@MainActor
public final class PlanetPass: RenderPass {
    public let name = "Planets"
    public let stage = PassStage.opaque
    public let order = 10
    public var reads: Set<ResourceID> { [.atmosphereIrradiance, .atmosphereProfile] }
    // (A2's `.spaceGroundScatter` and `.spaceGroundTransmittance` are used
    // when P0 wrote them this frame, as `.skyView` is through its slot.)

    private var pipeline: MTLRenderPipelineState?
    // E2 replaces: E1's tile hook. The tiled Earth's pipeline (the
    // `.planetTiled` module); every other draw uses `pipeline`, the plain
    // planet module, as without the tile store.
    private var tiledPipeline: MTLRenderPipelineState?
    private var textures: [Int: MTLTexture] = [:]
    private var fallbackTexture: MTLTexture?
    /// Load the user's planet textures (Application Support); off for
    /// snapshots that must not depend on them.
    public var loadsUserTextures: Bool
    /// E2 replaces: E1's tile store, whose albedo layer gives the Earth's
    /// albedo once any of it is resident.
    public let tiles: PlanetTilePass?

    public init(loadsUserTextures: Bool = true, tiles: PlanetTilePass? = nil) {
        self.loadsUserTextures = loadsUserTextures
        self.tiles = tiles
    }

    public func setUp(_ s: PassSetup) throws {
        probeLibraries = (s.device, try s.shaders.library(.planet), tiles == nil ? nil : try? s.shaders.library(.planetTiled))
        probePipelines = [:]
        pipeline = try PipelineBuilder.scene(try s.shaders.library(.planet), vertex: "planet_vertex",
                                             fragment: "planet_fragment", blend: .premultiplied, setup: s)
        // E2 replaces: a tile module that does not compile leaves the Earth untiled.
        tiledPipeline = tiles == nil ? nil : try? PipelineBuilder.scene(try s.shaders.library(.planetTiled),
                                                                       vertex: "planet_vertex", fragment: "planet_fragment",
                                                                       blend: .premultiplied, setup: s)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        fallbackTexture = s.device.makeTexture(descriptor: td)
        var white: [UInt8] = [255, 255, 255, 255]
        fallbackTexture?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &white, bytesPerRow: 4)
        textures = loadsUserTextures ? Self.loadTextures(device: s.device) : [:]
    }

    /// The textures loaded, by NAIF id.
    public var loadedTextures: [Int] { textures.keys.sorted() }

    /// Optional equirectangular textures: ~/Library/Application Support/OrbitSim/Textures/{earth,moon}.jpg
    static func loadTextures(device: MTLDevice) -> [Int: MTLTexture] {
        var textures: [Int: MTLTexture] = [:]
        let loader = MTKTextureLoader(device: device)
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return [:] }
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
        return textures
    }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {
        guard case .render(let enc) = e, let pipeline, let fallbackTexture else { return }
        let cam = f.scene.camera
        let tanY = tan(cam.fovY / 2)
        let aspect = Float(cam.aspect), near = Float(cam.near)
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(f.states.depthWrite)
        enc.setFragmentSamplerState(f.states.equirectSampler, index: 0)
        enc.setFragmentTexture(f.textures[.atmosphereIrradiance] ?? fallbackTexture, index: 1)
        enc.setFragmentTexture(f.textures[.atmosphereProfile] ?? fallbackTexture, index: 2)
        let air = f.atmosphere.radii.w > 0.5 && f.textures[.atmosphereProfile] != nil
        let groundSteps = Float(f.settings.atmosphere.groundSteps)
        // From space, A2's haze over the ground at a reduced resolution.
        let haze = f.textures[.spaceGroundScatter].flatMap { s in f.textures[.spaceGroundTransmittance].map { (s, $0) } }
        enc.setFragmentTexture(haze?.0 ?? fallbackTexture, index: 3)
        enc.setFragmentTexture(haze?.1 ?? fallbackTexture, index: 4)
        // E2 replaces: the albedo tiles, while the setting is on and once any are resident.
        let albedoTiles = f.settings.planetTile.enabled
            ? tiles?.layer(.albedo).flatMap { $0.residency.residentCount > 0 ? $0 : nil } : nil
        for body in f.scene.bodies where !body.isSun && !f.drawsPoint(body) {
            let rel = body.position
            let style = Self.style(for: body.id)
            // The camera in figure coordinates (body axes stretched along z
            // by a/b, where the figure is the sphere of radius a) and |o|^2 -
            // a^2, both in double: in float the latter would lose the
            // camera's height near the surface.
            let orientation = body.orientation, figure = body.figure
            let a = figure.equatorialRadius, stretch = a / figure.polarRadius
            let cameraBody = orientation.toBody(-rel)
            let origin = Vec3(cameraBody.x, cameraBody.y, cameraBody.z * stretch)
            let c = (origin.length - a) * (origin.length + a)
            let altitude = figure.geodetic(cameraBody).height
            let worldToBody = orientation.icrfToBody
            let texture = textures[body.id]
            // E2 replaces: the tiled Earth draws with the tile pipeline.
            let tiled = body.id == AtmosphereFrame.planetID ? albedoTiles : nil
            if let tiled, let tiledPipeline {
                enc.setRenderPipelineState(tiledPipeline)
                tiled.bindFragment(enc, atlas: 5, indirection: 6, deep: 1, uniforms: 2)
                enc.setFragmentSamplerState(tiled.sampler, index: 1)
            } else {
                enc.setRenderPipelineState(pipeline)
            }
            var u = PlanetUniforms(
                viewToWorld: simd_float4x4(rotation: cam.worldToView.transposed),
                worldToBody: simd_float4x4(rotation: worldToBody),
                centerRadius: SIMD4(rel, Float(a)),
                params: SIMD4(Float(altitude), Float(tanY) * aspect, Float(tanY), near),
                sunDir: SIMD4(body.toSun, body.isSun ? 1 : 0),
                baseColor: SIMD4(style.color.x, style.color.y, style.color.z, texture == nil ? 0 : 1),
                atmosphere: SIMD4(air && body.id == AtmosphereFrame.planetID ? 1 : 0, groundSteps, haze == nil ? 0 : 1,
                                  body.id == AtmosphereFrame.planetID ? 1 : 0),
                options: SIMD4(texture == nil && tiled == nil ? 1 : 0, 0.015, 0, 0),
                origin: SIMD4(origin, Float(c)),
                figure: SIMD4(Float(stretch), 0, 0, 0))
            enc.setFragmentBytes(&u, length: MemoryLayout<PlanetUniforms>.stride, index: 0)
            enc.setFragmentTexture(texture ?? fallbackTexture, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
    }

    // MARK: R3's probe entry point

    /// The device and the two planet modules, for the probe's pipelines.
    private var probeLibraries: (device: MTLDevice, plain: MTLLibrary, tiled: MTLLibrary?)?
    private var probePipelines: [String: (plain: MTLRenderPipelineState, tiled: MTLRenderPipelineState?)] = [:]

    /// R3's probe entry point: the bodies drawn into one 90° face of a
    /// radiance cube on `enc`, whose attachments have `formats`, seen from
    /// `center` (camera-relative, m), farthest first, as `encode` draws them
    /// but in cd/m² (the encoder's frame uniforms, buffer 30, carry a
    /// pre-exposure of 1), with no night floor and no grid, and from above
    /// the air with the ground's haze marched in the shader (`groundSteps`
    /// steps: A2's reduced-resolution haze is the camera's view). Inside the
    /// air the ground's haze is read from A2's sky-view LUT, the camera's,
    /// when the encoder's atmosphere uniforms carry the camera inside it
    /// (`radii.z`); R3 sets them above the air where the probe marches from
    /// its centre (`AtmosphereCompositePass.probeReadsSkyView`), so the haze
    /// is then marched from `center`. `viewToWorld`: the face's view basis
    /// (`EnvironmentProbe.basis`). Bodies under a texel across are left out
    /// (`faceSize` texels to the face's side). The encoder must have the
    /// atmosphere's uniforms (buffer 28) and its slots (25, 28, 29) bound.
    /// The pixels `encode` draws do not depend on this.
    public func encodeProbe(_ f: FrameContext, on enc: MTLRenderCommandEncoder, formats: SceneFormats,
                            viewToWorld: simd_float4x4, center: Vec3, faceSize: Int, groundSteps: Int, near: Double) {
        guard let libraries = probeLibraries, let fallbackTexture else { return }
        let key = "\(formats.color.rawValue) \(formats.depth.rawValue) \(formats.sampleCount)"
        if probePipelines[key] == nil {
            func make(_ library: MTLLibrary) -> MTLRenderPipelineState? {
                try? PipelineBuilder.make(library, vertex: "planet_vertex", fragment: "planet_fragment",
                                          blend: .premultiplied, color: formats.color, depth: formats.depth,
                                          sampleCount: formats.sampleCount, device: libraries.device)
            }
            guard let plain = make(libraries.plain) else { return }
            probePipelines[key] = (plain, libraries.tiled.flatMap(make))
        }
        guard let pipelines = probePipelines[key] else { return }
        enc.setRenderPipelineState(pipelines.plain)
        if formats.depth != .invalid { enc.setDepthStencilState(f.states.depthWrite) }
        enc.setFragmentSamplerState(f.states.equirectSampler, index: 0)
        enc.setFragmentTexture(f.textures[.atmosphereIrradiance] ?? fallbackTexture, index: 1)
        enc.setFragmentTexture(f.textures[.atmosphereProfile] ?? fallbackTexture, index: 2)
        enc.setFragmentTexture(fallbackTexture, index: 3)
        enc.setFragmentTexture(fallbackTexture, index: 4)
        let air = f.atmosphere.radii.w > 0.5 && f.textures[.atmosphereProfile] != nil
        let albedoTiles = f.settings.planetTile.enabled
            ? tiles?.layer(.albedo).flatMap { $0.residency.residentCount > 0 ? $0 : nil } : nil
        // A texel's angle at the face's centre.
        let texel = 2 / Double(max(faceSize, 1))
        let bodies = f.scene.bodies.filter { !$0.isSun }.sorted { ($0.position - center).length > ($1.position - center).length }
        for body in bodies {
            let rel = body.position - center
            let distance = rel.length
            let orientation = body.orientation, figure = body.figure
            let a = figure.equatorialRadius, stretch = a / figure.polarRadius
            let probeBody = orientation.toBody(-rel)
            let origin = Vec3(probeBody.x, probeBody.y, probeBody.z * stretch)
            let c = (origin.length - a) * (origin.length + a)
            // Outside the figure (its ellipsoid: on the pad the geocentric
            // radius is 4.9 km under the equatorial), and over a texel across.
            guard c > 0, 2 * asin(min(1, body.radius / max(distance, 1))) >= texel else { continue }
            let style = Self.style(for: body.id)
            let altitude = figure.geodetic(probeBody).height
            let texture = textures[body.id]
            let tiled = body.id == AtmosphereFrame.planetID ? albedoTiles : nil
            if let tiled, let tiledPipeline = pipelines.tiled {
                enc.setRenderPipelineState(tiledPipeline)
                tiled.bindFragment(enc, atlas: 5, indirection: 6, deep: 1, uniforms: 2)
                enc.setFragmentSamplerState(tiled.sampler, index: 1)
            } else {
                enc.setRenderPipelineState(pipelines.plain)
            }
            var u = PlanetUniforms(
                viewToWorld: viewToWorld,
                worldToBody: simd_float4x4(rotation: orientation.icrfToBody),
                centerRadius: SIMD4(rel, Float(a)),
                params: SIMD4(Float(altitude), 1, 1, Float(near)),
                sunDir: SIMD4(body.toSun, 0),
                baseColor: SIMD4(style.color.x, style.color.y, style.color.z, texture == nil ? 0 : 1),
                atmosphere: SIMD4(air && body.id == AtmosphereFrame.planetID ? 1 : 0, Float(groundSteps), 0, 0),
                options: SIMD4(0, 0, 0, 0),
                origin: SIMD4(origin, Float(c)),
                figure: SIMD4(Float(stretch), 0, 0, 0))
            enc.setFragmentBytes(&u, length: MemoryLayout<PlanetUniforms>.stride, index: 0)
            enc.setFragmentTexture(texture ?? fallbackTexture, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
    }

    struct BodyStyle {
        var color: SIMD3<Float>
    }

    static func style(for id: Int) -> BodyStyle {
        switch id {
        case 10: return BodyStyle(color: SIMD3(1.0, 0.95, 0.85))
        // Untextured, the Earth is an ocean: the open sea's albedo, about
        // 0.06 (its blue is the air's, A2's).
        case 399: return BodyStyle(color: SIMD3(0.04, 0.06, 0.08))
        case 301: return BodyStyle(color: SIMD3(0.35, 0.34, 0.32))
        case 499: return BodyStyle(color: SIMD3(0.7, 0.35, 0.2))
        case 299: return BodyStyle(color: SIMD3(0.9, 0.85, 0.7))
        case 5: return BodyStyle(color: SIMD3(0.85, 0.75, 0.6))
        case 6: return BodyStyle(color: SIMD3(0.9, 0.8, 0.6))
        default: return BodyStyle(color: SIMD3(0.6, 0.6, 0.6))
        }
    }
}

/// Swift mirror of PlanetShaders' uniforms.
struct PlanetUniforms {
    var viewToWorld: simd_float4x4
    var worldToBody: simd_float4x4
    var centerRadius: SIMD4<Float>
    var params: SIMD4<Float>
    var sunDir: SIMD4<Float>
    var baseColor: SIMD4<Float>
    var atmosphere: SIMD4<Float>
    var options: SIMD4<Float>
    var origin: SIMD4<Float>
    var figure: SIMD4<Float>
}
