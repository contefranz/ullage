import Foundation

/// Numbers as the flight HUD's instrument cluster shows them: SI with the
/// unit's symbol (the MFDs' Orbiter style, `MFDFormat`, drops the unit),
/// rounded so that the readouts do not flicker.
public enum HUDFormat {
    static let deg = 180 / Double.pi

    /// The time to an event, counted down in whole seconds rounded up, as a
    /// countdown clock shows it (0:01 until the event is due): "0:42",
    /// "12:05", "1:02:13", "2d 01:02:13"; "now" once it is due; "---" when
    /// unknown (NaN or infinite).
    public static func countdown(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "---" }
        guard seconds > 0 else { return "now" }
        var s = seconds.rounded(.up)
        let d = Int(s / 86400); s -= Double(d) * 86400
        let h = Int(s / 3600); s -= Double(h) * 3600
        let m = Int(s / 60); s -= Double(m) * 60
        if d > 0 { return String(format: "%dd %02d:%02d:%02d", d, h, m, Int(s)) }
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, Int(s)) }
        return String(format: "%d:%02d", m, Int(s))
    }

    /// "S-IVB cutoff (IGM) in 2:13".
    public static func nextEvent(_ name: String, in seconds: Double) -> String {
        let c = countdown(seconds)
        return c == "now" ? name + " now" : name + " in " + c
    }

    /// A distance: "0.8 m", "125.3 m", "8.43 km", "1234.5 km", "38416 km".
    public static func range(_ m: Double) -> String {
        guard m.isFinite else { return "---" }
        let a = abs(m)
        if a < 999.95 { return String(format: "%.1f m", m) }
        if a < 99_995 { return String(format: "%.2f km", m / 1000) }
        if a < 9_999_950 { return String(format: "%.1f km", m / 1000) }
        return String(format: "%.0f km", m / 1000)
    }

    /// A range rate, positive opening: "+0.31 m/s", "-12.4 m/s", "+7312 m/s".
    public static func rangeRate(_ v: Double) -> String {
        guard v.isFinite else { return "---" }
        let a = abs(v)
        let s = a < 9.995 ? String(format: "%+.2f", v) : a < 999.95 ? String(format: "%+.1f", v)
            : String(format: "%+.0f", v)
        return signless(s) + " m/s"
    }

    /// A bank angle about the air velocity, positive right, in whole
    /// degrees: "55°R", "120°L", "0°" (lift up), "180°" (lift down); "---"
    /// without one.
    public static func bank(_ rad: Double?) -> String {
        guard let rad, rad.isFinite else { return "---" }
        var d = remainder(rad * deg, 360).rounded()
        if d == -180 { d = 180 }
        if d == 0 || d == 180 { return String(format: "%.0f°", abs(d)) }
        return String(format: "%.0f°%@", abs(d), d > 0 ? "R" : "L")
    }

    /// A heat flux: "0 kW/m²", "657 kW/m²", "1.23 MW/m²".
    public static func heatFlux(_ w: Double) -> String {
        guard w.isFinite else { return "---" }
        return abs(w) < 999_500 ? String(format: "%.0f kW/m²", w / 1000) : String(format: "%.2f MW/m²", w / 1e6)
    }

    /// A heat load: "0.00 MJ/m²", "4.56 MJ/m²", "12.3 MJ/m²", "149 MJ/m²".
    public static func heatLoad(_ j: Double) -> String {
        guard j.isFinite else { return "---" }
        let a = abs(j) / 1e6
        return a < 9.995 ? String(format: "%.2f MJ/m²", j / 1e6) : a < 99.95 ? String(format: "%.1f MJ/m²", j / 1e6)
            : String(format: "%.0f MJ/m²", j / 1e6)
    }

    /// A load factor: "0.00 g", "3.42 g", "12.3 g".
    public static func loadFactor(_ g: Double) -> String {
        guard g.isFinite else { return "---" }
        return abs(g) < 9.995 ? String(format: "%.2f g", g) : String(format: "%.1f g", g)
    }

    /// "+0.00" as "0.00": a value that rounds to zero has no sign.
    static func signless(_ s: String) -> String {
        s.contains(where: { $0.isNumber && $0 != "0" }) ? s : String(s.drop { $0 == "+" || $0 == "-" })
    }
}
