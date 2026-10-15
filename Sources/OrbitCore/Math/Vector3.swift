import Foundation

/// Double-precision 3-vector. All simulation state uses doubles; conversion to
/// 32-bit floats happens only at the renderer, relative to the camera.
public struct Vec3: Equatable, Hashable, Codable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public var z: Double

    @inlinable public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x; self.y = y; self.z = z
    }

    public static let zero = Vec3(0, 0, 0)
    public static let unitX = Vec3(1, 0, 0)
    public static let unitY = Vec3(0, 1, 0)
    public static let unitZ = Vec3(0, 0, 1)

    @inlinable public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    @inlinable public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    @inlinable public static prefix func - (a: Vec3) -> Vec3 { Vec3(-a.x, -a.y, -a.z) }
    @inlinable public static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    @inlinable public static func * (s: Double, a: Vec3) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    @inlinable public static func / (a: Vec3, s: Double) -> Vec3 { Vec3(a.x / s, a.y / s, a.z / s) }
    @inlinable public static func += (a: inout Vec3, b: Vec3) { a = a + b }
    @inlinable public static func -= (a: inout Vec3, b: Vec3) { a = a - b }
    @inlinable public static func *= (a: inout Vec3, s: Double) { a = a * s }

    @inlinable public func dot(_ b: Vec3) -> Double { x * b.x + y * b.y + z * b.z }
    @inlinable public func cross(_ b: Vec3) -> Vec3 {
        Vec3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x)
    }
    @inlinable public var lengthSquared: Double { x * x + y * y + z * z }
    @inlinable public var length: Double { lengthSquared.squareRoot() }
    @inlinable public var normalized: Vec3 {
        let l = length
        return l > 0 ? self / l : .zero
    }
    /// Component-wise product.
    @inlinable public func scaled(by b: Vec3) -> Vec3 { Vec3(x * b.x, y * b.y, z * b.z) }

    public var description: String { String(format: "(%.6g, %.6g, %.6g)", x, y, z) }
}

/// Angle between two vectors in radians (numerically robust form).
public func angleBetween(_ a: Vec3, _ b: Vec3) -> Double {
    atan2(a.cross(b).length, a.dot(b))
}
