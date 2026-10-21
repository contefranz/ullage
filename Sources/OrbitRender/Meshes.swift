import Foundation
import Metal
import OrbitCore
import OrbitScene

/// Triangle list for a vessel built from its parts' shapes, in the vessel's
/// construction frame (metres; `part.offset - vessel.structureOrigin`), from
/// the scene's `VesselGeometry`. Rebuilt whenever the vessel's part list or a
/// part's shape count changes.
///
/// Every kind goes through the core's lathe (`VisualShape.triangles`), so the
/// caps are the ones the shape asks for and the winding is counter-clockwise
/// seen from outside. The vertices come in groups: closed shapes, drawn with
/// back faces culled; open (`twoSided`) ones, drawn from both sides; and one
/// group per shape linked to a gimballed thruster, which the vessel pass
/// turns each frame about the thruster's position.
public struct VesselMesh {
    public struct Group {
        public let range: Range<Int>
        /// Back faces culled (a closed shape).
        public let culled: Bool
        /// The gimballed thruster that turns the group; nil for the static ones.
        public let thruster: RenderScene.ThrusterKey?
        /// The thruster's position, construction frame.
        public let pivot: Vec3
    }

    public let buffer: MTLBuffer
    public let groups: [Group]
    public let signature: VesselGeometry.Signature

    public static func build(_ geometry: VesselGeometry, device: MTLDevice) -> VesselMesh? {
        var closed: [MeshVertex] = [], open: [MeshVertex] = []
        var dynamic: [(verts: [MeshVertex], culled: Bool, thruster: RenderScene.ThrusterKey, pivot: Vec3)] = []
        for part in geometry.parts {
            for shape in part.shapes {
                let verts = vertices(shape, offset: part.offset)
                let mount = shape.thruster.flatMap { name in part.thrusters.first { $0.name == name } }
                if let t = mount, t.isGimballed {
                    dynamic.append((verts, !shape.twoSided, t.key, t.position + part.offset))
                } else if shape.twoSided {
                    open += verts
                } else {
                    closed += verts
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
        return VesselMesh(buffer: buffer, groups: groups, signature: geometry.signature)
    }

    static func vertices(_ shape: VisualShape, offset: Vec3) -> [MeshVertex] {
        let color = SIMD4<Float>(Float(shape.color.0), Float(shape.color.1), Float(shape.color.2),
                                 Float(shape.emissive.rawValue))
        return shape.triangles(offset: offset).map {
            MeshVertex(position: SIMD4($0.position, 1), normal: SIMD4($0.normal, 0), color: color)
        }
    }
}

/// The vessels' meshes, kept while their geometry's signature holds.
@MainActor
public final class VesselMeshCache {
    private var meshes: [UUID: VesselMesh] = [:]

    public func mesh(_ id: UUID) -> VesselMesh? { meshes[id] }

    /// Builds the meshes of new or changed vessels and drops those of
    /// vessels gone.
    func update(_ scene: RenderScene, device: MTLDevice) {
        var live = Set<UUID>()
        for v in scene.vessels {
            live.insert(v.id)
            if meshes[v.id]?.signature != v.geometry.signature {
                meshes[v.id] = VesselMesh.build(v.geometry, device: device)
            }
        }
        if meshes.keys.contains(where: { !live.contains($0) }) { meshes = meshes.filter { live.contains($0.key) } }
    }
}

/// The parachute canopies: one open, two-sided dome per kind, of unit
/// diameter with its skirt at x = 0 and its vent towards +x
/// (`CanopyGeometry.depth`), in coloured gores; the vessel pass scales and
/// places it per canopy. Visual only: the profile is a generic inflated
/// dome, not the ringsail's or the ribbon's.
struct CanopyMesh {
    let buffer: MTLBuffer
    let vertexCount: Int

    /// `gores` sectors alternating between `colours`.
    static func build(device: MTLDevice, gores: Int, colours: [(Double, Double, Double)]) -> CanopyMesh? {
        typealias P = VisualShape.ProfilePoint
        let depth = CanopyGeometry.depth
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
