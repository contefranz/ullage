import Foundation
import OrbitCore

/// Where the deployed canopies hang. Visual only: the riser length and the
/// spread are guesses, and the dome is a generic inflated one, not the
/// ringsail's or the ribbon's.
public enum CanopyGeometry {
    /// Height of the inflated dome over its nominal diameter; the renderer's
    /// unit dome has its skirt at x = 0 and its vent at x = `depth`.
    public static let depth = 0.42

    /// The deployed canopies of `v` (at camera-relative `rel`), each along
    /// the air flow from its cluster's riser confluence (straight up without
    /// air speed), spread apart for a cluster, sized by its inflation
    /// (diameter as the square root of the drag-area share, deeper while
    /// reefed), with eight risers each.
    public static func canopies(of v: Vessel, at rel: Vec3, snapshot: SystemSnapshot) -> [RenderScene.Canopy] {
        let chutes = v.parts.flatMap { part in part.parachutes.map { (part, $0) } }
            .filter { $0.1.isDeployed && $0.1.currentDragArea > 0 }
        guard !chutes.isEmpty else { return [] }
        let air = v.surfaceVelocity(snapshot: snapshot)
        let up = v.reference.vertical(at: v.position, orientation: snapshot.orientation(v.reference))
        let trail = air.length > 1 ? -air.normalized : up
        let u0 = VisualShape.defaultReference(for: trail), w0 = trail.cross(u0)
        var out: [RenderScene.Canopy] = []
        for (part, chute) in chutes {
            let main = chute.diameter > 10
            let efficiency = chute.clusterEfficiency[chute.count] ?? 1
            let share = chute.currentDragArea / (Double(chute.count) * efficiency * chute.dragArea)
            let open = max(0.12, min(1, share).squareRoot())
            let radius = 0.5 * 0.72 * chute.diameter * open    // an inflated canopy spans ~0.72 of its nominal diameter
            let height = 2 * radius * depth * (1 + 0.8 * (1 - open))
            let riser = chute.diameter * (main ? 1.15 : 2.0)
            let confluence = rel + v.attitude.rotate(part.offset + chute.attachPoint)
            let spread = chute.count > 1 ? (main ? 0.32 : 0.2) * (0.6 + 0.4 * open) : 0
            for k in 0..<chute.count {
                let az = 2 * Double.pi * Double(k) / Double(chute.count) + 0.4
                let lean = u0 * cos(az) + w0 * sin(az)
                let axis = (trail * cos(spread) + lean * sin(spread)).normalized
                let side = VisualShape.defaultReference(for: axis), other = axis.cross(side)
                let skirt = confluence + axis * riser
                let sx = height / depth, sr = 2 * radius
                var risers: [(Vec3, Vec3)] = []
                for i in 0..<8 {
                    let a = 2 * Double.pi * Double(i) / 8
                    risers.append((confluence, skirt + (side * cos(a) + other * sin(a)) * radius))
                }
                out.append(RenderScene.Canopy(vesselID: v.id, isMain: main, axis: axis, side: side, other: other,
                                              skirt: skirt, sx: sx, sr: sr, risers: risers))
            }
        }
        return out
    }
}
