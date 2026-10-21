import Foundation
import Metal
import MetalKit
import simd
import OrbitCore
import OrbitScene

/// The bodies, farthest first, ray-traced on a full-screen triangle each,
/// with today's sky and haze (P1). Small ones are left to the far points.
/// Track E2 owns this pass and the planet module.
@MainActor
public final class PlanetPass: RenderPass {
    public let name = "Planets"
    public let stage = PassStage.opaque
    public let order = 10

    private var pipeline: MTLRenderPipelineState?
    private var textures: [Int: MTLTexture] = [:]
    private var fallbackTexture: MTLTexture?
    /// Load the user's planet textures (Application Support); off for
    /// snapshots that must not depend on them.
    public var loadsUserTextures: Bool

    public init(loadsUserTextures: Bool = true) {
        self.loadsUserTextures = loadsUserTextures
    }

    public func setUp(_ s: PassSetup) throws {
        pipeline = try PipelineBuilder.scene(try s.shaders.library(.planet), vertex: "planet_vertex",
                                             fragment: "planet_fragment", blend: .premultiplied, setup: s)
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
        for body in f.scene.bodies where !f.drawsPoint(body) {
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
            var u = PlanetUniforms(
                viewToWorld: simd_float4x4(rotation: cam.worldToView.transposed),
                worldToBody: simd_float4x4(rotation: worldToBody),
                centerRadius: SIMD4(rel, Float(a)),
                params: SIMD4(Float(altitude), Float(tanY) * aspect, Float(tanY), near),
                sunDir: SIMD4(body.toSun, body.isSun ? 1 : 0),
                baseColor: SIMD4(style.color.x, style.color.y, style.color.z, texture == nil ? 0 : 1),
                atmosphere: SIMD4(style.sky.x, style.sky.y, style.sky.z, style.scaleHeight),
                options: SIMD4(texture == nil ? 1 : 0, 0.015, 0, 0),
                origin: SIMD4(origin, Float(c)),
                figure: SIMD4(Float(stretch), 0, 0, 0))
            enc.setFragmentBytes(&u, length: MemoryLayout<PlanetUniforms>.stride, index: 0)
            enc.setFragmentTexture(texture ?? fallbackTexture, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
    }

    struct BodyStyle {
        var color: SIMD3<Float>
        var sky: SIMD3<Float> = .zero
        var scaleHeight: Float = 0
    }

    static func style(for id: Int) -> BodyStyle {
        switch id {
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
