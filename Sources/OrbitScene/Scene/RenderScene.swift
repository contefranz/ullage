import Foundation
import OrbitCore

/// One frame of the world as the renderer draws it: a value snapshot that
/// `SceneExtractor` builds from the simulation and the camera, so the
/// renderer never reads live `Vessel` classes while it encodes (and a later
/// simulation thread can publish it). Positions are camera-relative and in
/// double precision, in ICRF axes, metres; the renderer converts to float
/// only after subtracting the camera.
public struct RenderScene {
    public var clock: Clock
    public var camera: Camera
    public var sun: Sun
    /// Farthest from the camera first, the order they are drawn in.
    public var bodies: [Body]
    /// In the simulation's order.
    public var vessels: [Vessel]
    /// One per thruster delivering thrust, vessel by vessel, part by part.
    public var emitters: [Emitter]
    /// Deployed parachute canopies, vessel by vessel.
    public var canopies: [Canopy]
    /// Body-fixed sites (the launch complex), placed for this frame.
    public var sites: [Site]
    /// What happened since the previous scene: the core's events, and
    /// vessels appearing and going.
    public var transitions: [Transition]
    /// The focus vessel's orbit and its markers, when shown.
    public var orbit: OrbitOverlay?

    public init(clock: Clock, camera: Camera, sun: Sun, bodies: [Body] = [], vessels: [Vessel] = [],
                emitters: [Emitter] = [], canopies: [Canopy] = [], sites: [Site] = [],
                transitions: [Transition] = [], orbit: OrbitOverlay? = nil) {
        self.clock = clock
        self.camera = camera
        self.sun = sun
        self.bodies = bodies
        self.vessels = vessels
        self.emitters = emitters
        self.canopies = canopies
        self.sites = sites
        self.transitions = transitions
        self.orbit = orbit
    }

    public func vessel(_ id: UUID) -> Vessel? { vessels.first { $0.id == id } }

    // MARK: Time

    public struct Clock {
        /// The simulation's epoch.
        public var simTime: Epoch
        /// Simulation seconds since the previous scene (0 for the first).
        public var simDt: Double
        /// Wall-clock seconds, monotonic (given by the spec in snapshots).
        public var realTime: Double
        /// Wall-clock seconds since the previous scene (0 for the first).
        public var realDt: Double
        public var warp: Double
        public var paused: Bool
        /// Scenes extracted since the extractor was reset, this one included.
        public var frameIndex: Int
        /// Simulation seconds from the epoch the extractor was reset at.
        public var simTimeOfScene: Double
        /// History is stale: a camera cut, a scenario load, a change of warp,
        /// or the body under the camera turned more than 0.5° since the last
        /// scene. Temporal passes drop their history.
        public var temporalReset: Bool

        public init(simTime: Epoch, simDt: Double = 0, realTime: Double = 0, realDt: Double = 0, warp: Double = 1,
                    paused: Bool = false, frameIndex: Int = 1, simTimeOfScene: Double = 0, temporalReset: Bool = true) {
            self.simTime = simTime
            self.simDt = simDt
            self.realTime = realTime
            self.realDt = realDt
            self.warp = warp
            self.paused = paused
            self.frameIndex = frameIndex
            self.simTimeOfScene = simTimeOfScene
            self.temporalReset = temporalReset
        }

        /// Times safe to hand a shader as Float: wall-clock seconds modulo an
        /// hour and scene seconds modulo a day (a TDB epoch of about 1e9 s
        /// would have 64 s steps).
        public var shaderRealTime: Double { realTime.truncatingRemainder(dividingBy: 3_600) }
        public var shaderSimTime: Double { simTimeOfScene.truncatingRemainder(dividingBy: 86_400) }
    }

    // MARK: Camera

    public struct Viewport: Equatable {
        /// Drawable size, pixels.
        public var width: Double
        public var height: Double
        /// Pixels per point (the display's backing scale; 2 offscreen).
        public var pointScale: Double

        public init(width: Double, height: Double, pointScale: Double = 2) {
            self.width = width
            self.height = height
            self.pointScale = pointScale
        }
    }

    public struct Camera {
        /// Barycentric, m.
        public var position: Vec3
        /// Rows: the camera's right, up and back (world to view).
        public var worldToView: Mat3
        /// Vertical field of view, rad.
        public var fovY: Double
        /// Near plane of the infinite reversed-Z projection, m.
        public var near: Double
        public var viewport: Viewport
        /// The fraction of the viewport rendered (1; dynamic resolution later).
        public var renderScale: Double
        public var target: CameraTarget
        public var targetName: String

        public init(position: Vec3, worldToView: Mat3, fovY: Double, near: Double = Camera.externalNear,
                    viewport: Viewport, renderScale: Double = 1, target: CameraTarget, targetName: String = "") {
            self.position = position
            self.worldToView = worldToView
            self.fovY = fovY
            self.near = near
            self.viewport = viewport
            self.renderScale = renderScale
            self.target = target
            self.targetName = targetName
        }

        /// The external camera's near plane, m.
        public static let externalNear = 0.25

