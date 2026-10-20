import Foundation

// MARK: - Vacuum coast

/// A coast in vacuum about one body: the two-body conic, or with the body's
/// J2 about a fixed pole, integrated by RK4 at 1/2000 of the local circular
/// period (2.6 s in low Earth orbit, metres per orbit). No drag and no third
/// bodies: over the hour or so before entry the Sun and Moon move a low orbit
/// by metres, J2 by kilometres.
public struct VacuumCoast {
    public let body: CelestialBody
    public let pole: Vec3
    /// Whether J2 acts (false when the body has none).
    public let j2: Bool

    public init(body: CelestialBody, pole: Vec3, j2: Bool = true) {
        self.body = body
        self.pole = pole.normalized
        self.j2 = j2 && body.j2 != 0
    }

    public func acceleration(at r: Vec3) -> Vec3 {
        if j2 { return body.gravity(at: r, pole: pole) }
        let r2 = r.lengthSquared
        return r * (-body.gm / (r2 * r2.squareRoot()))
    }

    /// The integration step at `s` (s).
    func stepSize(_ s: Kepler.State) -> Double {
        let r = s.position.length
        return 2 * Double.pi * (r * r * r / body.gm).squareRoot() / 2000
    }

    /// One step of `h` seconds: RK4 with J2, the exact conic without.
    func step(_ s: Kepler.State, _ h: Double) -> Kepler.State {
        guard j2 else { return Kepler.propagate(s, mu: body.gm, by: h) }
        let r = s.position, v = s.velocity
        let a1 = acceleration(at: r)
        let v2 = v + a1 * (h / 2), a2 = acceleration(at: r + v * (h / 2))
        let v3 = v + a2 * (h / 2), a3 = acceleration(at: r + v2 * (h / 2))
        let v4 = v + a3 * h, a4 = acceleration(at: r + v3 * h)
        return Kepler.State(position: r + (v + v2 * 2 + v3 * 2 + v4) * (h / 6),
                            velocity: v + (a1 + a2 * 2 + a3 * 2 + a4) * (h / 6))
    }

    /// The state `dt` seconds later (dt ≥ 0).
    public func propagate(_ s: Kepler.State, by dt: Double) -> Kepler.State {
        guard j2 else { return Kepler.propagate(s, mu: body.gm, by: dt) }
        var state = s, t = 0.0
        while t < dt {
            let h = min(stepSize(state), dt - t)
            state = step(state, h)
            t += h
        }
        return state
    }

    /// Height above the body's figure at `r` (m). The figure is symmetric
    /// about the pole, so the body's rotation does not enter.
    public func height(at r: Vec3) -> Double {
        let z = r.dot(pole)
        let rho = (r - pole * z).length
        return body.figure.geodetic(Vec3(rho, 0, z)).height
    }
}

// MARK: - Entry interface

/// Entry interface (EI): where a coasting trajectory first comes down
/// through 400,000 ft (121,920 m) above the figure, Apollo's start of entry,
/// predicted in vacuum (`VacuumCoast`, with J2 by default).
///
/// Flight-path angles and azimuths are in the geocentric horizontal, normal
/// to the radius, as Apollo's trajectory listings give them (and as
/// `Simulation.place` takes them); "relative" is to the rotating body.
public struct EntryInterface {
    /// 400,000 ft (m).
    public static let standardHeight = 121_920.0

    public let time: Epoch
    /// Seconds from the prediction's start to EI.
    public let timeFromStart: Double
    /// Position and velocity at EI (ICRF, relative to the body).
    public let state: Kepler.State
    /// Geodetic latitude and longitude at EI (rad), and the height (m).
    public let latitude: Double
    public let longitude: Double
    public let height: Double
    public let inertialSpeed: Double
    public let inertialFlightPathAngle: Double
    /// From north through east (rad, [0, 2π)).
    public let inertialAzimuth: Double
    public let relativeSpeed: Double
    public let relativeFlightPathAngle: Double
    public let relativeAzimuth: Double
    /// The angle the radius vector turns through from the start to EI
    /// (rad, can exceed π).
    public let sweptAngle: Double
    /// The ground track's length from the start's sub-point to EI's, on
    /// the figure's mean sphere (m).
    public let groundRange: Double

    /// Great-circle distance from EI's sub-point to geodetic `latitude`,
    /// `longitude` on a sphere of `radius` (m).
    public func range(toLatitude lat: Double, longitude lon: Double, radius: Double) -> Double {
        GreatCircle.distance(fromLatitude: latitude, longitude: longitude, toLatitude: lat, longitude: lon,
                             radius: radius)
    }

