import Foundation
import OrbitCore

/// Surface normals from heights (M1.6 track E1's relief layer, from ETOPO
/// 2022): central differences over a ground step, in the local geodetic
/// east-north-up frame, so the renderer turns them with the ellipsoid's
/// normal at the point and no tile's own axes are involved.
public enum ReliefNormals {
    /// The meridional radius of curvature M at geodetic `latitude`, m.
    public static func meridionalRadius(_ figure: Ellipsoid, latitude: Double) -> Double {
        let e2 = figure.eccentricitySquared, s = sin(latitude)
        return figure.equatorialRadius * (1 - e2) / pow(1 - e2 * s * s, 1.5)
    }

    /// The unit normal (east, north, up) of the surface `height(lat, lon)`
    /// (m; rad) at geodetic `latitude`, `longitude`, from heights `step`
    /// metres either side along the meridian and the parallel. The
    /// parallel's step is held below a quarter turn near the poles.
    public static func normal(latitude: Double, longitude: Double, step: Double, figure: Ellipsoid,
                              height: (Double, Double) -> Double) -> Vec3 {
        let m = meridionalRadius(figure, latitude: latitude)
        let n = figure.primeVerticalRadius(latitude: latitude) * max(cos(latitude), 1e-9)
        let dLat = step / m, dLon = min(step / n, Double.pi / 2)
        let east = (height(latitude, longitude + dLon) - height(latitude, longitude - dLon)) / (2 * dLon * n)
        let north = (height(min(latitude + dLat, .pi / 2), longitude) - height(max(latitude - dLat, -.pi / 2), longitude))
            / ((min(latitude + dLat, .pi / 2) - max(latitude - dLat, -.pi / 2)) * m)
        guard east.isFinite && north.isFinite else { return Vec3(0, 0, 1) }
        return Vec3(-east, -north, 1).normalized
    }

    /// A unit vector's components as bytes, [-1, 1] to 0...255 (0 is 128,
    /// rounded), the relief tiles' RGB.
    public static func encode(_ n: Vec3) -> (UInt8, UInt8, UInt8) {
        func b(_ x: Double) -> UInt8 { UInt8(min(255, max(0, ((x * 0.5 + 0.5) * 255).rounded()))) }
        return (b(n.x), b(n.y), b(n.z))
    }

    /// The vector three bytes encode, as `encode` wrote it.
    public static func decode(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Vec3 {
        func f(_ x: UInt8) -> Double { Double(x) / 255 * 2 - 1 }
        return Vec3(f(r), f(g), f(b))
    }
}
