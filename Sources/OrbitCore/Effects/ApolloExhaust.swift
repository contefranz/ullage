import Foundation

/// The exhaust of every Apollo engine family, for the plume model: chamber
/// pressure, nozzle and gas from docs/exhaust-datasheet.md, whose gas comes
/// from the NASA CEA runs in tools/data/cea_apollo_exhaust.csv (frozen at the
/// throat for the liquids, shifting equilibrium for the solids; the
/// `ExhaustSpecTests` check these literals against the table). Nozzle exits
/// that the dresser draws take its own dimensions, so the plumes leave the
/// drawn bells. None of it feeds thrust or flow.
public enum ApolloExhaust {
    /// An engine family: its exhaust, and the propellant flow (kg/s) at
    /// which `spec.chamberPressure` holds. A choked throat makes the chamber
    /// pressure proportional to the flow, so a thruster's pressure is the
    /// spec's times `Thruster.massFlow / ratedFlow`: start and shutdown
    /// ramps, and the J-2's mixture-ratio steps, scale it.
    public struct Engine {
        public let spec: ExhaustSpec
        public let ratedFlow: Double
    }

    typealias D = AS506
    typealias C = ApolloCSM
    static let psi = 6_894.757293168          // Pa
    static let degree = Double.pi / 180

    /// The F-1: 982 psia nozzle stagnation at the rated 5,737 lb/s (Betts,
    /// NTRS 20140011656, H), the thrust chamber at o/f 2.404 (the engine's
    /// 2.27 without its gas generator's 167 lb/s at 0.416: M), 16:1. Its
    /// turbine exhaust, 2.9 % of the flow at about 887 K (1,138°F) after the
    /// heat exchanger, enters the nozzle extension at 10:1 as a fuel-rich
    /// film (R-3896-1 through a search extract: M), the dark sheath under
    /// the exit that AS-501 to 503's films show burning about three-fourths
    /// of a nozzle diameter downstream (D5-15796-1 §4.1.1, H).
    public static let f1 = Engine(
        spec: ExhaustSpec(family: .keroseneLOX, chamberPressure: 982 * psi, areaRatio: 16,
                          exitRadius: (D.f1ExitArea / Double.pi).squareRoot(), lipHalfAngle: 8 * degree,
                          exitGamma: 1.2330, molarMass: 0.023037, chamberTemperature: 3_615.69,
                          exitTemperature: 1_469.49, fuelRichFraction: 0.44871, sootIndex: 1,
                          film: .init(massFraction: 167.0 / 5_737, injectionAreaRatio: 10, temperature: 887),
                          source: "exhaust datasheet §2.1; CEA row F-1", grade: "M"),
        ratedFlow: 5_737 * D.pound)

    /// The J-2: 763 psia at the rated o/f 5.5 and 230,000 lbf at 425 s
    /// (Purdue's table through a search extract, M), 27.5:1. AS-506's S-II
    /// ran it at 5.0, 5.5 and 4.34, its S-IVB at about 4.96: the spec is
    /// the rated chemistry and the pressure follows the flow.
    public static let j2 = Engine(
        spec: ExhaustSpec(family: .hydrogenLOX, chamberPressure: 763 * psi, areaRatio: D.j2AreaRatio,
                          exitRadius: (D.j2ExitArea / Double.pi).squareRoot(), lipHalfAngle: 8 * degree,
                          exitGamma: 1.2338, molarMass: 0.012755, chamberTemperature: 3_372.93,
                          exitTemperature: 1_194.49, fuelRichFraction: 0.30025,
                          source: "exhaust datasheet §2.2; CEA row J-2", grade: "M"),
        ratedFlow: 230_000 * D.poundForce / (425 * standardGravity))

    /// The SPS: Aerozine 50 and N2O4 at o/f 1.6, 100 psia, 62.5:1 (AOH
    /// Vol. 1 pp. 2.4-1 and 2.4-43, H), at 68-FM-184's 67.49 lb/s.
    public static let sps = Engine(
        spec: ExhaustSpec(family: .hypergolic, chamberPressure: 100 * psi, areaRatio: ApolloShapeData.spsAreaRatio,
                          exitRadius: ApolloShapeData.spsExitDiameter / 2 * C.inch, lipHalfAngle: 8 * degree,
                          exitGamma: 1.2759, molarMass: 0.020764, chamberTemperature: 3_051.54,
                          exitTemperature: 721.05, fuelRichFraction: 0.23071,
                          source: "exhaust datasheet §2.3; CEA row SPS", grade: "M"),
        ratedFlow: C.spsThrust * C.poundForce / (C.spsIsp * standardGravity))

