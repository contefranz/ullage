import Foundation

/// Simple primitives used to draw a part until real meshes exist.
public struct VisualShape {
    public enum Kind { case frustum(baseRadius: Double, topRadius: Double), sphere(radius: Double) }
    public var kind: Kind
    /// Centre of the shape's base (frustum) or centre (sphere), part frame, m.
    public var origin: Vec3
    /// Frustum axis and length (base -> top).
    public var axis: Vec3
    public var length: Double
    /// Linear RGB.
    public var color: (Double, Double, Double)

    public static func frustum(from origin: Vec3, length: Double, baseRadius: Double, topRadius: Double,
                               axis: Vec3 = .unitX, color: (Double, Double, Double)) -> VisualShape {
        VisualShape(kind: .frustum(baseRadius: baseRadius, topRadius: topRadius), origin: origin,
                    axis: axis.normalized, length: length, color: color)
    }
}
