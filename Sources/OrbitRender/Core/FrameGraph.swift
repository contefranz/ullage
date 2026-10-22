import Foundation
import Metal

/// The frame's passes in slot order (P0-P5, then each pass's `order`),
/// encoded onto the encoders the target plan opens. A pass that fails to
/// set up (its shader module does not compile, or it reads what nothing
/// earlier writes) is disabled alone, with the reason in `failures`.
@MainActor
public final class FrameGraph {
    public private(set) var passes: [RenderPass]
    /// Disabled passes, by name, and why.
    public private(set) var failures: [String: String] = [:]
    public let plan: SceneTargetPlan

    public init(passes: [RenderPass], plan: SceneTargetPlan) {
        // Stable: passes with equal stage and order keep the given order.
        self.passes = passes.enumerated().sorted {
            ($0.element.stage, $0.element.order, $0.offset) < ($1.element.stage, $1.element.order, $1.offset)
        }.map(\.element)
        self.plan = plan
    }

    /// The passes that run: enabled, set up, their reads satisfied.
    public var active: [RenderPass] { passes.filter { $0.isEnabled && failures[$0.name] == nil } }

    /// The pass named `name`, if the graph has it.
    public func pass(named name: String) -> RenderPass? { passes.first { $0.name == name } }

    func setUp(device: MTLDevice, shaders: ShaderLibrary, states: CommonStates) {
        failures = [:]
        for p in passes where p.isEnabled {
            let setup = PassSetup(device: device, shaders: shaders, formats: plan.formats(for: p.stage), states: states)
            do {
                try p.setUp(setup)
            } catch {
                failures[p.name] = "\(error)"
                NSLog("OrbitSim: pipeline creation failed for pass \(p.name): \(error)")
            }
        }
        // Every read must be written by an earlier pass, be persistent, or be
        // the target plan's own.
        var written = plan.provides
        for p in active {
            let missing = p.reads.filter { !written.contains($0) && !$0.isPersistent }
            if missing.isEmpty {
                written.formUnion(p.writes)
            } else {
                failures[p.name] = "reads \(missing.map(\.name).sorted().joined(separator: ", ")), which no earlier pass writes"
                NSLog("OrbitSim: pass \(p.name) disabled: \(failures[p.name]!)")
            }
        }
    }

    func resize(_ size: RenderSize, device: MTLDevice) {
        plan.resize(size, device: device)
        for p in passes { p.resize(size) }
    }

