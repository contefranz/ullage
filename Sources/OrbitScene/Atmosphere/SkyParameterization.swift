import Foundation
import OrbitCore

/// The sky-view LUT's parameterisation (Hillaire 2020, §5.3), which
/// AtmosphereShaders mirrors in MSL: the sky around a camera inside the
/// atmosphere, as a function of the view's zenith angle and its azimuth from
/// the Sun's vertical, at the camera's radius r and the Sun's zenith angle.
///
/// - v: the horizon (dipped below the horizontal by the camera's height) at
///   v = 0.5; above it the zenith angle runs 0 → the horizon's on v = 0 →
///   0.5 through 1 − √(1 − x), below it the horizon → the nadir on 0.5 → 1
///   through √x: half the rows lie within a few degrees of the horizon,
///   where the sky changes fastest.
/// - u: √(½ − ½ cos φ), φ the azimuth from the Sun's vertical (0 toward the
///   Sun, π away): the sky is symmetric about that vertical, and the
///   aureole gets the most columns.
///
/// Both then map to texel centres (`AtmosphereLUT.textureCoordinate`).
public enum SkyViewParameterization {
    /// The view's zenith angle at the horizon, and the horizon's dip below
    /// the horizontal (β: the angle between the horizon ray and the nadir).
    public static func horizon(radius r: Double, bottomRadius rb: Double) -> (zenithAngle: Double, beta: Double) {
        let rr = max(r, rb)
        let vHorizon = max(0, (rr - rb) * (rr + rb)).squareRoot()
        let beta = acos(min(1, vHorizon / rr))
        return (Double.pi - beta, beta)
    }

    /// The table's (u, v), texel centres, for a view of zenith cosine `mu`
    /// and azimuth cosine `cosAzimuth` from the Sun's vertical.
    public static func uv(radius r: Double, bottomRadius rb: Double, cosZenith mu: Double, cosAzimuth: Double,
                          width: Int, height: Int) -> (u: Double, v: Double) {
        let (zh, beta) = horizon(radius: r, bottomRadius: rb)
        let zenith = acos(min(max(mu, -1), 1))
        var y: Double
        if zenith < zh {
            y = 0.5 * (1 - (1 - zenith / zh).squareRoot())
        } else {
            y = 0.5 + 0.5 * (min(max((zenith - zh) / beta, 0), 1)).squareRoot()
        }
        y = min(max(y, 0), 1)
        let x = (max(0, 0.5 - 0.5 * min(max(cosAzimuth, -1), 1))).squareRoot()
        return (AtmosphereLUT.textureCoordinate(unit: x, size: width),
                AtmosphereLUT.textureCoordinate(unit: y, size: height))
    }

    /// The view at the table's (u, v): its zenith cosine and its azimuth
    /// cosine from the Sun's vertical.
    public static func view(u: Double, v: Double, radius r: Double, bottomRadius rb: Double, width: Int,
                            height: Int) -> (cosZenith: Double, cosAzimuth: Double) {
        let x = AtmosphereLUT.unit(textureCoordinate: u, size: width)
        let y = AtmosphereLUT.unit(textureCoordinate: v, size: height)
        let (zh, beta) = horizon(radius: r, bottomRadius: rb)
        let zenith: Double
        if y < 0.5 {
            let c = 1 - 2 * y
            zenith = zh * (1 - c * c)
        } else {
            let c = 2 * y - 1
            zenith = zh + beta * c * c
        }
        return (cos(zenith), 1 - 2 * x * x)
    }
}

/// The aerial-perspective froxels' slices: slice i (of n) holds the light
/// along each view ray from the camera to far × ((i + 1)/n)^k, so a
/// distance d reads at slice coordinate s = n (d/far)^(1/k) − 1, between
/// slice centres; nearer than slice 0's distance the in-scattered light
/// fades linearly to none at the camera, and the transmittance to 1.
public struct FroxelSlices: Equatable {
    public var count: Int
    /// The last slice's distance, m.
    public var far: Double
    /// The distribution exponent k (1 linear; 2 crowds the near slices).
    public var exponent: Double

    public init(count: Int, far: Double, exponent: Double) {
        self.count = count
        self.far = far
        self.exponent = exponent
    }

    /// Slice i's distance, m.
    public func distance(slice i: Int) -> Double {
        far * pow(Double(i + 1) / Double(count), exponent)
    }

    /// The texture's w coordinate (0...1, texel centres) for distance `d`,
    /// and the weight of the in-scattered light (below 1 nearer than slice 0).
    public func coordinate(distance d: Double) -> (w: Double, weight: Double) {
        let s = Double(count) * pow(min(max(d, 0) / far, 1), 1 / exponent) - 1
        let w = (min(max(s, 0), Double(count - 1)) + 0.5) / Double(count)
        return (w, min(max(s + 1, 0), 1))
    }

    /// The far distance that keeps everything the camera can see through
    /// air in the froxels: its horizon's distance plus that of a cloud top
    /// of 12 km beyond it (`AtmosphereFrame.cloudTop`), within 32 and 2,000 km.
    public static func far(cameraAltitude h: Double, bottomRadius rb: Double) -> Double {
        func horizon(_ h: Double) -> Double { max(0, h * (2 * rb + h)).squareRoot() }
        return min(max(horizon(h) + horizon(AtmosphereFrame.cloudTop), 32_000), 2_000_000)
    }
}
