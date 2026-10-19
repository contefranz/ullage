import Foundation

// MARK: - Orbit with secular J2

/// A satellite orbit under its central body's J2 oblateness, to first order.
///
/// The mean elements drift at Brouwer's secular rates, to J2²: the node
/// regresses, the line of apsides turns and the mean motion takes its J2
/// terms. The
/// first-order short-period terms map them to and from the osculating orbit
/// (Brouwer 1959, in Lyddane's 1963 form, which stays regular at e = 0 and
/// i = 0), as Schaub and Junkins give them (Analytical Mechanics of Space
/// Systems, 4th ed., app. F, eqs. F.7-F.22; checked against their Basilisk
/// code, clMeanOscMap). The long-period terms are left out: they are of order
/// J2·e, singular at the critical inclination, and constant to within metres
/// over the few orbits a ground track covers.
///
/// The mean elements are those that the short-period map takes to the given
/// osculating state, solved by iteration, so the orbit passes through that
/// state at its epoch. Starting from the osculating elements instead would
/// put the mean motion out by up to about 1e-3 at 185 km (the semi-major axis
/// swings ±3 km twice an orbit), which is a degree after three orbits. Escape
/// orbits, eccentricities above 0.5 and bodies without J2 fall back to the
/// two-body conic.
public struct SecularJ2Orbit {
    public let epoch: Epoch
    public let mu: Double
    public let j2: Double
    /// J2's reference radius (m).
    public let radius: Double
    /// The equatorial frame the elements are measured in, as rows in the
    /// state's axes; its z is the pole.
    public let referenceFrame: Mat3
    /// Mean elements at `epoch` (m, rad).
    public let meanSemiMajorAxis: Double
    public let meanEccentricity: Double
    public let meanInclination: Double
    /// Secular rates of the node, the argument of periapsis and the mean
    /// anomaly (rad/s); the two-body ones (0, 0, n) on the fallback.
    public let nodeRate: Double
    public let periapsisRate: Double
    public let meanAnomalyRate: Double

    let mean: ClassicalElements
    let initial: Kepler.State
    /// True when the two-body conic is used.
    public let isTwoBody: Bool

    /// The orbit through `state` (ICRF or any inertial axes, relative to the
    /// body) at `epoch`, J2 acting about `pole`.
    public init(state: Kepler.State, epoch: Epoch, mu: Double, j2: Double, radius: Double, pole: Vec3) {
        self.epoch = epoch
        self.mu = mu
        self.j2 = j2
        self.radius = radius
        initial = state
        let el = OrbitalElements(position: state.position, velocity: state.velocity, mu: mu, pole: pole)
        referenceFrame = el.referenceFrame
        let osc = ClassicalElements(el)
        var m = osc
        var ok = j2 != 0 && el.isBound && el.eccentricity < 0.5
        if ok {
            m = Self.shortPeriod(osc, j2: j2, radius: radius, sign: -1)
            for _ in 0..<4 {
                let back = Self.shortPeriod(m, j2: j2, radius: radius, sign: 1)
                m = m.adding(osc.difference(back))
            }
            ok = m.e < 0.9 && m.a > 0 && m.a.isFinite
        }
        isTwoBody = !ok
        if ok {
            mean = m
            // Brouwer's secular rates to second order in J2 (Brouwer 1959,
            // eqs. for l, g, h; at e = 0 they are SGP4's mdot, argpdot and
            // nodedot without J4). The second-order terms are 0.25% of the
            // node's regression at 185 km and 32.5°, 0.05° in three orbits.
            let n = (mu / (m.a * m.a * m.a)).squareRoot()
            let eta2 = 1 - m.e * m.e, eta = eta2.squareRoot()
            let g = j2 / 2 * (radius / m.a) * (radius / m.a) / (eta2 * eta2), g2 = g * g
            let c = cos(m.i), c2 = c * c, c4 = c2 * c2
            nodeRate = n * (-3 * g * c + 3.0 / 8 * g2 * ((-5 + 12 * eta + 9 * eta2) * c
                                                         + (-35 - 36 * eta - 5 * eta2) * c2 * c))
            periapsisRate = n * (1.5 * g * (5 * c2 - 1) + 3.0 / 32 * g2 * (-35 + 24 * eta + 25 * eta2
                + (90 - 192 * eta - 126 * eta2) * c2 + (385 + 360 * eta + 45 * eta2) * c4))
            meanAnomalyRate = n * (1 + 1.5 * g * eta * (3 * c2 - 1) + 3.0 / 32 * g2 * eta * (-15 + 16 * eta
                + 25 * eta2 + (30 - 96 * eta - 90 * eta2) * c2 + (105 + 144 * eta + 25 * eta2) * c4))
        } else {
            mean = osc
            nodeRate = 0
            periapsisRate = 0
            meanAnomalyRate = el.isBound ? el.meanMotion : 0
        }
        meanSemiMajorAxis = mean.a
        meanEccentricity = mean.e
        meanInclination = mean.i
    }