    /// The first descending crossing of `height` after `epoch` from `state`
    /// (ICRF, relative to `body`, oriented as `orientation` at `epoch`), within
    /// `duration` seconds: by default 1.1 orbital periods, or on an escape
    /// orbit twice the time to periapsis plus ten minutes. A trajectory that
    /// starts below `height` (an ascent) has to climb through it first. Nil if
    /// it does not come down through `height` in that time.
    public static func predict(from state: Kepler.State, around body: CelestialBody, orientation: BodyOrientation,
                               at epoch: Epoch, height: Double = standardHeight, j2: Bool = true,
                               within duration: Double? = nil) -> EntryInterface? {
        let coast = VacuumCoast(body: body, pole: orientation.pole, j2: j2)
        let el = OrbitalElements(position: state.position, velocity: state.velocity, mu: body.gm,
                                 pole: orientation.pole)
        // No conic dips this low (J2 moves a low perigee by about 10 km).
        if el.periapsisRadius > body.figure.equatorialRadius + height + 30_000 { return nil }
        let limit: Double
        if let duration {
            limit = duration
        } else if el.specificEnergy < 0 {
            // By energy, so a radial (e = 1) fall counts as bound too.
            let a = el.semiMajorAxis
            limit = 1.1 * 2 * Double.pi * (a * a * a / body.gm).squareRoot()
        } else {
            guard state.position.dot(state.velocity) < 0 else { return nil }
            limit = 2 * el.timeToPeriapsis + 600
        }

        let rate = orientation.angularVelocity.dot(orientation.pole)
        let meanRadius = GreatCircle.meanRadius(of: body.figure)
        func subPoint(_ r: Vec3, _ dt: Double) -> (latitude: Double, longitude: Double, height: Double) {
            body.figure.geodetic(Mat3.frameZ(rate * dt) * orientation.toBody(r))
        }

        var s = state, t = 0.0
        var above = coast.height(at: s.position) > height
        var swept = 0.0, ground = 0.0
        var sub = subPoint(s.position, 0)
        while t < limit {
            let h = min(coast.stepSize(s), limit - t)
            let next = coast.step(s, h)
            let hNext = coast.height(at: next.position)
            if above && hNext <= height {
                // Bracketed in (t, t + h]: regula falsi (Illinois) on the step length.
                var a = 0.0, fa = coast.height(at: s.position) - height
                var b = h, fb = hNext - height
                var side = 0
                for _ in 0..<100 {
                    let c = fa == fb ? (a + b) / 2 : (a * fb - b * fa) / (fb - fa)
                    let fc = coast.height(at: coast.step(s, c).position) - height
                    if abs(fc) < 1e-7 || b - a < 1e-9 { a = c; b = c; break }
                    if fc > 0 {
                        a = c; fa = fc
                        if side == 1 { fb /= 2 }
                        side = 1
                    } else {
                        b = c; fb = fc
                        if side == -1 { fa /= 2 }
                        side = -1
                    }
                }
                let tau = (a + b) / 2
                let ei = coast.step(s, tau)
                let g = subPoint(ei.position, t + tau)
                swept += angleBetween(s.position, ei.position)
                ground += GreatCircle.angle(fromLatitude: sub.latitude, longitude: sub.longitude,
                                            toLatitude: g.latitude, longitude: g.longitude) * meanRadius
                return EntryInterface(epoch: epoch, timeFromStart: t + tau, state: ei, geodetic: g,
                                      bodyRate: orientation.angularVelocity, pole: orientation.pole,
                                      sweptAngle: swept, groundRange: ground)
            }
            if hNext > height { above = true }
            let g = subPoint(next.position, t + h)
            swept += angleBetween(s.position, next.position)
            ground += GreatCircle.angle(fromLatitude: sub.latitude, longitude: sub.longitude,
                                        toLatitude: g.latitude, longitude: g.longitude) * meanRadius
            sub = g
            s = next
            t += h
            if g.height < -100_000 { return nil }
        }
        return nil
    }

    /// The EI of vessel `v` from `snapshot`'s time.
    public static func predict(_ v: Vessel, snapshot: SystemSnapshot, height: Double = standardHeight,
                               j2: Bool = true) -> EntryInterface? {
        predict(from: Kepler.State(position: v.position, velocity: v.velocity), around: v.reference,
                orientation: snapshot.orientation(v.reference), at: snapshot.time, height: height, j2: j2)
    }

    init(epoch: Epoch, timeFromStart: Double, state: Kepler.State,
         geodetic g: (latitude: Double, longitude: Double, height: Double),
         bodyRate: Vec3, pole: Vec3, sweptAngle: Double, groundRange: Double) {
        time = epoch + timeFromStart
        self.timeFromStart = timeFromStart
        self.state = state
        latitude = g.latitude
        longitude = g.longitude
        height = g.height
        let r = state.position, v = state.velocity, vr = v - bodyRate.cross(r)
        inertialSpeed = v.length
        inertialFlightPathAngle = Self.flightPathAngle(position: r, velocity: v)
        inertialAzimuth = Self.azimuth(position: r, velocity: v, pole: pole)
        relativeSpeed = vr.length
        relativeFlightPathAngle = Self.flightPathAngle(position: r, velocity: vr)
        relativeAzimuth = Self.azimuth(position: r, velocity: vr, pole: pole)
        self.sweptAngle = sweptAngle
        self.groundRange = groundRange
    }

