import Foundation

extension Simulation {
    /// Stand `v` upright on the surface at geodetic `latitude`/`longitude`
    /// (degrees), its base `elevation` metres above the body's figure,
    /// along the normal. The vessel's -z axis (its "up" for the crew) faces
    /// `azimuth` degrees from north.
    public func placeLanded(_ v: Vessel, on body: CelestialBody, latitude: Double, longitude: Double,
                            azimuth: Double = 90, elevation: Double = 0) {
        let deg = Double.pi / 180
        let lat = latitude * deg, lon = longitude * deg, az = azimuth * deg
        let up = body.figure.normal(latitude: lat, longitude: lon)
        let east = Vec3(-sin(lon), cos(lon), 0)
        let north = up.cross(east)
        let dir = north * cos(az) + east * sin(az)
        let x = up, z = -dir, y = z.cross(x)
        let att = Quat(matrix: Mat3(columns: x, y, z))
        let l = LandedState(body: body,
                            bodyFixedPosition: body.figure.bodyFixed(latitude: lat, longitude: lon,
                                                                     height: elevation + v.baseHeight),
                            bodyFixedAttitude: att)
        v.landed = l
        v.status = .landed
        v.reference = body
        setLandedKinematics(v, l, snapshot: snapshot)
        updateTelemetry(v, snapshot: snapshot)
    }

    /// Put `v` on a circular orbit, facing prograde with its +z axis towards the body.
    public func placeInCircularOrbit(_ v: Vessel, around body: CelestialBody, altitude: Double,
                                     inclination: Double = 0, ascendingNode: Double = 0, argumentOfLatitude: Double = 0) {
        let deg = Double.pi / 180
        let snap = snapshot
        let pole = snap.orientation(body).pole
        var xRef = Vec3.unitZ.cross(pole)
        xRef = xRef.length < 1e-9 ? .unitX : xRef.normalized
        let yRef = pole.cross(xRef)
        let r = body.radius + altitude
        let speed = (body.gm / r).squareRoot()
        // Perifocal -> equatorial: Rz(Ω) Rx(i) Rz(u)
        let m = Mat3.rotZ(ascendingNode * deg) * Mat3.rotX(inclination * deg) * Mat3.rotZ(argumentOfLatitude * deg)
        let pLocal = m * Vec3(r, 0, 0)
        let vLocal = m * Vec3(0, speed, 0)
        let toICRF = Mat3(columns: xRef, yRef, pole)
        v.reference = body
        v.landed = nil
        v.status = .flying
        v.position = toICRF * pLocal
        v.velocity = toICRF * vLocal
        let x = v.velocity.normalized, z = -v.position.normalized, y = z.cross(x)
        v.attitude = Quat(matrix: Mat3(columns: x, y, z))
        v.angularVelocity = .zero
        updateTelemetry(v, snapshot: snap)
    }

    /// Put `v` in flight over geodetic `latitude`/`longitude` (degrees),
    /// `height` metres above the figure of `body` (the Earth if nil), at
    /// `inertialSpeed` m/s on the inertial flight-path angle and azimuth
    /// (degrees, the azimuth from north through east). Both angles are in
    /// the geocentric horizontal, perpendicular to the radius, as Apollo's
    /// trajectory listings give them. `attitude` turns the vessel from the
    /// flight-path frame (+x along the velocity, +z towards the body in the
    /// plane of the radius and the velocity), so the identity faces prograde
    /// with +z down, as in `placeInCircularOrbit`.
    public func place(_ v: Vessel, around body: CelestialBody? = nil, geodeticLatitude latitude: Double,
                      longitude: Double, height: Double, inertialSpeed: Double, flightPathAngle: Double,
                      azimuth: Double, attitude: Quat = .identity) {
        let deg = Double.pi / 180
        let body = body ?? system.earth
        let snap = snapshot
        let o = snap.orientation(body)
        let lat = latitude * deg, lon = longitude * deg, gamma = flightPathAngle * deg, az = azimuth * deg
        let r = o.toInertial(body.figure.bodyFixed(latitude: lat, longitude: lon, height: height))
        let up = r.normalized
        // East is defined by the longitude, at the poles too.
        let east = o.toInertial(Vec3(-sin(lon), cos(lon), 0)), north = up.cross(east)
        let horizontal = north * cos(az) + east * sin(az)
        let x = horizontal * cos(gamma) + up * sin(gamma)
        v.reference = body
        v.landed = nil
        v.status = .flying
        v.position = r
        v.velocity = x * inertialSpeed
        // Straight up or down, +z takes its limit: towards the azimuth climbing.
        let down = -up - x * (-up).dot(x)
        let z = down.length > 1e-9 ? down.normalized : horizontal * (gamma > 0 ? 1 : -1), y = z.cross(x)
        v.attitude = (Quat(matrix: Mat3(columns: x, y, z)) * attitude).normalized
        v.angularVelocity = .zero
        updateTelemetry(v, snapshot: snap)
    }
}
