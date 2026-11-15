import Foundation
import OrbitCore

// The frames particles live in, kept in double precision on the CPU; the
// particles store float positions and velocities relative to their anchor,
// so nothing jitters at 7.8 km/s or drifts at warp. Each frame the anchor
// becomes a camera-relative float origin and axes (`AnchorFrame`), the only
// place its large numbers meet the camera's. Frozen API: see
// docs/m16/design-plumes-particles.md, "P3 API (frozen)".

/// An anchor's slot in the frame's table, which the GPU indexes, and its
/// generation: an id kept past its anchor's life no longer resolves.
public struct EffectAnchorID: Hashable {
    public let slot: Int
    public let generation: Int

    public init(slot: Int, generation: Int) {
        self.slot = slot
        self.generation = generation
    }
}

/// Look-dev's studio: an anchor fixed to the camera's target, in its east,
/// north and up axes (`EffectTargetFrame`), with an air and gravity of its
/// own, so a shot is the same whatever the scenario's physics.
public struct StudioAnchor: Equatable {
    /// m/s², east, north, up.
    public var gravity: Vec3
    /// The air, the same at every height; its velocity is the wind (east, north, up).
    public var air: ParticlePhysics.Air

    public init(gravity: Vec3 = .zero, air: ParticlePhysics.Air = .vacuum) {
        self.gravity = gravity
        self.air = air
    }
}

/// Where particles live.
public enum EffectAnchor: Equatable {
    /// Fixed to a body (the pad, a splash): `origin` in the body's own axes,
    /// m from its centre. Particles move in those axes, under gravity down
    /// the local vertical, through the wind; Coriolis is neglected.
    case bodyFixed(bodyID: Int, origin: Vec3)
    /// Falling freely about a body (a staging's debris, a vessel's vent):
    /// its state relative to the body's centre (ICRF, m and m/s) at `epoch`,
    /// carried on with two-body + J2 gravity. Particles move in ICRF axes.
    /// The anchor falls with them, so their weight is gone; Archimedes'
    /// buoyancy is not, and the air, turning with the body (ω × r plus the
    /// wind, less the anchor's velocity), accelerates at −g relative to it.
    /// A particle's slip through the air is then exactly as in a body-fixed
    /// anchor. An anchor that falls deep into its body (below half its
    /// radius: one left at the ground for ten minutes) is retired with its
    /// particles.
    case freeFall(bodyID: Int, position: Vec3, velocity: Vec3, epoch: Epoch)
    /// Look-dev's studio (`StudioAnchor`).
    case studio(StudioAnchor)

    /// The longest step free fall is carried on in, s.
    public static let maximumStep = 10.0

    /// The anchor carried on to `epoch` (free fall); the others as they are.
    /// Two-body + J2 (`CelestialBody.gravity`), RK4 in steps of at most
    /// `maximumStep`.
    public func propagated(to epoch: Epoch, body: RenderScene.Body?) -> EffectAnchor {
        propagatedAboveHalfRadius(to: epoch, body: body) ?? self
    }

    /// As `propagated`, nil once a free-fall anchor has fallen below half
    /// its body's radius on the way (one left at the ground for ten
    /// minutes): it is retired before its orbit dives through the centre.
    public func propagatedAboveHalfRadius(to epoch: Epoch, body: RenderScene.Body?) -> EffectAnchor? {
        guard case let .freeFall(id, r0, v0, t0) = self, let body, body.gm > 0 else { return self }
        let total = epoch - t0
        guard total != 0 else { return self }
        let n = max(1, Int((abs(total) / Self.maximumStep).rounded(.up)))
        let h = total / Double(n)
        let pole = body.orientation.icrfToBody.r2
        func accel(_ r: Vec3) -> Vec3 { Self.gravity(at: r, body: body, pole: pole) }
        var r = r0, v = v0
        for _ in 0..<n {
            let a1 = accel(r)
            let r2 = r + v * (h / 2), v2 = v + a1 * (h / 2)
            let a2 = accel(r2)
            let r3 = r + v2 * (h / 2), v3 = v + a2 * (h / 2)
            let a3 = accel(r3)
            let r4 = r + v3 * h, v4 = v + a3 * h
            let a4 = accel(r4)
            r = r + (v + v2 * 2 + v3 * 2 + v4) * (h / 6)
            v = v + (a1 + a2 * 2 + a3 * 2 + a4) * (h / 6)
            guard r.length >= 0.5 * body.radius, r.length.isFinite, v.length.isFinite else { return nil }
        }
        return .freeFall(bodyID: id, position: r, velocity: v, epoch: epoch)
    }

