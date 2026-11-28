import Foundation
import OrbitCore

/// The soot (black carbon) a kerosene engine's exhaust leaves in the air,
/// once its plume's afterburning has burnt what it can (look round 2,
/// decision 4: little near the pad, more with height). One model, read by
/// P2's plume, P4's trail and LR4's launch cloud alike.
///
/// - **At the exit** the exhaust carries `exit` of soot: CSVEM's primary
///   emission index for kerosene, 22 g per kg of propellant (the National
///   Academies' Commercial Space Vehicle Emissions Modeling report, 2021,
///   as Barker, Marais and McDowell 2024 average it, their Table 1). Ross
///   and Sheaffer (2014) put kerosene engines' at 10-40 g/kg, Maloney et
///   al. (2022) use 20 g/kg; NASA TM X-2935 gives the F-1 0.0575 %
///   particulates at its exit, and P2's soot depth (a photo fit) implies
///   0.385 %.
/// - **The afterburning:** the fuel-rich exhaust burns again with the air
///   it entrains, its soot to CO₂, as long as the air has oxygen enough, so
///   its effect fades with height to nothing above about 40 km. CSVEM's fit
///   (Barker et al.'s Eq. 2, as their inventory's code computes it) leaves
///   0.04 e^(0.12 (h − 15 km)) of the soot, all of it from 41.8 km. Below
///   15 km CSVEM holds 4 %, the floor of a fit to a few model runs; Maloney
///   et al. burn all of it at the surface (and none by 15 km). Here the
///   fit's own exponential carries on down: 0.66 % at sea level (L, the
///   floor dropped), so the soot that survives near the pad is
///   0.015 % of the exhaust, where the global models' floor leaves 0.09 %.
/// - **h** is the US76 altitude of the ambient pressure: the fit's height
///   stands for the air's oxygen, so a plume in a studio, or on another
///   day's air, burns as the pressure it sees.
public enum KeroseneSoot {
    /// Soot at the nozzle exit, kg per kg of exhaust.
    public static let exit = 0.022

    /// CSVEM's fit: the share left at 15 km, and its growth with height
    /// (per km).
    public static let shareAt15km = 0.04
    public static let growthPerKm = 0.12

    /// The share of the exit's soot left after the afterburning, 0...1, in
    /// air of ambient pressure `pressure` (Pa); all of it in vacuum.
    public static func survivingShare(pressure: Double) -> Double {
        guard pressure > 0 else { return 1 }
        let h = standardAltitude(pressure: pressure) / 1_000
        return min(1, shareAt15km * exp(growthPerKm * (h - 15)))
    }

    /// Soot left after the afterburning, kg per kg of exhaust: `exit` times
    /// `survivingShare`.
    public static func surviving(pressure: Double) -> Double { exit * survivingShare(pressure: pressure) }

    /// The US76 altitude whose pressure is `pressure` (m), −5 to 100 km:
    /// bisection on the standard atmosphere's pressure, which falls with
    /// height.
    static func standardAltitude(pressure: Double) -> Double {
        var lo = -5_000.0, hi = 100_000.0
        let air = USStandardAtmosphere1976()
        guard pressure < air.state(altitude: lo).pressure else { return lo }
        guard pressure > air.state(altitude: hi).pressure else { return hi }
        for _ in 0..<60 {
            let mid = 0.5 * (lo + hi)
            if air.state(altitude: mid).pressure > pressure { lo = mid } else { hi = mid }
        }
        return 0.5 * (lo + hi)
    }
}
