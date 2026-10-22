import Foundation
import OrbitCore

/// What the renderer tessellates for a vessel: its parts' shapes in the
/// construction frame (metres; `part.offset - vessel.structureOrigin`), with
/// the thrusters the shapes link to, and the nozzle exits plumes start at.
/// Captured when the part list or a part's shape count changes
/// (`Signature`), as the renderer's mesh cache is.
public struct VesselGeometry {
    public struct Signature: Equatable {
        public let parts: [ObjectIdentifier]
        public let shapes: [Int]
    }

    public struct Part {
        public let id: ObjectIdentifier
        /// The part's name and its Apollo variant (nil for a part with
        /// none), which its paint depends on.
        public let name: String
        public let appearance: ApolloVariant?
        /// The part's origin in the construction frame, m.
        public let offset: Vec3
        public let shapes: [VisualShape]
        public let thrusters: [ThrusterMount]
    }

    /// A thruster as mounted (gimbal at null), part frame.
    public struct ThrusterMount {
        public let key: RenderScene.ThrusterKey
        public let name: String
        public let position: Vec3
        public let direction: Vec3
        public let isGimballed: Bool
    }

    /// A thruster's nozzle exit, construction frame, gimbal at null: where its
    /// plume starts.
    public struct Nozzle {
        public let exit: Vec3
        public let radius: Double
        public let pivot: Vec3
    }

    public let signature: Signature
    public let parts: [Part]
    public let nozzles: [RenderScene.ThrusterKey: Nozzle]

    public static func signature(of vessel: OrbitCore.Vessel) -> Signature {
        Signature(parts: vessel.parts.map { ObjectIdentifier($0) }, shapes: vessel.parts.map(\.shapes.count))
    }

    public init(of vessel: OrbitCore.Vessel) {
        var parts: [Part] = []
        var nozzles: [RenderScene.ThrusterKey: Nozzle] = [:]
        for part in vessel.parts {
            let offset = part.offset - vessel.structureOrigin
            var unlinked: [VisualShape] = []
            for shape in part.shapes {
                let thruster = shape.thruster.flatMap { name in part.thrusters.first { $0.name == name } }
                if let t = thruster, let exit = Self.exit(of: shape) {
                    nozzles[ObjectIdentifier(t)] = Nozzle(exit: exit.centre + offset, radius: exit.radius,
                                                          pivot: t.position + offset)
                }
                if thruster == nil { unlinked.append(shape) }
            }
            // Vessels dressed without links (the M0 test vehicles): a cone
            // narrowing towards a thruster's position along its direction is
            // taken as its nozzle.
            for t in part.thrusters where nozzles[ObjectIdentifier(t)] == nil {
                if let shape = unlinked.first(where: { Self.looksLikeNozzle($0, of: t) }), let exit = Self.exit(of: shape) {
                    nozzles[ObjectIdentifier(t)] = Nozzle(exit: exit.centre + offset, radius: exit.radius,
                                                          pivot: t.position + offset)
                }
            }
            parts.append(Part(id: ObjectIdentifier(part), name: part.name, appearance: part.appearance, offset: offset,
                              shapes: part.shapes,
                              thrusters: part.thrusters.map {
                                  ThrusterMount(key: ObjectIdentifier($0), name: $0.name, position: $0.position,
                                                direction: $0.direction, isGimballed: !$0.gimbal.isEmpty)
                              }))
        }
        self.signature = Self.signature(of: vessel)
        self.parts = parts
        self.nozzles = nozzles
    }

    /// The exit of a nozzle shape, part frame: a profile's first point (a
    /// bell runs from its exit to the injector), a frustum's base.
    public static func exit(of shape: VisualShape) -> (centre: Vec3, radius: Double)? {
        if case let .revolution(profile, _, _) = shape.kind {
            guard let first = profile.first else { return nil }
            return (shape.origin + shape.axis * first.x, first.r)
        }
        if case let .frustum(baseRadius, _) = shape.kind {
            return (shape.origin, baseRadius)
        }
        return nil
    }

    static func looksLikeNozzle(_ shape: VisualShape, of t: Thruster) -> Bool {
        guard case let .frustum(base, top) = shape.kind, base > top, shape.axis.dot(t.direction) > 0.98 else {
            return false
        }
        return (shape.origin + shape.axis * shape.length - t.position).length < 0.6
    }
}

extension Mat3 {
    /// The shortest rotation taking unit vector `a` to unit vector `b`
    /// (identity when they agree; a half turn about any normal when opposite).
    public static func rotation(from a: Vec3, to b: Vec3) -> Mat3 {
        let c = max(-1, min(1, a.dot(b))), axis = a.cross(b), s = axis.length
        if s < 1e-12 {
            if c > 0 { return .identity }
            let n = VisualShape.defaultReference(for: a)
            return Quat(axis: n, angle: Double.pi).matrix
        }
        return Quat(axis: axis / s, angle: atan2(s, c)).matrix
    }
}
