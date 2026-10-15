import Foundation

/// Orbiter-style attitude modes driven by the RCS.
public enum AttitudeAutopilot: String, CaseIterable, Codable {
    case killRotation = "KillRot"
    case prograde = "Prograde"
    case retrograde = "Retrograde"
    case normal = "Normal"
    case antinormal = "Antinormal"
    case radialOut = "Radial+"
    case radialIn = "Radial-"
    case horizonLevel = "Hold Level"

    /// Desired direction of the vessel +x axis (ICRF), or nil for rate damping.
    func target(for v: Vessel) -> Vec3? {
        let r = v.position, vel = v.velocity
        switch self {
        case .killRotation: return nil
        case .prograde: return vel.normalized
        case .retrograde: return -vel.normalized
        case .normal: return r.cross(vel).normalized
        case .antinormal: return -r.cross(vel).normalized
        case .radialOut: return r.normalized
        case .radialIn: return -r.normalized
        case .horizonLevel:
            let up = r.normalized
            let horiz = vel - up * vel.dot(up)
            return horiz.normalized
        }
    }
}

extension Vessel {
    /// Rotation command that steers towards the autopilot target (or nulls rates).
    func autopilotCommand(_ mode: AttitudeAutopilot) -> RotationCommand {
        let inertia = self.inertia
        let authority = rotationAuthority()
        let alpha = Vec3(authority.x / max(inertia[0, 0], 1e-6),
                         authority.y / max(inertia[1, 1], 1e-6),
                         authority.z / max(inertia[2, 2], 1e-6))
        guard alpha.x > 0 || alpha.y > 0 || alpha.z > 0 else { return RotationCommand() }

        var desired = Vec3.zero
        if let target = mode.target(for: self), target.lengthSquared > 0.5 {
            let tb = attitude.inverseRotate(target)
            var axis = Vec3.unitX.cross(tb)
            let angle = atan2(axis.length, tb.x)
            if axis.length < 1e-9 { axis = angle > 1 ? .unitY : .zero } else { axis = axis.normalized }
            // Bang-bang-like profile: approach rate that can still be stopped in time.
            let a = max(min(alpha.y, alpha.z), 1e-6)
            let rate = min(0.1, (2 * a * angle * 0.5).squareRoot())
            desired = axis * rate
            if angle < 0.002 { desired = .zero }
        }

        let err = desired - angularVelocity
        let response = 0.5  // s
        func axisCommand(_ e: Double, _ a: Double) -> Double {
            guard a > 0 else { return 0 }
            let c = e / (a * response)
            if abs(c) < 0.02 && abs(e) < 2e-4 { return 0 }
            return max(-1, min(1, c))
        }
        return RotationCommand(roll: axisCommand(err.x, alpha.x),
                               pitch: axisCommand(err.y, alpha.y),
                               yaw: axisCommand(err.z, alpha.z))
    }
}
