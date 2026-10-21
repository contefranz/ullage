import Foundation
import OrbitCore

/// How an exhaust looks, from the propellant (the feed's tank names) and
/// `isSolid`. The plume tracks refine it with `ExhaustSpec`; this is the
/// M1.5 renderer's classification.
public enum PlumeStyle: Equatable, Hashable {
    /// LOX/RP-1: bright orange, a dark fuel-rich core under the exit.
    case kerosene
    /// LOX/LH2: faint and bluish.
    case hydrogen
    /// Solid motors (retros, ullage, tower jettison): white-yellow.
    case solid
    /// N2O4 with a hydrazine (SPS, RCS, APS): faint orange-pink.
    case hypergolic

    public init(_ t: Thruster) {
        if t.isSolid { self = .solid; return }
        let names = (t.feed?.tanks ?? []).map { $0.name.uppercased() }
        if names.contains(where: { $0.contains("RP-1") || $0.contains("RP1") || $0.contains("KEROSENE") }) {
            self = .kerosene
            return
        }
        if names.contains(where: { $0.contains("LH2") || $0.contains("HYDROGEN") }) {
            self = .hydrogen
            return
        }
        let hypergols = ["N2O4", "MMH", "UDMH", "AEROZINE", "A-50", "HYPERGOL"]
        if names.contains(where: { name in hypergols.contains { name.contains($0) } }) {
            self = .hypergolic
            return
        }
        // The M0 test vehicles' generic "propellant": kerosene-like boosters,
        // hypergolic-like service-module engines and attitude jets.
        if names.contains(where: { $0.contains("RCS") || $0.contains("SPS") || $0.hasPrefix("SM ") })
            || !t.groups.contains(.main) {
            self = .hypergolic
            return
        }
        self = .kerosene
    }

    /// A nominal exit radius (m) for a jet with no nozzle shape, from its
    /// vacuum thrust (N): 0.0095 ∛F fits the F-1 (1.79 m), the J-2 (0.98 m)
    /// and the R-4D (about 0.07 m) within 10 %; solids' nozzles are smaller.
    public static func nominalExitRadius(thrust: Double, solid: Bool) -> Double {
        0.0095 * cbrt(max(thrust, 1)) * (solid ? 0.8 : 1)
    }
}
