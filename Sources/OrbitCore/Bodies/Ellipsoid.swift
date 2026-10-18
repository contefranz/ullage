import Foundation

/// A body's figure: an ellipsoid of revolution about its rotation axis
/// (body-fixed +z), flattened at the poles. Geodetic latitude is the angle
/// of the surface normal to the equator, and height is measured along that
/// normal; on a sphere they are the geocentric latitude and r - R.
public struct Ellipsoid: Equatable {
    /// a, m.
    public let equatorialRadius: Double
    /// f = (a - b) / a.
    public let flattening: Double

    public init(equatorialRadius: Double, flattening: Double) {
        self.equatorialRadius = equatorialRadius
        self.flattening = flattening
    }

    public init(equatorialRadius: Double, inverseFlattening: Double) {
        self.init(equatorialRadius: equatorialRadius, flattening: 1 / inverseFlattening)
    }

    /// WGS 84 (NIMA TR8350.2, 3rd ed., Table 3.1): the simulation's Earth.
    public static let wgs84 = Ellipsoid(equatorialRadius: 6_378_137, inverseFlattening: 298.257223563)
    /// Fischer 1960, the "Mercury datum" Apollo's trajectories are referred
    /// to (AS-506 FER and postflight trajectory altitudes; datasheet §5).
    public static let fischer1960 = Ellipsoid(equatorialRadius: 6_378_166, inverseFlattening: 298.3)
    /// A sphere of `radius`: geodetic coordinates are the geocentric ones.
    public static func sphere(_ radius: Double) -> Ellipsoid {
        Ellipsoid(equatorialRadius: radius, flattening: 0)
    }

    /// b, m.
    public var polarRadius: Double { equatorialRadius * (1 - flattening) }
    /// e² = f (2 - f).
    public var eccentricitySquared: Double { flattening * (2 - flattening) }

    /// Prime-vertical radius of curvature N at geodetic latitude `latitude`
    /// (rad): the distance along the normal from the surface to the axis.
    public func primeVerticalRadius(latitude: Double) -> Double {
        let s = sin(latitude)
        return equatorialRadius / (1 - eccentricitySquared * s * s).squareRoot()
    }

    /// Body-fixed position (m) of geodetic latitude and longitude (rad) and
    /// height (m) along the normal.
    public func bodyFixed(latitude: Double, longitude: Double, height: Double) -> Vec3 {
        let n = primeVerticalRadius(latitude: latitude)
        let c = (n + height) * cos(latitude)
        return Vec3(c * cos(longitude), c * sin(longitude), (n * (1 - eccentricitySquared) + height) * sin(latitude))
    }

    /// Outward unit normal at geodetic latitude and longitude (rad), body-fixed.
    public func normal(latitude: Double, longitude: Double) -> Vec3 {
        Vec3(cos(latitude) * cos(longitude), cos(latitude) * sin(longitude), sin(latitude))
    }

    /// The normal through a body-fixed point: the vertical there.
    public func normal(at position: Vec3) -> Vec3 {
        let g = geodetic(position)
        return normal(latitude: g.latitude, longitude: g.longitude)
    }

    /// Geodetic latitude, longitude (rad) and height (m) of a body-fixed
    /// point, in closed form (Vermeille, J. Geod. 85:105-117, 2011): k = 1 -
    /// e² + h/N is the root of p/(k + e²)² + q/k² = 1 that a cubic's positive
    /// root u gives. Exact at any distance (to 1e9 m and beyond), on the axis
    /// and at the poles, and for a sphere. Inside the evolute, the 43 km
    /// around the centre of the Earth where several normals pass through a
    /// point, it gives the nearest surface point: at the centre a pole, φ =
    /// 90°, h = -b.
    public func geodetic(_ position: Vec3) -> (latitude: Double, longitude: Double, height: Double) {
        let x = position.x, y = position.y, z = position.z
        let rho = (x * x + y * y).squareRoot()
        let lon = rho > 0 ? atan2(y, x) : 0
        let a = equatorialRadius, e2 = eccentricitySquared, e4 = e2 * e2
        guard e2 > 0 else {
            let r = (rho * rho + z * z).squareRoot()
            return (r > 0 ? atan2(z, rho) : Double.pi / 2, lon, r - a)
        }
        let p = rho * rho / (a * a), q = (1 - e2) * z * z / (a * a)
        if z == 0 && p <= e4 {
            // The equatorial plane inside the evolute: the nearest normal is
            // the one that crosses the plane at rho = N e² cos φ (northern).
            let cos2 = rho * rho * (1 - e2) / (e2 * (a * a * e2 - rho * rho))
            let lat = acos(min(1, cos2.squareRoot()))
            return (lat, lon, -primeVerticalRadius(latitude: lat) * (1 - e2))
        }
        let r = (p + q - e4) / 6
        let m = e4 * p * q
        let evolute = 8 * r * r * r + m
        let u: Double
        if evolute > 0 {
            // One real root (Cardano), positive.
            let c = cbrt(r * r * r + (m + (m * evolute).squareRoot()) / 4)
            u = r + c + r * r / c
        } else {
            // Three real roots (r < 0): the largest.
            let theta = 2 * atan2((-evolute).squareRoot(), m.squareRoot())
            u = -4 * r * sin((Double.pi + theta) / 6) * sin((Double.pi - theta) / 6)
        }
        let v = (u * u + e4 * q).squareRoot()
        let uv = u + v
        let w = e2 * (uv - q) / (2 * v)
        let k = w >= 0 ? uv / ((w * w + uv).squareRoot() + w) : (w * w + uv).squareRoot() - w
        let d = k * rho / (k + e2)
        let dz = (d * d + z * z).squareRoot()
        return (2 * atan2(z, d + dz), lon, (k + e2 - 1) / k * dz)
    }
}
