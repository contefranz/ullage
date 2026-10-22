import Foundation
import Metal
import OrbitScene

// The effect slots (track R6): the half-resolution targets that clouds
// (C2), plumes (P2) and smoke (P3) draw into, and the frame's half of the
// contract. TransparentComposite.swift brings them back to the frame.
//
// How an effect draws through the slots:
// 1. It adopts `HalfResEffect` and is listed in
//    `HalfResTransparentPass(effects:)` in `SceneRenderer.defaultPasses`,
//    clouds first, then plumes, then smoke.
// 2. In `setUpHalfRes` it builds its pipelines with
//    `HalfResSetup.pipeline(_:vertex:fragment:layer:)`. Its module includes
//    the `.effectSlots` header.
// 3. Each frame, `halfResLayers(in:)` says which layers it draws, and
//    `encodeHalfRes` draws them on the encoder R6 opens. That encoder has
//    every layer cleared, R6's bindings set (EffectSlotsCommon) and the
//    targets' viewport.
//    - A volume (clouds, plumes) writes premultiplied radiance, pre-exposed
//      (FrameUniforms.exposure.x), with 1 − T in a. It writes its front
//      code too: `orbit_frontCode` of the nearest linear depth where its
//      contribution, accumulated front to back, becomes visible
//      (`orbit_frontReached`: coverage 2 % or radiance 1/256, so a bright
//      thin glow has a front), else ORBIT_EFFECT_NO_FRONT, which sorts
//      beneath every layer that has one. It draws its own items back to
//      front.
//    - OIT fragments (smoke) return `orbit_oitOutput`, in any order; each
//      reports its front if it is visible on its own.
//    - Depth: a proxy that marches clamps its march at
//      `orbit_effectSceneDistance` (texture 18) and draws with no depth
//      test (`HalfResSlots.noDepth`), back faces only. Sprites test
//      against the test depth (`HalfResSlots.depthTest`) and fade softly
//      on texture 18.

/// The layers an effect draws into this frame.
public struct HalfResLayers: OptionSet, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Clouds, premultiplied over (C2).
    public static let clouds = HalfResLayers(rawValue: 1)
    /// Volumes, premultiplied over: plumes (P2).
    public static let volumes = HalfResLayers(rawValue: 2)
    /// Weighted-blended OIT: smoke, steam, spray (P3).
    public static let oit = HalfResLayers(rawValue: 4)

    public init(_ layer: EffectSlots.Layer) {
        switch layer {
        case .clouds: self = .clouds
        case .volumes: self = .volumes
        case .oit: self = .oit
        }
    }
}

/// An effect that draws into the slots' half-resolution targets: the
/// contract R6 gives C2, P2 and P3 (see this file's header).
@MainActor
public protocol HalfResEffect: AnyObject {
    /// Its name, for the profiler's timings and `effectFailures`.
    var name: String { get }
    /// Builds its pipelines with `HalfResSetup.pipeline`. A throw disables
    /// this effect alone.
    func setUpHalfRes(_ s: HalfResSetup) throws
    /// The layers it draws this frame; empty when it has nothing to draw.
    /// With every effect empty the slots cost nothing.
    func halfResLayers(in f: FrameContext) -> HalfResLayers
    /// Draws its items on `enc`, open on the targets with R6's bindings.
    /// Within a layer it sorts its own items: over is order-dependent, OIT
    /// is not.
    func encodeHalfRes(_ f: FrameContext, _ slots: HalfResSlots, _ enc: MTLRenderCommandEncoder)
}

/// The resources the slots add to F0's reserved names (`halfResDepth`,
/// `halfResTransparent`, `oitAccumulation`, `oitRevealage`).
extension ResourceID {
    /// The clouds layer (rgba16Float, premultiplied).
    public static let halfResClouds = ResourceID("halfResClouds")
    /// The layers' fronts (rgba16Float front codes: r clouds, g volumes, b OIT).
    public static let halfResFronts = ResourceID("halfResFronts")
}

/// The half-resolution targets' formats, by colour attachment
/// (EffectSlotsCommon's ORBIT_EFFECT_*), and the depth's.
public enum HalfResFormats {
    public static let color: [MTLPixelFormat] = [.rgba16Float, .rgba16Float, .rgba16Float, .r16Float, .rgba16Float]
    public static let depth = MTLPixelFormat.depth32Float
    /// The downsample's min/max target, which texture 18 binds.
    public static let sceneDepth = MTLPixelFormat.rg32Float
    static let clouds = 0, volumes = 1, oitAccumulation = 2, oitRevealage = 3, fronts = 4
}

/// What an effect gets once, to build its pipelines.
@MainActor
public struct HalfResSetup {
    public let device: MTLDevice
    public let shaders: ShaderLibrary
    public let states: CommonStates

