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
        if !plan.hasPostStage {
            for p in active where p.stage == .post {
                failures[p.name] = "needs a target plan with a post stage (an HDR scene target)"
                NSLog("OrbitSim: pass \(p.name) disabled: \(failures[p.name]!)")
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
    /// on the command buffer between them.
    func encode(_ f: FrameContext) {
        let active = self.active
        let cb = f.commandBuffer
        for p in active where p.stage == .prepare { p.encode(f, .commandBuffer(cb)) }
        f.uploadShared()

        var encoder: MTLRenderCommandEncoder?
        for stage in PassStage.allCases where stage != .prepare {
            let here = active.filter { $0.stage == stage }
            if !stage.isRenderStage {
                guard !here.isEmpty else { continue }
                encoder?.endEncoding()
                encoder = nil
                for p in here { p.encode(f, .commandBuffer(cb)) }
                continue
            }
            if let descriptor = plan.renderPass(for: stage, f) {
                encoder?.endEncoding()
                encoder = cb.makeRenderCommandEncoder(descriptor: descriptor)
                encoder?.label = "\(stage)"
                if let encoder { f.bindShared(encoder) }
            }
            guard let encoder else { continue }
            for p in here {
                encoder.pushDebugGroup(p.name)
                p.encode(f, .render(encoder))
                encoder.popDebugGroup()
            }
        }
        encoder?.endEncoding()
    }
}
