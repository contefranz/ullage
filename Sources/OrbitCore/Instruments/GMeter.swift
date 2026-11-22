import Foundation

/// The command module's G-meter ("ACCEL G", on MDC-1 above the commander's
/// FDAI), read from a vessel's `sensedAcceleration`: what an accelerometer
/// at the centre of mass senses, the aerodynamic, parachute and thrust forces
/// over the mass, and on the ground the support that holds the vessel. So it
/// reads 1 g on the pad, about 0 coasting above the air, thrust over the
/// falling mass in powered flight, and the deceleration of an entry.
///
/// Like the real meter, a mechanical accelerometer of its own along the
/// spacecraft's X axis (AOH SM2A-03-Block II-(1), p. 3-53), it shows the
/// acceleration along the vehicle's axis, body +x (the CM's X axis, apex
/// forward): positive when it pushes the crew into their couches, as thrust
/// does at launch and the heat shield's drag does in an entry. Its dial runs
/// from −1 to +15 g, 15° per g clockwise with 0 g at 9 o'clock, 6 g at 12
/// and 12 g at 3 (AOH Fig. 3-1; SA-506 Flight Manual Fig. 3-1), and its
/// single pointer stops at the ends. It has no peak pointers. The total, the
/// magnitude of the sensed acceleration in any direction, is the HUD's
/// addition.
public struct GMeter: Equatable {
    /// The dial's range, g.
    public static let scale: ClosedRange<Double> = -1...15
    /// The dial's turn per g, rad.
    public static let anglePerG = 15 * Double.pi / 180

    /// Sensed acceleration along +x, g (standard gravity, 9.80665 m/s²).
    public let axial: Double
    /// Magnitude of the sensed acceleration, g.
    public let total: Double

    /// The meter reading a sensed acceleration (body axes, m/s²).
    public init(sensedAcceleration a: Vec3 = .zero) {
        axial = a.x / standardGravity
        total = a.length / standardGravity
    }

    /// The meter reading `v`'s accelerometer.
    public init(vessel v: Vessel) { self.init(sensedAcceleration: v.sensedAcceleration) }

    /// Where the pointer stands, g: `axial`, held at the dial's stops.
    public var pointer: Double { Self.onDial(axial) }

    /// `g` held at the dial's stops.
    public static func onDial(_ g: Double) -> Double { min(max(g, scale.lowerBound), scale.upperBound) }

    /// Where a reading of `g` sits on the dial: rad, counterclockwise from 3
    /// o'clock (π at 0 g, π/2 at 6 g, 0 at 12 g), held at the stops.
    public static func dialAngle(_ g: Double) -> Double { Double.pi - onDial(g) * anglePerG }
}