    /// A pipeline that draws `layer` into the half-resolution targets:
    /// - clouds and volumes premultiplied over, into their own attachment;
    /// - OIT added into the accumulation, with the revealage multiplied by
    ///   1 − a;
    /// - the layer's front channel taken with min.
    /// The other attachments are left untouched. `configure` may change
    /// the rest (vertex descriptor, culling is the encoder's).
    public func pipeline(_ library: MTLLibrary, vertex: String, fragment: String, layer: EffectSlots.Layer,
                         configure: ((MTLRenderPipelineDescriptor) -> Void)? = nil) throws -> MTLRenderPipelineState {
        guard let vfn = library.makeFunction(name: vertex), let ffn = library.makeFunction(name: fragment) else {
            throw ShaderLibrary.Failure.missingFunction("\(vertex) / \(fragment)")
        }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = vfn
        d.fragmentFunction = ffn
        d.depthAttachmentPixelFormat = HalfResFormats.depth
        d.rasterSampleCount = 1
        for (i, format) in HalfResFormats.color.enumerated() {
            d.colorAttachments[i].pixelFormat = format
            d.colorAttachments[i].writeMask = []
        }
        func blend(_ i: Int, _ src: MTLBlendFactor, _ dst: MTLBlendFactor, op: MTLBlendOperation = .add,
                   mask: MTLColorWriteMask = .all) {
            let c = d.colorAttachments[i]!
            c.writeMask = mask
            c.isBlendingEnabled = true
            c.rgbBlendOperation = op
            c.alphaBlendOperation = op
            c.sourceRGBBlendFactor = src
            c.sourceAlphaBlendFactor = src
            c.destinationRGBBlendFactor = dst
            c.destinationAlphaBlendFactor = dst
        }
        switch layer {
        case .clouds:
            blend(HalfResFormats.clouds, .one, .oneMinusSourceAlpha)
            blend(HalfResFormats.fronts, .one, .one, op: .min, mask: .red)
        case .volumes:
            blend(HalfResFormats.volumes, .one, .oneMinusSourceAlpha)
            blend(HalfResFormats.fronts, .one, .one, op: .min, mask: .green)
        case .oit:
            blend(HalfResFormats.oitAccumulation, .one, .one)
            blend(HalfResFormats.oitRevealage, .zero, .oneMinusSourceColor, mask: .red)
            blend(HalfResFormats.fronts, .one, .one, op: .min, mask: .blue)
        }
        configure?(d)
        return try device.makeRenderPipelineState(descriptor: d)
    }
}

/// What an effect sees each frame: the targets' size and the depth states.
/// R6 has bound the uniforms (buffer 27) and the half-resolution scene
/// depth (texture 18).
@MainActor
public struct HalfResSlots {
    /// The targets' size, texels.
    public let size: RenderSize
    /// Frame pixels per texel (2 at half resolution, 1 at full).
    public let scale: Int
    public let uniforms: EffectSlotUniforms
    /// Read-only greater-equal against the test depth, for sprites.
    public let depthTest: MTLDepthStencilState
    /// No depth test, for proxies that clamp their march in the shader.
    public let noDepth: MTLDepthStencilState
    /// The half-resolution scene depth (rg32Float: x the test depth, y
    /// the quad's other extreme), bound at texture 18.
    public let sceneDepth: MTLTexture
}

/// The slots' uniforms (EffectSlotsCommon's EffectSlotUniforms, buffer 27).
public struct EffectSlotUniforms {
    /// xy: the targets' size (texels), zw: 1 / size.
    public var target = SIMD4<Float>.zero
    /// x: frame pixels per texel, y: 1 / x, z: log2(1 + upsample
    /// tolerance), w: the layers drawn (`HalfResLayers.rawValue`).
    public var scale = SIMD4<Float>.zero
    /// x: the OIT reference depth (m), y: the weight's exponent, z and w:
    /// the depth factor's bounds.
    public var oit = SIMD4<Float>.zero
    /// x: the front opacity, y: the most a fragment adds to an
    /// accumulation channel, z: the front radiance (pre-exposed).
    public var front = SIMD4<Float>.zero

    public init() {}

    /// The frame's: `layers` drawn into targets of `size` at `scale`.
    public init(size: RenderSize, scale: Int, layers: HalfResLayers, settings: TransparencySettings, reference: Double) {
        let w = Float(size.width), h = Float(size.height)
        target = SIMD4(w, h, 1 / w, 1 / h)
        self.scale = SIMD4(Float(scale), 1 / Float(scale), Float(log2(1 + settings.upsampleTolerance)),
                           Float(layers.rawValue))
        oit = SIMD4(Float(min(max(reference, 1), 1e6)), Float(EffectSlots.oitWeightExponent),
                    Float(EffectSlots.oitWeightRange.min), Float(EffectSlots.oitWeightRange.max))
        front = SIMD4(Float(EffectSlots.frontOpacity), Float(EffectSlots.oitMaxAccumulation),
                      Float(EffectSlots.frontRadiance), 0)
    }
}

