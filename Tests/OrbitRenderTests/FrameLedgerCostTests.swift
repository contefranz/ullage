import Foundation
import Metal
import XCTest
import OrbitCore
import OrbitScene
@testable import OrbitRender

/// LR0's frame ledger (docs/look/frame-ledger.md): what whole frames cost on
/// the GPU, as the app draws them: every default pass, the app's default
/// settings (High, the weather "auto", the user's Earth tiles when they are
/// installed), three frames in flight, 3024×1964 at point scale 2. Six
/// frames of AS-506's launch: the pad at T+0 (380 m east), the ML's base at
/// T+3 and T+5.5 s (62 m from the vehicle, following it), T+8 s (480 m
/// east), max-Q (T+80 s, a 300 m chase) and staging (0.3 s after S-IC/S-II
/// separation). Each is measured twice:
/// - **held**: the frame's instant, its effects' clocks running at 1/60 s a
///   frame (the plumes, the particles and the clouds' wind live; the
///   vehicle and the camera still, so C2 reprojects). The whole frame, and
///   the shares of C2's clouds, P2's plumes, P3/P4's particles and R6's
///   slots, each turned off in blocks of frames (the first frames after a
///   switch dropped), the difference of the medians. "Others" is the frame
///   with all three off, which also stops the slots; "slots" is a tiny
///   test emitter added to it, which wakes them alone.
/// - **flown**: the simulation stepped 1/60 s a frame from the instant for
///   2.5 s, the camera following, as in the app; the first 0.5 s dropped.
/// Then the split profiler's per-pass medians (which overstate passes of
/// several encoders) for the breakdown.
///
/// The frame's cost is its **period**: one frame's GPU end to the next's.
/// With frames in flight consecutive command buffers overlap on the GPU, so
/// a buffer's own span (`gpuEndTime − gpuStartTime`) reads up to twice the
/// frame. With ORBITSIM_LEDGER_WAIT=1 each frame is waited for and its span
/// is its own (the cross-check). A performance run, which holds the GPU lock:
///
///     ORBITSIM_TIMINGS=1 scripts/test.sh fast --no-parallel --filter FrameLedgerCostTests
///
/// ORBITSIM_TIMINGS_SIZE=WxH, ORBITSIM_TIMINGS_ROUNDS=N (blocks per
/// configuration, 8 by default) and ORBITSIM_TIMINGS_SHOTS=<name,name> say
/// otherwise; ORBITSIM_LEDGER_OUT=<file> also writes the lines there;
/// ORBITSIM_LEDGER_FLOWN=<configuration>, ORBITSIM_LEDGER_FLOWN_FRAMES=N and
/// ORBITSIM_LEDGER_SERIES=1 fly without something, for longer, and print
/// each flown frame.
@MainActor
final class FrameLedgerCostTests: XCTestCase {
    final class Times: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int: (start: Double, end: Double)] = [:]
        func set(_ k: Int, _ cb: MTLCommandBuffer) { lock.withLock { values[k] = (cb.gpuStartTime, cb.gpuEndTime) } }
        var all: [Int: (start: Double, end: Double)] { lock.withLock { values } }
    }

    /// The ledger's frames: name, script and camera (yaw, pitch, distance, fov).
    static let frames: [(name: String, advance: [String], camera: SnapshotSpec.CameraSpec)] = [
        ("pad-t+0", [], SnapshotSpec.CameraSpec(yaw: 90, pitch: 2, distance: 380, fov: 50)),
        ("pad-base-t+3", ["met:3"], SnapshotSpec.CameraSpec(yaw: 149, pitch: -2, distance: 62, fov: 62)),
        ("pad-base-t+5.5", ["met:5.5"], SnapshotSpec.CameraSpec(yaw: 149, pitch: -2, distance: 62, fov: 62)),
        ("t+8", ["met:8"], SnapshotSpec.CameraSpec(yaw: 90, pitch: 4, distance: 480, fov: 50)),
        ("max-q", ["met:80"], SnapshotSpec.CameraSpec(yaw: 170, pitch: -35, distance: 300, fov: 60)),
        ("staging", ["ev:S-IC/S-II separation", "wait:0.3"], SnapshotSpec.CameraSpec(yaw: 69, pitch: 17, distance: 80, fov: 60)),
    ]

    /// What a held frame turns off.
    enum Config: String, CaseIterable {
        case full, noClouds = "no clouds", noPlumes = "no plumes", noParticles = "no particles", others, slots

        func apply(_ s: RenderSettings) -> RenderSettings {
            var s = s
            switch self {
            case .full: break
            case .noClouds: s.cloud.enabled = false
            case .noPlumes: s.plume.quality = .off
            case .noParticles: s.particle.quality = .off
            case .others, .slots:
                s.cloud.enabled = false
                s.plume.quality = .off
                s.particle.quality = .off
                if self == .slots {
                    s.transparency.testEmitters = [EffectTestEmitter(.sprites, position: [5_000, 0, 0], size: 0.1, count: 1)]
                }
            }
            return s
        }
    }

    func testCostReport() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["ORBITSIM_TIMINGS"] != nil else { throw XCTSkip("a performance run: ORBITSIM_TIMINGS=1") }
        let lock = GPULock { print("FrameLedgerCostTests: waiting for the GPU lock") }
        if lock == nil { print("FrameLedgerCostTests: no GPU lock; timings may be disturbed") }
        defer { withExtendedLifetime(lock) {} }
        let size = (env["ORBITSIM_TIMINGS_SIZE"] ?? "3024x1964").split(separator: "x").compactMap { Int($0) }
        let (w, h) = (size.first ?? 3024, size.last ?? 1964)
        let blocks = Int(env["ORBITSIM_TIMINGS_ROUNDS"] ?? "") ?? 8
        let waits = env["ORBITSIM_LEDGER_WAIT"] == "1"
        // The flown frames without something ("no clouds", "others"...).
        let flownFrames = max(Int(env["ORBITSIM_LEDGER_FLOWN_FRAMES"] ?? "") ?? 150, 31)
        let flownConfig = env["ORBITSIM_LEDGER_FLOWN"].flatMap(Config.init(rawValue:)) ?? .full
        let only = env["ORBITSIM_TIMINGS_SHOTS"].map { Set($0.split(separator: ",").map(String.init)) }

        let device = try XCTUnwrap(RenderDevice.shared)
        let snapper = try SnapshotRenderer(device: device)
        let r = try SceneRenderer(device: device)
        r.setStars(snapper.stars)
        XCTAssertEqual(r.failures, [:])
        let target = try XCTUnwrap(OffscreenTarget(device: device, width: w, height: h))
        var lines: [String] = []
        func report(_ s: String) {
            print("FrameLedgerCostTests: \(s)")
            lines.append(s)
        }
        report("\(GPUFamily.name(device)), \(device.name), \(w)×\(h); \(Inputs.report)")

        for frame in Self.frames where only?.contains(frame.name) ?? true {
            var shot = SnapshotSpec.Shot(name: frame.name, scenario: "as506-first-motion", advance: frame.advance,
                                         camera: frame.camera)
            shot.width = w
            shot.height = h
            shot.userTextures = true
            var app = RenderSettings()
            app.planetTile.synchronous = true

            func stats(_ values: [Double]) -> (median: Double, p90: Double, max: Double) {
                let v = values.sorted()
                guard !v.isEmpty else { return (.nan, .nan, .nan) }
                return (v[v.count / 2], v[min(v.count - 1, v.count * 9 / 10)], v.last!)
            }

            // Held: the instant, its effects' clocks running.
            r.startOver()
            let prepared = try shot.prepare(system: snapper.system)
            var scene = shot.scene(prepared)
            let start = scene.clock.simTime
            let times = Times()
            var index = 0
            var last: MTLCommandBuffer?
            func held(_ config: Config) -> Int {
                index += 1
                scene.clock.frameIndex = index
                scene.clock.simTime = start + Double(index) / 60
                scene.clock.simTimeOfScene = Double(index) / 60
                scene.clock.realTime = Double(index) / 60
                scene.clock.simDt = 1.0 / 60
                scene.clock.realDt = 1.0 / 60
                scene.clock.paused = false
                scene.clock.temporalReset = index == 1
                if index > 1 { scene.transitions = [] }
                r.settings = config.apply(app)
                let k = index
                if waits {
                    if let cb = r.renderAndWait(scene, into: target) { times.set(k, cb) }
                } else if let cb = r.render(scene, to: target.texture, completion: { cb in times.set(k, cb) }) {
                    last = cb
                }
                return k
            }
            for _ in 0..<60 { _ = held(.full) }
            var kept: [Config: [Int]] = [:]
            var medians: [Config: (Double, Double)] = [:]
            let order = Config.allCases
            for b in 0..<blocks {
                // Each configuration in turn, the order rotated each round.
                for j in 0..<order.count {
                    let c = order[(j + b) % order.count]
                    for i in 0..<10 {
                        let k = held(c)
                        if i >= 4 { kept[c, default: []].append(k) }
                    }
                }
            }
            last?.waitUntilCompleted()
            let all = times.all
            let clock = start - VesselLibrary.apollo11RangeZero
            // Each frame's own GPU span, and the period: one frame's end to
            // the next's within a block, the frame rate a GPU-bound app gets
            // (consecutive command buffers overlap on the GPU, so a span
            // can exceed the period).
            func span(_ k: Int) -> Double? { all[k].map { ($0.end - $0.start) * 1e3 } }
            func period(_ k: Int) -> Double? {
                guard let a = all[k - 1], let b = all[k] else { return nil }
                return (b.end - a.end) * 1e3
            }
            for c in Config.allCases {
                let ks = kept[c] ?? []
                let sp = stats(ks.compactMap(span)), pe = stats(ks.compactMap(period))
                report(String(format: "%@ held (T%+.1f s) %@: span %.2f ms (90th %.2f, max %.2f), period %.2f ms (90th %.2f)",
                              frame.name, clock, c.rawValue, sp.median, sp.p90, sp.max, pe.median, pe.p90))
                medians[c] = (sp.median, pe.median)
            }
            // The shares: by the period with frames in flight, by the span
            // with each frame waited for.
            let m = medians.mapValues { waits ? $0.0 : $0.1 }
            report(String(format: "%@ held, by %@: frame %.2f ms; clouds %.2f, plumes %.2f, particles %.2f, slots %.2f, "
                          + "others %.2f (all three off), the three with the slots %.2f", frame.name,
                          waits ? "span (waited)" : "period (in flight)", m[.full]!,
                          m[.full]! - m[.noClouds]!, m[.full]! - m[.noPlumes]!, m[.full]! - m[.noParticles]!,
                          m[.slots]! - m[.others]!, m[.others]!, m[.full]! - m[.others]!))

            // The split profiler's breakdown of the full frame.
            r.settings = app
            r.profiling = true
            r.profileInterval = 1
            var samples: [String: [Double]] = [:], passOrder: [String] = []
            for _ in 0..<24 {
                index += 1
                scene.clock.frameIndex = index
                scene.clock.simTime = start + Double(index) / 60
                scene.clock.realTime = Double(index) / 60
                _ = r.renderAndWait(scene, into: target)
                for t in r.lastReport?.passes ?? [] {
                    if samples[t.pass] == nil { passOrder.append(t.pass) }
                    samples[t.pass, default: []].append(t.seconds * 1e3)
                }
            }
            r.profiling = false
            r.profileInterval = 4
            let breakdown = passOrder.compactMap { k -> String? in
                guard let v = samples[k]?.sorted(), !v.isEmpty, v[v.count / 2] >= 0.005 else { return nil }
                return String(format: "%@ %.2f", k, v[v.count / 2])
            }.joined(separator: ", ")
            report("\(frame.name) split profiler (ms, overstates passes of several encoders): \(breakdown)")

            // Flown: the simulation stepped from the instant.
            r.startOver()
            let flight = try shot.prepare(system: snapper.system)
            let sim = flight.sim
            sim.paused = false
            sim.stepBudget = nil
            var camera = flight.camera
            let flownTimes = Times()
            var flown: [Int] = []
            for k in 0..<flownFrames {
                if k > 0 { sim.advance(by: 1.0 / 60) }
                camera.update(sim: sim)
                let s = flight.extractor.extract(sim: sim, camera: camera, viewport: shot.viewport,
                                                 realTime: Double(k) / 60)
                r.settings = flownConfig.apply(app)
                if waits {
                    if let cb = r.renderAndWait(s, into: target) { flownTimes.set(k, cb) }
                } else if let cb = r.render(s, to: target.texture, completion: { cb in flownTimes.set(k, cb) }) {
                    last = cb
                }
                if k >= 30 { flown.append(k) }
            }
            last?.waitUntilCompleted()
            let ft = flownTimes.all
            let end = sim.time - VesselLibrary.apollo11RangeZero
            let fs = stats(flown.compactMap { k in ft[k].map { ($0.end - $0.start) * 1e3 } })
            let fp = stats(flown.compactMap { k in ft[k - 1].flatMap { a in ft[k].map { ($0.end - a.end) * 1e3 } } })
            report(String(format: "%@ flown (T%+.1f to %+.1f s%@): span %.2f ms (90th %.2f, max %.2f), period %.2f ms (90th %.2f)",
                          frame.name, clock, end, flownConfig == .full ? "" : ", \(flownConfig.rawValue)", fs.median, fs.p90,
                          fs.max, fp.median, fp.p90))
            if env["ORBITSIM_LEDGER_SERIES"] == "1" {
                report("\(frame.name) flown spans (ms): " + (0..<flownFrames).map { k in
                    ft[k].map { String(format: "%.1f", ($0.end - $0.start) * 1e3) } ?? "-" }.joined(separator: " "))
            }
        }
        if let out = env["ORBITSIM_LEDGER_OUT"] {
            try lines.joined(separator: "\n").appending("\n").write(toFile: out, atomically: true, encoding: .utf8)
        }
        XCTAssertFalse(lines.isEmpty)
    }
}

/// What the frames draw from outside the repository, which changes their
/// cost: PlanetPass's Earth image (Application Support/OrbitSim/Textures,
/// earth.jpg), E1's tile store (`PlanetTilePass.defaultDirectory`, or
/// ORBITSIM_TILES_DIR: its files counted) and C2's gitignored weather fields
/// (`<mission>.oscloud` in OrbitScene's resources; without them C2 falls
/// back to the climatology).
@MainActor
private enum Inputs {
    static var report: String {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let image = fm.fileExists(atPath: support.appendingPathComponent("OrbitSim/Textures/earth.jpg").path)
        let store = PlanetTilePass.defaultDirectory
        var tiles = 0
        if let e = fm.enumerator(at: store, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                tiles += 1
            }
        }
        let fields = ["apollo11", "apollo8", "apollo7"].filter { OrbitSceneResources.url($0 + ".oscloud") != nil }
        return "Earth image \(image ? "earth.jpg" : "absent"); E1 tile store \(store.path): \(tiles) files; "
            + "weather fields: \(fields.isEmpty ? "none (climatology)" : fields.joined(separator: ", "))"
    }
}
