import Foundation

/// How much of the Sun's disc a point sees: the conical shadow model of
/// Montenbruck & Gill, *Satellite Orbits* (2000) §3.4.2. The Sun and each
/// occulter are discs on the sky, of apparent radii a = asin(R_sun/|s - r|)
/// and b = asin(R/|c - r|) a separation c apart; the occulted share is
/// their overlap's area over π a². No refraction or atmospheric dimming.
public enum Eclipse {
    /// IAU 2015 Resolution B3's nominal solar radius, m.
    public static let solarRadius = 695_700_000.0

    /// Sunlit fraction (0 in umbra, 1 in full sunlight) at `point`, with the
    /// Sun's centre at `sun` and `occulters` as spheres, all in one frame (m).
    /// Two occulters' shares combine as if independent: the product of their
    /// sunlit fractions, which lies between the bounds their overlap allows
    /// and is exact when either is 0 or 1. A point within an occulter's
    /// radius sees it fill half the sky (b = 90°), the horizon of a point on
    /// the surface of a body the sphere stands for.
    public static func sunlitFraction(at point: Vec3, sun: Vec3, sunRadius: Double = solarRadius,
                                      occulters: [(center: Vec3, radius: Double)]) -> Double {
        let toSun = sun - point, sunDistance = toSun.length
        guard sunDistance > sunRadius else { return 1 }
        let a = asin(sunRadius / sunDistance)
        var lit = 1.0
        for o in occulters {
            let toOcculter = o.center - point, distance = toOcculter.length
            // Nothing beyond the Sun's centre can hide it.
            guard distance - o.radius < sunDistance else { continue }
            let b = distance > o.radius ? asin(o.radius / distance) : Double.pi / 2
            let c = angleBetween(toSun, toOcculter)
            lit *= 1 - overlapArea(a, b, separation: c) / (Double.pi * a * a)
        }
        return max(0, min(1, lit))
    }

    /// Sunlit fraction at `position` relative to `reference` (ICRF, m), with
    /// the system's Earth (as a sphere of its equatorial radius) and Moon as
    /// occulters, from `snapshot`.
    public static func sunlitFraction(at position: Vec3, relativeTo reference: CelestialBody, in system: SolarSystem,
                                      snapshot s: SystemSnapshot) -> Double {
        let point = s.position(reference) + position
        return sunlitFraction(at: point, sun: s.position(system.sun),
                              occulters: [(s.position(system.earth), system.earth.figure.equatorialRadius),
                                          (s.position(system.moon), system.moon.radius)])
    }

    /// Overlap area of two discs of radii `a` and `b` whose centres are `c`
    /// apart, in the plane (M&G eq. 3.94).
    public static func overlapArea(_ a: Double, _ b: Double, separation c: Double) -> Double {
        if c >= a + b { return 0 }
        if c <= abs(a - b) { return Double.pi * min(a, b) * min(a, b) }
        let x = (c * c + a * a - b * b) / (2 * c), y = max(0, a * a - x * x).squareRoot()
        return a * a * acos(max(-1, min(1, x / a))) + b * b * acos(max(-1, min(1, (c - x) / b))) - c * y
    }
}
