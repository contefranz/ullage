import Foundation
import OrbitCore

// Track C2: what the cloud pass computes in Double each frame before it
// becomes Float: the Earth's figure coordinates around the camera, the cloud
// shells' ray constants, the noise origins (body-fixed, wrapped to the noise
// tile, advected by the layers' winds), the reprojection of body-fixed
// points into last frame's view, the cloud shadow map's frame, and the
// regimes. CloudPass turns these into its uniforms.

/// The clouds' frame for one scene: the Earth's body axes, centred on the
/// camera.
public struct CloudFrame: Equatable {
    /// WGS-84's equatorial radius, m.
    public static let earthRadius = 6_378_137.0
    /// The Earth's equatorial radius, m: the figure's sphere.
    public let radius: Double
    /// a / b: body z times this is the figure's z, where the ellipsoid is a
    /// sphere of `radius`.
    public let stretch: Double
    /// ICRF to the Earth's body axes.
    public let icrfToBody: Mat3
    /// The Earth's centre, camera-relative, ICRF (m).
    public let planetCenter: Vec3
    /// The camera in body axes from the Earth's centre (m), and in figure
    /// coordinates.
    public let cameraBody: Vec3
    public let cameraFigure: Vec3
    /// The camera's geodetic latitude, east longitude (rad) and height (m).
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double
    /// Unit vector from the Earth's centre to the Sun, body axes.
    public let sunBody: Vec3

    public init(earth: RenderScene.Body) {
        let a = earth.figure.equatorialRadius
        radius = a
        stretch = a / earth.figure.polarRadius
        icrfToBody = earth.orientation.icrfToBody
        planetCenter = earth.position
        let cam = earth.orientation.toBody(-earth.position)
        cameraBody = cam
        cameraFigure = Vec3(cam.x, cam.y, cam.z * stretch)
        let g = earth.figure.geodetic(cam)
        latitude = g.latitude
        longitude = g.longitude
        altitude = g.height
        sunBody = earth.orientation.toBody(earth.toSun).normalized
    }

    /// The Earth in `scene`, nil when it has none.
    public static func earth(in scene: RenderScene) -> RenderScene.Body? { scene.bodies.first { $0.id == 399 } }

    /// |o|² − r² for the camera's figure position o and a shell of radius r,
    /// as (|o| − r)(|o| + r) in Double, so that the ray's quadratic keeps the
    /// camera's height near the surface (as PlanetPass does).
    public func shellConstant(height h: Double) -> Double {
        let o = cameraFigure.length, r = radius + h
        return (o - r) * (o + r)
    }

    /// A body-fixed position wrapped to [0, tile) per axis: the noise
    /// origin, exact in Double before it becomes Float.
    public static func wrap(_ p: Vec3, tile: Double) -> Vec3 {
        func w(_ x: Double) -> Double { x - (x / tile).rounded(.down) * tile }
        return Vec3(w(p.x), w(p.y), w(p.z))
    }

    /// East and north at the camera's geodetic position, body axes.
    public var eastNorth: (east: Vec3, north: Vec3) {
        let east = Vec3(-sin(longitude), cos(longitude), 0)
        let north = Vec3(-sin(latitude) * cos(longitude), -sin(latitude) * sin(longitude), cos(latitude))
        return (east, north)
    }

    // MARK: Reprojection

    /// Where last frame saw a body-fixed point this frame sees at
    /// camera-relative p: R p + t, camera-relative in last frame's ICRF axes
    /// (R = B_prev^T B, t = c_prev − R c, with B the body axes and c the
    /// Earth's centre). Its product with last frame's view-projection takes
    /// this frame's camera-relative world to last frame's clip space.
    public func reprojection(from previous: CloudFrame) -> (rotation: Mat3, translation: Vec3) {
        let r = previous.icrfToBody.transposed * icrfToBody
        return (r, previous.planetCenter - r * planetCenter)
    }

    // MARK: Shadow map