    /// The orbit through `state` about `body`, J2 acting about `pole`.
    public init(state: Kepler.State, epoch: Epoch, body: CelestialBody, pole: Vec3) {
        self.init(state: state, epoch: epoch, mu: body.gm, j2: body.j2, radius: body.radius, pole: pole)
    }

    /// The time between ascending nodes (s): 2π over the mean argument of
    /// latitude's rate.
    public var nodalPeriod: Double { 2 * Double.pi / (periapsisRate + meanAnomalyRate) }

    /// The osculating state at `t`, in the axes the orbit was given in.
    public func state(at t: Epoch) -> Kepler.State {
        let dt = t - epoch
        if isTwoBody { return Kepler.propagate(initial, mu: mu, by: dt) }
        var el = mean
        el.node += nodeRate * dt
        el.periapsis += periapsisRate * dt
        el.meanAnomaly = remainder(el.meanAnomaly + meanAnomalyRate * dt, 2 * Double.pi)
        let osc = Self.shortPeriod(el, j2: j2, radius: radius, sign: 1)
        let s = osc.state(mu: mu)
        let toState = referenceFrame.transposed
        return Kepler.State(position: toState * s.position, velocity: toState * s.velocity)
    }

    /// The first-order short-period J2 terms (Schaub and Junkins F.7-F.22,
    /// less the long-period ones): `sign` +1 maps mean elements to
    /// osculating, -1 osculating to mean.
    static func shortPeriod(_ el: ClassicalElements, j2: Double, radius: Double, sign: Double) -> ClassicalElements {
        let a = el.a, e = el.e, i = el.i, node = el.node, w = el.periapsis, m = el.meanAnomaly
        let f = Kepler.trueAnomaly(meanAnomaly: m, eccentricity: e)
        let g2 = sign * j2 / 2 * (radius / a) * (radius / a)
        let eta2 = 1 - e * e, eta = eta2.squareRoot(), eta6 = eta2 * eta2 * eta2
        let g2p = g2 / (eta2 * eta2)
        let ar = (1 + e * cos(f)) / eta2, ar3 = ar * ar * ar
        let c = cos(i), c2 = c * c, s = sin(i)
        let cf = cos(f), sf = sin(f)
        let w2f = 2 * w + 2 * f, w1f = 2 * w + f, w3f = 2 * w + 3 * f

        let da = a * g2 * ((3 * c2 - 1) * (ar3 - 1 / (eta2 * eta)) + 3 * (1 - c2) * ar3 * cos(w2f))
        let poly = 3 * cf + 3 * e * cf * cf + e * e * cf * cf * cf
        let de = eta2 / 2 * (g2 * ((3 * c2 - 1) / eta6 * (e * eta + e / (1 + eta) + poly)
                                   + 3 * (1 - c2) / eta6 * (e + poly) * cos(w2f))
                             - g2p * (1 - c2) * (3 * cos(w1f) + cos(w3f)))
        let di = g2p / 2 * c * s * (3 * cos(w2f) + 3 * e * cos(w1f) + e * cos(w3f))
        // The equation of the centre, f - M, plus e sin f.
        let centre = remainder(f - m, 2 * Double.pi) + e * sf
        let sines = 3 * sin(w2f) + 3 * e * sin(w1f) + e * sin(w3f)
        let dnode = -g2p / 2 * c * (6 * centre - sines)
        let lambda = m + w + node + g2p / 4 * (-6 * (1 - 5 * c2) * centre + (3 - 5 * c2) * sines) + dnode
        let ae2 = ar * eta * ar * eta
        let edm = -g2p / 4 * eta2 * eta * (2 * (3 * c2 - 1) * (ae2 + ar + 1) * sf
            + 3 * (1 - c2) * ((-ae2 - ar + 1) * sin(w1f) + (ae2 + ar + 1.0 / 3) * sin(w3f)))

        let d1 = (e + de) * sin(m) + edm * cos(m)
        let d2 = (e + de) * cos(m) - edm * sin(m)
        let si2 = sin(i / 2), ci2 = cos(i / 2)
        let d3 = (si2 + ci2 * di / 2) * sin(node) + si2 * dnode * cos(node)
        let d4 = (si2 + ci2 * di / 2) * cos(node) - si2 * dnode * sin(node)
        let mp = atan2(d1, d2), nodep = atan2(d3, d4)
        return ClassicalElements(a: a + da, e: (d1 * d1 + d2 * d2).squareRoot(),
                                 i: 2 * asin(min(1, (d3 * d3 + d4 * d4).squareRoot())),
                                 node: nodep, periapsis: lambda - mp - nodep, meanAnomaly: mp)
    }
}