        /// Width over height.
        public var aspect: Double { viewport.width / max(viewport.height, 1) }
        /// Pixels per radian at the centre of the view.
        public var pixelsPerRadian: Double { viewport.height / (2 * tan(fovY / 2)) }
    }

    // MARK: Sun and bodies

    public struct Sun {
        /// Camera-relative position of its centre, m.
        public var position: Vec3
        /// Unit vector from the camera.
        public var direction: Vec3
        /// From the camera, m.
        public var distance: Double
        /// Illuminance at the camera on a surface facing it, lux, above any
        /// atmosphere (`Photometry.solarIlluminanceAt1AU` over the squared
        /// distance in astronomical units).
        public var illuminance: Double
        /// Angular radius seen from the camera, rad.
        public var angularRadius: Double

        public init(position: Vec3, direction: Vec3, distance: Double, illuminance: Double, angularRadius: Double) {
            self.position = position
            self.direction = direction
            self.distance = distance
            self.illuminance = illuminance
            self.angularRadius = angularRadius
        }
    }

    public struct Body {
        /// NAIF id.
        public var id: Int
        public var name: String
        /// Camera-relative centre, m.
        public var position: Vec3
        public var orientation: BodyOrientation
        public var figure: Ellipsoid
        /// Mean radius, m: its angular size.
        public var radius: Double
        public var isSun: Bool
        /// Unit vector from its centre to the Sun's.
        public var toSun: Vec3

        public init(id: Int, name: String, position: Vec3, orientation: BodyOrientation, figure: Ellipsoid,
                    radius: Double, isSun: Bool, toSun: Vec3) {
            self.id = id
            self.name = name
            self.position = position
            self.orientation = orientation
            self.figure = figure
            self.radius = radius
            self.isSun = isSun
            self.toSun = toSun
        }

        public var distance: Double { position.length }
        public var angularRadius: Double { asin(min(1, radius / distance)) }
    }

    // MARK: Vessels

    /// A thruster's identity, stable while its part lives.
    public typealias ThrusterKey = ObjectIdentifier

    public struct Vessel {
        public var id: UUID
        public var name: String
        public var isFocus: Bool
        public var status: VesselStatus
        public var isLanded: Bool
        /// NAIF id of the body it moves about.
        public var referenceBodyID: Int
        /// Camera-relative centre of mass, m.
        public var position: Vec3
        public var attitude: Quat
        /// The construction frame's origin from the centre of mass, body axes, m.
        public var structureOrigin: Vec3
        public var boundingRadius: Double
        /// Parts, shapes and thruster mounts in the construction frame.
        public var geometry: VesselGeometry
        /// The thrusters' current directions, for the gimballed nozzles.
        public var thrusters: [ThrusterKey: ThrusterPose]
        /// Today's lighting heuristics (`LegacyLighting`).
        public var light: LegacyLight
        /// The heat shield's glow, cd/m² in linear Rec. 709, added on emissive
        /// vertices (`LegacyLighting.glowLuminance`).
        public var glow: RGB
        /// Unit velocity through the air (world); zero in vacuum.
        public var flowDirection: Vec3
        /// The plume style that tints it when drawn as a point (a main
        /// engine or a solid motor firing); nil otherwise.
        public var farPointStyle: PlumeStyle?
        /// W/m² and J/m² at the stagnation point.
        public var heatFlux: Double
        public var heatLoad: Double

        public init(id: UUID, name: String, isFocus: Bool, status: VesselStatus, isLanded: Bool, referenceBodyID: Int,
                    position: Vec3, attitude: Quat, structureOrigin: Vec3, boundingRadius: Double,
                    geometry: VesselGeometry, thrusters: [ThrusterKey: ThrusterPose], light: LegacyLight, glow: RGB,
                    flowDirection: Vec3, farPointStyle: PlumeStyle?, heatFlux: Double, heatLoad: Double) {
            self.id = id
            self.name = name
            self.isFocus = isFocus
            self.status = status
            self.isLanded = isLanded
            self.referenceBodyID = referenceBodyID
            self.position = position
            self.attitude = attitude
            self.structureOrigin = structureOrigin
            self.boundingRadius = boundingRadius
            self.geometry = geometry
            self.thrusters = thrusters
            self.light = light
            self.glow = glow
            self.flowDirection = flowDirection
            self.farPointStyle = farPointStyle
            self.heatFlux = heatFlux
            self.heatLoad = heatLoad
        }

        /// Its size on screen, pixels across its bounding radius.
        public func pixelSize(_ camera: Camera) -> Double {
            boundingRadius / max(position.length, 1e-3) * camera.pixelsPerRadian
        }
    }

    public struct ThrusterPose {
        /// Mounting direction, body axes (gimbal at null).
        public var direction: Vec3
        /// Where it thrusts now, body axes.
        public var thrustDirection: Vec3

        public init(direction: Vec3, thrustDirection: Vec3) {
            self.direction = direction
            self.thrustDirection = thrustDirection
        }
    }

