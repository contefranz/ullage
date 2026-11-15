import Foundation
import OrbitCore

/// The transverse Mercator projection on an ellipsoid, by Krüger's series
/// to fourth order in the third flattening n (Karney 2011, "Transverse
/// Mercator with an accuracy of a few nanometers", J. Geodesy 85:475, eqs.
/// 7-11, 35-36; within UTM zones the truncation is far under a millimetre).
/// Landsat scenes are on UTM grids: the Cape inset samples them through it.
public struct TransverseMercator {
    public let figure: Ellipsoid
    /// Central meridian, rad.
    public let centralMeridian: Double
    public let scale: Double
    public let falseEasting: Double
    public let falseNorthing: Double
    let a: Double, e: Double, alpha: [Double], beta: [Double], delta: [Double]

    public init(figure: Ellipsoid, centralMeridian: Double, scale: Double, falseEasting: Double = 0,
                falseNorthing: Double = 0) {
        self.figure = figure
        self.centralMeridian = centralMeridian
        self.scale = scale
        self.falseEasting = falseEasting
        self.falseNorthing = falseNorthing
        let f = figure.flattening
        let n = f / (2 - f), n2 = n * n, n3 = n2 * n, n4 = n3 * n
        a = figure.equatorialRadius / (1 + n) * (1 + n2 / 4 + n4 / 64)
        e = figure.eccentricitySquared.squareRoot()
        alpha = [n / 2 - 2 * n2 / 3 + 5 * n3 / 16 + 41 * n4 / 180,
                 13 * n2 / 48 - 3 * n3 / 5 + 557 * n4 / 1440,
                 61 * n3 / 240 - 103 * n4 / 140,
                 49561 * n4 / 161280]
        beta = [n / 2 - 2 * n2 / 3 + 37 * n3 / 96 - n4 / 360,
                n2 / 48 + n3 / 15 - 437 * n4 / 1440,
                17 * n3 / 480 - 37 * n4 / 840,
                4397 * n4 / 161280]
        delta = [2 * n - 2 * n2 / 3 - 2 * n3 + 116 * n4 / 45,
                 7 * n2 / 3 - 8 * n3 / 5 - 227 * n4 / 45,
                 56 * n3 / 15 - 136 * n4 / 35,
                 4279 * n4 / 630]
    }

    /// UTM zone `zone` (1-60) of the northern or southern hemisphere on WGS 84.
    public static func utm(zone: Int, north: Bool = true, figure: Ellipsoid = .wgs84) -> TransverseMercator {
        TransverseMercator(figure: figure, centralMeridian: Double(6 * zone - 183) * .pi / 180, scale: 0.9996,
                           falseEasting: 500_000, falseNorthing: north ? 0 : 10_000_000)
    }

    /// Easting and northing (m) of geodetic `latitude`, `longitude` (rad).
    public func forward(latitude: Double, longitude: Double) -> (easting: Double, northing: Double) {
        let dl = remainder(longitude - centralMeridian, 2 * Double.pi)
        let s = sin(latitude)
        let t = sinh(atanh(s) - e * atanh(e * s))
        let xi = atan2(t, cos(dl)), eta = atanh(sin(dl) / (1 + t * t).squareRoot())
        var x = eta, y = xi
        for j in 1 ... 4 {
            let k = 2 * Double(j)
            x += alpha[j - 1] * cos(k * xi) * sinh(k * eta)
            y += alpha[j - 1] * sin(k * xi) * cosh(k * eta)
        }
        return (falseEasting + scale * a * x, falseNorthing + scale * a * y)
    }

    /// Geodetic latitude and longitude (rad) of an easting and northing (m).
    public func inverse(easting: Double, northing: Double) -> (latitude: Double, longitude: Double) {
        let xi = (northing - falseNorthing) / (scale * a), eta = (easting - falseEasting) / (scale * a)
        var xp = xi, ep = eta
        for j in 1 ... 4 {
            let k = 2 * Double(j)
            xp -= beta[j - 1] * sin(k * xi) * cosh(k * eta)
            ep -= beta[j - 1] * cos(k * xi) * sinh(k * eta)
        }
        let chi = asin(sin(xp) / cosh(ep))
        var phi = chi
        for j in 1 ... 4 { phi += delta[j - 1] * sin(2 * Double(j) * chi) }
        return (phi, centralMeridian + atan2(sinh(ep), cos(xp)))
    }
}
