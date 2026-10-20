import Foundation
import Metal
import OrbitCore

/// Triangle list for a vessel built from its parts' shapes, in the vessel's
/// construction frame (metres; `part.offset - vessel.structureOrigin`).
/// Rebuilt whenever the vessel's part list or a part's shape count changes.
///
/// Every kind goes through the core's lathe (`VisualShape.triangles`), so the
/// caps are the ones the shape asks for and the winding is counter-clockwise
/// seen from outside. The vertices come in groups: closed shapes, drawn with
/// back faces culled; open (`twoSided`) ones, drawn from both sides; and one
/// group per shape linked to a gimballed thruster, which the renderer turns
/// each frame about the thruster's position.
struct VesselMesh {
    struct Group {
        let range: Range<Int>
        /// Back faces culled (a closed shape).
        let culled: Bool
        /// The gimballed thruster that turns the group; nil for the static ones.
        let thruster: Thruster?
        /// The thruster's position, construction frame.
        let pivot: Vec3
    }

    /// A thruster's nozzle exit, construction frame, gimbal at null: where its
    /// plume starts.
    struct Nozzle {
        let exit: Vec3
        let radius: Double
        let pivot: Vec3
    }

    struct Signature: Equatable {
        let parts: [ObjectIdentifier]
        let shapes: [Int]
    }

    let buffer: MTLBuffer
    let groups: [Group]
    let nozzles: [ObjectIdentifier: Nozzle]
    let signature: Signature

    static func signature(of vessel: Vessel) -> Signature {
        Signature(parts: vessel.parts.map { ObjectIdentifier($0) }, shapes: vessel.parts.map(\.shapes.count))
    }

    static func build(for vessel: Vessel, device: MTLDevice) -> VesselMesh? {
        var closed: [MeshVertex] = [], open: [MeshVertex] = []
        var dynamic: [(verts: [MeshVertex], culled: Bool, thruster: Thruster, pivot: Vec3)] = []
        var nozzles: [ObjectIdentifier: Nozzle] = [:]
        for part in vessel.parts {
            let offset = part.offset - vessel.structureOrigin
            var unlinked: [VisualShape] = []
            for shape in part.shapes {
                let verts = vertices(shape, offset: offset)
                let thruster = shape.thruster.flatMap { name in part.thrusters.first { $0.name == name } }
                if let t = thruster, let exit = exit(of: shape) {
                    nozzles[ObjectIdentifier(t)] = Nozzle(exit: exit.centre + offset, radius: exit.radius,
                                                          pivot: t.position + offset)
                }
                if let t = thruster, !t.gimbal.isEmpty {
                    dynamic.append((verts, !shape.twoSided, t, t.position + offset))
                } else if shape.twoSided {
                    open += verts
                } else {
                    closed += verts
                }
                if thruster == nil { unlinked.append(shape) }
            }
            // Vessels dressed without links (the M0 test vehicles): a cone
            // narrowing towards a thruster's position along its direction is
            // taken as its nozzle.
            for t in part.thrusters where nozzles[ObjectIdentifier(t)] == nil {
                if let shape = unlinked.first(where: { looksLikeNozzle($0, of: t) }), let exit = exit(of: shape) {
                    nozzles[ObjectIdentifier(t)] = Nozzle(exit: exit.centre + offset, radius: exit.radius,
                                                          pivot: t.position + offset)
                }
            }
        }

        var all = closed + open
        var groups: [Group] = []
        if !closed.isEmpty { groups.append(Group(range: 0..<closed.count, culled: true, thruster: nil, pivot: .zero)) }
        if !open.isEmpty {
            groups.append(Group(range: closed.count..<all.count, culled: false, thruster: nil, pivot: .zero))
        }
        for d in dynamic where !d.verts.isEmpty {
            groups.append(Group(range: all.count..<(all.count + d.verts.count), culled: d.culled,
                                thruster: d.thruster, pivot: d.pivot))
            all += d.verts
        }
        guard !all.isEmpty,
              let buffer = device.makeBuffer(bytes: all, length: all.count * MemoryLayout<MeshVertex>.stride,
                                             options: .storageModeShared) else { return nil }
        return VesselMesh(buffer: buffer, groups: groups, nozzles: nozzles, signature: signature(of: vessel))
    }

    static func vertices(_ shape: VisualShape, offset: Vec3) -> [MeshVertex] {
        let color = SIMD4<Float>(Float(shape.color.0), Float(shape.color.1), Float(shape.color.2),
                                 Float(shape.emissive.rawValue))
        return shape.triangles(offset: offset).map {
            MeshVertex(position: SIMD4($0.position, 1), normal: SIMD4($0.normal, 0), color: color)
        }
    }

    /// The exit of a nozzle shape, part frame: a profile's first point (a
    /// bell runs from its exit to the injector), a frustum's base.
    static func exit(of shape: VisualShape) -> (centre: Vec3, radius: Double)? {
        switch shape.kind {
        case let .revolution(profile, _, _):
            guard let first = profile.first else { return nil }
            return (shape.origin + shape.axis * first.x, first.r)
        case let .frustum(baseRadius, _):
            return (shape.origin, baseRadius)
        case .sphere:
            return nil
        }
    }

    static func looksLikeNozzle(_ shape: VisualShape, of t: Thruster) -> Bool {
        guard case let .frustum(base, top) = shape.kind, base > top, shape.axis.dot(t.direction) > 0.98 else {
            return false
        }
        return (shape.origin + shape.axis * shape.length - t.position).length < 0.6
    }
}

/// The parachute canopies: one open, two-sided dome per kind, of unit
/// diameter with its skirt at x = 0 and its vent towards +x, in coloured
/// gores; the renderer scales and places it per canopy. Visual only: the
/// profile is a generic inflated dome, not the ringsail's or the ribbon's.
struct CanopyMesh {
    let buffer: MTLBuffer
    let vertexCount: Int

    /// Height of the inflated dome over its nominal diameter.
    static let depth = 0.42

    /// `gores` sectors alternating between `colours`.
    static func build(device: MTLDevice, gores: Int, colours: [(Double, Double, Double)]) -> CanopyMesh? {
        typealias P = VisualShape.ProfilePoint
        // Skirt to vent: a flattened dome, open at both ends.
        let profile = [P(0, 0.5), P(0.12, 0.49), P(0.22, 0.46), P(0.31, 0.4), P(0.37, 0.32), P(0.41, 0.2),
                       P(0.42, 0.06)].map { P($0.x * depth / 0.42, $0.r) }
        let width = 2 * Double.pi / Double(gores)
        var verts: [MeshVertex] = []
        for g in 0..<gores {
            var s = VisualShape.revolution(profile, from: .zero, axis: .unitX, segments: 4 * gores,
                                           sweep: Double(g) * width...Double(g + 1) * width,
                                           color: colours[g % colours.count])
            s.capBase = false
            s.capTop = false
            s.twoSided = true
            verts += VesselMesh.vertices(s, offset: .zero)
        }
        guard let buffer = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<MeshVertex>.stride,
                                             options: .storageModeShared) else { return nil }
        return CanopyMesh(buffer: buffer, vertexCount: verts.count)
    }
}
