import Foundation
import Metal

/// The frame's slots, in the order the frame graph runs them.
public enum PassStage: Int, CaseIterable, Comparable, CustomStringConvertible {
    /// P0: compute pre-passes and offscreen maps (probe, shadows, LUTs,
    /// cloud and particle simulation), on the command buffer.
    case prepare
    /// P1: opaque geometry (stars, planets, vessels, sites), into the scene targets.
    case opaque
    /// P2: full-screen composite of the sky, aerial perspective and clouds.
    case composite
    /// P3: transparents (plumes, particles), depth read-only.
    case transparent
    /// P4: post (exposure, bloom, tone mapping), on the command buffer.
    case post
    /// P5: display-space overlays (markers, labels, debug views).
    case overlay

    public static func < (a: PassStage, b: PassStage) -> Bool { a.rawValue < b.rawValue }

    /// "P0" ... "P5".
    public var description: String { "P\(rawValue)" }

    /// The stages that draw through a render encoder the graph opens; the
    /// others get the command buffer and make their own encoders.
    public var isRenderStage: Bool { self != .prepare && self != .post }
}

/// What a pass encodes into.
public enum PassEncoding {
    /// The frame's command buffer (P0 and P4): make compute, blit or render
    /// encoders of your own.
    case commandBuffer(MTLCommandBuffer)
    /// The shared render encoder of the scene targets (P1-P3, and P5 while
    /// there is no post pass). Set every state you rely on.
    case render(MTLRenderCommandEncoder)
}

/// A named texture or buffer passes hand each other through the frame
/// (`FrameContext.textures`). The frame graph checks at setup that each one
/// read is written by an earlier pass, is persistent, or is the graph's own.
public struct ResourceID: Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let name: String
    /// Kept from frame to frame (exposure, the probe, particle state,
    /// history): reading last frame's is fine.
    public let isPersistent: Bool

    public init(_ name: String, persistent: Bool = false) {
        self.name = name
        isPersistent = persistent
    }

    public init(stringLiteral name: String) { self.init(name) }

    public var description: String { name }

    // The graph's own.
    /// The scene's colour attachment (P1-P3; LDR until R1).
    public static let sceneColor = ResourceID("sceneColor")
    /// The scene's depth attachment (reversed-Z, cleared to 0).
    public static let sceneDepth = ResourceID("sceneDepth")
    /// The texture the frame ends in: the drawable or an offscreen target.
    public static let output = ResourceID("output")
    static let provided: Set<ResourceID> = [.sceneColor, .sceneDepth, .output]

    // Reserved for the tracks (names only; each track allocates its own).
    public static let hdrColor = ResourceID("hdrColor")                               // R1
    public static let exposure = ResourceID("exposure", persistent: true)             // R1
    public static let bloom = ResourceID("bloom")                                     // R1
    public static let dfgLUT = ResourceID("dfgLUT", persistent: true)                 // R2
    public static let environment = ResourceID("environment", persistent: true)       // R3
    public static let shadowAtlas = ResourceID("shadowAtlas")                         // R4
    public static let halfResDepth = ResourceID("halfResDepth")                       // R6
    public static let halfResTransparent = ResourceID("halfResTransparent")           // R6
    public static let oitAccumulation = ResourceID("oitAccumulation")                 // R6
    public static let oitRevealage = ResourceID("oitRevealage")                       // R6
    public static let atmosphereLUTs = ResourceID("atmosphereLUTs", persistent: true) // A2
    public static let aerialPerspective = ResourceID("aerialPerspective")             // A2
    public static let cloudLayer = ResourceID("cloudLayer")                           // C2
    public static let cloudDepth = ResourceID("cloudDepth")                           // C2
    public static let cloudShadow = ResourceID("cloudShadow")                         // C2
    public static let plumeLights = ResourceID("plumeLights")                         // P2
    public static let particles = ResourceID("particles", persistent: true)           // P3
}

/// A pixel size of the frame's targets.
public struct RenderSize: Equatable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// What a pass gets once, to build its pipelines.
@MainActor
public struct PassSetup {
    public let device: MTLDevice
    public let shaders: ShaderLibrary
    public let formats: SceneFormats
    public let states: CommonStates
}

/// The scene targets' formats, which a pass's render pipelines must match.
public struct SceneFormats: Equatable {
    /// The scene colour attachment (P1-P3, and P5 while there is no post).
    public var color: MTLPixelFormat
    public var depth: MTLPixelFormat
    public var sampleCount: Int
    /// The output (drawable or offscreen).
    public var output: MTLPixelFormat

    public init(color: MTLPixelFormat, depth: MTLPixelFormat, sampleCount: Int, output: MTLPixelFormat) {
        self.color = color
        self.depth = depth
        self.sampleCount = sampleCount
        self.output = output
    }
}