/// The scene depth to half resolution, then the effects into the
/// half-resolution layers (P3, first, on encoders of its own). Its
/// targets are `.halfResDepth`, `.halfResClouds`, `.halfResTransparent`
/// (volumes), `.oitAccumulation`, `.oitRevealage` and `.halfResFronts`.
/// It runs only on frames when an effect draws.
@MainActor
public final class HalfResTransparentPass: RenderPass {
    public let name = "Half-resolution transparents"
    public let stage = PassStage.transparent
    /// First in P3: a target plan that opens P3 with a render pass of its
    /// own then pays nothing for the scene's break.
    public let order = -10
    public var encodesOnCommandBuffer: Bool { true }
    public var reads: Set<ResourceID> { [.sceneDepth] }
    public var writes: Set<ResourceID> {
        [.halfResDepth, .halfResClouds, .halfResTransparent, .oitAccumulation, .oitRevealage, .halfResFronts]
    }

    /// The effects, in the order they draw.
    public let effects: [HalfResEffect]
    /// Effects whose set-up failed, by name, and why: they are skipped.
    public private(set) var effectFailures: [String: String] = [:]
    /// The layers drawn this frame, once it has encoded.
    public private(set) var layers: HalfResLayers = []
    /// This frame's uniforms, in the arena, for the composite and the debug view.
    private(set) var uniformsBuffer: (buffer: MTLBuffer, offset: Int)?

    private var depthPipeline: MTLRenderPipelineState?
    private var depthWrite: MTLDepthStencilState?
    private var depthTest: MTLDepthStencilState?
    private var noDepth: MTLDepthStencilState?
    /// Memoryless stand-ins for the attachments of layers not drawn.
    private var idle: (size: RenderSize, textures: [MTLTexture])?
    private var device: MTLDevice?

    public init(effects: [HalfResEffect] = []) {
        self.effects = effects
    }

    /// The effects that draw this frame and their layers.
    func drawing(in f: FrameContext) -> [(effect: HalfResEffect, layers: HalfResLayers)] {
        effects.compactMap { e in
            guard effectFailures[e.name] == nil else { return nil }
            let l = e.halfResLayers(in: f)
            return l.isEmpty ? nil : (e, l)
        }
    }

    public func isActive(in f: FrameContext) -> Bool { !drawing(in: f).isEmpty }

    public func setUp(_ s: PassSetup) throws {
        device = s.device
        let library = try s.shaders.library(.halfResTransparent)
        let d = MTLRenderPipelineDescriptor()
        guard let vfn = library.makeFunction(name: "effect_fullscreen_vertex"),
              let ffn = library.makeFunction(name: "effect_depth_fragment") else {
            throw ShaderLibrary.Failure.missingFunction("effect_fullscreen_vertex / effect_depth_fragment")
        }
        d.vertexFunction = vfn
        d.fragmentFunction = ffn
        d.colorAttachments[0].pixelFormat = HalfResFormats.sceneDepth
        d.depthAttachmentPixelFormat = HalfResFormats.depth
        depthPipeline = try s.device.makeRenderPipelineState(descriptor: d)
        let w = MTLDepthStencilDescriptor()
        w.depthCompareFunction = .always
        w.isDepthWriteEnabled = true
        depthWrite = s.device.makeDepthStencilState(descriptor: w)
        depthTest = s.states.depthReadOnly
        noDepth = s.states.noDepth

        effectFailures = [:]
        let setup = HalfResSetup(device: s.device, shaders: s.shaders, states: s.states)
        for e in effects {
            do {
                try e.setUpHalfRes(setup)
            } catch {
                effectFailures[e.name] = "\(error)"
                NSLog("OrbitSim: half-resolution effect \(e.name) disabled: \(error)")
            }
        }
    }

