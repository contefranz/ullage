import Foundation

/// The local horizon at a point: north, east and up, unit vectors in ICRF.
/// The navball, its heading/pitch/roll and its markers are read in it.
///
/// - `geodetic`: up is the reference body's figure normal (WGS 84 on the
///   Earth), as the HUD altitude, the camera horizon and the pad use; the
///   Saturn's axis on the pad reads exactly 90°.
/// - `geocentric`: up is the radius, as Apollo's trajectory listings give
///   flight-path angle and heading (FER Table 4-2, PFT Table B-II).
///
/// The two differ by the deviation of the vertical, 0.16° at LC-39A.
public struct LocalHorizon: Equatable {
    public let north: Vec3
    public let east: Vec3
    public let up: Vec3

    /// The horizon about `up`, north towards `pole`: east = (pole × up)̂,
    /// north = up × east. Where up lies along the pole, north is
    /// `fallbackNorth` made horizontal.
    public init(up: Vec3, pole: Vec3, fallbackNorth: Vec3) {
        let u = up.normalized
        let e = pole.cross(u)
        if e.length > 1e-9 {
            east = e.normalized
            north = u.cross(east)
        } else {
            var n = fallbackNorth - u * fallbackNorth.dot(u)
            if n.length < 1e-9 { n = Vec3.unitY - u * u.y }
            north = n.normalized
            east = north.cross(u)
        }
        self.up = u
    }

    /// The geodetic horizon at `r` (ICRF, from the body's centre): up along
    /// the figure's normal through `r`. At a pole, north is the prime
    /// meridian's direction.
    public static func geodetic(at r: Vec3, body: CelestialBody, orientation o: BodyOrientation) -> LocalHorizon {
        LocalHorizon(up: body.vertical(at: r, orientation: o), pole: o.pole, fallbackNorth: o.toInertial(.unitX))
    }

    /// The geocentric horizon at `r`: up along the radius, north towards
    /// `pole` (the body's spin axis in the frame of `r`).
    public static func geocentric(at r: Vec3, pole: Vec3) -> LocalHorizon {
        LocalHorizon(up: r, pole: pole, fallbackNorth: .unitX)
    }

    /// North-east-down axes -> ICRF: its columns are north, east and -up.
    public var nedToInertial: Mat3 { Mat3(columns: north, east, -up) }

    /// Elevation above the horizon (-π/2...π/2) and azimuth from north
    /// through east (0..<2π) of the direction `d`, rad.
    public func elevationAzimuth(of d: Vec3) -> (elevation: Double, azimuth: Double) {
        let u = d.normalized
        let az = atan2(u.dot(east), u.dot(north))
        return (asin(max(-1, min(1, u.dot(up)))), az < 0 ? az + 2 * .pi : az)
    }

    /// The unit direction at `elevation` and `azimuth`, rad.
    public func direction(elevation: Double, azimuth: Double) -> Vec3 {
        (north * cos(azimuth) + east * sin(azimuth)) * cos(elevation) + up * sin(elevation)
    }
}

/// An attitude as heading, pitch and roll (rad): the aerospace 3-2-1
/// sequence from north-east-down to the body axes (+x nose, +y right, +z
/// down), an aircraft's. Heading is in 0..<2π, pitch in -π/2...π/2 (positive
/// nose above the horizon) and roll in -π...π (positive right wing down).
///
/// With the nose straight up or down only heading less roll is defined;
/// there the angles read the head's (-z) convention: roll 0 and the heading
/// the azimuth the head faces. In crew axes (`Vessel.controlFrame`) the
/// Saturn on the pad reads heading 090, pitch 90, roll 0 (its crew's heads
/// east, Position I), and once the roll program has turned it, 072.058;
/// pitched over towards the head, it reads roll 180, heads down.
public struct HorizonAttitude: Equatable {
    public var heading: Double
    public var pitch: Double
    public var roll: Double

    /// Below this cos(pitch) the nose counts as vertical.
    static let vertical = 1e-9

    public init(heading: Double, pitch: Double, roll: Double) {
        self.heading = heading
        self.pitch = pitch
        self.roll = roll
    }

    /// The angles of the body -> NED matrix `c`.
    public init(bodyToNED c: Mat3) {
        let cosPitch = hypot(c[0, 0], c[1, 0])
        pitch = atan2(-c[2, 0], cosPitch)
        if cosPitch < Self.vertical {
            roll = 0
            heading = atan2(-c[1, 2], -c[0, 2])
        } else {
            roll = atan2(c[2, 1], c[2, 2])
            heading = atan2(c[1, 0], c[0, 0])
        }
        if heading < 0 { heading += 2 * .pi }
    }

    /// The angles of `attitude` (body -> ICRF) in `horizon`.
    public init(attitude: Quat, in horizon: LocalHorizon) {
        self.init(bodyToNED: horizon.nedToInertial.transposed * attitude.matrix)
    }

    /// Body -> NED: Rz(heading) Ry(pitch) Rx(roll), active rotations. With
    /// the nose vertical, the head faces the heading, as the angles read.
    public var bodyToNED: Mat3 {
        let headUp = cos(pitch) < Self.vertical && pitch > 0
        return Mat3.rotZ(heading) * Mat3.rotY(pitch) * Mat3.rotX(roll + (headUp ? .pi : 0))
    }

    /// The attitude (body -> ICRF) with these angles in `horizon`.
    public func attitude(in horizon: LocalHorizon) -> Quat {
        Quat(matrix: horizon.nedToInertial * bodyToNED)
    }
}
