import Foundation
import OrbitCore

/// What the camera orbits around.
enum CameraTarget: Equatable {
    case vessel(UUID)
    case body(Int)
}

/// External "orbit" camera. All positions are barycentric doubles; the
/// renderer subtracts `position` from everything before converting to float.
struct OrbitCamera {
    enum Frame: String { case horizon = "Horizon", vessel = "Vessel", inertial = "Inertial" }

    var target: CameraTarget = .body(399)
    var frame: Frame = .horizon
    var yaw = -2.4          // rad, around the frame's up axis
    var pitch = 0.25        // rad, elevation
    var distance = 60.0     // m
    var fovY = 50.0 * Double.pi / 180

    // Outputs of `update`.
    private(set) var position = Vec3.zero        // barycentric
    private(set) var targetPosition = Vec3.zero  // barycentric
    /// Rows: camera right, up, back (world -> view rotation).
    private(set) var worldToView = Mat3.identity
    private(set) var targetName = ""

    mutating func orbit(dx: Double, dy: Double) {
        yaw -= dx * 0.006
        pitch = min(max(pitch + dy * 0.006, -1.55), 1.55)
    }

    mutating func zoom(_ amount: Double, minimum: Double) {
        distance = max(minimum, distance * exp(-amount * 0.04))
    }

    /// Recompute the camera pose for the current simulation state.
    mutating func update(sim: Simulation) {
        let snap = sim.snapshot
        var up = Vec3.unitZ, forward = Vec3.unitX
        var minDistance = 1.0

        switch target {
        case .vessel(let id):
            guard let v = sim.vessels.first(where: { $0.id == id }) ?? sim.focus else { return }
            targetPosition = snap.position(v.reference) + v.position
            targetName = v.name
            minDistance = v.boundingRadius * 1.2
            switch frame {
            case .horizon:
                up = v.position.normalized
                let pole = snap.orientation(v.reference).pole
                var north = pole - up * pole.dot(up)
                if north.length < 1e-6 { north = Vec3.unitX - up * up.x }
                forward = north.normalized
            case .vessel:
                up = v.attitude.rotate(Vec3(0, 0, -1))
                forward = v.attitude.rotate(.unitX)
            case .inertial:
                break
            }
        case .body(let bodyID):
            guard let b = sim.system.body(id: bodyID) else { return }
            targetPosition = snap.position(b)
            targetName = b.name
            minDistance = b.radius * 1.05
            if frame != .inertial {
                up = snap.orientation(b).pole
                forward = (Vec3.unitX - up * up.x).normalized
            }
        }
        distance = max(distance, minDistance)

        let right = forward.cross(up).normalized       // horizontal basis
        let fwd = up.cross(right)
        let horizontal = fwd * cos(yaw) + right * sin(yaw)
        let offset = (horizontal * cos(pitch) + up * sin(pitch)) * distance
        position = targetPosition + offset

        // Keep the camera above the ground near a surface.
        if case .vessel(let id) = target, let v = sim.vessels.first(where: { $0.id == id }) {
            let center = snap.position(v.reference)
            let fromCenter = position - center
            let minRadius = v.reference.radius + 2
            if fromCenter.length < minRadius {
                position = center + fromCenter.normalized * minRadius
            }
        }

        // Look at the target with `up` as the vertical reference.
        let back = (position - targetPosition).normalized
        var camRight = up.cross(back)
        if camRight.length < 1e-6 { camRight = right }
        camRight = camRight.normalized
        let camUp = back.cross(camRight)
        worldToView = Mat3(rows: camRight, camUp, back)
    }

    static func minimumDistance(for target: CameraTarget, sim: Simulation) -> Double {
        switch target {
        case .vessel(let id):
            return (sim.vessels.first { $0.id == id }?.boundingRadius ?? 5) * 1.2
        case .body(let id):
            return (sim.system.body(id: id)?.radius ?? 1) * 1.05
        }
    }
}