    /// The cloud shadow map's frame: an orthographic view along the Sun,
    /// `extent` m across in `texels` texels, centred on the camera's ground
    /// point snapped to whole texels of a lattice through the Earth's centre
    /// in the map's plane, so that it does not swim as the camera moves (an
    /// anchor near the camera jumped by 8 km at a time, a fraction of a
    /// texel each time). As the Sun turns about the Earth the lattice turns
    /// with it, under a texel a minute at the ground.
    public struct ShadowMap: Equatable {
        /// Its centre, body axes from the Earth's centre (m).
        public let center: Vec3
        /// Its axes: u and v across the map, and the Sun's direction.
        public let u: Vec3
        public let v: Vec3
        public let sun: Vec3
        public let extent: Double
        public let texels: Int

        /// The map's uv (0...1 across) and the height along the Sun (m) of a
        /// body-fixed point.
        public func coordinates(_ p: Vec3) -> (u: Double, v: Double, along: Double) {
            let d = p - center
            return (0.5 + d.dot(u) / extent, 0.5 + d.dot(v) / extent, d.dot(sun))
        }

        /// The body-fixed point of map coordinates (u, v), at `along` m
        /// along the Sun from the map's plane.
        public func point(u x: Double, v y: Double, along: Double) -> Vec3 {
            center + u * ((x - 0.5) * extent) + v * ((y - 0.5) * extent) + sun * along
        }
    }

    /// The shadow map's extent, m: 100 km on the ground, growing with the
    /// camera's height (four times it) to 1,000 km from orbit.
    public static func shadowExtent(altitude: Double) -> Double {
        min(max(100_000 + 4 * altitude, 100_000), 1_000_000)
    }

    public func shadowMap(texels: Int, extent: Double? = nil) -> ShadowMap {
        let extent = extent ?? Self.shadowExtent(altitude: altitude)
        let s = sunBody
        // Axes across the Sun: from the pole unless the Sun is near it.
        let ref = abs(s.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)
        let u = ref.cross(s).normalized, v = s.cross(u)
        let ground = cameraBody.normalized * radius, texel = extent / Double(texels)
        let center = u * ((ground.dot(u) / texel).rounded() * texel) + v * ((ground.dot(v) / texel).rounded() * texel)
            + s * ground.dot(s)
        return ShadowMap(center: center, u: u, v: v, sun: s, extent: extent, texels: texels)
    }

    // MARK: Regimes

    /// The regimes' weights at the camera's height (docs/m16/design-earth-
    /// moon.md, clouds): `near` (the volumetric march with its detail, below
    /// about 20 km), the `orbit` slab march, and the far surface layer (from
    /// about 5,000 km). Each crosses smoothly into the next. The march itself
    /// fades its detail and lengthens its steps with each sample's distance
    /// and the pixel's footprint, so the weights only set its budget.
    public static func regimes(altitude h: Double) -> (near: Double, orbit: Double, far: Double) {
        let near = 1 - smoothstep(12_000, 30_000, h)
        let far = smoothstep(3_000_000, 6_000_000, h)
        return (near, max(1 - near - far, 0), far)
    }

    public static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// The detail noise drifting with the layers' winds: the body-fixed offset
/// each layer's noise has travelled, accumulated in Double from the wind at
/// the camera's ground point and the simulation's time steps, wrapped to the
/// noise tile. Continuous at any warp; reset with the scene.
public struct CloudAdvection: Equatable {
    /// Body-fixed offsets (m) of the low, mid and high layers' noise.
    public private(set) var offsets: [Vec3] = [Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(0, 0, 0)]
    public let tile: Double

    public init(tile: Double) {
        self.tile = tile
    }

    /// Moves each layer by its wind (east, north; m/s) for `dt` s at the
    /// camera's ground point. Winds the field does not know are calm.
    public mutating func advance(_ frame: CloudFrame, winds: [LayerWind?], dt: Double) {
        guard dt.isFinite, dt != 0 else { return }
        let axes = frame.eastNorth
        for i in 0..<min(offsets.count, winds.count) {
            guard let w = winds[i] else { continue }
            let step = axes.east * (w.east * dt) + axes.north * (w.north * dt)
            offsets[i] = CloudFrame.wrap(offsets[i] - step, tile: tile)
        }
    }
}

/// The cirrus's streak frame (docs/look/clouds.md, cirrus): a body-fixed
/// anchor on the ground with axes along the high wind there, across it and
/// up, and the wind's drift. The fibres are the shape volume at (x·along /
/// 8, x·across, x·up) from the anchor, so they stay put as the camera moves
/// and turns (a frame at the camera turned with it: fibres far away swam),
/// and the camera's noise coordinate wraps by whole periods (a body-axis
/// wrap of a stretched coordinate jumped by a fraction of one).
public struct CirrusFrame: Equatable {
    public let anchor: Vec3
    public let along: Vec3
    public let across: Vec3
    public let up: Vec3
    /// The wind's drift, noise-space metres (along already divided by 8).
    public private(set) var drift = Vec3(0, 0, 0)