/// One step of the frame: a Swift file plus its own shader module.
@MainActor
public protocol RenderPass: AnyObject {
    var name: String { get }
    var stage: PassStage { get }
    /// Its place within the stage, lowest first.
    var order: Int { get }
    var reads: Set<ResourceID> { get }
    var writes: Set<ResourceID> { get }
    /// False for a slot nobody has filled yet: the graph skips it, at no cost.
    var isEnabled: Bool { get }
    /// A pass in a render stage (P1-P3, P5) that makes encoders of its own
    /// on the command buffer (half-resolution targets, compute) instead of
    /// drawing in the shared one: the graph ends the scene's encoder before
    /// it, and the next pass that draws in the scene opens its stage's own
    /// render pass or resumes the scene (`SceneTargetPlan.continuation`).
    /// It gets `.commandBuffer`. False by default.
    var encodesOnCommandBuffer: Bool { get }
    /// Whether it runs this frame (a debug view only while one is chosen);
    /// the encoders are planned around the passes that run.
    func isActive(in f: FrameContext) -> Bool
    /// Builds pipelines; a throw (a shader module that does not compile)
    /// disables this pass alone.
    func setUp(_ s: PassSetup) throws
    func resize(_ size: RenderSize)
    func encode(_ f: FrameContext, _ e: PassEncoding)
}

extension RenderPass {
    public var reads: Set<ResourceID> { [] }
    public var writes: Set<ResourceID> { [] }
    public var isEnabled: Bool { true }
    public var encodesOnCommandBuffer: Bool { false }
    public func isActive(in f: FrameContext) -> Bool { true }
    public func setUp(_ s: PassSetup) throws {}
    public func resize(_ size: RenderSize) {}
}

/// Depth and sampler states every pass may share.
@MainActor
public final class CommonStates {
    /// Reversed-Z: greater-equal, writing depth.
    public let depthWrite: MTLDepthStencilState
    /// Reversed-Z: greater-equal, depth read-only.
    public let depthReadOnly: MTLDepthStencilState
    /// No depth test.
    public let noDepth: MTLDepthStencilState
    /// Trilinear, 8× anisotropic, repeating in u (longitude) and clamped in v.
    public let equirectSampler: MTLSamplerState
    /// Bilinear, clamped.
    public let linearClamp: MTLSamplerState
    /// Greater-equal comparison, for the shadow maps.
    public let shadowCompare: MTLSamplerState

    init?(device: MTLDevice) {
        let dw = MTLDepthStencilDescriptor()
        dw.depthCompareFunction = .greaterEqual
        dw.isDepthWriteEnabled = true
        let dr = MTLDepthStencilDescriptor()
        dr.depthCompareFunction = .greaterEqual
        dr.isDepthWriteEnabled = false
        let dn = MTLDepthStencilDescriptor()
        dn.depthCompareFunction = .always
        dn.isDepthWriteEnabled = false

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.mipFilter = .linear
        sd.sAddressMode = .repeat
        sd.tAddressMode = .clampToEdge
        sd.maxAnisotropy = 8

        let lc = MTLSamplerDescriptor()
        lc.minFilter = .linear
        lc.magFilter = .linear
        lc.sAddressMode = .clampToEdge
        lc.tAddressMode = .clampToEdge

        let sc = MTLSamplerDescriptor()
        sc.minFilter = .linear
        sc.magFilter = .linear
        sc.sAddressMode = .clampToEdge
        sc.tAddressMode = .clampToEdge
        sc.compareFunction = .greaterEqual

        guard let depthWrite = device.makeDepthStencilState(descriptor: dw),
              let depthReadOnly = device.makeDepthStencilState(descriptor: dr),
              let noDepth = device.makeDepthStencilState(descriptor: dn),
              let equirect = device.makeSamplerState(descriptor: sd),
              let linearClamp = device.makeSamplerState(descriptor: lc),
              let shadowCompare = device.makeSamplerState(descriptor: sc) else { return nil }
        self.depthWrite = depthWrite
        self.depthReadOnly = depthReadOnly
        self.noDepth = noDepth
        equirectSampler = equirect
        self.linearClamp = linearClamp
        self.shadowCompare = shadowCompare
    }
}

/// Builds a render pipeline for the scene targets, with one of the blend
/// modes the passes use.
@MainActor
public enum PipelineBuilder {
    public enum Blend { case opaque, alpha, premultiplied, additive }

    public static func make(_ library: MTLLibrary, vertex: String, fragment: String, blend: Blend,
                            color: MTLPixelFormat, depth: MTLPixelFormat, sampleCount: Int,
                            device: MTLDevice) throws -> MTLRenderPipelineState {
        let d = MTLRenderPipelineDescriptor()
        guard let vfn = library.makeFunction(name: vertex), let ffn = library.makeFunction(name: fragment) else {
            throw ShaderLibrary.Failure.missingFunction("\(vertex) / \(fragment)")
        }
        d.vertexFunction = vfn
        d.fragmentFunction = ffn
        d.colorAttachments[0].pixelFormat = color
        d.depthAttachmentPixelFormat = depth
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

    /// A pipeline drawing into the scene targets.
    public static func scene(_ library: MTLLibrary, vertex: String, fragment: String, blend: Blend,
                             setup s: PassSetup) throws -> MTLRenderPipelineState {
        try make(library, vertex: vertex, fragment: fragment, blend: blend, color: s.formats.color,
                 depth: s.formats.depth, sampleCount: s.formats.sampleCount, device: s.device)
    }
}
