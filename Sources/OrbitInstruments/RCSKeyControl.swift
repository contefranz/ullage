import OrbitCore

/// The RCS keys as pulse controls. A tap fires one pulse; a key still down
/// after `holdDelay` fires continuously until it goes up. With Control held
/// both are fine: the pulse is the jets' minimum impulse and the continuous
/// firing a tenth of full thrust, for docking-scale corrections (Orbiter's
/// fine RCS is Control as well; Shift belongs to the MFDs).
///
/// A tap's pulse is timed in simulation time (`Vessel.firePilotPulse`), so
/// it gives the same impulse at any time warp. The hold is timed in real
/// time, as the pilot feels it.
public struct RCSKeyControl {
    /// Real time a key must stay down before it fires continuously, s. A
    /// shorter tap fires only its pulse.
    public static let holdDelay = 0.25
    /// Simulation time a tap fires at full thrust, s.
    public static let pulse = 0.1
    /// Simulation time a fine (Control) tap fires at full thrust, s: the
    /// Apollo RCS jets' minimum impulse, as the CSM's phase-plane pulses
    /// (`ApolloCSM.phasePlaneLaw`, 14 ms).
    public static let finePulse = 0.014
    /// Level of a fine (Control) continuous firing: a tenth of full thrust.
    public static let fineLevel = 0.1

    /// Keys by axis, (plus, minus), as `AppModel` reads them: roll E/Q,
    /// pitch S/W, yaw D/A; translation x U/O, y L/J, z K/I.
    public static let rotationKeys: [(plus: PhysicalKey, minus: PhysicalKey)] = [(.e, .q), (.s, .w), (.d, .a)]
    public static let translationKeys: [(plus: PhysicalKey, minus: PhysicalKey)] = [(.u, .o), (.l, .j), (.k, .i)]

    /// One tap's pulse, pilot axes: a unit command on one axis.
    public struct Pulse: Equatable {
        public var rotation: RotationCommand
        public var translation: Vec3
        public var duration: Double
    }

    /// What a frame commands: the pulses of the keys that went down, and the
    /// continuous commands of the keys held past `holdDelay` (pilot axes).
    public struct Output: Equatable {
        public var pulses: [Pulse] = []
        public var rotation = RotationCommand()
        public var translation = Vec3.zero
    }

    /// Real time each RCS key went down, s.
    private var downSince: [PhysicalKey: Double] = [:]

    public init() {}

    /// One frame. `pressed`: keys that went down since the last frame, in
    /// order; `isHeld`: which keys are down now; `fine`: whether Control is
    /// down; `now`: real time, s.
    public mutating func update(pressed: [PhysicalKey], isHeld: (PhysicalKey) -> Bool, fine: Bool,
                                now: Double) -> Output {
        var out = Output()
        let duration = fine ? Self.finePulse : Self.pulse
        for key in pressed {
            guard let (axis, sign, rotational) = Self.axis(of: key) else { continue }
            downSince[key] = now
            var unit = Vec3.zero
            switch axis {
            case 0: unit.x = sign
            case 1: unit.y = sign
            default: unit.z = sign
            }
            out.pulses.append(rotational
                ? Pulse(rotation: RotationCommand(roll: unit.x, pitch: unit.y, yaw: unit.z), translation: .zero,
                        duration: duration)
                : Pulse(rotation: RotationCommand(), translation: unit, duration: duration))
        }
        // Forget keys that went up; a key found down without its press seen
        // (held across a focus change) counts from now.
        for key in downSince.keys where !isHeld(key) { downSince[key] = nil }
        let level = fine ? Self.fineLevel : 1
        func held(_ key: PhysicalKey) -> Double {
            guard isHeld(key) else { return 0 }
            let since = downSince[key] ?? now
            downSince[key] = since
            return now - since >= Self.holdDelay ? level : 0
        }
        var r = [0.0, 0.0, 0.0], t = [0.0, 0.0, 0.0]
        for (i, k) in Self.rotationKeys.enumerated() { r[i] = held(k.plus) - held(k.minus) }
        for (i, k) in Self.translationKeys.enumerated() { t[i] = held(k.plus) - held(k.minus) }
        out.rotation = RotationCommand(roll: r[0], pitch: r[1], yaw: r[2])
        out.translation = Vec3(t[0], t[1], t[2])
        return out
    }

    /// The axis (0, 1, 2), its sign and whether it is a rotation, for an RCS key.
    static func axis(of key: PhysicalKey) -> (Int, Double, Bool)? {
        for (i, k) in rotationKeys.enumerated() {
            if key == k.plus { return (i, 1, true) }
            if key == k.minus { return (i, -1, true) }
        }
        for (i, k) in translationKeys.enumerated() {
            if key == k.plus { return (i, 1, false) }
            if key == k.minus { return (i, -1, false) }
        }
        return nil
    }
}
