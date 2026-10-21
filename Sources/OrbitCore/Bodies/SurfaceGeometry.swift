import Foundation

/// Where the Sun and an observer stand over a body's figure: the subsolar,
/// sub-observer and specular (glint) points, and the Sun's elevation and
/// azimuth at a geodetic site. The Earth and ocean passes and the atmosphere
/// read them; the simulation does not.
///
/// A sub-point is the foot of the normal through a point: the point of the
/// figure nearest it, where it stands at the zenith (SPICE's "near point").
/// Positions are geometric, from the ephemeris at one instant, as the
/// renderer draws the Sun: the apparent Sun of an almanac differs from it by
/// the aberration of light, at most 20.5", and there is no refraction.
public enum SurfaceGeometry {
    /// A point on a body's figure: geodetic latitude and longitude (rad), and
    /// its body-fixed position (m) and outward normal.
    public struct SurfacePoint: Equatable {
        public let latitude: Double
        public let longitude: Double
        public let position: Vec3
        public let normal: Vec3

        /// The point of `figure` at geodetic `latitude` and `longitude` (rad).
        public init(latitude: Double, longitude: Double, on figure: Ellipsoid) {
            self.latitude = latitude
            self.longitude = longitude
            position = figure.bodyFixed(latitude: latitude, longitude: longitude, height: 0)
            normal = figure.normal(latitude: latitude, longitude: longitude)
        }
    }

    // MARK: Body-fixed geometry

    /// The foot of the normal through `point` (body-fixed, m) on `figure`.
    /// Outside the evolute, the 43 km about the Earth's centre, it is the
    /// figure's nearest point; at any distance, the Sun's included.
    public static func subPoint(below point: Vec3, on figure: Ellipsoid) -> SurfacePoint {
        let g = figure.geodetic(point)
        return SurfacePoint(latitude: g.latitude, longitude: g.longitude, on: figure)
    }

    /// The specular point on `figure` for an observer at `observer` and a
    /// source at `source` (body-fixed, m): the point whose normal bisects
    /// the directions to the two, where the source's image (the Sun's glint)
    /// stands on a mirror-smooth surface. Nil when no point of the figure is
    /// seen from both, or when either is on or inside the figure.
    ///
    /// The point is the stationary point of the path length |O - P| + |S - P|
    /// (Fermat). On the sphere through the observer's sub-point it lies in
    /// the plane of the centre, observer and source, where the path length is
    /// convex over the arc both see and its slope is bracketed at the arc's
    /// ends: bisection finds it. Newton's method on geodetic latitude and
    /// longitude then moves it onto the ellipsoid, where the flattening puts
    /// it up to a few kilometres out of that plane.
    public static func specularPoint(observer: Vec3, source: Vec3, on figure: Ellipsoid) -> SurfacePoint? {
        guard figure.geodetic(observer).height > 0, figure.geodetic(source).height > 0,
              let start = sphericalSpecularNormal(observer: observer, source: source,
                                                  radius: subPoint(below: observer, on: figure).position.length)
        else { return nil }
        var lat = asin(max(-1, min(1, start.z))), lon = atan2(start.y, start.x)
        var converged = false
        for _ in 0..<20 {
            let f = reflectionResidual(lat, lon, observer: observer, source: source, figure: figure)
            let h = 1e-6
            let fLat1 = reflectionResidual(lat + h, lon, observer: observer, source: source, figure: figure)
            let fLat0 = reflectionResidual(lat - h, lon, observer: observer, source: source, figure: figure)
            let fLon1 = reflectionResidual(lat, lon + h, observer: observer, source: source, figure: figure)
            let fLon0 = reflectionResidual(lat, lon - h, observer: observer, source: source, figure: figure)
            // Jacobian columns: d/dlat and d/dlon of (north, east) residuals.
            let a = (fLat1.north - fLat0.north) / (2 * h), b = (fLon1.north - fLon0.north) / (2 * h)
            let c = (fLat1.east - fLat0.east) / (2 * h), d = (fLon1.east - fLon0.east) / (2 * h)
            let det = a * d - b * c
            guard det != 0, det.isFinite else { break }
            var dLat = (-f.north * d + f.east * b) / det
            var dLon = (-f.east * a + f.north * c) / det
            // Steps of at most 0.05 rad (320 km) keep a poor start from leaping
            // across the figure.
            let step = (dLat * dLat + dLon * dLon).squareRoot()
            if step > 0.05 { dLat *= 0.05 / step; dLon *= 0.05 / step }
            lat = max(-Double.pi / 2, min(Double.pi / 2, lat + dLat))
            lon += dLon
            if step < 1e-12 { converged = true; break }
        }
        let p = SurfacePoint(latitude: lat, longitude: atan2(sin(lon), cos(lon)), on: figure)
        let toObserver = (observer - p.position).normalized, toSource = (source - p.position).normalized
        let bisector = (toObserver + toSource).normalized
        guard p.normal.dot(toObserver) > 0, p.normal.dot(toSource) > 0,
              converged || p.normal.cross(bisector).length < 1e-9 else { return nil }
        return p
    }

