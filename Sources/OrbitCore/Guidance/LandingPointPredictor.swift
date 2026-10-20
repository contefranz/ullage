import Foundation

/// A display-only landing-point predictor for a command module: a point
/// mass with the capsule's trim drag and lift at its current centre of mass
/// and mass, flown from the vessel's state at a constant bank in 1 s RK4
/// steps through the reference body's standard atmosphere (rotating with
/// the body, no wind), central gravity with J2, down to `endAltitude` (the
/// drogues' 24,000 ft, below which the CM comes down nearly vertically). It
/// guides nothing.
public struct LandingPointPredictor {
    /// Integration step, s.
    public var step = 1.0
    /// Where the prediction ends: geodetic height, m.
    public var endAltitude = 7_315.2
    /// Longest flight predicted, s.
    public var maxDuration = 3_600.0

    public init() {}

    /// The predicted point.
    public struct Prediction {
        /// Geodetic latitude and longitude, rad, and the epoch it is reached.
        public var latitude: Double
        public var longitude: Double
        public var time: Epoch
        /// Highest sensed load factor on the way, g.
        public var peakLoadFactor: Double
    }

    /// Where `v`, flying `capsule`, comes down at a constant `bank` (rad; nil
    /// for zero mean lift, as rolling flies), from its state in `sim`. Nil
    /// when the reference body has no atmosphere or the flight does not
    /// come down within `maxDuration`.
    public func predict(_ v: Vessel, capsule: CapsuleAerodynamics, bank: Double?,
                        in sim: Simulation) -> Prediction? {
        let body = v.reference
        guard let atm = body.atmosphere else { return nil }
        let snap = sim.snapshot, o = snap.orientation(body)
        let omega = o.angularVelocity, pole = o.pole, rate = omega.length
        let mass = v.mass, com = v.structuralCenterOfMass
        let side = v.liftSide(capsule)

        /// Drag and lift per unit q (m^2) at Mach `mach`, trimmed.
        func coefficients(_ mach: Double) -> (drag: Double, lift: Double) {
            let a = capsule.trimAngle(mach: mach, centerOfMass: com)
            let air = AtmosphereState(temperature: 288, pressure: 1, density: 1, speedOfSound: 1)
            let u = (Vec3.unitX * -cos(a) + side * sin(a)) * max(mach, 0.05)
            let f = capsule.loads(air: u, atmosphere: air, structureOrigin: -com).force
            let q = 0.5 * u.lengthSquared, back = -u.normalized
            let d = f.dot(back)
            return (d / q, (f - back * d).length / q)
        }
        // The body rotates rigidly: track its angle to put the end point on it.
        func acceleration(_ r: Vec3, _ vel: Vec3, _ t: Double) -> (a: Vec3, n: Double) {
            var a = body.gravity(at: r, pole: pole)
            let fixed = Quat(axis: pole, angle: -rate * t).rotate(r)
            let h = body.figure.geodetic(o.toBody(fixed)).height
            guard h < atm.ceiling else { return (a, 0) }
            let s = atm.state(altitude: h)
            let air = vel - omega.cross(r), speed = air.length
            guard s.density > 0, speed > 1e-3 else { return (a, 0) }
            let c = coefficients(speed / s.speedOfSound)
            let q = 0.5 * s.density * speed * speed
            let f = air / speed, up = r.normalized, across = up - f * up.dot(f)
            var lift = Vec3.zero
            if let bank, across.length > 1e-9 {
                let u = across.normalized, right = f.cross(u)
                lift = (u * cos(bank) + right * sin(bank)) * (c.lift * q / mass)
            }
            let sensed = f * (-c.drag * q / mass) + lift
            a += sensed
            return (a, sensed.length / 9.80665)
        }
        var r = v.position, vel = v.velocity, t = 0.0, peak = 0.0
        while t < maxDuration {
            let h = step
            let k1 = acceleration(r, vel, t)
            let k2 = acceleration(r + vel * (h / 2), vel + k1.a * (h / 2), t + h / 2)
            let k3 = acceleration(r + (vel + k1.a * (h / 2)) * (h / 2), vel + k2.a * (h / 2), t + h / 2)
            let k4 = acceleration(r + (vel + k2.a * (h / 2)) * h, vel + k3.a * h, t + h)
            r += (vel * 6 + (k1.a + k2.a + k3.a) * h) * (h / 6)
            vel += (k1.a + k2.a * 2 + k3.a * 2 + k4.a) * (h / 6)
            t += h
            peak = max(peak, k1.n, k4.n)
            let fixed = Quat(axis: pole, angle: -rate * t).rotate(r)
            let g = body.figure.geodetic(o.toBody(fixed))
            if g.height <= endAltitude {
                return Prediction(latitude: g.latitude, longitude: g.longitude, time: sim.time + t,
                                  peakLoadFactor: peak)
            }
        }
        return nil
    }
}