    /// γ = asin(r̂ · v̂): the velocity's angle above the plane normal to the
    /// radius (rad).
    public static func flightPathAngle(position r: Vec3, velocity v: Vec3) -> Double {
        asin(max(-1, min(1, r.normalized.dot(v.normalized))))
    }

    /// The velocity's direction in the plane normal to the radius, from north
    /// (towards `pole`) through east (rad, [0, 2π)).
    public static func azimuth(position r: Vec3, velocity v: Vec3, pole: Vec3) -> Double {
        let up = r.normalized
        let east = pole.cross(up).normalized, north = up.cross(east)
        let a = atan2(v.dot(east), v.dot(north))
        return a < 0 ? a + 2 * Double.pi : a
    }
}

// MARK: - Great circles

/// Great-circle geometry on a sphere, with latitudes and longitudes in
/// radians (east positive) and bearings from north through east. Geodetic
/// coordinates taken as spherical put distances out by up to about 0.5%
/// on the Earth, which is how Apollo's entry ranges were figured too.
public enum GreatCircle {
    static func unit(_ lat: Double, _ lon: Double) -> Vec3 {
        Vec3(cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat))
    }

    /// The central angle between two points (rad, [0, π]).
    public static func angle(fromLatitude lat1: Double, longitude lon1: Double,
                             toLatitude lat2: Double, longitude lon2: Double) -> Double {
        angleBetween(unit(lat1, lon1), unit(lat2, lon2))
    }

    /// The distance between two points on a sphere of `radius` (m).
    public static func distance(fromLatitude lat1: Double, longitude lon1: Double,
                                toLatitude lat2: Double, longitude lon2: Double, radius: Double) -> Double {
        angle(fromLatitude: lat1, longitude: lon1, toLatitude: lat2, longitude: lon2) * radius
    }

    /// The initial bearing from the first point to the second (rad, [0, 2π)).
    public static func bearing(fromLatitude lat1: Double, longitude lon1: Double,
                               toLatitude lat2: Double, longitude lon2: Double) -> Double {
        let dl = lon2 - lon1
        let b = atan2(sin(dl) * cos(lat2), cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dl))
        return b < 0 ? b + 2 * Double.pi : b
    }

    /// The point `angle` (rad) from the start along `bearing`, its longitude
    /// in (-π, π].
    public static func destination(fromLatitude lat: Double, longitude lon: Double, bearing: Double,
                                   angle: Double) -> (latitude: Double, longitude: Double) {
        let lat2 = asin(max(-1, min(1, sin(lat) * cos(angle) + cos(lat) * sin(angle) * cos(bearing))))
        let lon2 = lon + atan2(sin(bearing) * sin(angle) * cos(lat), cos(angle) - sin(lat) * sin(lat2))
        return (lat2, remainder(lon2, 2 * Double.pi))
    }

    /// How far a point lies off the great circle leaving the start on
    /// `bearing` (rad): positive to the right of the direction of travel.
    public static func crossTrackAngle(fromLatitude lat1: Double, longitude lon1: Double, bearing: Double,
                                       toLatitude lat3: Double, longitude lon3: Double) -> Double {
        let d13 = angle(fromLatitude: lat1, longitude: lon1, toLatitude: lat3, longitude: lon3)
        let b13 = self.bearing(fromLatitude: lat1, longitude: lon1, toLatitude: lat3, longitude: lon3)
        return asin(max(-1, min(1, sin(d13) * sin(b13 - bearing))))
    }

    /// How far along the great circle leaving the start on `bearing` the
    /// point lies abeam (rad): negative behind the start.
    public static func alongTrackAngle(fromLatitude lat1: Double, longitude lon1: Double, bearing: Double,
                                       toLatitude lat3: Double, longitude lon3: Double) -> Double {
        let d13 = angle(fromLatitude: lat1, longitude: lon1, toLatitude: lat3, longitude: lon3)
        let b13 = self.bearing(fromLatitude: lat1, longitude: lon1, toLatitude: lat3, longitude: lon3)
        return atan2(sin(d13) * cos(b13 - bearing), cos(d13))
    }

    /// The figure's mean radius, (2a + b)/3 (IUGG R1; 6,371,008.8 m for WGS 84).
    public static func meanRadius(of figure: Ellipsoid) -> Double {
        (2 * figure.equatorialRadius + figure.polarRadius) / 3
    }
}