    /// The tangential components, north and east, of the sum of the unit
    /// vectors from the figure's point at (`lat`, `lon`) to the observer and
    /// the source: both vanish at the specular point.
    private static func reflectionResidual(_ lat: Double, _ lon: Double, observer: Vec3, source: Vec3,
                                           figure: Ellipsoid) -> (north: Double, east: Double) {
        let p = figure.bodyFixed(latitude: lat, longitude: lon, height: 0)
        let h = (observer - p).normalized + (source - p).normalized
        let north = Vec3(-sin(lat) * cos(lon), -sin(lat) * sin(lon), cos(lat))
        let east = Vec3(-sin(lon), cos(lon), 0)
        return (h.dot(north), h.dot(east))
    }

    /// The outward normal at the specular point on a sphere of `radius`
    /// about the origin, nil when no point of it is seen from both.
    private static func sphericalSpecularNormal(observer: Vec3, source: Vec3, radius: Double) -> Vec3? {
        let o = observer.length, s = source.length
        guard o > radius, s > radius else { return nil }
        let e1 = observer / o
        let across = source - e1 * source.dot(e1)
        // The source on the observer's radius: straight below the observer.
        guard across.length > 1e-12 * s else { return source.dot(e1) > 0 ? e1 : nil }
        let e2 = across.normalized
        let gamma = atan2(source.dot(e2), source.dot(e1))
        // The arc both see: within acos(R/o) of the observer's sub-point and
        // acos(R/s) of the source's.
        let low = max(0, gamma - acos(radius / s)), high = min(gamma, acos(radius / o))
        guard low < high else { return nil }
        // The path length's slope along the arc, (Ô + Ŝ)·t̂: positive at
        // `low`, negative at `high`.
        func slope(_ t: Double) -> Double {
            let n = e1 * cos(t) + e2 * sin(t), tangent = e2 * cos(t) - e1 * sin(t)
            let p = n * radius
            return ((observer - p).normalized + (source - p).normalized).dot(tangent)
        }
        var lo = low, hi = high
        for _ in 0..<64 {
            let mid = (lo + hi) / 2
            if slope(mid) > 0 { lo = mid } else { hi = mid }
        }
        let t = (lo + hi) / 2
        return e1 * cos(t) + e2 * sin(t)
    }

    // MARK: On a body at an instant

    /// The subsolar point of `body`: the foot of the normal through the
    /// Sun's centre, where the Sun stands at the zenith.
    public static func subsolarPoint(on body: CelestialBody, in system: SolarSystem,
                                     snapshot s: SystemSnapshot) -> SurfacePoint {
        let sun = s.orientation(body).toBody(s.position(system.sun) - s.position(body))
        return subPoint(below: sun, on: body.figure)
    }

    /// The sub-observer point of an observer at `observer` (ICRF, m, from the
    /// body's centre), the body oriented as `o`: the foot of the normal
    /// through it, its geodetic latitude and longitude.
    public static func subObserverPoint(_ observer: Vec3, on body: CelestialBody,
                                        orientation o: BodyOrientation) -> SurfacePoint {
        subPoint(below: o.toBody(observer), on: body.figure)
    }

    /// The Sun's specular point on `body` as seen from `observer` (ICRF, m,
    /// from the body's centre); nil when the observer sees no sunlit point
    /// that can mirror the Sun (in the body's shadow, or on or below its
    /// surface).
    public static func specularPoint(observer: Vec3, on body: CelestialBody, in system: SolarSystem,
                                     snapshot s: SystemSnapshot) -> SurfacePoint? {
        let o = s.orientation(body)
        let sun = o.toBody(s.position(system.sun) - s.position(body))
        return specularPoint(observer: o.toBody(observer), source: sun, on: body.figure)
    }

    /// The Sun's elevation above the geodetic horizon (-π/2...π/2) and its
    /// azimuth from north through east (0..<2π), rad, at geodetic `latitude`
    /// and `longitude` (rad) and `height` (m) on `body`: the direction of
    /// its centre from the site, airless.
    public static func sunElevationAzimuth(latitude: Double, longitude: Double, height: Double = 0,
                                           on body: CelestialBody, in system: SolarSystem,
                                           snapshot s: SystemSnapshot) -> (elevation: Double, azimuth: Double) {
        let o = s.orientation(body)
        let site = body.figure.bodyFixed(latitude: latitude, longitude: longitude, height: height)
        let sun = o.toBody(s.position(system.sun) - s.position(body))
        let up = body.figure.normal(latitude: latitude, longitude: longitude)
        let horizon = LocalHorizon(up: up, pole: .unitZ, fallbackNorth: .unitX)
        return horizon.elevationAzimuth(of: sun - site)
    }
}