/// Classical elements with the mean anomaly, in an equatorial frame.
struct ClassicalElements {
    var a: Double, e: Double, i: Double, node: Double, periapsis: Double, meanAnomaly: Double

    init(a: Double, e: Double, i: Double, node: Double, periapsis: Double, meanAnomaly: Double) {
        self.a = a; self.e = e; self.i = i; self.node = node; self.periapsis = periapsis
        self.meanAnomaly = meanAnomaly
    }

    init(_ el: OrbitalElements) {
        self.init(a: el.semiMajorAxis, e: el.eccentricity, i: el.inclination, node: el.longitudeOfAscendingNode,
                  periapsis: el.argumentOfPeriapsis,
                  meanAnomaly: Kepler.meanAnomaly(trueAnomaly: el.trueAnomaly, eccentricity: el.eccentricity))
    }

    /// Equinoctial form (a, e cos ϖ, e sin ϖ, sin(i/2) cos Ω, sin(i/2) sin Ω,
    /// λ = M + ϖ), regular at e = 0 and i = 0.
    var equinoctial: [Double] {
        let lp = node + periapsis
        return [a, e * cos(lp), e * sin(lp), sin(i / 2) * cos(node), sin(i / 2) * sin(node), meanAnomaly + lp]
    }

    init(equinoctial q: [Double]) {
        let lp = atan2(q[2], q[1]), node = atan2(q[4], q[3])
        self.init(a: q[0], e: (q[1] * q[1] + q[2] * q[2]).squareRoot(),
                  i: 2 * asin(min(1, (q[3] * q[3] + q[4] * q[4]).squareRoot())),
                  node: node, periapsis: lp - node, meanAnomaly: remainder(q[5] - lp, 2 * Double.pi))
    }

    /// self - other in equinoctial form, the mean longitude wrapped.
    func difference(_ other: ClassicalElements) -> [Double] {
        var d = zip(equinoctial, other.equinoctial).map { $0 - $1 }
        d[5] = remainder(d[5], 2 * Double.pi)
        return d
    }

    func adding(_ d: [Double]) -> ClassicalElements {
        ClassicalElements(equinoctial: zip(equinoctial, d).map { $0 + $1 })
    }

    /// Position and velocity in the equatorial frame.
    func state(mu: Double) -> Kepler.State {
        let f = Kepler.trueAnomaly(meanAnomaly: meanAnomaly, eccentricity: e)
        let p = a * (1 - e * e)
        let r = p / (1 + e * cos(f))
        let m = Mat3.rotZ(node) * Mat3.rotX(i) * Mat3.rotZ(periapsis)
        let pHat = m.c0, qHat = m.c1
        return Kepler.State(position: (pHat * cos(f) + qHat * sin(f)) * r,
                            velocity: (pHat * -sin(f) + qHat * (e + cos(f))) * (mu / p).squareRoot())
    }
}

// MARK: - Ground track

/// The sub-vessel point's path over a rotating body, the Sun's place on it
/// and the visibility circle.
public enum GroundTrack {
    /// A sub-vessel point: geodetic latitude and longitude (rad, east
    /// positive, in (-π, π]) and height above the figure (m).
    public struct Point: Equatable {
        public var time: Epoch
        public var latitude: Double
        public var longitude: Double
        public var height: Double

        public init(time: Epoch, latitude: Double, longitude: Double, height: Double) {
            self.time = time
            self.latitude = latitude
            self.longitude = longitude
            self.height = height
        }
    }

