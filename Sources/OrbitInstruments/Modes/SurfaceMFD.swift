import Foundation
import OrbitCore

/// SURFACE: flight data over the rotating body, for the pad, the ascent and
/// the end of entry. The navball is the attitude instrument, so this page is
/// numbers only:
/// - geodetic altitude and its rate (the speed along the normal);
/// - orbital (inertial), ground (over the rotating surface) and true air
///   speed, Mach and dynamic pressure;
/// - the flight-path angle over the ground and inertial, the course over the
///   ground, and the nose's heading, pitch and roll as the navball reads them;
/// - angle of attack, sensed and thrust acceleration;
/// - position and the air.
public final class SurfaceMFD: MFDMode {
    public init() {}

    public var id: MFDModeID { .surface }

    public func buttons(_ c: MFDContext?) -> [MFDButton?] { [] }

    static let left = 4, leftEnd = 18, right = 21, rightEnd = 35

    public func page(_ c: MFDContext) -> MFDPage {
        let v = c.vessel, s = c.snapshot, o = c.orientation
        var page = MFDPage(title: "SURFACE  " + c.body.name)
        var row = 2
        func pair(_ l1: String, _ v1: String, _ l2: String, _ v2: String, _ style: MFDStyle = .own) {
            page.field(Self.left, row, l1, v1, valueEnd: Self.leftEnd, style, labelStyle: .reference)
            page.field(Self.right, row, l2, v2, valueEnd: Self.rightEnd, style, labelStyle: .reference)
            row += 1
        }
        func gap() { row += 1 }

        let up = c.body.vertical(at: v.position, orientation: o)
        let ground = v.surfaceVelocity(snapshot: s)
        let ll = v.latitudeLongitude(snapshot: s)
        let ball = Navball(vessel: v, in: c.sim, snapshot: s, frame: .surface)
        let moving = ground.length > 0.5

        pair("ALT", MFDFormat.si(v.altitude), "VS", MFDFormat.fixed(v.velocity.dot(up), 1, signed: true))
        gap()
        pair("OS", MFDFormat.si(v.velocity.length), "GS", MFDFormat.si(ground.length))
        pair("TAS", MFDFormat.si(v.airspeed), "M", MFDFormat.fixed(v.mach, 2))
        pair("q", MFDFormat.si(v.dynamicPressure), "AoA",
             v.atmosphere.density > 0 && v.airspeed > 1 ? MFDFormat.degrees(v.angleOfAttack) : "---")
        gap()
        pair("FPA", moving ? MFDFormat.degrees(EntryInterface.flightPathAngle(position: v.position, velocity: ground),
                                               signed: true) : "---",
             "FPAi", MFDFormat.degrees(EntryInterface.flightPathAngle(position: v.position, velocity: v.velocity),
                                       signed: true))
        pair("CRS", moving ? MFDFormat.heading(EntryInterface.azimuth(position: v.position, velocity: ground,
                                                                      pole: o.pole)) : "---",
             "HDG", MFDFormat.heading(ball.angles.heading))
        pair("PIT", MFDFormat.degrees(ball.angles.pitch, signed: true),
             "RLL", MFDFormat.degrees(ball.angles.roll, signed: true))
        gap()
        pair("ACC", MFDFormat.fixed(v.loadFactor, 2) + "g",
             "THR", MFDFormat.fixed(v.thrustAcceleration / 9.80665, 2) + "g")
        gap()
        pair("LAT", MFDFormat.latitude(ll.lat), "LON", MFDFormat.longitude(ll.lon))
        gap()
        let air = v.atmosphere
        pair("RHO", air.density > 0 ? String(format: "%.3g", air.density) : "0",
             "P", MFDFormat.si(air.pressure))
        pair("OAT", air.density > 0 ? MFDFormat.fixed(air.temperature, 1) + "K" : "---",
             "SoS", air.density > 0 ? MFDFormat.fixed(air.speedOfSound, 1) : "---")

        page.add(4, 22, "SI: m, m/s, Pa, kg/m3", .referenceDim)
        return page
    }
}
