import Foundation
import OrbitCore

/// The display modes, with the key that selects each on the mode-select page
/// (Shift and the key, as in Orbiter) and the label of its button there.
public enum MFDModeID: String, CaseIterable, Codable, Sendable {
    case orbit, surface, map, deorbit, entry

    public var name: String {
        switch self {
        case .orbit: "Orbit"
        case .surface: "Surface"
        case .map: "Map"
        case .deorbit: "Deorbit"
        case .entry: "Entry"
        }
    }

    public var selectKey: PhysicalKey {
        switch self {
        case .orbit: .o
        case .surface: .s
        case .map: .m
        case .deorbit: .d
        case .entry: .e
        }
    }

    /// The three letters of its button on the select page.
    public var label: String {
        switch self {
        case .orbit: "ORB"
        case .surface: "SRF"
        case .map: "MAP"
        case .deorbit: "DEO"
        case .entry: "ENT"
        }
    }

    /// A fresh instance of the mode, with its default settings.
    public func make() -> MFDMode {
        switch self {
        case .orbit: OrbitMFD()
        case .surface: SurfaceMFD()
        case .map: MapMFD()
        case .deorbit: DeorbitMFD()
        case .entry: EntryMFD()
        }
    }
}

/// A side button of a mode: its three-letter label, the key that presses it
/// with Shift, and a line or two of help for the menu page (MNU).
public struct MFDButton: Hashable, Sendable {
    public var label: String
    public var key: PhysicalKey
    public var help: String
    /// Drawn dim when it does nothing now.
    public var active: Bool

    public init(_ label: String, _ key: PhysicalKey, _ help: String, active: Bool = true) {
        self.label = label
        self.key = key
        self.help = help
        self.active = active
    }
}

/// A display mode: its buttons, its keys and the page it draws. A panel keeps
/// one instance of each mode it has shown, so a mode's settings survive a
/// switch to another mode and back.
public protocol MFDMode: AnyObject {
    var id: MFDModeID { get }
    /// Up to twelve, 0-5 down the left side and 6-11 down the right; nil
    /// leaves a button blank.
    func buttons(_ context: MFDContext?) -> [MFDButton?]
    /// Act on a key pressed with Shift (or its button); false if it is not
    /// this mode's.
    func handle(_ key: PhysicalKey, _ context: MFDContext?) -> Bool
    /// What a button does (the default for `handle`); false if nothing.
    func press(_ button: MFDButton, _ context: MFDContext?) -> Bool
    /// The page for the focus vessel; the title row and buttons are the
    /// controller's.
    func page(_ context: MFDContext) -> MFDPage
}

extension MFDMode {
    public func handle(_ key: PhysicalKey, _ context: MFDContext?) -> Bool {
        guard let b = buttons(context).compactMap({ $0 }).first(where: { $0.key == key }), b.active else {
            return false
        }
        return press(b, context)
    }

    /// What a button does; the default does nothing.
    public func press(_ button: MFDButton, _ context: MFDContext?) -> Bool { false }
}

// MARK: - Hooks

/// A flight program that predicts where its vessel comes down, such as E1's
/// command-module entry program (or the program hosting it). The ENTRY and
/// MAP pages show the point once the vessel's program conforms.
public protocol LandingPointPredicting: AnyObject {
    /// Geodetic latitude and longitude (rad) and when the vessel gets there;
    /// nil while there is no prediction.
    var predictedLandingPoint: (latitude: Double, longitude: Double, time: Epoch)? { get }
}

// MARK: - Environment

/// A point on a body's surface: geodetic latitude and longitude, rad.
public struct GeoPoint: Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// A named place for the map (a launch pad, a recovery target).
public struct MFDSite: Hashable, Sendable {
    public var name: String
    public var location: GeoPoint
    public init(_ name: String, latitude: Double, longitude: Double) {
        self.name = name
        location = GeoPoint(latitude: latitude, longitude: longitude)
    }
}