    /// The predicted track from `state` (ICRF, relative to `body`) at
    /// `epoch`, every `step` seconds over `duration`, both ends included.
    ///
    /// The orbit follows `SecularJ2Orbit` (or the two-body conic if `j2` is
    /// false), and the body turns rigidly about its pole at `epoch` at its
    /// rotation rate: over a few orbits precession and nutation move the
    /// Earth's axis by milliarcseconds, so evaluating them at each point is
    /// not worth its cost. Vacuum: no drag, so it is not valid in the air or
    /// under thrust. The track ends at the first point below the surface.
    public static func predict(from state: Kepler.State, around body: CelestialBody, orientation: BodyOrientation,
                               at epoch: Epoch, duration: Double, step: Double = 30, j2: Bool = true) -> [Point] {
        let orbit = SecularJ2Orbit(state: state, epoch: epoch, mu: body.gm, j2: j2 ? body.j2 : 0,
                                   radius: body.radius, pole: orientation.pole)
        let rate = orientation.angularVelocity.dot(orientation.pole)
        let count = max(0, Int((duration / step).rounded(.up)))
        var points: [Point] = []
        points.reserveCapacity(count + 1)
        for k in 0...count {
            let dt = min(Double(k) * step, duration)
            let r = orbit.state(at: epoch + dt).position
            let g = body.figure.geodetic(Mat3.frameZ(rate * dt) * orientation.toBody(r))
            points.append(Point(time: epoch + dt, latitude: g.latitude, longitude: g.longitude, height: g.height))
            if g.height < 0 { break }
        }
        return points
    }

    /// The predicted track of vessel `v` from `snapshot`'s time.
    public static func predict(_ v: Vessel, snapshot: SystemSnapshot, duration: Double, step: Double = 30,
                               j2: Bool = true) -> [Point] {
        predict(from: Kepler.State(position: v.position, velocity: v.velocity), around: v.reference,
                orientation: snapshot.orientation(v.reference), at: snapshot.time, duration: duration, step: step,
                j2: j2)
    }

    // MARK: Sun

    /// Where the Sun stands at the zenith, and the Sun's elevation elsewhere.
    public struct SubsolarPoint {
        /// Geodetic latitude and longitude (rad) of the point whose vertical
        /// points at the Sun.
        public let latitude: Double
        public let longitude: Double
        /// The apparent direction of the Sun from the body's centre, in the
        /// body-fixed frame (unit vector).
        public let direction: Vec3

        /// The Sun's elevation above the horizon (rad) at geodetic `latitude`
        /// and `longitude`, without parallax (under 0.0025° for the Earth)
        /// and refraction.
        public func solarElevation(latitude lat: Double, longitude lon: Double) -> Double {
            asin(max(-1, min(1, sin(lat) * sin(latitude) + cos(lat) * cos(latitude) * cos(lon - longitude))))
        }

        /// The line where the Sun stands at `elevation` (rad; 0 for the
        /// geometric terminator, -0.833° for sunrise and sunset with
        /// refraction): the circle of geodetic points `π/2 - elevation` from
        /// the subsolar point, as `n` intervals from due north of it,
        /// clockwise, closed (the last point repeats the first).
        public func terminator(points n: Int, elevation: Double = 0) -> [(latitude: Double, longitude: Double)] {
            guard n > 0 else { return [] }
            return (0...n).map { k in
                GreatCircle.destination(fromLatitude: latitude, longitude: longitude,
                                        bearing: 2 * Double.pi * Double(k % n) / Double(n),
                                        angle: Double.pi / 2 - elevation)
            }
        }

        /// The geometric terminator's latitude at `longitude` (rad), where
        /// tan φ = -cos(λ - λs) / tan φs; at an equinox, ±π/2 on either side.
        public func terminatorLatitude(atLongitude lon: Double) -> Double {
            let num = -cos(latitude) * cos(lon - longitude), den = sin(latitude)
            if abs(den) < 1e-15 { return num == 0 ? 0 : (num > 0 ? Double.pi / 2 : -Double.pi / 2) }
            return atan(num / den)
        }
    }

