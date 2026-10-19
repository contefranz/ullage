import Foundation

/// A cluster of identical parachutes packed in a part (`VesselPart.parachutes`).
/// It only carries its description and state for now: no loads act on the
/// vessel, and nothing deploys it.
public final class Parachute {
    public enum State: Equatable {
        case stowed
        /// Inflating, before the first reefing stage.
        case deploying
        /// In reefing stage `n` (1 is the first).
        case reefed(Int)
        case open
        /// Cut away from the vessel.
        case released
    }

    public let name: String
    /// Canopies in the cluster.
    public var count: Int
    /// Nominal diameter of one canopy, m.
    public var diameter: Double
    /// Drag area C_D S of one fully open canopy, m^2.
    public var dragArea: Double
    /// Where the risers meet (the confluence), part frame, m.
    public var attachPoint: Vec3
    public var state = State.stowed

    public init(name: String, count: Int, diameter: Double, dragArea: Double, attachPoint: Vec3) {
        self.name = name
        self.count = count
        self.diameter = diameter
        self.dragArea = dragArea
        self.attachPoint = attachPoint
    }
}
