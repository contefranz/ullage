import Foundation
import OrbitCore

/// What the renderer tessellates for a vessel: its parts' shapes in the
/// construction frame (metres; `part.offset - vessel.structureOrigin`), with
/// the thrusters the shapes link to, and the nozzle exits plumes start at.
/// Captured when the part list or a part's shape count changes
/// (`Signature`), as the renderer's mesh cache is.
public struct VesselGeometry {
    public struct Signature: Equatable {
        public let parts: [ObjectSerial]
        public let shapes: [Int]
    }

    public struct Part {
        /// The part's `VesselPart.serial`.
        public let id: ObjectSerial
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
    /// plume starts. From the nozzle shape linked to it, else the port
    /// (`VisualAttachment`) it fires through.
    public struct Nozzle {
        public let exit: Vec3
        public let radius: Double
        public let pivot: Vec3
        /// The drawn exhaust direction (unit, construction frame, gimbal at
        /// null): out of the nozzle shape's exit, or the port's.
        public let exhaust: Vec3

        public init(exit: Vec3, radius: Double, pivot: Vec3, exhaust: Vec3) {
            self.exit = exit
            self.radius = radius
            self.pivot = pivot
            self.exhaust = exhaust
        }
    }

    public let signature: Signature
    public let parts: [Part]
    public let nozzles: [RenderScene.ThrusterKey: Nozzle]

    public static func signature(of vessel: OrbitCore.Vessel) -> Signature {
        Signature(parts: vessel.parts.map(\.serial), shapes: vessel.parts.map(\.shapes.count))
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
                    nozzles[t.serial] = Nozzle(exit: exit.centre + offset, radius: exit.radius,
                                               pivot: t.position + offset, exhaust: Self.exhaust(of: shape))
                }
                if thruster == nil { unlinked.append(shape) }
            }
            // A thruster with no nozzle drawn but a port (the S-IC retros'
            // breaches in their fairings, the S-II ullage motors' exits):
            // its plume starts at the port, which the dresser draws, not at
            // the physics' thrust point inside the fairing. A port of
            // unknown size takes the exhaust library's exit.
            for t in part.thrusters where nozzles[t.serial] == nil {
                guard let port = part.attachments.first(where: { a in
                    a.thruster == t.name && (a.kind == .retroPort || a.kind == .ullageExit)
                }) else { continue }
                // The exhaust library's exit where it knows the motor (the
                // S-IC retros' ports are their cases' breaches, wider than
                // the nozzle), else the port's.
                let radius = ApolloExhaust.engine(for: t, in: part)?.spec.exitRadius
                    ?? (port.radius > 0 ? port.radius
                        : PlumeStyle.nominalExitRadius(thrust: t.currentRating.thrustVacuum, solid: t.isSolid))
                nozzles[t.serial] = Nozzle(exit: port.position + offset, radius: radius,
                                           pivot: t.position + offset, exhaust: port.direction)
            }
            // Vessels dressed without links (the M0 test vehicles): a cone
            // narrowing towards a thruster's position along its direction is
            // taken as its nozzle.
            for t in part.thrusters where nozzles[t.serial] == nil {
                if let shape = unlinked.first(where: { Self.looksLikeNozzle($0, of: t) }), let exit = Self.exit(of: shape) {
                    nozzles[t.serial] = Nozzle(exit: exit.centre + offset, radius: exit.radius,
                                               pivot: t.position + offset, exhaust: Self.exhaust(of: shape))
                }
            }
            parts.append(Part(id: part.serial, name: part.name, appearance: part.appearance, offset: offset,
                              shapes: part.shapes,
                              thrusters: part.thrusters.map {
                                  ThrusterMount(key: $0.serial, name: $0.name, position: $0.position,
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

    /// The way a nozzle shape exhausts: from its narrowest point (the
    /// throat, or a frustum's top) towards its exit.
    public static func exhaust(of shape: VisualShape) -> Vec3 {
        let axis = shape.axis.normalized
        if case let .revolution(profile, _, _) = shape.kind, let first = profile.first,
           let throat = profile.min(by: { $0.r < $1.r }), throat.x != first.x {
            return first.x > throat.x ? axis : -axis
        }
        if case let .frustum(base, top) = shape.kind, base < top { return axis }
        return -axis
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
