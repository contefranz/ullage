import Foundation
import OrbitCore

/// The soot (black carbon) a kerosene engine's exhaust leaves in the air,
/// once its plume's afterburning has burnt what it can (look round 2,
/// decision 4: little near the pad, more with height). One model, read by
/// P2's plume, P4's trail and LR4's launch cloud alike.
///
/// - **At the exit** the exhaust carries `exit` of soot, 22 g per kg of
///   propellant (`PlumeSettings.sootExit` switches it): Barker, Marais and
///   McDowell's (2024) Table 1 mean for kerosene, 21.7 g/kg, of Ross and
///   Sheaffer (2014, 20 g/kg within 10-40), CSVEM (the National Academies'
///   Commercial Space Vehicle Emissions Modeling report, 2021, after James
///   et al.: 25) and Maloney et al. (2022, 20). NASA TM X-2935 (Table II)
///   gives the F-1 0.0575 wt % particulates at its exit: MSFC's theoretical
///   estimate, mostly the turbine's exhaust, the same after reaction (it
///   assumes no burnout), 38 times below this exit; applied with no burnout
///   it is 4 times this model's soot near the pad. P2's soot depth (a
///   photo fit) implies 0.385 %.
/// - **The afterburning:** the fuel-rich exhaust burns again with the air
///   it entrains, its soot to CO₂, as long as the air has oxygen enough, so
///   its effect fades with height to nothing above about 40 km. CSVEM's fit
///   (constrained by ambient and laboratory measurements; Barker et al.'s
///   Eq. 2 as their inventory's code computes it, the typeset equation
///   having a typo) leaves 0.04 e^(0.12 (h − 15 km)) of the soot, all of it
///   from 41.8 km. Below 15 km CSVEM holds 4 %; Maloney et al. burn all of
///   it at the surface. Here the fit's own exponential carries on down (L,
///   the floor dropped): 0.66 % at sea level. Weighted by the S-IC's
///   exhaust per layer of height (NASA TM X-2935, Table I) the curve leaves
///   3.4 % of the stage's surviving soot below 15 km, about Maloney et
///   al.'s 3 % in the troposphere, where the floor would leave 9.3 %. So
///   the soot that survives near the pad is 0.015 % of the exhaust, where
///   the floor leaves 0.09 %.
/// - **h** is the US76 altitude of the ambient pressure: the fit's height
///   stands for the air's oxygen, so a plume in a studio, or on another
///   day's air, burns as the pressure it sees.
public enum KeroseneSoot {
    /// Soot at the nozzle exit, kg per kg of exhaust: the default of
    /// `PlumeSettings.sootExit`.
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

    /// Soot left after the afterburning, kg per kg of exhaust: `exit` (the
    /// frame's `PlumeSettings.sootExit`, so that one setting switches every
    /// reader) times `survivingShare`.
    public static func surviving(pressure: Double, exit: Double = KeroseneSoot.exit) -> Double {
        exit * survivingShare(pressure: pressure)
    }

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