    /// The fibres' stretch along the wind.
    public static let stretch = 8.0

    /// A frame at the camera's ground point, its fibres along `streak` (a
    /// horizontal direction there; east when the wind is calm).
    public init(_ frame: CloudFrame, streak: Vec3) {
        let up = frame.cameraBody.normalized
        var a = streak - up * streak.dot(up)
        if a.length < 1e-6 { a = frame.eastNorth.east }
        a = a.normalized
        anchor = up * frame.radius
        along = a
        across = up.cross(a).normalized
        self.up = up
    }

    /// The camera's noise coordinate (noise-space m), wrapped to [0, period).
    public func origin(camera: Vec3, period: Double) -> Vec3 {
        let r = camera - anchor
        return CloudFrame.wrap(Vec3(r.dot(along) / Self.stretch, r.dot(across), r.dot(up)) + drift, tile: period)
    }

    /// Moves the fibres with the wind (east, north; m/s) for `dt` s.
    public mutating func advance(_ frame: CloudFrame, wind: LayerWind?, dt: Double, period: Double) {
        guard let wind, dt.isFinite, dt != 0 else { return }
        let axes = frame.eastNorth
        let step = axes.east * (wind.east * dt) + axes.north * (wind.north * dt)
        drift = CloudFrame.wrap(drift - Vec3(step.dot(along) / Self.stretch, step.dot(across), step.dot(up)), tile: period)
    }

    /// The camera has gone `reach` m from the anchor, or the wind there has
    /// turned more than `turn` from the frame's: time for a new one.
    public func stale(_ frame: CloudFrame, streak: Vec3) -> Bool {
        if (frame.cameraBody.normalized * frame.radius - anchor).length > Self.reach { return true }
        let up = frame.cameraBody.normalized
        let a = streak - up * streak.dot(up)
        guard a.length > 1e-6 else { return false }
        return a.normalized.dot(along) < cos(Self.turn)
    }

    public static let reach = 1_000_000.0
    public static let turn = 30.0 * .pi / 180
}

/// The cirrus's current frame and the one it replaced, fading out over
/// `fadeTime` s of wall clock (the two drawn and mixed meanwhile).
public struct CirrusFrames: Equatable {
    public private(set) var current: CirrusFrame?
    public private(set) var previous: CirrusFrame?
    /// The previous frame's weight, 1 to 0.
    public private(set) var fade = 0.0
    public static let fadeTime = 2.0

    public init() {}

    public mutating func update(_ frame: CloudFrame, streak: Vec3, wind: LayerWind?, dt: Double, realDt: Double,
                                period: Double) {
        fade = max(fade - realDt / Self.fadeTime, 0)
        if fade <= 0 { previous = nil }
        if let c = current, !c.stale(frame, streak: streak) {
            current?.advance(frame, wind: wind, dt: dt, period: period)
            previous?.advance(frame, wind: wind, dt: dt, period: period)
            return
        }
        previous = current
        fade = previous == nil ? 0 : 1
        current = CirrusFrame(frame, streak: streak)
    }
}

/// When the near field may reuse last frame's clouds (docs/m16/design-
/// earth-moon.md, performance (a)): never at 10× warp or more, after a
/// temporal reset, or when the clouds move more than 1.5 pixels a frame on
/// the screen; then each frame is marched fresh.
public enum CloudReprojection {
    public static let maximumWarp = 10.0
    public static let maximumMotion = 1.5

    public static func allowed(warp: Double, temporalReset: Bool, motionPixels: Double) -> Bool {
        !temporalReset && warp < maximumWarp && motionPixels.isFinite && motionPixels <= maximumMotion
    }
}
