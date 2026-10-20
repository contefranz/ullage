import Foundation
import OrbitCore

/// The burn the crew has loaded for a vessel: DEORBIT's SET writes it with
/// the ΔV counter's load, CLR clears it (`MFDVesselData.maneuver`), and the
/// navball shows its direction as the manoeuvre marker until the counter
/// has counted it down (`isPending(on:)`).
public struct ActiveManeuver: Equatable {
    /// What the burn is, for the HUD ("DEORBIT").
    public var name: String
    /// When the pilot lights the engine (the centred ignition when the burn
    /// time is known, else the impulsive time).
    public var ignition: Epoch
    /// The burn's Δv, ICRF, m/s; its direction is where the thrust points.
    public var deltaV: Vec3
    /// Seconds on the engines planned, if known.
    public var burnTime: Double?

    public init(name: String, ignition: Epoch, deltaV: Vec3, burnTime: Double? = nil) {
        self.name = name
        self.ignition = ignition
        self.deltaV = deltaV
        self.burnTime = burnTime
    }

    /// The burn of a deorbit plan (B1's `DeorbitPlanner`).
    public init(deorbit plan: DeorbitPlanner.Plan) {
        self.init(name: "DEORBIT", ignition: plan.centredIgnition ?? plan.ignition, deltaV: plan.deltaV,
                  burnTime: plan.burnTime)
    }

    /// The thrust direction (ICRF).
    public var direction: Vec3 { deltaV.normalized }

    /// Below this Δv still to go (m/s) the counter has counted the burn
    /// down: the SPS cutoff leaves about 0.01 m/s, the tail-off then counts
    /// past zero.
    public static let doneBelow = 0.05

    /// Whether the burn is still to fly on `v`: its program's ΔV counter
    /// (`DeltaVCounting`) is loaded and has more than `doneBelow` to go.
    /// A vessel without a counter has no way to know, so the burn stands.
    public func isPending(on v: Vessel) -> Bool {
        guard let counter = v.flightProgram as? DeltaVCounting else { return true }
        return (counter.deltaVRemaining ?? 0) > Self.doneBelow
    }
}

extension MFDController {
    /// The burn loaded for `v` (DEORBIT's SET) while it is still to fly; nil
    /// otherwise.
    public func activeManeuver(for v: Vessel) -> ActiveManeuver? {
        guard let m = data(for: v).maneuver, m.isPending(on: v) else { return nil }
        return m
    }
}
