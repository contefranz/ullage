import Foundation

/// Water ice sublimating from shed frost: Murphy and Koop's vapour pressure
/// over ice, a Hertz-Knudsen flux limited in air by vapour diffusion in
/// series, and the ice's temperature, the air's in air and its radiative
/// equilibrium in vacuum (sunlit or in eclipse). For the frost particles;
/// visual only.
public enum IceSublimation {
    /// Water's molar mass, kg/mol; ice's density, kg/m³; ice's latent heat
    /// of sublimation near 250 K, J/kg.
    public static let molarMass = 0.018_015_28
    public static let iceDensity = 917.0
    public static let latentHeat = 2.836e6
    static let gasConstant = 8.314462618
    static let stefanBoltzmann = 5.670374419e-8
    /// Ice's solar absorptance and thermal emissivity (L: frost is bright
    /// in the visible and nearly black in the infrared), and the solar
    /// constant, W/m².
    public static let solarAbsorptance = 0.3
    public static let emissivity = 0.97
    public static let solarConstant = 1_361.0

    /// Murphy and Koop (2005) eq. 7: the vapour pressure over hexagonal ice,
    /// Pa, for T above 110 K.
    public static func vaporPressure(temperature t: Double) -> Double {
        exp(9.550426 - 5_723.265 / t + 3.53068 * log(t) - 0.00728332 * t)
    }

    /// Water vapour's diffusivity in air, m²/s (Pruppacher and Klett eq.
    /// 13-3), infinite in vacuum.
    public static func diffusivity(temperature t: Double, pressure p: Double) -> Double {
        p > 0 ? 2.11e-5 * pow(t / 273.15, 1.94) * 101_325 / p : .infinity
    }

    /// The mass flux leaving ice at `temperature` (K) into air of `pressure`
    /// (Pa) and `temperature` holding water vapour at `vaporPressure` (Pa;
    /// the launch-day sounding has no humidity: dry by default), from a
    /// sphere of `radius` (m), kg/(m² s); negative where vapour deposits.
    /// Hertz and Knudsen's α Δρ_v v̄/4, in series in air with diffusion's D
    /// Δρ_v / r (Maxwell); α, the sublimation coefficient, 1 by default (L).
    public static func massFlux(iceTemperature ts: Double, airPressure p: Double, airTemperature ta: Double,
                                vaporPressure pv: Double = 0, radius r: Double, coefficient alpha: Double = 1) -> Double {
        let r0 = gasConstant / molarMass
        let excess = vaporPressure(temperature: ts) / (r0 * ts) - pv / (r0 * max(ta, 1))
        let kinetic = alpha * (r0 * ts / (2 * Double.pi)).squareRoot()
        let d = diffusivity(temperature: max(ta, 1), pressure: p)
        let resistance = 1 / kinetic + (d.isFinite ? r / d : 0)
        return excess / resistance
    }

    /// The ice's temperature in vacuum where absorbed sunlight (times
    /// `sunlitFraction`: 0 in eclipse) and Earth's infrared (W/m² on its
    /// cross-section) balance its thermal emission and the latent heat of
    /// the ice it sublimates, K. Sublimating, sunlit ice holds itself well
    /// below the 208 K that radiation alone would give it.
    public static func radiativeEquilibriumTemperature(sunlitFraction: Double, earthInfrared: Double = 0) -> Double {
        // The surplus falls with T: bisect for its zero.
        var lo = 30.0, hi = 400.0
        for _ in 0..<100 {
            let mid = 0.5 * (lo + hi)
            if surplus(temperature: mid, sunlitFraction: sunlitFraction, earthInfrared: earthInfrared) > 0 {
                lo = mid
            } else {
                hi = mid
            }
        }
        return 0.5 * (lo + hi)
    }

    /// The energy balance per m² of cross-section at `temperature`, W:
    /// absorbed, α S f + ε q_IR, less emitted, 4 ε σ T⁴, less the latent
    /// heat sublimation carries off, 4 L J(T).
    static func surplus(temperature t: Double, sunlitFraction: Double, earthInfrared: Double = 0) -> Double {
        let absorbed = solarAbsorptance * solarConstant * max(0, min(1, sunlitFraction)) + emissivity * earthInfrared
        let flux = massFlux(iceTemperature: t, airPressure: 0, airTemperature: t, radius: 1)
        return absorbed - 4 * emissivity * stefanBoltzmann * pow(t, 4) - 4 * latentHeat * flux
    }

    /// The rate at which a sphere of ice's radius shrinks, m/s (positive
    /// while it sublimates).
    public static func radiusRate(iceTemperature ts: Double, airPressure p: Double, airTemperature ta: Double,
                                  vaporPressure pv: Double = 0, radius r: Double) -> Double {
        massFlux(iceTemperature: ts, airPressure: p, airTemperature: ta, vaporPressure: pv, radius: r) / iceDensity
    }

    /// The time for a sphere of ice of `radius` to sublimate away in vacuum
    /// at a steady `temperature`, s: there the flux does not depend on the
    /// radius, which shrinks at a steady rate.
    public static func vacuumLifetime(radius r: Double, temperature t: Double) -> Double {
        r / radiusRate(iceTemperature: t, airPressure: 0, airTemperature: t, radius: r)
    }
}