    /// The subsolar point on `body` in `snapshot`, from the ephemeris (DE421)
    /// and the body's orientation, with the Sun's light time and annual
    /// aberration: where an observer on the body sees the Sun overhead.
    public static func subsolarPoint(on body: CelestialBody, sun: CelestialBody,
                                     snapshot s: SystemSnapshot) -> SubsolarPoint {
        let c = 299_792_458.0
        var d = s.position(sun) - s.position(body)
        d -= s.velocity(sun) * (d.length / c)                       // light time
        let u = d.normalized, beta = s.velocity(body) / c
        let apparent = (u + beta - u * u.dot(beta)).normalized       // aberration, first order
        let o = s.orientation(body)
        let dir = o.toBody(apparent)
        let sunBodyFixed = dir * d.length
        // The point whose normal points at the Sun as seen from it.
        var toSun = dir
        var g = (latitude: asin(max(-1, min(1, toSun.z))), longitude: atan2(toSun.y, toSun.x))
        for _ in 0..<3 {
            toSun = (sunBodyFixed - body.figure.bodyFixed(latitude: g.latitude, longitude: g.longitude, height: 0))
                .normalized
            g = (asin(max(-1, min(1, toSun.z))), atan2(toSun.y, toSun.x))
        }
        return SubsolarPoint(latitude: g.latitude, longitude: g.longitude, direction: dir)
    }

    // MARK: Horizon

    /// The angular radius of the horizon seen from `height` above a sphere of
    /// `radius`: acos(R / (R + h)) (rad).
    public static func horizonAngle(height: Double, radius: Double) -> Double {
        acos(max(-1, min(1, radius / (radius + max(0, height)))))
    }

    /// The horizon (visibility) circle seen from `height` above geodetic
    /// `latitude`, `longitude` on `figure`, as `n` intervals from due north,
    /// clockwise, closed: a spherical cap on the local radius of the figure.
    public static func horizonCircle(latitude: Double, longitude: Double, height: Double, figure: Ellipsoid,
                                     points n: Int) -> [(latitude: Double, longitude: Double)] {
        guard n > 0 else { return [] }
        let ground = figure.bodyFixed(latitude: latitude, longitude: longitude, height: 0).length
        let above = figure.bodyFixed(latitude: latitude, longitude: longitude, height: max(0, height)).length
        let angle = acos(max(-1, min(1, ground / above)))
        return (0...n).map { k in
            GreatCircle.destination(fromLatitude: latitude, longitude: longitude,
                                    bearing: 2 * Double.pi * Double(k % n) / Double(n), angle: angle)
        }
    }
}

// MARK: - Recorder

/// The track a vessel has flown, oldest first: a point kept for each
/// `spacing` of great-circle angle (or each `interval` of time, whichever
/// comes first), and the latest one recorded at the end. When the
/// buffer holds a quarter more than `capacity` points, the oldest are
/// dropped back to `capacity`. A time earlier than the last point (a
/// reloaded scenario) starts the track again.
public struct GroundTrackRecorder {
    public private(set) var points: [GroundTrack.Point] = []
    public let capacity: Int
    public let spacing: Double
    public let interval: Double

    /// - Parameters:
    ///   - capacity: points kept (about 20 orbits at the defaults in LEO).
    ///   - spacing: great-circle angle between kept points (rad).
    ///   - interval: longest time between kept points (s), for slow tracks.
    public init(capacity: Int = 4000, spacing: Double = 0.5 * Double.pi / 180, interval: Double = 120) {
        self.capacity = max(2, capacity)
        self.spacing = spacing
        self.interval = interval
    }

    public mutating func record(_ p: GroundTrack.Point) {
        guard let last = points.last else { points.append(p); return }
        if p.time < last.time { points = [p]; return }
        if points.count >= 2 {
            // The head moves with the vessel until it is a spacing (or an
            // interval) past the last kept point; then it is kept too.
            let anchor = points[points.count - 2]
            let angle = GreatCircle.angle(fromLatitude: anchor.latitude, longitude: anchor.longitude,
                                          toLatitude: last.latitude, longitude: last.longitude)
            if angle < spacing && last.time - anchor.time < interval {
                points[points.count - 1] = p
                return
            }
        }
        points.append(p)
        if points.count > capacity + capacity / 4 { points.removeFirst(points.count - capacity) }
    }

    /// Records vessel `v`'s sub-point in `snapshot`.
    public mutating func record(_ v: Vessel, snapshot: SystemSnapshot) {
        let g = v.reference.geodetic(v.position, orientation: snapshot.orientation(v.reference))
        record(GroundTrack.Point(time: snapshot.time, latitude: g.latitude, longitude: g.longitude, height: g.height))
    }

    public mutating func reset() { points = [] }
}