    /// Linear RGB in single precision, as the GPU takes it.
    public struct RGB: Equatable {
        public var r: Float, g: Float, b: Float
        public init(_ r: Float, _ g: Float, _ b: Float) {
            self.r = r
            self.g = g
            self.b = b
        }
        public static let black = RGB(0, 0, 0)
    }

    /// One thruster delivering thrust: where its plume starts and how it looks.
    public struct Emitter {
        public var vesselID: UUID
        public var thruster: ThrusterKey
        public var name: String
        /// Camera-relative centre of the nozzle exit (or the thruster's
        /// position for a jet with no nozzle shape), m.
        public var exit: Vec3
        /// Unit exhaust direction (world).
        public var axis: Vec3
        public var exitRadius: Double
        public var style: PlumeStyle
        /// Delivered thrust over the vacuum rating.
        public var thrustFraction: Double
        /// Ambient pressure over sea level's.
        public var pressureRatio: Double
        public var isSolid: Bool
        /// An attitude or ullage jet (not a main engine, not a solid).
        public var isJet: Bool

        public init(vesselID: UUID, thruster: ThrusterKey, name: String, exit: Vec3, axis: Vec3, exitRadius: Double,
                    style: PlumeStyle, thrustFraction: Double, pressureRatio: Double, isSolid: Bool, isJet: Bool) {
            self.vesselID = vesselID
            self.thruster = thruster
            self.name = name
            self.exit = exit
            self.axis = axis
            self.exitRadius = exitRadius
            self.style = style
            self.thrustFraction = thrustFraction
            self.pressureRatio = pressureRatio
            self.isSolid = isSolid
            self.isJet = isJet
        }
    }

    /// A deployed canopy: the unit dome (`CanopyGeometry`) scaled by `sx`
    /// along `axis` and `sr` across, its skirt at `skirt`, and its risers.
    public struct Canopy {
        public var vesselID: UUID
        /// A main (ringsail) canopy; a drogue otherwise.
        public var isMain: Bool
        /// Unit vectors (world): the canopy's axis, skirt to vent, and two across it.
        public var axis: Vec3, side: Vec3, other: Vec3
        /// Camera-relative centre of the skirt, m.
        public var skirt: Vec3
        public var sx: Double, sr: Double
        /// Camera-relative riser lines, confluence to skirt, m.
        public var risers: [(Vec3, Vec3)]

        public init(vesselID: UUID, isMain: Bool, axis: Vec3, side: Vec3, other: Vec3, skirt: Vec3, sx: Double,
                    sr: Double, risers: [(Vec3, Vec3)]) {
            self.vesselID = vesselID
            self.isMain = isMain
            self.axis = axis
            self.side = side
            self.other = other
            self.skirt = skirt
            self.sx = sx
            self.sr = sr
            self.risers = risers
        }
    }

    /// A body-fixed site (`SitePlacement`) placed for this frame.
    public struct Site {
        public var name: String
        public var bodyID: Int
        /// Camera-relative origin, m.
        public var origin: Vec3
        /// Site axes to world, columns: forward (along the placement's
        /// azimuth), left, up (the geodetic normal).
        public var orientation: Mat3
        public var placement: SitePlacement

        public init(name: String, bodyID: Int, origin: Vec3, orientation: Mat3, placement: SitePlacement) {
            self.name = name
            self.bodyID = bodyID
            self.origin = origin
            self.orientation = orientation
            self.placement = placement
        }
    }

    // MARK: Overlay

    public struct OrbitOverlay {
        /// Camera-relative line strips, m.
        public var strips: [[Vec3]]
        /// The markers whose anchors no body hides.
        public var markers: [OrbitMarker]

        public init(strips: [[Vec3]], markers: [OrbitMarker]) {
            self.strips = strips
            self.markers = markers
        }
    }

    public struct OrbitMarker {
        public var kind: OrbitMarkerKind
        /// Camera-relative anchor, m.
        public var position: Vec3
        public var text: String?

        public init(kind: OrbitMarkerKind, position: Vec3, text: String?) {
            self.kind = kind
            self.position = position
            self.text = text
        }
    }
}

/// The markers on the focus vessel's orbit line.
public enum OrbitMarkerKind: CaseIterable {
    case periapsis, apoapsis, ascendingNode, descendingNode, entryInterface

    public var label: String {
        switch self {
        case .periapsis: "Pe"
        case .apoapsis: "Ap"
        case .ascendingNode: "AN"
        case .descendingNode: "DN"
        case .entryInterface: "EI"
        }
    }
}

/// Where a body-fixed site stands: geodetic latitude and longitude (rad),
/// height above the figure (m) and the azimuth of its forward axis (rad,
/// from north towards east).
public struct SitePlacement: Equatable {
    public var name: String
    public var bodyID: Int
    public var latitude: Double
    public var longitude: Double
    public var height: Double
    public var azimuth: Double

    public init(name: String, bodyID: Int, latitude: Double, longitude: Double, height: Double, azimuth: Double = 0) {
        self.name = name
        self.bodyID = bodyID
        self.latitude = latitude
        self.longitude = longitude
        self.height = height
        self.azimuth = azimuth
    }
}
