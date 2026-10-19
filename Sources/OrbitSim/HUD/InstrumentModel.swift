import Foundation
import Combine
import OrbitCore
import OrbitInstruments

/// What the flight instruments show, refreshed every frame (`update`, from
/// `AppModel.tick`) and pulled by the navball's Metal view and the cluster's
/// timeline, so the ball and the tapes move in step with the scene. Only the
/// HUD's visibility is published.
@MainActor
final class InstrumentModel: ObservableObject {
    /// F2 (or the key left of 1) cycles them: everything, the instrument
    /// cluster alone, nothing (clean screenshots).
    enum Visibility: CaseIterable {
        case full, instruments, off
    }

    @Published private(set) var visibility = Visibility.full

    /// The speed mode the automatic rule gives (40/50 km); nil before the
    /// first update.
    private(set) var automaticFrame: VelocityFrame?
    /// The pilot's choice (N), kept until the automatic mode next changes.
    private(set) var override: VelocityFrame?
    /// The speed mode shown.
    var frame: VelocityFrame { override ?? automaticFrame ?? .orbit }

    private(set) var navball: Navball?
    private(set) var readouts = Readouts()

    /// The cluster's numbers besides the ball's.
    struct Readouts {
        var frame = VelocityFrame.orbit
        var automatic = true
        var speed = 0.0
        var altitude = 0.0
        var verticalSpeed = 0.0
        var apoapsisAltitude: Double?
        var periapsisAltitude: Double?
        var mach = 0.0
        var dynamicPressure = 0.0
        /// Commanded main throttle, 0...1.
        var throttle = 0.0
        var autopilot: AttitudeAutopilot?
        /// The flight program flies the attitude (the IU's command under the hold).
        var programSteers = false
        var landed = true
    }

    /// Forget the speed mode for a new scenario.
    func reset() {
        automaticFrame = nil
        override = nil
        navball = nil
    }

    /// Recompute the ball and the readouts for the focus vessel.
    func update(sim: Simulation) {
        guard let v = sim.focus else {
            navball = nil
            return
        }
        let snap = sim.snapshot
        let auto = Navball.autoFrame(previous: automaticFrame, vessel: v, snapshot: snap)
        if let previous = automaticFrame, previous != auto { override = nil }
        automaticFrame = auto
        let ball = Navball(vessel: v, in: sim, snapshot: snap, frame: frame)
        navball = ball

        var r = Readouts()
        r.frame = frame
        r.automatic = override == nil
        r.speed = ball.speed
        r.altitude = v.altitude
        r.verticalSpeed = ball.verticalSpeed
        if v.landed == nil {
            let el = v.elements(snapshot: snap)
            r.apoapsisAltitude = el.isBound ? el.apoapsisRadius - v.reference.radius : nil
            r.periapsisAltitude = el.periapsisRadius - v.reference.radius
        }
        r.mach = v.mach
        r.dynamicPressure = v.dynamicPressure
        r.throttle = v.mainThrottle
        r.autopilot = v.autopilot
        r.programSteers = v.flightProgram != nil && v.autopilot == .attitudeHold && v.attitudeCommand != nil
        r.landed = v.landed != nil
        readouts = r
    }

    /// Take `key` if it is the instruments' (N: speed mode; F2 or the key
    /// left of 1: HUD visibility). Returns true when taken.
    func handle(_ key: PhysicalKey, sim: Simulation) -> Bool {
        switch key {
        case .n:
            // The next mode; back on the automatic one, the override ends.
            let modes = VelocityFrame.allCases
            let next = modes[((modes.firstIndex(of: frame) ?? 0) + 1) % modes.count]
            override = next == automaticFrame ? nil : next
            update(sim: sim)
            return true
        case .f2, .grave, .isoSection:
            let all = Visibility.allCases
            visibility = all[((all.firstIndex(of: visibility) ?? 0) + 1) % all.count]
            return true
        default:
            return false
        }
    }
}
