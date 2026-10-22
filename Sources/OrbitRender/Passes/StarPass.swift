import Foundation
import Metal
import simd
import OrbitCore
import OrbitScene

/// The stars and the Sun's disc, at infinity (P1, first), in photometric
/// units. Track R1 owns this file and the star module.
///
/// A star is its V magnitude as illuminance (`Photometry.illuminance`),
/// coloured as a blackbody at the temperature its B-V gives, spread over a
/// tent two pixels in radius whose samples sum to its light: so the
/// exposure decides what shows, and stars vanish beside a sunlit vehicle or
/// a daylit sky, as in the Apollo photographs, and come out in the dark.
/// The Sun is a limb-darkened disc of E⊙/Ω⊙ (1.96e9 cd/m²), or a point
/// source of E⊙ when it covers less than a pixel.
@MainActor
public final class StarPass: RenderPass {
    public let name = "Stars"
    public let stage = PassStage.opaque
    public let order = 0

    /// The tent's radius, px.
    public static let spread: Float = 2

    private var pointPipeline: MTLRenderPipelineState?
    private var sunPipeline: MTLRenderPipelineState?
    private var device: MTLDevice?
    private var stars: [Star] = []
    private var buffer: MTLBuffer?
    private var count = 0

    public init() {}

    public func setUp(_ s: PassSetup) throws {
        let library = try s.shaders.library(.star)
        pointPipeline = try PipelineBuilder.scene(library, vertex: "star_vertex", fragment: "star_fragment",
                                                  blend: .additive, setup: s)
        sunPipeline = try PipelineBuilder.scene(library, vertex: "sun_vertex", fragment: "sun_fragment",
                                                blend: .additive, setup: s)
        device = s.device
        upload()
    }

    /// The catalogue to draw (`StarCatalog`), set once.
    public func setStars(_ stars: [Star]) {
        self.stars = stars
        upload()
    }

    private func upload() {
        guard let device else { return }
        let points = stars.map(Self.point)
        count = points.count
        buffer = points.isEmpty ? nil : device.makeBuffer(bytes: points, length: points.count * MemoryLayout<StarPoint>.stride,
                                                          options: .storageModeShared)
    }

    /// A star as a point source: its illuminance, coloured by its B-V.
    static func point(_ s: Star) -> StarPoint {
        let c = Self.color(bv: s.colorIndex).scaled(by: Photometry.illuminance(visualMagnitude: s.magnitude))
        return StarPoint(position: SIMD4(s.direction, 0), illuminance: SIMD4(Float(c.r), Float(c.g), Float(c.b), 0))
    }

    /// A star's colour at unit luminance, from its B-V, through a table of
    /// blackbodies (B-V from -0.4 to 2.0 in steps of 0.1), interpolated.
    static func color(bv: Double) -> Photometry.RGB {
        let x = (min(max(bv, -0.4), 2.0) + 0.4) / 0.1
        let i = min(Int(x), colorTable.count - 2), t = x - Double(i)
        let a = colorTable[i], b = colorTable[i + 1]
        return Photometry.RGB(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t)
    }

    private nonisolated static let colorTable: [Photometry.RGB] = (0...24).map {
        Photometry.blackbody(Photometry.starTemperature(colorIndex: -0.4 + 0.1 * Double($0))).color
    }

    /// The uniforms of the point sources.
    static func uniforms(_ f: FrameContext) -> StarUniforms {
        let cam = f.scene.camera
        let pixel = 2 * tan(cam.fovY / 2) / max(cam.viewport.height, 1)
        return StarUniforms(viewProjection: f.viewProjection, view: f.view,
                            viewport: SIMD4(Float(f.size.width), Float(f.size.height), 0, 0),
                            params: SIMD4(Float(pixel * pixel), spread, f.frame.exposure.x, 0))
    }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {
        guard case .render(let enc) = e, let pointPipeline, let sunPipeline else { return }
        enc.setDepthStencilState(f.states.noDepth)
        var u = Self.uniforms(f)
        if let buffer {
            enc.setRenderPipelineState(pointPipeline)
            enc.setVertexBuffer(buffer, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<StarUniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<StarUniforms>.stride, index: 1)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: count)
        }
        // The Sun: a disc, or a point when it covers less than a pixel.
        let sun = f.scene.sun, cam = f.scene.camera
        let lux = Photometry.sunColor.scaled(by: sun.illuminance)
        let radius = sun.angularRadius * cam.pixelsPerRadian
        if radius < 1 {
            let p = [StarPoint(position: SIMD4(sun.direction, 0), illuminance: SIMD4(Float(lux.r), Float(lux.g), Float(lux.b), 0))]
            guard let b = f.arena.push(p) else { return }
            enc.setRenderPipelineState(pointPipeline)
            enc.setVertexBuffer(b.buffer, offset: b.offset, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<StarUniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<StarUniforms>.stride, index: 1)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 1)
            return
        }
        let centre = Photometry.sunColor.scaled(by: Photometry.solarLuminance * Photometry.solarCentreOverMean
                                                * Double(f.frame.exposure.x))
        let margin = 2 / cam.pixelsPerRadian
        var s = SunUniforms(direction: SIMD4(sun.direction, Float(sun.angularRadius)),
                            light: SIMD4(Float(centre.r), Float(centre.g), Float(centre.b),
                                         Float(Photometry.solarLimbDarkening)),
                            quad: SIMD4(Float(tan(sun.angularRadius + margin)), Float(cam.pixelsPerRadian), 0, 0),
                            viewProjection: f.viewProjection)
        enc.setRenderPipelineState(sunPipeline)
        enc.setVertexBytes(&s, length: MemoryLayout<SunUniforms>.stride, index: 1)
        enc.setFragmentBytes(&s, length: MemoryLayout<SunUniforms>.stride, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
}

