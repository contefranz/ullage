import Foundation

/// Row-major 3x3 matrix of doubles.
public struct Mat3: Equatable, Codable {
    public var r0: Vec3
    public var r1: Vec3
    public var r2: Vec3

    @inlinable public init(rows r0: Vec3, _ r1: Vec3, _ r2: Vec3) {
        self.r0 = r0; self.r1 = r1; self.r2 = r2
    }

    public init(columns c0: Vec3, _ c1: Vec3, _ c2: Vec3) {
        self.init(rows: Vec3(c0.x, c1.x, c2.x), Vec3(c0.y, c1.y, c2.y), Vec3(c0.z, c1.z, c2.z))
    }

    public static let identity = Mat3(rows: .unitX, .unitY, .unitZ)
    public static let zero = Mat3(rows: .zero, .zero, .zero)

    public static func diagonal(_ d: Vec3) -> Mat3 {
        Mat3(rows: Vec3(d.x, 0, 0), Vec3(0, d.y, 0), Vec3(0, 0, d.z))
    }

    public subscript(row: Int, col: Int) -> Double {
        let r = row == 0 ? r0 : (row == 1 ? r1 : r2)
        return col == 0 ? r.x : (col == 1 ? r.y : r.z)
    }

    public var c0: Vec3 { Vec3(r0.x, r1.x, r2.x) }
    public var c1: Vec3 { Vec3(r0.y, r1.y, r2.y) }
    public var c2: Vec3 { Vec3(r0.z, r1.z, r2.z) }

    @inlinable public static func * (m: Mat3, v: Vec3) -> Vec3 {
        Vec3(m.r0.dot(v), m.r1.dot(v), m.r2.dot(v))
    }

    public static func * (a: Mat3, b: Mat3) -> Mat3 {
        let bc0 = b.c0, bc1 = b.c1, bc2 = b.c2
        return Mat3(rows: Vec3(a.r0.dot(bc0), a.r0.dot(bc1), a.r0.dot(bc2)),
                    Vec3(a.r1.dot(bc0), a.r1.dot(bc1), a.r1.dot(bc2)),
                    Vec3(a.r2.dot(bc0), a.r2.dot(bc1), a.r2.dot(bc2)))
    }

    public static func + (a: Mat3, b: Mat3) -> Mat3 { Mat3(rows: a.r0 + b.r0, a.r1 + b.r1, a.r2 + b.r2) }
    public static func * (a: Mat3, s: Double) -> Mat3 { Mat3(rows: a.r0 * s, a.r1 * s, a.r2 * s) }

    public var transposed: Mat3 { Mat3(rows: c0, c1, c2) }

    public var determinant: Double { r0.dot(r1.cross(r2)) }

    public var inverse: Mat3 {
        let det = determinant
        // Columns of the inverse are the cross products of the rows / det.
        let i0 = r1.cross(r2), i1 = r2.cross(r0), i2 = r0.cross(r1)
        return Mat3(columns: i0 / det, i1 / det, i2 / det)
    }

    // MARK: Elementary rotations
    //
    // `frameX/Y/Z(a)` are *passive* rotations (the R1/R2/R3 of the Explanatory
    // Supplement and SPICE): they rotate the coordinate frame by `a`, so a fixed
    // vector's coordinates rotate by -a. `rotX/Y/Z(a)` are *active* rotations.

    public static func rotX(_ a: Double) -> Mat3 {
        let c = cos(a), s = sin(a)
        return Mat3(rows: Vec3(1, 0, 0), Vec3(0, c, -s), Vec3(0, s, c))
    }
    public static func rotY(_ a: Double) -> Mat3 {
        let c = cos(a), s = sin(a)
        return Mat3(rows: Vec3(c, 0, s), Vec3(0, 1, 0), Vec3(-s, 0, c))
    }
    public static func rotZ(_ a: Double) -> Mat3 {
        let c = cos(a), s = sin(a)
        return Mat3(rows: Vec3(c, -s, 0), Vec3(s, c, 0), Vec3(0, 0, 1))
    }
    public static func frameX(_ a: Double) -> Mat3 { rotX(-a) }
    public static func frameY(_ a: Double) -> Mat3 { rotY(-a) }
    public static func frameZ(_ a: Double) -> Mat3 { rotZ(-a) }

    /// Skew-symmetric cross-product matrix: `cross(w) * v == w.cross(v)`.
    public static func cross(_ w: Vec3) -> Mat3 {
        Mat3(rows: Vec3(0, -w.z, w.y), Vec3(w.z, 0, -w.x), Vec3(-w.y, w.x, 0))
    }

    /// Re-orthonormalise (Gram-Schmidt on rows).
    public var orthonormalized: Mat3 {
        let a = r0.normalized
        let b = (r1 - a * a.dot(r1)).normalized
        return Mat3(rows: a, b, a.cross(b))
    }
}
