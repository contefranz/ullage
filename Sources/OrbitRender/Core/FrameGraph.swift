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
    /// timings) every render pass gets an encoder of its own.
    func encode(_ f: FrameContext) {
        let running = active.filter { $0.isActive(in: f) }
        f.wanted = Set(running.filter { $0.stage > .opaque }.flatMap(\.reads))
        let cb = f.commandBuffer
        for p in running where p.stage == .prepare {
            f.currentPass = p.name
            p.encode(f, .commandBuffer(cb))
        }
        f.uploadShared()

        var encoder: MTLRenderCommandEncoder?
        func open(_ descriptor: MTLRenderPassDescriptor, _ label: String, continuation: Bool = false) {
            encoder?.endEncoding()
            f.profile?.attach(descriptor, pass: label, continuation: continuation)
            encoder = cb.makeRenderCommandEncoder(descriptor: descriptor)
            encoder?.label = label
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
        for stage in PassStage.allCases where stage != .prepare {
            let here = running.filter { $0.stage == stage }
            if !stage.isRenderStage {
                guard !here.isEmpty else { continue }
                measureSplitOverhead()
                encoder?.endEncoding()
                encoder = nil
                for p in here {
                    f.currentPass = p.name
                    p.encode(f, .commandBuffer(cb))
                }
                continue
            }
            let fresh = plan.renderPass(for: stage, f)
            if !f.splitsEncoders || here.isEmpty {
                if let fresh { open(fresh, "\(stage)") }
            }
            for (i, p) in here.enumerated() {
                if f.splitsEncoders {
                    // Each pass in an encoder of its own, so the profiler
                    // can time it: the stage's own render pass first, then
                    // the plan's continuation of the scene.
                    if i == 0, let fresh {
                        open(fresh, p.name)
                    } else if encoder != nil, let next = plan.continuation(f) {
                        open(next, p.name, continuation: true)
                    }
                }
                guard let encoder else { break }
                f.currentPass = p.name
                encoder.pushDebugGroup(p.name)
                p.encode(f, .render(encoder))
                encoder.popDebugGroup()
            }
        }
        measureSplitOverhead()
        encoder?.endEncoding()
        f.currentPass = nil
    }
}