    /// Two-body + J2 about `pole`, as `CelestialBody.gravity(at:pole:)`.
    public static func gravity(at r: Vec3, body: RenderScene.Body, pole: Vec3) -> Vec3 {
        let r2 = r.lengthSquared, rn = r2.squareRoot()
        var a = r * (-body.gm / (r2 * rn))
        if body.j2 != 0 {
            let zc = r.dot(pole)
            let k = -1.5 * body.j2 * body.gm * body.radius * body.radius / (r2 * r2 * rn)
            a += (r * (1 - 5 * zc * zc / r2) + pole * (2 * zc)) * k
        }
        return a
    }

    /// The body it is about, or nil for the studio.
    public var bodyID: Int? {
        switch self {
        case .bodyFixed(let id, _), .freeFall(let id, _, _, _): id
        case .studio: nil
        }
    }
}

/// An anchor as one frame's GPU takes it, still in double precision: its
/// origin relative to the camera and its axes, and what the particles in it
/// feel. The renderer turns it to float (EffectAnchors.swift).
public struct AnchorFrame: Equatable {
    /// The anchor's origin, camera-relative, m.
    public var origin: Vec3
    /// Its axes to world (ICRF), columns.
    public var toWorld: Mat3
    /// Unit, in its axes: up (away from the body), east and north at the origin.
    public var up: Vec3
    public var east: Vec3
    public var north: Vec3
    /// The origin's height above the body's surface (geodetic), and the
    /// ground's under it (the kill plane), m.
    public var altitude: Double
    public var groundAltitude: Double
    /// The body's radius there, m: a particle at p is at
    /// altitude + p·up + |p⊥|² / (2 R).
    public var radius: Double
    /// The body's gravity at the origin, in its axes, m/s².
    public var gravity: Vec3
    /// The anchor falls freely at `gravity` with its particles: their weight
    /// is gone, but not Archimedes' buoyancy, and the air accelerates at
    /// −`gravity` relative to it (`ParticlePhysics.Environment.freeFall`).
    public var fallsFreely: Bool
    /// The air's velocity relative to the anchor at its origin, less the
    /// wind, in its axes (free fall: ω × r − v; else zero), and the body's
    /// rotation (free fall: the air at p moves ω × p more; else zero).
    public var airVelocity: Vec3
    public var rotation: Vec3
    /// The frame's air profile the anchor reads (`EffectFrameOutput.airProfiles`), nil in vacuum.
    public var airProfile: Int?
    /// How much of the Sun's disc the origin sees (`Eclipse.sunlitFraction`).
    public var sunlitFraction: Double
    /// Ice's temperature in vacuum there (`IceSublimation.radiativeEquilibriumTemperature`), K.
    public var vacuumIceTemperature: Double
    /// Lit by the Sun as it is above any air, whatever the camera's air
    /// says (the studio); otherwise by the Sun through the air the camera
    /// is in (A2's), times `sunlitFraction`.
    public var sunAboveAir: Bool

    public init(origin: Vec3, toWorld: Mat3, up: Vec3, east: Vec3, north: Vec3, altitude: Double,
                groundAltitude: Double, radius: Double, gravity: Vec3, fallsFreely: Bool = false, airVelocity: Vec3,
                rotation: Vec3, airProfile: Int?, sunlitFraction: Double, vacuumIceTemperature: Double,
                sunAboveAir: Bool = false) {
        self.origin = origin
        self.toWorld = toWorld
        self.up = up
        self.east = east
        self.north = north
        self.altitude = altitude
        self.groundAltitude = groundAltitude
        self.radius = radius
        self.gravity = gravity
        self.fallsFreely = fallsFreely
        self.airVelocity = airVelocity
        self.rotation = rotation
        self.airProfile = airProfile
        self.sunlitFraction = sunlitFraction
        self.vacuumIceTemperature = vacuumIceTemperature
        self.sunAboveAir = sunAboveAir
    }