/// What the displays know besides the simulation: the Earth's coastlines,
/// the places to mark on the map and where the mission means to land.
public struct MFDEnvironment {
    /// The Earth's coastlines, each an open or closed line of points.
    public var coastlines: [[GeoPoint]]
    public var sites: [MFDSite]
    /// The planned landing point on the Earth, such as Apollo 7's 29.8° N
    /// 67.0° W (68-FM-184 §5.4.3): MAP marks it, and ENTRY gives the range
    /// and bearing to it and how far the predicted landing point misses it.
    /// Nil when the scenario plans none.
    public var recoveryTarget: MFDSite?
    public init(coastlines: [[GeoPoint]] = [], sites: [MFDSite] = [], recoveryTarget: MFDSite? = nil) {
        self.coastlines = coastlines
        self.sites = sites
        self.recoveryTarget = recoveryTarget
    }
}

// MARK: - Context

/// What a mode draws from: the simulation, its focus vessel at a snapshot,
/// the mission clock, and what the controller keeps for the vessel.
public struct MFDContext {
    public let sim: Simulation
    public let vessel: Vessel
    public let snapshot: SystemSnapshot
    /// Zero of the mission clock (MET); nil when none is known.
    public let missionClockZero: Epoch?
    public let data: MFDVesselData
    public let environment: MFDEnvironment

    public init(sim: Simulation, vessel: Vessel, snapshot: SystemSnapshot, missionClockZero: Epoch? = nil,
                data: MFDVesselData = MFDVesselData(), environment: MFDEnvironment = MFDEnvironment()) {
        self.sim = sim
        self.vessel = vessel
        self.snapshot = snapshot
        self.missionClockZero = missionClockZero
        self.data = data
        self.environment = environment
    }

    public var time: Epoch { snapshot.time }
    public var body: CelestialBody { vessel.reference }
    public var orientation: BodyOrientation { snapshot.orientation(vessel.reference) }

    /// The osculating elements about the reference body's pole of date; nil
    /// on the ground.
    public var elements: OrbitalElements? { vessel.landed == nil ? vessel.elements(snapshot: snapshot) : nil }

    /// The vessel's ΔV counter, when its flight program has one (track C's
    /// Apollo SCS).
    public var deltaVCounter: DeltaVCounting? { vessel.flightProgram as? DeltaVCounting }

    /// The landing point the vessel's program predicts, if it predicts one.
    public var landingPoint: (latitude: Double, longitude: Double, time: Epoch)? {
        (vessel.flightProgram as? LandingPointPredicting)?.predictedLandingPoint
    }

    /// The environment's recovery target, while the vessel is about the
    /// Earth.
    public var recoveryTarget: MFDSite? { body.id == 399 ? environment.recoveryTarget : nil }

    /// Where the ascending node's longitude is measured from: the mean
    /// equinox of date on the Earth (the textbook RAAN); elsewhere the
    /// elements' own axis.
    public var equinox: Vec3? {
        body.id == 399 ? EarthOrientation.biasPrecessionMatrix(tt: time.tt).r0 : nil
    }

    /// Engines that would fly a burn: the active stage's main engines that
    /// can run, as one engine (summed thrust, flow-weighted Isp); nil when
    /// there are none.
    public var mainEngine: DeorbitPlanner.Engine? {
        let mains = vessel.activeStage?.thrusters.filter { $0.groups.contains(.main) && $0.isAvailable && $0.hasPropellant
                                                         && !$0.isSolid } ?? []
        let thrust = mains.reduce(0) { $0 + $1.maxThrustVacuum }
        let flow = mains.reduce(0) { $0 + $1.maxThrustVacuum / $1.ispVacuum }
        guard thrust > 0, flow > 0 else { return nil }
        return DeorbitPlanner.Engine(thrust: thrust, specificImpulse: thrust / flow)
    }

    /// The vacuum predictions (ground track, EI) do not hold now: the vessel
    /// is thrusting or in the air (q of 1 Pa or more), or on the ground.
    public var predictionCaveat: String? {
        if vessel.landed != nil { return "ON THE GROUND" }
        if vessel.thrustAcceleration > 0.01 { return "THRUSTING" }
        if vessel.dynamicPressure >= 1 { return "IN THE AIR" }
        return nil
    }
}
