import Foundation

/// What `orbitsnap` renders: shots, each a scenario advanced by a script and
/// seen by a camera. A JSON file of these (`docs/look/shots/<track>.json`)
/// is a track's look-dev set; every member but `name` and `scenario` may be
/// left out.
///
///     {"shots": [{"name": "staging", "scenario": "as506-pad",
///                 "advance": ["ev:S-IC OECO", "wait:0.8"],
///                 "camera": {"yaw": 70, "pitch": 15, "distance": 140}}]}
public struct SnapshotSpec: Codable, Equatable {
    public var shots: [Shot]
    /// How the golden tests treat the shots' goldens
    /// (`Tests/OrbitRenderTests/Goldens/<gpu family>/<shot>.png`).
    public var goldens = GoldenKind.none

    /// The plan's golden policy: a track's look-dev goldens (material
    /// spheres, a plume on black, a cloud slab) fail the tests; scene
    /// goldens, which many tracks change, are reported between checkpoints
    /// and re-blessed at each (`ORBITSIM_STRICT_GOLDENS=1` makes them fail).
    public enum GoldenKind: String, Codable {
        case none
        case scene
        case lookDev = "lookdev"
    }

    public init(shots: [Shot], goldens: GoldenKind = .none) {
        self.shots = shots
        self.goldens = goldens
    }

    private enum CodingKeys: String, CodingKey { case shots, goldens }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shots = try c.decode([Shot].self, forKey: .shots)
        goldens = try c.decodeIfPresent(GoldenKind.self, forKey: .goldens) ?? .none
    }

    public static func load(_ url: URL) throws -> SnapshotSpec {
        try JSONDecoder().decode(SnapshotSpec.self, from: Data(contentsOf: url))
    }

    public struct Shot: Codable, Equatable {
        public var name: String
        /// A `Scenario` id.
        public var scenario: String
        /// `ScenarioScript` commands, run in order before the frame.
        public var advance: [String] = []
        public var camera = CameraSpec()
        /// Pixels.
        public var width = 640
        public var height = 400
        /// Pixels per point (the markers' size), as on a Retina display.
        public var pointScale = 2.0
        /// Load the user's planet textures from Application Support. Off by
        /// default, so a shot does not depend on files outside the repo.
        public var userTextures = false
        public var showOrbit = true
        public var settings = RenderSettings()
        /// Debug views to write beside the image (`<name>.<view>.png`).
        public var aovs: [DebugView] = []
        /// The wall-clock time the frame says it is, s (procedural animation).
        public var realTime = 0.0
        /// The NASA photograph the shot is matched against, for the contact sheet.
        public var reference: String?

        public init(name: String, scenario: String, advance: [String] = [], camera: CameraSpec = CameraSpec()) {
            self.name = name
            self.scenario = scenario
            self.advance = advance
            self.camera = camera
        }

        private enum CodingKeys: String, CodingKey {
            case name, scenario, advance, camera, width, height, pointScale, userTextures, showOrbit, settings, aovs
            case realTime, reference
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            scenario = try c.decode(String.self, forKey: .scenario)
            advance = try c.decodeIfPresent([String].self, forKey: .advance) ?? []
            camera = try c.decodeIfPresent(CameraSpec.self, forKey: .camera) ?? CameraSpec()
            width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 640
            height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 400
            pointScale = try c.decodeIfPresent(Double.self, forKey: .pointScale) ?? 2
            userTextures = try c.decodeIfPresent(Bool.self, forKey: .userTextures) ?? false
            showOrbit = try c.decodeIfPresent(Bool.self, forKey: .showOrbit) ?? true
            settings = try c.decodeIfPresent(RenderSettings.self, forKey: .settings) ?? RenderSettings()
            aovs = try c.decodeIfPresent([DebugView].self, forKey: .aovs) ?? []
            realTime = try c.decodeIfPresent(Double.self, forKey: .realTime) ?? 0
            reference = try c.decodeIfPresent(String.self, forKey: .reference)
        }
    }

    /// The orbit camera, as the app's: around a target, in a frame, at a yaw
    /// and pitch (degrees) and a distance.
    public struct CameraSpec: Codable, Equatable {
        /// "focus" (the scenario's focus vessel), "vessel:<name prefix>" or
        /// "body:<NAIF id>".
        public var target = "focus"
        /// "horizon", "vessel" or "inertial" (`OrbitCamera.Frame`, lower case).
        public var frame = "horizon"
        /// Degrees: the app's opening -137.5° and 14.3°.
        public var yaw = -2.4 * 180 / Double.pi
        public var pitch = 0.25 * 180 / Double.pi
        /// Metres; nil for the app's opening distance (3 bounding radii, at least 30 m).
        public var distance: Double?
        /// Vertical field of view, degrees; `lens` wins when given.
        public var fov = 50.0
        /// "hasselblad80" or "hasselblad250".
        public var lens: String?

        public init(target: String = "focus", frame: String = "horizon", yaw: Double = -2.4 * 180 / Double.pi,
                    pitch: Double = 0.25 * 180 / Double.pi, distance: Double? = nil, fov: Double = 50,
                    lens: String? = nil) {
            self.target = target
            self.frame = frame
            self.yaw = yaw
            self.pitch = pitch
            self.distance = distance
            self.fov = fov
            self.lens = lens
        }

        private enum CodingKeys: String, CodingKey { case target, frame, yaw, pitch, distance, fov, lens }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init()
            target = try c.decodeIfPresent(String.self, forKey: .target) ?? target
            frame = try c.decodeIfPresent(String.self, forKey: .frame) ?? frame
            yaw = try c.decodeIfPresent(Double.self, forKey: .yaw) ?? yaw
            pitch = try c.decodeIfPresent(Double.self, forKey: .pitch) ?? pitch
            distance = try c.decodeIfPresent(Double.self, forKey: .distance)
            fov = try c.decodeIfPresent(Double.self, forKey: .fov) ?? fov
            lens = try c.decodeIfPresent(String.self, forKey: .lens)
        }
    }
}
