import Foundation
import Metal
import OrbitCore
import OrbitRender
import OrbitScene

// orbitsnap renders snapshot specs offscreen, with no window, and writes
// what a session needs to look at them: per shot <name>.png, <name>.pfm,
// <name>.<view>.png for each debug view asked for, <name>.json (camera,
// time, GPU ms), and contact.jpg for all of them.

let usage = """
    usage: orbitsnap SPEC.json... --out DIR [options]
      --shot NAME            render only this shot (repeatable)
      --timings N            time each pass on the GPU over N frames (holds the GPU lock)
      --goldens [DIR]        compare with DIR/<shot>.png (default: the golden folder for this GPU);
                             exits 1 when a shot is out of tolerance
      --update-goldens [DIR] write the renders as the goldens
      --dump-shaders DIR     write each shader module's full source as DIR/<Module>.metal and exit
      --list                 list the shots and exit
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("orbitsnap: \(message)\n".utf8))
    exit(2)
}

/// Tests/OrbitRenderTests/Goldens/<family> in this source tree.
func defaultGoldens(_ device: MTLDevice) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/OrbitRenderTests/Goldens/\(GPUFamily.name(device))")
}

struct Options {
    var specs: [URL] = []
    var out: URL?
    var shots: Set<String> = []
    var timingFrames = 0
    var goldens: URL??
    var update: URL??
    var dumpShaders: URL?
    var list = false
}

func parse(_ args: [String]) -> Options {
    var o = Options(), i = 0
    func value() -> String {
        i += 1
        guard i < args.count else { fail("\(args[i - 1]) needs a value\n\(usage)") }
        return args[i]
    }
    func optionalPath() -> URL? {
        guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else { return nil }
        i += 1
        return URL(fileURLWithPath: args[i])
    }
    while i < args.count {
        switch args[i] {
        case "--out": o.out = URL(fileURLWithPath: value())
        case "--shot": o.shots.insert(value())
        case "--timings": o.timingFrames = Int(value()) ?? 0
        case "--goldens": o.goldens = .some(optionalPath())
        case "--update-goldens": o.update = .some(optionalPath())
        case "--dump-shaders": o.dumpShaders = URL(fileURLWithPath: value())
        case "--list": o.list = true
        case "-h", "--help": print(usage); exit(0)
        default:
            if args[i].hasPrefix("--") { fail("unknown option \(args[i])\n\(usage)") }
            o.specs.append(URL(fileURLWithPath: args[i]))
        }
        i += 1
    }
    return o
}

@MainActor func run() -> Int32 {
    let o = parse(Array(CommandLine.arguments.dropFirst()))
    if let dir = o.dumpShaders {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for m in ShaderModule.all {
            do {
                try m.fullSource.write(to: dir.appendingPathComponent("\(m.name).metal"), atomically: true, encoding: .utf8)
            } catch {
                fail("cannot write \(dir.path): \(error)")
            }
        }
        return 0
    }
    guard !o.specs.isEmpty else { fail("no spec\n\(usage)") }
    var shots: [SnapshotSpec.Shot] = []
    for url in o.specs {
        do {
            shots += try SnapshotSpec.load(url).shots
        } catch {
            fail("cannot read \(url.path): \(error)")
        }
    }
    if !o.shots.isEmpty {
        let unknown = o.shots.subtracting(shots.map(\.name))
        if !unknown.isEmpty { fail("no shot \(unknown.sorted().joined(separator: ", "))") }
        shots = shots.filter { o.shots.contains($0.name) }
    }
    if o.list {
        for s in shots { print("\(s.name)\t\(s.scenario)\t\(s.advance.joined(separator: "; "))") }
        return 0
    }
    guard let out = o.out else { fail("no --out\n\(usage)") }
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

    let snapper: SnapshotRenderer
    do {
        snapper = try SnapshotRenderer()
    } catch {
        fail("cannot start the renderer: \(error)")
    }
    let device = snapper.device
    let goldens = o.goldens.map { $0 ?? defaultGoldens(device) }
    let update = o.update.map { $0 ?? defaultGoldens(device) }
    if let update { try? FileManager.default.createDirectory(at: update, withIntermediateDirectories: true) }
    var lock: GPULock?
    if o.timingFrames > 0 {
        lock = GPULock { print("orbitsnap: waiting for the GPU lock (\(GPULock.url.path))") }
        if lock == nil { print("orbitsnap: could not take the GPU lock; timings may be disturbed") }
    }

    var sheet = ContactSheet(), failed = false
    for shot in shots {
        let start = Date()
        let output: SnapshotRenderer.Output
        do {
            output = try snapper.render(shot, timingFrames: o.timingFrames)
        } catch {
            print("\(shot.name): FAILED: \(error)")
            failed = true
            continue
        }
        let w = shot.width, h = shot.height
        func file(_ suffix: String) -> URL { out.appendingPathComponent("\(shot.name)\(suffix)") }
        let record = output.record
        var row: [ContactSheet.Cell] = []
        var verdict = ""
        do {
            try ImageFiles.writePNG(output.pixels, width: w, height: h, order: .bgra, to: file(".png"))
            try ImageFiles.writePFM(output.pixels, width: w, height: h, order: .bgra, to: file(".pfm"))
            for aov in output.aovs {
                try ImageFiles.writePNG(aov.pixels, width: w, height: h, order: .bgra, to: file(".\(aov.view.rawValue).png"))
            }
            if let update {
                try ImageFiles.writePNG(output.pixels, width: w, height: h, order: .bgra,
                                        to: update.appendingPathComponent("\(shot.name).png"))
            }
            let render = ImageFiles.cgImage(output.pixels, width: w, height: h, order: .bgra)
            if let goldens {
                let url = goldens.appendingPathComponent("\(shot.name).png")
                if let golden = try? ImageFiles.readPNG(url), golden.width == w, golden.height == h {
                    let mine = ImageFiles.rgba(fromBGRA: output.pixels)
                    let c = ImageMetrics.compare(golden.pixels, mine)
                    let diff = ImageMetrics.difference(golden.pixels, mine)
                    try ImageFiles.writePNG(diff, width: w, height: h, order: .rgba, to: file(".diff.png"))
                    verdict = String(format: " golden %@: mean %.4f%%, p99.5 dE %.2f, %d px differ",
                                     c.withinGoldenTolerance ? "ok" : "FAILED", c.meanLinearError * 100,
                                     c.p995DeltaE, c.differingPixels)
                    failed = failed || !c.withinGoldenTolerance
                    if let g = ImageFiles.cgImage(golden.pixels, width: w, height: h, order: .rgba) {
                        row.append(.init(image: g, caption: "\(shot.name): golden"))
                    }
                    if let render { row.append(.init(image: render, caption: "render" + (shot.reference.map { " (\($0))" } ?? ""))) }
                    if let d = ImageFiles.cgImage(diff, width: w, height: h, order: .rgba) {
                        row.append(.init(image: d, caption: String(format: "diff ×8: p99.5 ΔE %.2f", c.p995DeltaE)))
                    }
                } else {
                    verdict = " golden missing"
                    failed = true
                }
            }
            if row.isEmpty, let render {
                row.append(.init(image: render, caption: shot.name + (shot.reference.map { " (\($0))" } ?? "")))
                for aov in output.aovs {
                    if let i = ImageFiles.cgImage(aov.pixels, width: w, height: h, order: .bgra) {
                        row.append(.init(image: i, caption: "\(shot.name).\(aov.view.rawValue)"))
                    }
                }
            }
            sheet.rows.append(row)
            if !output.timings.isEmpty {
                print("  " + output.timings.map { String(format: "%@ %.2f ms", $0.pass, $0.seconds * 1_000) }
                    .joined(separator: ", "))
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(record).write(to: file(".json"))
        } catch {
            print("\(shot.name): FAILED to write: \(error)")
            failed = true
            continue
        }
        print(String(format: "%@: %@, %.1f s%@", shot.name, record.utc, Date().timeIntervalSince(start), verdict))
    }
    withExtendedLifetime(lock) {}
    do {
        try sheet.write(to: out.appendingPathComponent("contact.jpg"))
    } catch {
        print("contact sheet: \(error)")
    }
    print("orbitsnap: \(shots.count) shots in \(out.path)" + (failed ? "; some FAILED" : ""))
    return failed ? 1 : 0
}

exit(MainActor.assumeIsolated { run() })
