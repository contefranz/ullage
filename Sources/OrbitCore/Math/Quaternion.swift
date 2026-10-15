import Foundation

/// Unit quaternion representing an attitude. Convention: `q.rotate(v)` maps a
/// vector from the body frame into the reference (inertial) frame.
public struct Quat: Equatable, Codable, CustomStringConvertible {
    public var w: Double
    public var x: Double
    public var y: Double
    public var z: Double

    @inlinable public init(w: Double, x: Double, y: Double, z: Double) {
        self.w = w; self.x = x; self.y = y; self.z = z
    }

    public static let identity = Quat(w: 1, x: 0, y: 0, z: 0)

    public init(axis: Vec3, angle: Double) {
        let n = axis.normalized
        let s = sin(angle / 2)
        self.init(w: cos(angle / 2), x: n.x * s, y: n.y * s, z: n.z * s)
    }

    /// Build from a rotation matrix whose columns are the body axes expressed in
    /// the reference frame (i.e. the body->reference matrix).
    public init(matrix m: Mat3) {
        let trace = m[0, 0] + m[1, 1] + m[2, 2]
        if trace > 0 {
            let s = (trace + 1).squareRoot() * 2
            self.init(w: 0.25 * s, x: (m[2, 1] - m[1, 2]) / s, y: (m[0, 2] - m[2, 0]) / s, z: (m[1, 0] - m[0, 1]) / s)
        } else if m[0, 0] > m[1, 1] && m[0, 0] > m[2, 2] {
            let s = (1 + m[0, 0] - m[1, 1] - m[2, 2]).squareRoot() * 2
            self.init(w: (m[2, 1] - m[1, 2]) / s, x: 0.25 * s, y: (m[0, 1] + m[1, 0]) / s, z: (m[0, 2] + m[2, 0]) / s)
        } else if m[1, 1] > m[2, 2] {
            let s = (1 + m[1, 1] - m[0, 0] - m[2, 2]).squareRoot() * 2
            self.init(w: (m[0, 2] - m[2, 0]) / s, x: (m[0, 1] + m[1, 0]) / s, y: 0.25 * s, z: (m[1, 2] + m[2, 1]) / s)
        } else {
            let s = (1 + m[2, 2] - m[0, 0] - m[1, 1]).squareRoot() * 2
            self.init(w: (m[1, 0] - m[0, 1]) / s, x: (m[0, 2] + m[2, 0]) / s, y: (m[1, 2] + m[2, 1]) / s, z: 0.25 * s)
        }
        self = self.normalized
    }

    @inlinable public static func * (a: Quat, b: Quat) -> Quat {
        Quat(w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
             x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
             y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
             z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w)
    }

    public static func + (a: Quat, b: Quat) -> Quat { Quat(w: a.w + b.w, x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    public static func * (a: Quat, s: Double) -> Quat { Quat(w: a.w * s, x: a.x * s, y: a.y * s, z: a.z * s) }

    public var conjugate: Quat { Quat(w: w, x: -x, y: -y, z: -z) }
    public var norm: Double { (w * w + x * x + y * y + z * z).squareRoot() }
    public var normalized: Quat {
        let n = norm
        return n > 0 ? self * (1 / n) : .identity
    }

    /// Rotate a vector from body frame into reference frame.
    @inlinable public func rotate(_ v: Vec3) -> Vec3 {
        // v' = v + 2w(u x v) + 2 u x (u x v), u = (x, y, z)
        let u = Vec3(x, y, z)
        let t = u.cross(v) * 2
        return v + t * w + u.cross(t)
    }

    /// Rotate a vector from reference frame into body frame.
    @inlinable public func inverseRotate(_ v: Vec3) -> Vec3 { conjugate.rotate(v) }

    /// Body->reference rotation matrix (columns are body axes).
    public var matrix: Mat3 {
        Mat3(columns: rotate(.unitX), rotate(.unitY), rotate(.unitZ))
    }

    /// Time derivative for body-frame angular velocity `omega` (rad/s).
    @inlinable public func derivative(bodyRate omega: Vec3) -> Quat {
        (self * Quat(w: 0, x: omega.x, y: omega.y, z: omega.z)) * 0.5
    }

    public var description: String { String(format: "Quat(w: %.6f, x: %.6f, y: %.6f, z: %.6f)", w, x, y, z) }
}