/// Bodies and vessels too small to draw, as point sources (P3, after the
/// plumes), tested against the depth: a body by its reflected sunlight (a
/// Lambert sphere of its Bond albedo, at its phase), a vessel the same, in
/// its share of sunlight, plus its plume's light while a main engine or a
/// solid fires. Track R1 owns this pass.
@MainActor
public final class FarPointPass: RenderPass {
    public let name = "Far points"
    public let stage = PassStage.transparent
    public let order = 20

    private var pipeline: MTLRenderPipelineState?

    public init() {}

    public func setUp(_ s: PassSetup) throws {
        pipeline = try PipelineBuilder.scene(try s.shaders.library(.star), vertex: "star_vertex",
                                             fragment: "star_fragment", blend: .additive, setup: s)
    }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {
        guard case .render(let enc) = e, let pipeline else { return }
        var points: [StarPoint] = []
        let sun = f.scene.sun
        for body in f.scene.bodies where !body.isSun && f.drawsPoint(body) {
            let toSun = sun.position - body.position
            let e = Self.lambertSphere(radius: body.radius, albedo: Self.bondAlbedo(body.id), distance: body.distance,
                                       sunIlluminance: Photometry.solarIlluminance(distance: toSun.length),
                                       phase: Self.phaseAngle(toSun: toSun, toCamera: -body.position))
            let c = Self.unitColor(PlanetPass.style(for: body.id).color).scaled(by: e)
            points.append(StarPoint(position: SIMD4(body.position.normalized, 0),
                                    illuminance: SIMD4(Float(c.r), Float(c.g), Float(c.b), 0)))
        }
        for v in f.scene.vessels where f.drawsPoint(v.id) {
            points.append(Self.point(of: v, sun: sun))
        }
        guard let b = f.arena.push(points) else { return }
        var u = StarPass.uniforms(f)
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(f.states.depthReadOnly)
        enc.setVertexBuffer(b.buffer, offset: b.offset, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<StarUniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<StarUniforms>.stride, index: 1)
        enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: points.count)
    }

    /// The illuminance (lux) at `distance` from a Lambert sphere of
    /// `radius` and Bond albedo `albedo` (geometric albedo 2/3 of it) lit by
    /// `sunIlluminance`, at phase angle `phase` (rad).
    static func lambertSphere(radius: Double, albedo: Double, distance: Double, sunIlluminance: Double,
                              phase: Double) -> Double {
        let p = 2 * albedo / 3
        let phi = (sin(phase) + (Double.pi - phase) * cos(phase)) / Double.pi
        let r = radius / max(distance, radius)
        return sunIlluminance * p * r * r * max(phi, 0)
    }

    static func phaseAngle(toSun: Vec3, toCamera: Vec3) -> Double {
        acos(max(-1, min(1, toSun.normalized.dot(toCamera.normalized))))
    }

    static func bondAlbedo(_ id: Int) -> Double {
        switch id {
        case 399: 0.30
        case 301: 0.12
        case 499: 0.25
        case 299: 0.76
        case 5, 6: 0.34
        default: 0.3
        }
    }

    /// `c` scaled to a luminance of 1.
    static func unitColor(_ c: SIMD3<Float>) -> Photometry.RGB {
        let rgb = Photometry.RGB(Double(c.x), Double(c.y), Double(c.z))
        return rgb.luminance > 0 ? rgb.scaled(by: 1 / rgb.luminance) : Photometry.RGB(1, 1, 1)
    }

    /// A vessel's effective radius over its bounding radius, and its Bond
    /// albedo (white paint and foil): visual estimates.
    static let crossSection = 0.4, vesselAlbedo = 0.6
    /// A plume's luminous intensity seen from afar, cd: kerosene and solid
    /// plumes glow; hydrogen and hypergolic ones are faint (visual estimates).
    static func plumeIntensity(_ style: PlumeStyle) -> Double {
        switch style {
        case .kerosene, .solid: 3e8
        case .hydrogen: 2e6
        case .hypergolic: 1e6
        }
    }

    static func point(of v: RenderScene.Vessel, sun: RenderScene.Sun) -> StarPoint {
        let d = v.position.length
        let phase = phaseAngle(toSun: sun.position - v.position, toCamera: -v.position)
        var lux = Photometry.sunColor.scaled(by: lambertSphere(radius: v.boundingRadius * crossSection,
                                                               albedo: vesselAlbedo, distance: d,
                                                               sunIlluminance: sun.illuminance * v.light.sunlit,
                                                               phase: phase))
        if let style = v.farPointStyle {
            let c = unitColor(Plumes.pointColor(style)).scaled(by: plumeIntensity(style) / max(d * d, 1))
            lux = Photometry.RGB(lux.r + c.r, lux.g + c.g, lux.b + c.b)
        }
        return StarPoint(position: SIMD4(v.position, 1), illuminance: SIMD4(Float(lux.r), Float(lux.g), Float(lux.b), 0))
    }
}

// Swift mirrors of StarShaders' structs.

/// A point source.
struct StarPoint {
    /// xyz: direction or camera-relative position (world), w: 0 = direction, 1 = point.
    var position: SIMD4<Float>
    /// rgb: illuminance at the camera, lux.
    var illuminance: SIMD4<Float>
}

struct StarUniforms {
    var viewProjection: simd_float4x4
    var view: simd_float4x4
    var viewport: SIMD4<Float>
    /// x: a pixel's solid angle on the axis (sr), y: the tent's radius (px), z: pre-exposure.
    var params: SIMD4<Float>
}

struct SunUniforms {
    var direction: SIMD4<Float>
    var light: SIMD4<Float>
    var quad: SIMD4<Float>
    var viewProjection: simd_float4x4
}
