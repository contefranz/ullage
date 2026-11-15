import Foundation
import OrbitCore
import OrbitScene

/// The effect director (P3): each frame it runs the effect session
/// (OrbitScene's `EffectSession`: the clocks, resets, the journal's new
/// events and every producer's emitters) on the scene, and hands the result
/// to the GPU particles. The effect tracks list their producers in
/// `defaultProducers`.
@MainActor
public final class EffectDirector {
    public let session: EffectSession
    /// The latest frame's output.
    public private(set) var last: EffectFrameOutput?
    /// Every frame's counts, for the warp matrix's log: requests, particles
    /// asked for, requests dropped, anchors alive.
    public private(set) var totals = Totals()

    public struct Totals: Equatable {
        public var frames = 0
        public var requests = 0
        public var particles = 0
        public var dropped = 0
        public var resets = 0
        public var mostAnchors = 0
    }

    /// The effect tracks' producers, in order: P4's launch effects, P5's
    /// staging and spacecraft effects, P6's entry and recovery effects. Each
    /// track adds its own line here.
    public nonisolated static func defaultProducers() -> [EffectProducer] {
        [LaunchEffects()]
    }

    /// The director with `producers`, or the default ones.
    public init(producers: [EffectProducer]? = nil) {
        session = EffectSession(producers: producers ?? Self.defaultProducers())
    }

    /// Runs the session on `scene`.
    public func frame(_ scene: RenderScene, settings: ParticleSettings) -> EffectFrameOutput {
        let out = session.frame(scene, settings: settings)
        last = out
        totals.frames += 1
        totals.requests += out.requests.count
        totals.particles += out.requests.reduce(0) { $0 + $1.count }
        totals.dropped += out.dropped
        if out.resets { totals.resets += 1 }
        totals.mostAnchors = max(totals.mostAnchors, out.anchors.count)
        return out
    }
}
