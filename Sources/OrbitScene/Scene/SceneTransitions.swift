import Foundation
import OrbitCore

extension RenderScene {
    /// What changed since the previous scene.
    public enum Transition {
        /// An event the core's journal recorded (`EffectEvent`: liftoff,
        /// separations, ignitions and cutoffs, parachutes, splashdown,
        /// breakup), with its exact epoch and the vessel's state then, so an
        /// effect can start at its true age at any warp.
        case event(EffectEvent)
        /// A vessel that was not there before: staging, separation or a
        /// jettison, found by comparing with the previous scene (the
        /// journal's separation record says the same with its epoch).
        /// `parentID` is the nearest vessel that was there before, and the
        /// velocity is relative to it.
        case vesselAppeared(id: UUID, name: String, parts: [String], parentID: UUID?, position: Vec3,
                            relativeVelocity: Vec3)
        case vesselRemoved(id: UUID, name: String)
    }
}
