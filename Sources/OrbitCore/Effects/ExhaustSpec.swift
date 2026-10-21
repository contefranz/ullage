import Foundation

/// What leaves an engine's nozzle, as the plume model needs it: derived from
/// engine data and none of it fed back into the physics. Values carry their
/// source and grade in the datasheet's style: "H", "M" or "L".
public struct ExhaustSpec: Equatable {
    /// The propellant combination, which sets the plume's chemistry and look.
    public enum Family: String, CaseIterable {
        case keroseneLOX, hydrogenLOX, hypergolic, solidAluminized, solidOther, coldGas
    }

    /// A stream injected along the nozzle's wall (the F-1's turbine exhaust
    /// cooling its nozzle extension), which burns at the plume's edge.
    public struct Film: Equatable {
        /// Share of the engine's mass flow.
        public var massFraction: Double
        /// The nozzle's area ratio where it is injected.
        public var injectionAreaRatio: Double
        /// Its temperature there, K.
        public var temperature: Double

        public init(massFraction: Double, injectionAreaRatio: Double, temperature: Double) {
            self.massFraction = massFraction
            self.injectionAreaRatio = injectionAreaRatio
            self.temperature = temperature
        }
    }

    public var family: Family
    /// Nozzle stagnation pressure at the rated flow, Pa (it scales with the
    /// flow: a choked throat).
    public var chamberPressure: Double
    /// Exit to throat area.
    public var areaRatio: Double
    /// Exit radius, m, and the nozzle lip's half-angle, rad.
    public var exitRadius: Double
    public var lipHalfAngle: Double
    /// The gas at the exit: ratio of specific heats and molar mass (kg/mol).
    public var exitGamma: Double
    public var molarMass: Double
    /// Chamber and exit temperatures, K.
    public var chamberTemperature: Double
    public var exitTemperature: Double
    /// Mole fraction of CO and H2 at the exit, which afterburns in air.
    public var fuelRichFraction: Double
    /// 0 (none) to 1 (kerosene's dense soot): how sooty the plume is.
    public var sootIndex: Double
    /// Mass fraction of Al2O3 in the exhaust (aluminised solids).
    public var aluminaFraction: Double
    public var film: Film?
    /// Where the values come from, and how sure they are.
    public var source: String
    public var grade: String

    public init(family: Family, chamberPressure: Double, areaRatio: Double, exitRadius: Double, lipHalfAngle: Double,
                exitGamma: Double, molarMass: Double, chamberTemperature: Double, exitTemperature: Double,
                fuelRichFraction: Double = 0, sootIndex: Double = 0, aluminaFraction: Double = 0, film: Film? = nil,
                source: String, grade: String) {
        self.family = family
        self.chamberPressure = chamberPressure
        self.areaRatio = areaRatio
        self.exitRadius = exitRadius
        self.lipHalfAngle = lipHalfAngle
        self.exitGamma = exitGamma
        self.molarMass = molarMass
        self.chamberTemperature = chamberTemperature
        self.exitTemperature = exitTemperature
        self.fuelRichFraction = fuelRichFraction
        self.sootIndex = sootIndex
        self.aluminaFraction = aluminaFraction
        self.film = film
        self.source = source
        self.grade = grade
    }
}

/// The exhaust of each thruster the plume model draws, keyed by the part's
/// and thruster's names as the dresser keys its shapes ("S-IC engine n",
/// "SPS", "SM RCS A1", "S-IC retro motor n"...), so that neither the
/// components nor the vehicle data change. Empty so far: the exhaust
/// physics track fills it, from its datasheet and CEA runs.
public enum ExhaustLibrary {
    /// The exhaust of `thruster` on `part`; nil for one the library does
    /// not know, which draws no plume of its own.
    public static func spec(for thruster: Thruster, in part: VesselPart) -> ExhaustSpec? {
        specs[thruster.name]
    }

    /// The specs by thruster name.
    static let specs: [String: ExhaustSpec] = [:]
}
