import Foundation
import Metal
import OrbitCore
import OrbitScene

/// F12 in the app: the frame on screen, rendered again offscreen, written as
/// PNG, PFM, its depth, normal and luminance views and a JSON record to
/// `ORBITSIM_SNAPSHOT_DIR`, else ~/Library/Application Support/OrbitSim/Snapshots.
@MainActor
public enum AppSnapshot {
    public static var directory: URL {
        if let dir = ProcessInfo.processInfo.environment["ORBITSIM_SNAPSHOT_DIR"] {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("OrbitSim/Snapshots", isDirectory: true)
    }

    struct Record: Codable {
        var utc: String
        var width: Int
        var height: Int
        var camera: String
        var fovY: Double
        var vessels: [String]
        var settings: RenderSettings
        var gpuFamily: String
    }

    /// Writes the snapshot; returns the PNG's URL.
    public static func write(_ scene: RenderScene, renderer: SceneRenderer) throws -> URL {
        let dir = directory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        let name = "orbitsim-\(stamp.string(from: Date()))"
        let w = Int(scene.camera.viewport.width), h = Int(scene.camera.viewport.height)
        guard let target = OffscreenTarget(device: renderer.device, width: w, height: h) else {
            throw SceneRenderer.Failure.noResources
        }
        let saved = renderer.settings, profiling = renderer.profiling
        defer {
            renderer.settings = saved
            renderer.profiling = profiling
        }
        renderer.profiling = false
        func frame(_ view: DebugView) -> [UInt8] {
            var s = saved
            s.debug.view = view
            renderer.settings = s
            renderer.renderAndWait(scene, into: target)
            return target.bytes()
        }
        let image = frame(.none)
        let png = dir.appendingPathComponent("\(name).png")
        try ImageFiles.writePNG(image, width: w, height: h, order: .bgra, to: png)
        try ImageFiles.writePFM(image, width: w, height: h, order: .bgra, to: dir.appendingPathComponent("\(name).pfm"))
        for view in DebugView.allCases where view != .none {
            try ImageFiles.writePNG(frame(view), width: w, height: h, order: .bgra,
                                    to: dir.appendingPathComponent("\(name).\(view.rawValue).png"))
        }
        let record = Record(utc: scene.clock.simTime.description, width: w, height: h,
                            camera: scene.camera.targetName, fovY: scene.camera.fovY * 180 / Double.pi,
                            vessels: scene.vessels.map(\.name), settings: saved,
                            gpuFamily: GPUFamily.name(renderer.device))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: dir.appendingPathComponent("\(name).json"))
        return png
    }
}