    /// The camera-relative world position of `p`, given in the anchor's axes.
    public func world(_ p: Vec3) -> Vec3 { origin + toWorld * p }

    /// The altitude of `p` (anchor axes), m, as the GPU reckons it.
    public func altitude(of p: Vec3) -> Double {
        let along = p.dot(up), across = (p - up * along).lengthSquared
        return altitude + along + across / (2 * max(radius, 1))
    }
}

extension EffectAnchor {
    /// Local east, north and up at a body-fixed point of `figure`, body axes.
    static func localAxes(_ p: Vec3, figure: Ellipsoid) -> (east: Vec3, north: Vec3, up: Vec3) {
        let up = figure.normal(at: p)
        var east = Vec3.unitZ.cross(up)
        if east.length < 1e-9 { east = Vec3.unitX.cross(up) }
        east = east.normalized
        return (east, up.cross(east), up)
    }

    /// This anchor for one frame of `scene`. `airProfile` gives the index
    /// of a body's air in the frame's profiles (nil for none);
    /// `iceTemperature` the vacuum ice temperature for a sunlit fraction;
    /// `studioProfile` the studio's air's index.
    public func frame(in scene: RenderScene, airProfile: (Int) -> Int?, studioProfile: Int?,
                      iceTemperature: (Double) -> Double) -> AnchorFrame? {
        let occulters = scene.bodies.filter { !$0.isSun }.map { (center: $0.position, radius: $0.radius) }
        func lit(_ p: Vec3) -> Double {
            Eclipse.sunlitFraction(at: p, sun: scene.sun.position, occulters: occulters)
        }
        switch self {
        case let .bodyFixed(id, origin):
            guard let body = scene.bodies.first(where: { $0.id == id }) else { return nil }
            let toWorld = body.orientation.icrfToBody.transposed
            let world = body.position + toWorld * origin
            let axes = Self.localAxes(origin, figure: body.figure)
            let height = body.figure.geodetic(origin).height
            let g = Self.gravity(at: toWorld * origin, body: body, pole: body.orientation.icrfToBody.r2)
            let sunlit = lit(world)
            return AnchorFrame(origin: world, toWorld: toWorld, up: axes.up, east: axes.east, north: axes.north,
                               altitude: height, groundAltitude: 0, radius: origin.length,
                               gravity: axes.up * -g.length, airVelocity: .zero, rotation: .zero,
                               airProfile: airProfile(id), sunlitFraction: sunlit,
                               vacuumIceTemperature: iceTemperature(sunlit))
        case let .freeFall(id, r, v, _):
            guard let body = scene.bodies.first(where: { $0.id == id }) else { return nil }
            let toBody = body.orientation.icrfToBody, toWorld = toBody.transposed
            let fixed = toBody * r
            let axes = Self.localAxes(fixed, figure: body.figure)
            let height = body.figure.geodetic(fixed).height
            let omega = body.orientation.angularVelocity
            let world = body.position + r
            let sunlit = lit(world)
            return AnchorFrame(origin: world, toWorld: .identity, up: toWorld * axes.up, east: toWorld * axes.east,
                               north: toWorld * axes.north, altitude: height, groundAltitude: 0, radius: r.length,
                               gravity: Self.gravity(at: r, body: body, pole: toBody.r2), fallsFreely: true,
                               airVelocity: omega.cross(r) - v, rotation: omega,
                               airProfile: airProfile(id), sunlitFraction: sunlit,
                               vacuumIceTemperature: iceTemperature(sunlit))
        case let .studio(s):
            let t = EffectTargetFrame(scene: scene)
            let toWorld = Mat3(columns: t.east, t.north, t.up)
            return AnchorFrame(origin: t.origin, toWorld: toWorld, up: .unitZ, east: .unitX, north: .unitY,
                               altitude: 0, groundAltitude: -.infinity, radius: 6.371e6, gravity: s.gravity,
                               airVelocity: .zero, rotation: .zero, airProfile: s.air.isVacuum ? nil : studioProfile,
                               sunlitFraction: 1, vacuumIceTemperature: iceTemperature(1), sunAboveAir: true)
        }
    }
}