    /// An SM RCS R-4D: MMH and N2O4 at o/f 2.0, 90 psia (Marquardt's
    /// reference engine, NTRS 19690029231: M), 40:1 through a 5.6 in exit
    /// (AOH Vol. 1 p. 2.5-24, H), at the model's flow for 99.8 lbf.
    public static let smRCS = Engine(
        spec: ExhaustSpec(family: .hypergolic, chamberPressure: 90 * psi, areaRatio: 40,
                          exitRadius: ApolloShapeData.rcsExitDiameter / 2 * C.inch, lipHalfAngle: 10 * degree,
                          exitGamma: 1.2634, molarMass: 0.022052, chamberTemperature: 3_120.88,
                          exitTemperature: 893.10, fuelRichFraction: 0.18933,
                          source: "exhaust datasheet §2.4; CEA row SM RCS", grade: "M"),
        ratedFlow: C.rcsFourJetThrust / 4 * C.poundForce / (C.rcsIsp * standardGravity))

    /// A CM RCS SE-8: MMH and N2O4 at o/f 2.0, 9:1 through a 2.13 in exit
    /// (AOH Vol. 1 p. 2.5-47, H); 139 psia, the pressure CEA's thrust
    /// coefficient needs for its 93 lbf (derived, M).
    public static let cmRCS = Engine(
        spec: ExhaustSpec(family: .hypergolic, chamberPressure: 139 * psi, areaRatio: 9,
                          exitRadius: 2.13 / 2 * C.inch, lipHalfAngle: 15 * degree,
                          exitGamma: 1.2471, molarMass: 0.022132, chamberTemperature: 3_165.98,
                          exitTemperature: 1_433.80, fuelRichFraction: 0.18777,
                          source: "exhaust datasheet §2.5; CEA row CM RCS", grade: "M"),
        ratedFlow: ApolloCM.rcsThrust * C.poundForce / (ApolloCM.rcsIsp * standardGravity))

    /// An S-IVB APS attitude engine (TRW TR-204, 147 lbf): MMH and N2O4 at
    /// o/f 1.6 and its nominal 100 psia (AS-501 FER §7.12, H), at a guessed
    /// 40:1 whose exit the thrust then sizes (L).
    public static let apsAttitude = Engine(
        spec: ExhaustSpec(family: .hypergolic, chamberPressure: 100 * psi, areaRatio: 40,
                          exitRadius: 6.427 / 2 * D.inch, lipHalfAngle: 15 * degree,
                          exitGamma: 1.2780, molarMass: 0.020331, chamberTemperature: 3_003.90,
                          exitTemperature: 794.05, fuelRichFraction: 0.30372,
                          source: "exhaust datasheet §2.6; CEA row APS attitude", grade: "L"),
        ratedFlow: D.apsAttitudeThrust * D.poundForce / (D.apsAttitudeIsp * standardGravity))

    /// An S-IVB APS ullage engine (Rocketdyne SE-7-1, 72 lbf): as the
    /// attitude engines, at a guessed 9:1 (L).
    public static let apsUllage = Engine(
        spec: ExhaustSpec(family: .hypergolic, chamberPressure: 100 * psi, areaRatio: 9,
                          exitRadius: 2.211 / 2 * D.inch, lipHalfAngle: 15 * degree,
                          exitGamma: 1.2612, molarMass: 0.020331, chamberTemperature: 3_003.90,
                          exitTemperature: 1_286.53, fuelRichFraction: 0.30372,
                          source: "exhaust datasheet §2.6; CEA row APS ullage", grade: "L"),
        ratedFlow: D.apsUllageThrust * D.poundForce / (D.apsUllageIsp * standardGravity))

    /// The LES tower jettison motor (Thiokol TE-380): TP-E-8104,
    /// polysulfide and ammonium perchlorate with 2 % aluminium, 1,330 psia
    /// over its web burn, each of its two 10° conical nozzles 14:1 from a
    /// 10.18 in² throat (TN D-6295, H). One nozzle's exit: the model's one
    /// thruster stands for both.
    public static let towerJettison = Engine(
        spec: ExhaustSpec(family: .solidOther, chamberPressure: 1_330 * psi, areaRatio: 14,
                          exitRadius: 13.471 / 2 * D.inch, lipHalfAngle: 10 * degree,
                          exitGamma: 1.1739, molarMass: 0.029220, chamberTemperature: 2_708.35,
                          exitTemperature: 1_394.94, fuelRichFraction: 0.13479, aluminaFraction: 0.03779,
                          source: "exhaust datasheet §2.7; CEA row Tower jettison", grade: "M"),
        ratedFlow: D.towerJettisonPropellant / D.towerJettisonBurnTime)

    /// An S-IC retro (Thiokol TE-M-424): polysulfide and ammonium
    /// perchlorate (MSFC-MAN-503, H; TP-E-8104 standing in, L) at Thiokol's
    /// nominal 1,650 psia (AS-501 FER §12.2.1, H); its 4.5:1 exit sized at
    /// 0.9 of the 15.25 in case (L).
    public static let sICRetro = Engine(
        spec: ExhaustSpec(family: .solidOther, chamberPressure: 1_650 * psi, areaRatio: 4.5,
                          exitRadius: 13.580 / 2 * D.inch, lipHalfAngle: 15 * degree,
                          exitGamma: 1.1729, molarMass: 0.028843, chamberTemperature: 2_716.41,
                          exitTemperature: 1_724.72, fuelRichFraction: 0.16749, aluminaFraction: 0.03778,
                          source: "exhaust datasheet §2.8; CEA row S-IC retro", grade: "L"),
        ratedFlow: D.sICRetroPropellant / 8 / D.sICRetroBurnTime)