    /// P0 on the command buffer; the shared uniforms; then each render stage
    /// in the encoder the plan opens for it (or the one still open), and P4
    /// on the command buffer between them. With `f.splitsEncoders` (GPU
    /// timings) every render pass gets an encoder of its own. A render-stage
    /// pass that encodes on the command buffer ends the scene's encoder; the
    /// next pass drawing in the scene opens its stage's own render pass if
    /// the plan has one, or resumes the scene.
    func encode(_ f: FrameContext) {
        let running = active.filter { $0.isActive(in: f) }
        f.wanted = Set(running.filter { $0.stage > .opaque }.flatMap(\.reads))
        f.breaksScene = running.contains { $0.stage.isRenderStage && $0.encodesOnCommandBuffer }
        // Where the frame's last break is: the resume after it, from P2 on,
        // is the scene's last encoder when timing does not split them.
        let lastBreak = running.lastIndex { $0.stage.isRenderStage && $0.encodesOnCommandBuffer } ?? -1
        let cb = f.commandBuffer
        for p in running where p.stage == .prepare {
            f.currentPass = p.name
            p.encode(f, .commandBuffer(cb))
        }
        f.uploadShared()

        var encoder: MTLRenderCommandEncoder?
        // The scene's encoder was ended for a render-stage pass on the
        // command buffer (`breaker`): the next pass drawing in the scene
        // resumes it.
        var suspended = false
        var breaker = ""
        func open(_ descriptor: MTLRenderPassDescriptor, _ label: String, continuation: Bool = false) {
            encoder?.endEncoding()
            f.profile?.attach(descriptor, pass: label, continuation: continuation)
            encoder = cb.makeRenderCommandEncoder(descriptor: descriptor)
            encoder?.label = label
            suspended = false
            if let encoder { f.bindShared(encoder) }
        }
        // While timing: one empty continuation of the scene, whose time is
        // what each split costs (loading and storing the targets); the
        // profile takes it off each render pass. Taken before anything
        // ends the scene's encoders (a P4 pass, the frame's end).
        var overheadMeasured = false
        func measureSplitOverhead() {
            guard f.splitsEncoders, !overheadMeasured, encoder != nil, let next = plan.continuation(f) else { return }
            open(next, FrameProfile.splitOverhead, continuation: true)
            overheadMeasured = true
        }
        // A scene left suspended by a break, at a stage on the command buffer
        // or the frame's end, resumes once more, empty, to resolve.
        func finishScene() {
            guard suspended, !f.splitsEncoders else { return }
            f.resumesLast = true
            if let next = plan.continuation(f) { open(next, "resolve") }
            f.resumesLast = false
        }
        for stage in PassStage.allCases where stage != .prepare {
            let here = running.filter { $0.stage == stage }
            if !stage.isRenderStage {
                guard !here.isEmpty else { continue }
                finishScene()
                measureSplitOverhead()
                encoder?.endEncoding()
                encoder = nil
                suspended = false
                for p in here {
                    f.currentPass = p.name
                    p.encode(f, .commandBuffer(cb))
                }
                continue
            }
            // The stage's own render pass, opened before its first pass that
            // draws in the scene: at once, unless timing splits the encoders
            // or the stage starts with a pass on the command buffer.
            var fresh = plan.renderPass(for: stage, f)
            if here.isEmpty || !f.splitsEncoders && !here[0].encodesOnCommandBuffer, let pass = fresh {
                open(pass, "\(stage)")
                fresh = nil
            }
            for p in here {
                if p.encodesOnCommandBuffer {
                    measureSplitOverhead()
                    if encoder != nil {
                        suspended = true
                        breaker = p.name
                    }
                    encoder?.endEncoding()
                    encoder = nil
                    f.currentPass = p.name
                    p.encode(f, .commandBuffer(cb))
                    continue
                }
                // Each pass in an encoder of its own while timing, so the
                // profiler can time it: the stage's own render pass first,
                // then the plan's continuation of the scene. Without timing,
                // the scene resumes only after a pass on the command buffer.
                if let pass = fresh {
                    open(pass, f.splitsEncoders ? p.name : "\(stage)")
                    fresh = nil
                } else if encoder == nil, suspended {
                    // The resume loads and stores the targets in the plain
                    // frame too: while timing, an empty encoder measures it
                    // for the pass that broke the scene, kept whole, before
                    // this pass's continuation.
                    if f.splitsEncoders, let resume = plan.continuation(f) { open(resume, breaker) }
                    let index = running.firstIndex { $0 === p } ?? 0
                    f.resumesLast = !f.splitsEncoders && stage > .opaque && index > lastBreak
                    if let next = plan.continuation(f) {
                        open(next, f.splitsEncoders ? p.name : "\(stage)", continuation: f.splitsEncoders)
                    }
                    f.resumesLast = false
                } else if f.splitsEncoders, encoder != nil, let next = plan.continuation(f) {
                    open(next, p.name, continuation: true)
                }
                guard let encoder else { continue }
                f.currentPass = p.name
                encoder.pushDebugGroup(p.name)
                p.encode(f, .render(encoder))
                encoder.popDebugGroup()
            }
            // A stage of passes on the command buffer only still opens its
            // render pass, for its load and clear actions.
            if let pass = fresh { open(pass, "\(stage)") }
        }
        finishScene()
        measureSplitOverhead()
        encoder?.endEncoding()
        f.currentPass = nil
    }
}
