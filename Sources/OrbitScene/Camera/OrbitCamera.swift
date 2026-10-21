import Foundation
import OrbitCore

/// What the camera orbits around.
public enum CameraTarget: Equatable, Hashable {
    case vessel(UUID)
    case body(Int)
}

/// External "orbit" camera. All positions are barycentric doubles; the
/// renderer subtracts `position` from everything before converting to float.
public struct OrbitCamera {
    public enum Frame: String, CaseIterable { case horizon = "Horizon", vessel = "Vessel", inertial = "Inertial" }

    public var target: CameraTarget = .body(399)
    public var frame: Frame = .horizon
    public var yaw = -2.4          // rad, around the frame's up axis
    public var pitch = 0.25        // rad, elevation
    public var distance = 60.0     // m
    /// Vertical field of view, rad: the external camera's 50°, or a lens's
    /// (`hasselblad80mm`, `hasselblad250mm`).
    public var fovY = OrbitCamera.defaultFovY

    // Outputs of `update`.
    public private(set) var position = Vec3.zero        // barycentric
    public private(set) var targetPosition = Vec3.zero  // barycentric
    /// Rows: camera right, up, back (world -> view rotation).
    public private(set) var worldToView = Mat3.identity
    public private(set) var targetName = ""

    public init() {}

    public mutating func orbit(dx: Double, dy: Double) {
        yaw -= dx * 0.006
        pitch = min(max(pitch + dy * 0.006, -1.55), 1.55)
    }

    public mutating func zoom(_ amount: Double, minimum: Double) {
        distance = max(minimum, distance * exp(-amount * 0.04))
    }

    /// Recompute the camera pose for the current simulation state.
    public mutating func update(sim: Simulation) {
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
                up = v.reference.vertical(at: v.position, orientation: snap.orientation(v.reference))
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

        // Keep the camera 2 m above the ground (the body's figure) near a surface.
        if case .vessel(let id) = target, let v = sim.vessels.first(where: { $0.id == id }) {
            let center = snap.position(v.reference), o = snap.orientation(v.reference)
            let g = v.reference.geodetic(position - center, orientation: o)
            if g.height < 2 {
                position = center + o.toInertial(v.reference.figure.bodyFixed(latitude: g.latitude,
                                                                               longitude: g.longitude, height: 2))
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

    public static func minimumDistance(for target: CameraTarget, sim: Simulation) -> Double {
        switch target {
        case .vessel(let id):
            return (sim.vessels.first { $0.id == id }?.boundingRadius ?? 5) * 1.2
        case .body(let id):
            return (sim.system.body(id: id)?.radius ?? 1) * 1.05
        }
    }

    // MARK: Field of view

    /// The external camera's vertical field of view, rad (50°).
    public static let defaultFovY = 50.0 * Double.pi / 180

    /// The Hasselblad 500 EL's square frame on 70 mm film, m: 55 mm across,
    /// as the Apollo crews' magazines exposed it.
    public static let hasselbladFrame = 0.055

    /// The field of view across a frame `frame` wide behind a lens of
    /// `focalLength` (both m), focused at infinity: 2 atan(frame / 2f).
    public static func fieldOfView(focalLength: Double, frame: Double = hasselbladFrame) -> Double {
        2 * atan(frame / (2 * focalLength))
    }

    /// The Hasselblad's 80 mm Planar, the crews' standard lens: 37.9°.
    public static let hasselblad80mm = fieldOfView(focalLength: 0.080)
    /// The 250 mm Sonnar, the long lens of the Earthrise photograph: 12.6°.
    public static let hasselblad250mm = fieldOfView(focalLength: 0.250)
}
