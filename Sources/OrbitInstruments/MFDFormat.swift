import Foundation
import OrbitCore

/// Numbers as the MFDs show them. Orbiter's style for distances and speeds:
/// four significant figures with an SI prefix letter and no unit ("185.0k"
/// for 185 km, "6.563M", "7.793k" m/s); angles in degrees; times as clocks.
public enum MFDFormat {
    static let deg = 180 / Double.pi

    /// Four significant figures, with k, M, G or T from 1000 up: "185.0k",
    /// "6.563M", "950.0", "12.30", "-1.234k". "inf" for an infinite value
    /// and "---" for NaN.
    public static func si(_ x: Double) -> String {
        guard x.isFinite else { return x.isNaN ? "---" : (x > 0 ? "inf" : "-inf") }
        let prefixes = ["", "k", "M", "G", "T", "P"]
        var a = abs(x), k = 0
        while a >= 999.95, k < prefixes.count - 1 {
            a /= 1000
            k += 1
        }
        let mantissa = a >= 99.995 ? String(format: "%.1f", a) : a >= 9.9995 ? String(format: "%.2f", a)
            : String(format: "%.3f", a)
        return (x < 0 && mantissa.contains(where: { $0 != "0" && $0 != "." }) ? "-" : "") + mantissa + prefixes[k]
    }

    /// Degrees from radians, four significant figures with one to three
    /// decimals: "32.50°", "235.6°", "5.123°"; `signed` adds a plus sign.
    public static func degrees(_ rad: Double, signed: Bool = false) -> String {
        guard rad.isFinite else { return "---" }
        let d = rad * deg, a = abs(d)
        let s = unsignedZero(a >= 99.995 ? String(format: "%.1f", d) : a >= 9.9995 ? String(format: "%.2f", d)
            : String(format: "%.3f", d))
        return (signed && !s.hasPrefix("-") ? "+" : "") + s + "°"
    }

    /// A direction from north, 0...360°, three integer digits: "072.1°".
    public static func heading(_ rad: Double) -> String {
        guard rad.isFinite else { return "---" }
        var d = (rad * deg).truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        if d >= 359.95 { d = 0 }
        return String(format: "%05.1f°", d)
    }

    /// Geodetic latitude: "28.61°N".
    public static func latitude(_ rad: Double) -> String {
        let d = (rad * deg * 100).rounded() / 100
        return String(format: "%.2f°%@", abs(d), d >= 0 ? "N" : "S")
    }

    /// Longitude, east positive: "80.60°W".
    public static func longitude(_ rad: Double) -> String {
        var d = (remainder(rad * deg, 360) * 100).rounded() / 100
        if d <= -180 { d += 360 }
        return String(format: "%.2f°%@", abs(d), d >= 0 ? "E" : "W")
    }

    /// A duration as a clock: "28:24", "1:28:24", "2d 01:28:24"; "-0:12"
    /// below zero; "---" when infinite or NaN.
    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "---" }
        var s = abs(seconds).rounded(.down)
        let d = Int(s / 86400); s -= Double(d) * 86400
        let h = Int(s / 3600); s -= Double(h) * 3600
        let m = Int(s / 60); s -= Double(m) * 60
        let sign = seconds < 0 && (d + h + m > 0 || s > 0) ? "-" : ""
        if d > 0 { return String(format: "%@%dd %02d:%02d:%02d", sign, d, h, m, Int(s)) }
        if h > 0 { return String(format: "%@%d:%02d:%02d", sign, h, m, Int(s)) }
        return String(format: "%@%d:%02d", sign, m, Int(s))
    }

    /// A time on the mission clock, as the HUD shows MET: "+01:23:45"
    /// ("+1d 01:23:45" past a day); without a mission clock, the UTC time of
    /// day: "13:44:12Z".
    public static func clock(_ t: Epoch, zero: Epoch?) -> String {
        guard let zero else {
            let c = t.utc
            return String(format: "%02d:%02d:%02dZ", c.hour, c.minute, Int(c.second))
        }
        let dt = t - zero
        var s = abs(dt).rounded(.down)
        let d = Int(s / 86400); s -= Double(d) * 86400
        let h = Int(s / 3600); s -= Double(h) * 3600
        let m = Int(s / 60); s -= Double(m) * 60
        let sign = dt < 0 ? "-" : "+"
        if d > 0 { return String(format: "%@%dd %02d:%02d:%02d", sign, d, h, m, Int(s)) }
        return String(format: "%@%02d:%02d:%02d", sign, h, m, Int(s))
    }

    /// An angle reduced to [0, 2π).
    public static func wrapped(_ a: Double) -> Double {
        let w = a.truncatingRemainder(dividingBy: 2 * Double.pi)
        return w < 0 ? w + 2 * Double.pi : w
    }

    /// An angle reduced to [-π, π).
    public static func signedAngle(_ a: Double) -> Double {
        let w = wrapped(a)
        return w >= Double.pi ? w - 2 * Double.pi : w
    }

    /// A distance in nautical miles (1852 m) to a tenth, as Apollo's
    /// computer and EMS gave the ranges of an entry: "1644.1NM"; `signed`
    /// adds a plus sign.
    public static func nauticalMiles(_ metres: Double, signed: Bool = false) -> String {
        guard metres.isFinite else { return "---" }
        return fixed(metres / 1852, 1, signed: signed) + "NM"
    }

    /// Fixed decimals with an optional sign: "+12.3".
    public static func fixed(_ x: Double, _ decimals: Int, signed: Bool = false) -> String {
        guard x.isFinite else { return "---" }
        let s = unsignedZero(String(format: "%.\(decimals)f", x))
        return signed && !s.hasPrefix("-") ? "+" + s : s
    }

    /// "-0.000" as "0.000": a value that rounds to zero has no sign.
    static func unsignedZero(_ s: String) -> String {
        s.hasPrefix("-") && !s.contains(where: { $0.isNumber && $0 != "0" }) ? String(s.dropFirst()) : s
    }
}
