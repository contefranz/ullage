import Foundation
import OrbitCore

/// A body's air for the particles: density, temperature, pressure and wind
/// at 64 altitudes, h_i = top × (i / 63)² (25 m apart at the ground, 3 km at
/// the top), sampled each frame from the simulation's own atmosphere (the
/// launch day's sounding over US76) and uploaded with the anchors. The GPU
/// interpolates it as `sample` does: linearly in altitude, the density and
/// pressure log-linearly. Above `top`, or the atmosphere's ceiling, there is
/// vacuum.
public struct AirProfile: Equatable {
    public static let count = 64
    /// m.
    public static let top = 100_000.0

    /// Per level: kg/m³, K, Pa, and the wind towards east and north, m/s.
    public var density: [Double]
    public var temperature: [Double]
    public var pressure: [Double]
    public var windEast: [Double]
    public var windNorth: [Double]

    /// Level `i`'s altitude, m.
    public static func altitude(_ i: Int) -> Double {
        let x = Double(i) / Double(count - 1)
        return top * x * x
    }

    /// Sampled from `atmosphere`.
    public init(_ atmosphere: Atmosphere) {
        var d: [Double] = [], t: [Double] = [], p: [Double] = [], e: [Double] = [], n: [Double] = []
        for i in 0..<Self.count {
            let h = Self.altitude(i)
            let s = h <= atmosphere.ceiling ? atmosphere.state(altitude: h) : .vacuum
            let w = atmosphere.wind(altitude: h)
            d.append(s.density)
            t.append(s.temperature)
            p.append(s.pressure)
            e.append(w.east)
            n.append(w.north)
        }
        self.init(density: d, temperature: t, pressure: p, windEast: e, windNorth: n)
    }

    /// The same air at every altitude (look-dev's studio air).
    public init(constant air: ParticlePhysics.Air, windEast: Double = 0, windNorth: Double = 0) {
        let k = Self.count
        self.init(density: Array(repeating: air.density, count: k), temperature: Array(repeating: air.temperature, count: k),
                  pressure: Array(repeating: air.pressure, count: k), windEast: Array(repeating: windEast, count: k),
                  windNorth: Array(repeating: windNorth, count: k))
    }

    public init(density: [Double], temperature: [Double], pressure: [Double], windEast: [Double], windNorth: [Double]) {
        precondition([density, temperature, pressure, windEast, windNorth].allSatisfy { $0.count == Self.count })
        self.density = density
        self.temperature = temperature
        self.pressure = pressure
        self.windEast = windEast
        self.windNorth = windNorth
    }

    /// The least density or pressure the log-linear interpolation takes the
    /// log of; below it, vacuum.
    public static let floor = 1e-30

    /// The air at altitude `h` (m): its density, temperature, pressure and
    /// the wind (east, north); vacuum above the top, the lowest level's
    /// below the ground.
    public func sample(altitude h: Double) -> (density: Double, temperature: Double, pressure: Double,
                                              windEast: Double, windNorth: Double) {
        guard h < Self.top else { return (0, 3, 0, 0, 0) }
        let u = (max(h, 0) / Self.top).squareRoot() * Double(Self.count - 1)
        let i = min(Int(u), Self.count - 2)
        // Linear in altitude between the levels: the fraction of the way in h.
        let h0 = Self.altitude(i), h1 = Self.altitude(i + 1)
        let w = min(max((max(h, 0) - h0) / (h1 - h0), 0), 1)
        func lin(_ a: [Double]) -> Double { a[i] + w * (a[i + 1] - a[i]) }
        func log(_ a: [Double]) -> Double {
            guard a[i] > Self.floor, a[i + 1] > Self.floor else { return a[i] + w * (a[i + 1] - a[i]) }
            return exp(Foundation.log(a[i]) + w * (Foundation.log(a[i + 1]) - Foundation.log(a[i])))
        }
        return (log(density), lin(temperature), log(pressure), lin(windEast), lin(windNorth))
    }
}
