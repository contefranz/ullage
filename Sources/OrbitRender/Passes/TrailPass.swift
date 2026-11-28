import Foundation
import Metal
import OrbitCore
import OrbitScene

/// The frame's light on the trail (TrailShaders' `TrailFrame`).
struct TrailFrameGPU {
    /// xyz: unit to the Sun (world), w: 1 lit.
    var sun = SIMD4<Float>.zero
    /// rgb: the Sun's lux at the trail, w: 1 with C2's cloud shadow.
    var sunLight = SIMD4<Float>.zero
    /// rgb: the ambient where R3's probe is not drawn (cd/m², not pre-exposed).
    var ambient = SIMD4<Float>.zero
    /// x: 1 with aerial perspective, z: the line's σ along for its shadows (m).
    var params = SIMD4<Float>.zero
}

/// LR5's exhaust trail in R6's volumes layer (P3, half resolution): the
/// effect session's Gaussian media (`EffectFrameOutput.media`, the
/// trail's nodes, merged far off), each an instanced 3σ box drawn back
/// faces only, its chord shaded in closed form (TrailShaders). Over is
/// order-dependent, so the media come far to near, and the trail draws in
/// two parts about P2's march where it joins the S-IC's plume
/// (`EffectFrameOutput.mediaJoint`): those farther than the joint before
/// the plumes, the rest after them. Its back codes report where it ended
/// (LR0).
@MainActor
public final class TrailEffect: HalfResEffect {
    /// Which media this part draws: those beyond the joint (listed before
    /// P2's march) or the rest (after it).
    public enum Part { case beyondJoint, nearerThanJoint }

    public let name: String
    let part: Part
    let particles: ParticleSystem
    private var pipeline: MTLRenderPipelineState?

    /// The trail's line through a medium, for its shadows, is this long
    /// (σ, m): the column within a few kilometres of the point.
    public static let lineSigma = 2_000.0

    public init(particles: ParticleSystem, part: Part) {
        self.particles = particles
        self.part = part
        name = part == .beyondJoint ? "Trail (beyond the plume)" : "Trail"
    }

    public func setUpHalfRes(_ s: HalfResSetup) throws {
        pipeline = try s.pipeline(try s.shaders.library(.trail), vertex: "trail_box_vertex", fragment: "trail_box_fragment",
                                  layer: .volumes)
    }

    /// The reconstruction's codes (LR0): its boxes write back codes.
    public var reconstructedLayers: HalfResLayers { [.volumes] }

    /// This part's media, far to near, with their lines' peaks.
    func items(_ f: FrameContext) -> (media: ArraySlice<GaussianMedium>, lines: ArraySlice<Double>) {
        guard f.settings.particle.trail, let out = particles.plan(for: f)?.output, !out.media.isEmpty else { return ([], []) }
        // The media are far to near: those beyond the joint first.
        let split: Int
        if let joint = out.mediaJoint {
            let d = joint.lengthSquared
            split = out.media.firstIndex { $0.centre.lengthSquared <= d } ?? out.media.count
        } else {
            split = 0
        }
        switch part {
        case .beyondJoint: return (out.media[..<split], out.mediaLinePeaks[..<split])
        case .nearerThanJoint: return (out.media[split...], out.mediaLinePeaks[split...])
        }
    }

    public func halfResLayers(in f: FrameContext) -> HalfResLayers {
        pipeline != nil && !items(f).media.isEmpty ? .volumes : []
    }

    public func encodeHalfRes(_ f: FrameContext, _ slots: HalfResSlots, _ enc: MTLRenderCommandEncoder) {
        let (media, lines) = items(f)
        guard let pipeline, !media.isEmpty,
              let boxes = f.arena.push(media.map { GaussianMediumGPU($0, camera: .zero) }),
              let peaks = f.arena.push(lines.map { Float($0) }) else { return }
        var u = Self.uniforms(f, output: particles.plan(for: f)?.output)
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(slots.noDepth)
        // Back faces only: each texel once, the camera inside too.
        enc.setFrontFacing(.counterClockwise)
        enc.setCullMode(.front)
        enc.setVertexBuffer(boxes.buffer, offset: boxes.offset, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<TrailFrameGPU>.stride, index: 0)
        enc.setFragmentBuffer(boxes.buffer, offset: boxes.offset, index: 1)
        enc.setFragmentBuffer(peaks.buffer, offset: peaks.offset, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 36, instanceCount: media.count)
        enc.setCullMode(.none)
    }

    /// The light, as P2 takes it for its plumes (`PlumeSystem.prepare`):
    /// A2's Sun at the camera through the air (in vacuum, or for the
    /// studio's media, above it), times the media's anchor's sunlit share;
    /// its sky's mean radiance as the stand-in ambient.
    static func uniforms(_ f: FrameContext, output: EffectFrameOutput?) -> TrailFrameGPU {
        let sun = f.scene.sun, a = f.atmosphere
        let air = a.radii.w > 0.5 && a.radii.z < a.radii.y - a.radii.x && !(output?.mediaSunAboveAir ?? false)
        let sunlit = output?.mediaSunlit ?? 1
        let sunLux = (air && a.sunTransmitted.w > 0
            ? Photometry.RGB(Double(a.sunTransmitted.x * a.sunTransmitted.w), Double(a.sunTransmitted.y * a.sunTransmitted.w),
                             Double(a.sunTransmitted.z * a.sunTransmitted.w))
            : Photometry.sunColor.scaled(by: sun.illuminance)).scaled(by: sunlit)
        let sky = Photometry.RGB(Double(a.skyIrradiance.x), Double(a.skyIrradiance.y), Double(a.skyIrradiance.z))
        var u = TrailFrameGPU()
        u.sun = Plumes.f4(sun.direction, sunlit > 0 ? 1 : 0)
        u.sunLight = Plumes.f4(sunLux, 1)
        u.ambient = Plumes.f4(sky.scaled(by: 1 / (2 * Double.pi)), 0)
        u.params = SIMD4(f.settings.atmosphere.enabled ? 1 : 0, 0, Float(lineSigma), 0)
        return u
    }
}
