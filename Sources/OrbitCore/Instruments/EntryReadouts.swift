import Foundation

/// The entry instruments the HUD shows for a vessel, from its entry
/// telemetry (`Vessel.sensedAcceleration` ... `heatLoad`) and the command
/// module's entry program and earth landing system when it carries them:
/// the g meter, the bank angle, the heating, the ELS and the EMS's 0.05 g
/// light.
public struct EntryReadouts: Equatable {
    /// Sensed load factor, g, and the highest the entry program has sensed
    /// since it woke (nil without one), this step's included (the program
    /// reads the load at the start of a step, the telemetry at its end).
    public var loadFactor: Double
    public var peakLoadFactor: Double?
    /// Bank angle about the air velocity, rad (0 lift up, positive right);
    /// nil without a capsule model.
    public var bankAngle: Double?
    /// Stagnation-point heat flux (W/m²) and its integral (J/m²).
    public var heatFlux: Double
    public var heatLoad: Double
    /// The 0.05 g light: the entry program's, latched from the moment it
    /// sensed 0.05 g; without one, lit while the vessel senses 0.05 g coming
    /// down unpowered.
    public var pointZeroFiveG: Bool
    /// The earth landing system's state ("ELS armed", "ELS drogues reefed
    /// 1" ...); nil without one.
    public var landingSystem: String?

    /// Height below which a vessel coming down unpowered is entering, m (the
    /// ENTRY page's trace starts there too).
    public static let ceiling = 130_000.0
    /// The EMS's threshold, g.
    public static let entryLoadFactor = CMEntryProgram.entryLoadFactor

    /// The readouts for `v`, or nil when they do not matter: shown while it
    /// flies a capsule model (the command module free of the service
    /// module), or while it comes down unpowered below `ceiling` sensing
    /// 0.05 g or more (any vessel's entry).
    public init?(vessel v: Vessel) {
        let capsule = v.activeAerodynamics?.capsule != nil
        let entering = Self.isEntering(v)
        guard capsule || entering else { return nil }
        let program = ApolloMission.entryProgram(of: v)
        loadFactor = v.loadFactor
        peakLoadFactor = program.flatMap { $0.phase == .dormant ? nil : max($0.peakLoadFactor, v.loadFactor) }
        bankAngle = v.bankAngle
        heatFlux = v.heatFlux
        heatLoad = v.heatLoad
        if let p = program, p.phase != .dormant {
            pointZeroFiveG = p.pointZeroFiveG != nil
        } else {
            pointZeroFiveG = entering
        }
        landingSystem = ApolloMission.landingSystem(of: v)?.status
    }

    /// `v` comes down unpowered through the air below `ceiling` sensing at
    /// least 0.05 g.
    public static func isEntering(_ v: Vessel) -> Bool {
        v.landed == nil && v.altitude < ceiling && v.position.dot(v.velocity) < 0
            && v.thrustAcceleration < 0.01 * 9.80665 && v.loadFactor >= entryLoadFactor
    }
}
