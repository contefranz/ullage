import Foundation

/// The Apollo spacecraft axes (X_A, Y_A, Z_A) in the Saturn V construction
/// frame: the Saturn's axes turned 180° about x, so X_A = +x, Y_A = -y and
/// Z_A = -z, and +Z_A points at Position III (datasheet §12, MSFC-MAN-506
/// Fig. 7-15, H). Spacecraft parts are placed through these helpers, never
/// with a raw y or z.
public enum ApolloAxes {
    /// Apollo axes -> construction axes, Rx(π): the crew's control frame on
    /// a vessel built in construction axes.
    public static let rotation = Quat(w: 0, x: 1, y: 0, z: 0)

    /// Construction coordinates (m) of the point at Apollo station `xa`, `ya`
    /// and `za` off the axis, in inches as the sources give them.
    public static func construction(xa: Double, ya: Double = 0, za: Double = 0) -> Vec3 {
        Vec3(AS506.apolloStation(xa), -ya * AS506.inch, -za * AS506.inch)
    }

    /// Construction-axis components of a direction whose Apollo-axis
    /// components are (`xa`, `ya`, `za`).
    public static func direction(xa: Double, ya: Double, za: Double) -> Vec3 {
        Vec3(xa, -ya, -za)
    }
}