    public func resize(_ size: RenderSize) { idle = nil }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {
        layers = []
        uniformsBuffer = nil
        let drawing = drawing(in: f)
        guard case .commandBuffer = e, !drawing.isEmpty, let depthPipeline, let depthWrite, let depthTest,
              let noDepth, let sceneDepth = f.textures[.sceneDepth] else { return }
        let used = drawing.reduce(HalfResLayers()) { $0.union($1.layers) }
        let scale = f.settings.transparency.resolution.scale
        let t = EffectSlots.targetSize(width: f.size.width, height: f.size.height, scale: scale)
        let size = RenderSize(width: t.width, height: t.height)
        func target(_ format: MTLPixelFormat, _ usage: MTLTextureUsage = [.renderTarget, .shaderRead]) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size.width, height: size.height,
                                                             mipmapped: false)
            d.usage = usage
            d.storageMode = .private
            return f.pool.texture(d)
        }
        guard let depths = target(HalfResFormats.sceneDepth), let testDepth = target(HalfResFormats.depth, .renderTarget),
              let idle = idleTargets(size) else { return }
        let ids: [ResourceID] = [.halfResClouds, .halfResTransparent, .oitAccumulation, .oitRevealage, .halfResFronts]
        let usedAt: [Bool] = [used.contains(.clouds), used.contains(.volumes), used.contains(.oit), used.contains(.oit), true]
        var colors: [MTLTexture] = []
        for i in 0..<ids.count {
            guard let c = usedAt[i] ? target(HalfResFormats.color[i]) : idle[i] else { return }
            colors.append(c)
        }

        let reference = EffectTargetFrame(scene: f.scene).distance
        let uniforms = EffectSlotUniforms(size: size, scale: scale, layers: used, settings: f.settings.transparency,
                                          reference: reference)
        guard let u = f.arena.push(value: uniforms) else { return }

        // The scene depth to the test depth and its min/max.
        let dp = MTLRenderPassDescriptor()
        dp.colorAttachments[0].texture = depths
        dp.colorAttachments[0].loadAction = .dontCare
        dp.colorAttachments[0].storeAction = .store
        dp.depthAttachment.texture = testDepth
        dp.depthAttachment.loadAction = .dontCare
        dp.depthAttachment.storeAction = .store
        guard let denc = f.makeRenderEncoder(dp) else { return }
        denc.setRenderPipelineState(depthPipeline)
        denc.setDepthStencilState(depthWrite)
        denc.setFragmentBuffer(u.buffer, offset: u.offset, index: Self.uniformsIndex)
        denc.setFragmentTexture(sceneDepth, index: 0)
        denc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        denc.endEncoding()

        // The effects, on one encoder (one each while timing, so the
        // profiler sees each under its name).
        let slots = HalfResSlots(size: size, scale: scale, uniforms: uniforms, depthTest: depthTest, noDepth: noDepth,
                                 sceneDepth: depths)
        let clears: [MTLClearColor] = [MTLClearColor(), MTLClearColor(), MTLClearColor(),
                                       MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1),
                                       MTLClearColor(red: EffectSlots.noFront, green: EffectSlots.noFront,
                                                     blue: EffectSlots.noFront, alpha: EffectSlots.noFront)]
        let pass = f.currentPass
        defer { f.currentPass = pass }
        let groups = f.splitsEncoders ? drawing.map { [$0] } : [drawing]
        for (g, group) in groups.enumerated() {
            let ep = MTLRenderPassDescriptor()
            for i in 0..<colors.count {
                let c = ep.colorAttachments[i]!
                c.texture = colors[i]
                c.clearColor = clears[i]
                c.loadAction = usedAt[i] ? (g == 0 ? .clear : .load) : .dontCare
                c.storeAction = usedAt[i] ? .store : .dontCare
            }
            ep.depthAttachment.texture = testDepth
            ep.depthAttachment.loadAction = .load
            ep.depthAttachment.storeAction = g + 1 < groups.count ? .store : .dontCare
            if f.splitsEncoders { f.currentPass = group[0].effect.name }
            guard let enc = f.makeRenderEncoder(ep) else { return }
            enc.setVertexBuffer(u.buffer, offset: u.offset, index: Self.uniformsIndex)
            enc.setFragmentBuffer(u.buffer, offset: u.offset, index: Self.uniformsIndex)
            enc.setFragmentTexture(depths, index: Self.sceneDepthIndex)
            for d in group {
                enc.pushDebugGroup(d.effect.name)
                d.effect.encodeHalfRes(f, slots, enc)
                enc.popDebugGroup()
            }
            enc.endEncoding()
        }

        f.textures[.halfResDepth] = depths
        for (i, id) in ids.enumerated() where usedAt[i] { f.textures[id] = colors[i] }
        layers = used
        uniformsBuffer = (u.buffer, u.offset)
    }

    /// EffectSlotsCommon's ORBIT_EFFECT_BUFFER_SLOTS and _TEXTURE_HALFRES_DEPTH.
    public static let uniformsIndex = 27
    public static let sceneDepthIndex = 18

    private func idleTargets(_ size: RenderSize) -> [MTLTexture]? {
        if let idle, idle.size == size { return idle.textures }
        guard let device else { return nil }
        let textures = HalfResFormats.color.compactMap { format -> MTLTexture? in
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size.width, height: size.height,
                                                             mipmapped: false)
            d.usage = .renderTarget
            d.storageMode = .memoryless
            return device.makeTexture(descriptor: d)
        }
        guard textures.count == HalfResFormats.color.count else { return nil }
        idle = (size, textures)
        return textures
    }
}
