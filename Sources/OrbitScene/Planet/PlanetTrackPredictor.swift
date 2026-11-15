import Foundation
import OrbitCore

/// Where the camera will be, so the tile cache can prefetch along the
/// predicted ground track (M1.6 design §3, "Time warp" (b)): the camera's
/// velocity from its last positions, then a two-body arc in orbit (above
/// `orbitAltitude` and faster than `orbitSpeed`), else a straight line in
/// the body-fixed frame (the pad, an ascent at 1×). The view is turned with
/// the track: the camera keeps its attitude relative to the local vertical
/// and the direction of motion.
public struct PlanetTrackPredictor {
    /// The body's gravitational parameter, m³/s².
    public var mu: Double
    public var orbitAltitude = 80_000.0
    public var orbitSpeed = 3_000.0
    /// Faster than this between two frames is a jump (a new scenario or
    /// camera), not motion, m/s.
    public var jumpSpeed = 50_000.0

    var last: (time: Double, position: Vec3)?
    var lastStep = 0.0
    /// The camera's velocity relative to the body's centre (ICRF), m/s: the
    /// chord over the last frame, the velocity at its middle.
    public private(set) var velocity: Vec3?

    public init(mu: Double) { self.mu = mu }

    /// Feeds the camera's position relative to the body's centre (ICRF, m)
    /// at simulation time `time` (s). `reset` forgets the history.
    public mutating func observe(time: Double, position: Vec3, reset: Bool = false) {
        defer { last = (time, position) }
        guard !reset, let l = last else { velocity = nil; return }
        let dt = time - l.time
        guard dt > 0 else { return }          // paused: keep the estimate
        let v = (position - l.position) / dt
        velocity = v.length > jumpSpeed ? nil : v
        lastStep = dt
    }

    /// The position and velocity (ICRF, relative to the centre) `dt`
    /// seconds on from `position` at `velocity`, two-body, by RK4 steps of
    /// at most 30 s.
    public func propagate(_ position: Vec3, _ velocity: Vec3, _ dt: Double) -> (position: Vec3, velocity: Vec3) {
        guard dt > 0 else { return (position, velocity) }
        let steps = max(1, Int((dt / 30).rounded(.up)))
        let h = dt / Double(steps)
        var r = position, v = velocity
        func a(_ p: Vec3) -> Vec3 { let d = p.length; return p * (-mu / (d * d * d)) }
        for _ in 0 ..< steps {
            let k1v = a(r), k1r = v
            let k2v = a(r + k1r * (h / 2)), k2r = v + k1v * (h / 2)
            let k3v = a(r + k2r * (h / 2)), k3r = v + k2v * (h / 2)
            let k4v = a(r + k3r * h), k4r = v + k3v * h
            r += (k1r + k2r * 2 + k3r * 2 + k4r) * (h / 6)
            v += (k1v + k2v * 2 + k3v * 2 + k4v) * (h / 6)
        }
        return (r, v)
    }

    /// The camera's view `dt` simulation seconds ahead, body-fixed, as
    /// `view` is now (its pixel angle and motion kept): nil without a
    /// velocity estimate. `position` is the camera relative to the body's
    /// centre (ICRF), `forward` and `up` its axes (ICRF), `fovY` and
    /// `aspect` its field.
    public func predictedView(after dt: Double, position: Vec3, forward: Vec3, up: Vec3, fovY: Double, aspect: Double,
                              orientation: BodyOrientation, figure: Ellipsoid, current view: PlanetQuadtree.View)
        -> PlanetQuadtree.View? {
        guard let velocity, dt > 0 else { return nil }
        let omega = orientation.angularVelocity
        let bodyNow = orientation.toBody(position)
        let altitude = figure.geodetic(bodyNow).height
        // The body-fixed frame dt from now: turned by the body's spin.
        let spin = omega.dot(orientation.pole) * dt
        let later = Mat3.rotZ(-spin) * orientation.icrfToBody
        let p1: Vec3, v1: Vec3
        if altitude > orbitAltitude && velocity.length > orbitSpeed {
            // In free fall the velocity now is the chord's plus half a step of gravity.
            let r = position.length
            let now = velocity + position * (-mu / (r * r * r) * lastStep / 2)
            (p1, v1) = propagate(position, now, dt)
        } else {
            // A straight line over the ground, in the body-fixed frame.
            let groundVelocity = velocity - omega.cross(position)
            let b1 = bodyNow + orientation.toBody(groundVelocity) * dt
            p1 = later.transposed * b1
            v1 = later.transposed * orientation.toBody(groundVelocity) + omega.cross(p1)
        }
        // The camera's attitude in the track frame (up, along-track, cross-track).
        func frame(_ r: Vec3, _ v: Vec3) -> (Vec3, Vec3, Vec3)? {
            let up = r.normalized
            let h = v - up * v.dot(up)
            guard h.length > 1e-3 else { return nil }
            let along = h.normalized
            return (up, along, up.cross(along))
        }
        let relative0 = velocity - omega.cross(position)
        var forward1 = forward, up1 = up
        if let f0 = frame(position, relative0), let f1 = frame(p1, v1 - omega.cross(p1)) {
            func turn(_ x: Vec3) -> Vec3 { f1.0 * x.dot(f0.0) + f1.1 * x.dot(f0.1) + f1.2 * x.dot(f0.2) }
            forward1 = turn(forward); up1 = turn(up)
        }
        let b1 = later * p1
        var v = view
        v.position = b1
        if view.frustum != nil {
            v.frustum = PlanetQuadtree.Frustum(apex: b1, forward: later * forward1, up: later * up1, fovY: fovY,
                                                aspect: aspect)
        }
        return v
    }
}