    /// An S-II ullage motor: 82 % ammonium perchlorate (MSFC-MAN-503, H; the
    /// rest TP-E-8104's other ingredients, L) at 999 psia (AS-501 FER Table
    /// 12-3, H); its 7.5:1 exit sized at 0.9 of the 12.5 in case (L).
    public static let sIIUllage = Engine(
        spec: ExhaustSpec(family: .solidOther, chamberPressure: 999 * psi, areaRatio: 7.5,
                          exitRadius: 11.274 / 2 * D.inch, lipHalfAngle: 15 * degree,
                          exitGamma: 1.1617, molarMass: 0.030538, chamberTemperature: 2_947.16,
                          exitTemperature: 1_801.70, fuelRichFraction: 0.00045, aluminaFraction: 0.02429,
                          source: "exhaust datasheet §2.8; CEA row S-II ullage", grade: "L"),
        ratedFlow: D.sIIUllageMotorPropellant / 4 / D.sIIUllageMotorBurnTime)

    /// An S-II retro (Thiokol TE-M-29): TP-E-8104 standing in (L) at 1,761
    /// psia (AS-501 FER Table 12-4, H); its 4.3:1 exit sized at 0.9 of the
    /// 9 in case (L).
    public static let sIIRetro = Engine(
        spec: ExhaustSpec(family: .solidOther, chamberPressure: 1_761 * psi, areaRatio: 4.3,
                          exitRadius: 8.148 / 2 * D.inch, lipHalfAngle: 15 * degree,
                          exitGamma: 1.1728, molarMass: 0.028836, chamberTemperature: 2_718.84,
                          exitTemperature: 1_741.12, fuelRichFraction: 0.16822, aluminaFraction: 0.03778,
                          source: "exhaust datasheet §2.8; CEA row S-II retro", grade: "L"),
        ratedFlow: D.sIIRetroPropellant / 4 / D.sIIRetroBurnTime)

    /// An S-IVB ullage motor (Thiokol TX-280): TP-E-8104 standing in (L) at
    /// 980 psia (AS-501 FER Table 12-5, H); its 16:1 exit sized at 0.9 of an
    /// inferred 7 in case (L).
    public static let sIVBUllage = Engine(
        spec: ExhaustSpec(family: .solidOther, chamberPressure: 980 * psi, areaRatio: 16,
                          exitRadius: 6.222 / 2 * D.inch, lipHalfAngle: 15 * degree,
                          exitGamma: 1.1733, molarMass: 0.029227, chamberTemperature: 2_696.89,
                          exitTemperature: 1_360.35, fuelRichFraction: 0.13395, aluminaFraction: 0.03779,
                          source: "exhaust datasheet §2.8; CEA row S-IVB ullage", grade: "L"),
        ratedFlow: D.sIVBUllageMotorPropellant / 2 / D.sIVBUllageMotorBurnTime)

    /// Every family, by its row in tools/data/cea_apollo_exhaust.csv.
    static let byTableRow: [String: Engine] = [
        "F-1": f1, "J-2": j2, "SPS": sps, "SM RCS": smRCS, "CM RCS": cmRCS, "APS attitude": apsAttitude,
        "APS ullage": apsUllage, "Tower jettison": towerJettison, "S-IC retro": sICRetro,
        "S-II ullage": sIIUllage, "S-II retro": sIIRetro, "S-IVB ullage": sIVBUllage,
    ]

    /// The engine of thruster `thruster` on part `part`, by the names the
    /// vehicle builders give them ("S-IC engine 1", "S-IVB engine", "S-IC
    /// retro motor 3", "Tower jettison motor", "SPS", "SM RCS A1", "CM RCS
    /// 3B", "APS I pitch", "APS III ullage"...); nil for one it does not
    /// know (the M0 test vehicles').
    public static func engine(thruster: String, part: String) -> Engine? {
        if thruster.hasPrefix("S-IC engine") { return f1 }
        if thruster.hasPrefix("S-II engine") || thruster == "S-IVB engine" { return j2 }
        if thruster == "SPS" { return sps }
        if thruster.hasPrefix("SM RCS") { return smRCS }
        if thruster.hasPrefix("CM RCS") { return cmRCS }
        if thruster.hasPrefix("APS ") { return thruster.hasSuffix(" ullage") ? apsUllage : apsAttitude }
        if thruster == "Tower jettison motor" { return towerJettison }
        if thruster.hasPrefix("S-IC retro motor") { return sICRetro }
        if thruster.hasPrefix("S-II ullage motor") { return sIIUllage }
        if thruster.hasPrefix("S-II retro motor") { return sIIRetro }
        if thruster.hasPrefix("S-IVB ullage motor") { return sIVBUllage }
        return nil
    }

    /// `engine(thruster:part:)` for a thruster on its part.
    public static func engine(for thruster: Thruster, in part: VesselPart) -> Engine? {
        engine(thruster: thruster.name, part: part.name)
    }
}
