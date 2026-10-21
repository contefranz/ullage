import Foundation
import OrbitCore

/// An event the core recorded, with the state the effects need: its exact
/// epoch, so a burst can be spawned at its true age at any warp. The core's
/// EffectJournal (track K0) is the source; `SceneEventSource` adapts it.
public struct SceneEvent {
    public enum Kind: Equatable {
        case liftoff
        /// Staging or a jettison: the event number and the parts that left.
        case separation(event: Int?, parts: [String])
        case ignition(thruster: String)
        case cutoff(thruster: String)
        case chuteDeployed(name: String)
        /// Speed at contact, m/s.
        case splashdown(speed: Double)
        case breakup
        /// A record this version does not know.
        case other(String)
    }

    public var kind: Kind
    public var epoch: Epoch
    public var vesselID: UUID?
    public var referenceBodyID: Int?
    /// Relative to the reference body's centre, ICRF, m and m/s.
    public var position: Vec3?
    public var velocity: Vec3?
    /// A unit axis the event has (a thruster's exhaust, a separation plane's normal).
    public var axis: Vec3?

    public init(kind: Kind, epoch: Epoch, vesselID: UUID? = nil, referenceBodyID: Int? = nil, position: Vec3? = nil,
                velocity: Vec3? = nil, axis: Vec3? = nil) {
        self.kind = kind
        self.epoch = epoch
        self.vesselID = vesselID
        self.referenceBodyID = referenceBodyID
        self.position = position
        self.velocity = velocity
        self.axis = axis
    }
}

/// Where `SceneExtractor` drains events from: the core's journal, through
/// an adapter in OrbitScene once it exists.
public protocol SceneEventSource: AnyObject {
    /// The events recorded after `cursor`, oldest first, and the cursor to
    /// pass next time (0 reads everything still held).
    func sceneEvents(after cursor: UInt64) -> (events: [SceneEvent], cursor: UInt64)
}

extension RenderScene {
    /// What changed since the previous scene.
    public enum Transition {
        /// A vessel that was not there before: staging, separation or a
        /// jettison. `parentID` is the vessel it most likely left (the
        /// nearest one that was there before), and the velocity is relative
        /// to it.
        case vesselAppeared(id: UUID, name: String, parts: [String], parentID: UUID?, position: Vec3,
                            relativeVelocity: Vec3)
        case vesselRemoved(id: UUID, name: String)
        /// An event from the core's journal.
        case event(SceneEvent)
    }
}
