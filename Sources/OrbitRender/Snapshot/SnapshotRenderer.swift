import Foundation
import Metal
import OrbitCore
import OrbitScene

/// Renders snapshot shots offscreen: the scenario, its script, the camera,
/// the frame and the debug views it asks for, and, on request, the GPU time
/// of each pass. `orbitsnap`, the golden tests and the app's F12 use it.
@MainActor
public final class SnapshotRenderer {
    public let device: MTLDevice
    public let system: SolarSystem
    public let stars: [Star]
    private var renderers = [Bool: SceneRenderer]()
    /// The GPU time of the frame a renderer just finished, s (a seam for tests).
    var frameGPUTime: (SceneRenderer) -> Double? = { $0.lastReport?.gpu }

    public init(device: MTLDevice? = nil) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else { throw SceneRenderer.Failure.noDevice }
        self.device = device
        system = try SolarSystem.bundled()
        stars = try StarCatalog.bundled()
    }

    /// The renderer for shots with or without the user's planet textures.
    public func renderer(userTextures: Bool) throws -> SceneRenderer {
        if let r = renderers[userTextures] { return r }
        let r = try SceneRenderer(device: device, loadsUserTextures: userTextures)
        r.setStars(stars)
        renderers[userTextures] = r
        return r
    }

    public struct Output {
        public let shot: SnapshotSpec.Shot
        /// BGRA, rows top first.
        public let pixels: [UInt8]
        /// The debug views the shot asked for, BGRA.
        public let aovs: [(view: DebugView, pixels: [UInt8])]
        /// Median GPU time of each pass over the timed frames.
        public let timings: [PassTiming]
        /// A timed (split) frame's pixels, which must equal `pixels`; nil
        /// without timing.
        public let profiledPixels: [UInt8]?
        public let record: SnapshotRecord
    }

    /// Renders `shot`; with `timingFrames` > 0 also renders that many frames
    /// split and timed, keeping each pass's median, and that many unsplit,
    /// keeping the median GPU time of the whole frame.
    public func render(_ shot: SnapshotSpec.Shot, timingFrames: Int = 0) throws -> Output {
        let prepared = try shot.prepare(system: system)
        let scene = shot.scene(prepared)
        let r = try renderer(userTextures: shot.userTextures)
        guard let target = OffscreenTarget(device: device, width: shot.width, height: shot.height) else {
            throw SceneRenderer.Failure.noResources
        }
        var gpuTimes: [Double] = []
        func frame(_ settings: RenderSettings) -> [UInt8] {
            r.settings = settings
            r.renderAndWait(scene, into: target)
            gpuTimes.append(frameGPUTime(r) ?? 0)
            return target.bytes()
        }
        let pixels = frame(shot.settings)
        var gpu = gpuTimes[0]       // the main frame's, not an AOV's
        var aovs: [(view: DebugView, pixels: [UInt8])] = []
        for view in shot.aovs where view != .none {
            var s = shot.settings
            s.debug.view = view
            aovs.append((view, frame(s)))
        }
        var timings: [PassTiming] = [], profiledPixels: [UInt8]?
        if timingFrames > 0 {
            r.profiling = true
            r.profileInterval = 1
            var samples = [String: [Double]](), order: [String] = []
            for _ in 0..<timingFrames {
                let image = frame(shot.settings)
                if profiledPixels == nil { profiledPixels = image }
                for t in r.lastReport?.passes ?? [] {
                    if samples[t.pass] == nil { order.append(t.pass) }
                    samples[t.pass, default: []].append(t.seconds)
                }
            }
            r.profiling = false
            r.profileInterval = 4
            timings = order.map { PassTiming(pass: $0, seconds: Self.median(samples[$0]!)) }
            for _ in 0..<timingFrames { _ = frame(shot.settings) }
            gpu = Self.median(Array(gpuTimes.suffix(timingFrames)))
        }
        r.settings = RenderSettings()
        let record = SnapshotRecord(shot: shot, prepared: prepared, scene: scene, gpuSeconds: gpu, timings: timings,
                                    failures: r.failures, gpuFamily: GPUFamily.name(device))
        return Output(shot: shot, pixels: pixels, aovs: aovs, timings: timings, profiledPixels: profiledPixels,
                      record: record)
    }

    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : 0.5 * (s[s.count / 2 - 1] + s[s.count / 2])
    }
}

/// What a snapshot was, written beside it as JSON.
public struct SnapshotRecord: Codable {
    public var name: String
    public var scenario: String
    public var advance: [String]
    public var reference: String?
    /// UTC of the frame, and the mission clock (s) when the scenario has one.
    public var utc: String
    public var missionTime: Double?
    public var width: Int
    public var height: Int
    public var camera: Camera
    public var vessels: [String]
    /// 1 until R1's HDR: the PNG is the frame, the PFM its linear light.
    public var preExposure: Double
    public var gpuFamily: String
    /// The frame's GPU time and each pass's (when timed), ms.
    public var gpuMilliseconds: Double
    public var passMilliseconds: [String: Double]
    public var passOrder: [String]
    /// Disabled passes and failed shader modules, with why.
    public var failures: [String: String]

    public struct Camera: Codable {
        public var target: String
        public var frame: String
        public var yaw: Double
        public var pitch: Double
        public var distance: Double
        public var fovY: Double
    }

    init(shot: SnapshotSpec.Shot, prepared p: SnapshotSpec.Shot.Prepared, scene: RenderScene, gpuSeconds: Double,
         timings: [PassTiming], failures: [String: String], gpuFamily: String) {
        name = shot.name
        scenario = shot.scenario
        advance = shot.advance
        reference = shot.reference
        utc = p.sim.time.description
        missionTime = p.scenario.missionClockZero.map { p.sim.time - $0 }
        width = shot.width
        height = shot.height
        let deg = 180 / Double.pi
        camera = Camera(target: p.camera.targetName, frame: p.camera.frame.rawValue, yaw: p.camera.yaw * deg,
                        pitch: p.camera.pitch * deg, distance: p.camera.distance, fovY: p.camera.fovY * deg)
        vessels = p.sim.vessels.map(\.name)
        preExposure = 1
        self.gpuFamily = gpuFamily
        gpuMilliseconds = gpuSeconds * 1_000
        passMilliseconds = Dictionary(timings.map { ($0.pass, $0.seconds * 1_000) }) { a, _ in a }
        passOrder = timings.map(\.pass)
        self.failures = failures
    }
}

/// The Apple GPU family a device belongs to ("apple9" for the M3), which
/// names the golden-image folder.
public enum GPUFamily {
    public static func name(_ device: MTLDevice) -> String {
        for raw in stride(from: 1_012, through: 1_001, by: -1) {
            if let family = MTLGPUFamily(rawValue: raw), device.supportsFamily(family) { return "apple\(raw - 1_000)" }
        }
        return "other"
    }
}
