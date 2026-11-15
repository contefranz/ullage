import Foundation
import OrbitCore

/// One layer's tiles across its files: a base pyramid and insets over it
/// (the Cape's Landsat over BMNG), the later file winning where both hold a
/// tile. The files must agree on the layout's shape (format, tile size,
/// border, channels, body); a file that does not is left out. The union
/// must hold every stored tile's ancestors (the tile cache loads parents
/// first): tiles whose parent no file holds are dropped, with a note.
public final class PlanetTileCatalog {
    public let files: [PlanetTileFile]
    public let names: [String]
    /// The first file's layout, `maxLevel` the deepest of them all.
    public let layout: PlanetTileLayout
    /// Which file holds each tile.
    let source: [TileKey: Int]
    /// Tiles with a stored child: where the layer is finer.
    let parents: Set<TileKey>
    /// The deepest level whose every tile is stored (levels 0 to it all
    /// complete): BMNG's 7, the water's 5; -1 without the roots.
    public let completeLevel: Int
    /// Why files or tiles were left out.
    public private(set) var notes: [String] = []

    public init(files: [(name: String, file: PlanetTileFile)]) throws {
        guard let first = files.first else { throw PlanetTileError.badFormat("no files") }
        var kept: [PlanetTileFile] = [], keptNames: [String] = [], notes: [String] = []
        var layout = first.file.layout
        for (name, f) in files {
            let l = f.layout
            guard l.format == layout.format, l.tileSize == layout.tileSize, l.border == layout.border,
                  l.channels == layout.channels, l.bodyID == layout.bodyID, l.scale == layout.scale,
                  l.offset == layout.offset else {
                notes.append("\(name): its layout differs from \(files[0].name)'s; left out")
                continue
            }
            layout.maxLevel = max(layout.maxLevel, l.maxLevel)
            kept.append(f)
            keptNames.append(name)
        }
        var source: [TileKey: Int] = [:]
        for (i, f) in kept.enumerated() { for e in f.entries { source[e.key] = i } }
        // Ancestor closure, coarse to fine.
        var dropped = 0
        for key in source.keys.sorted(by: { $0.level < $1.level }) {
            if let p = key.parent, source[p] == nil { source[key] = nil; dropped += 1 }
        }
        if dropped > 0 { notes.append("\(dropped) tiles without a stored parent left out") }
        parents = Set(source.keys.compactMap(\.parent))
        var perLevel: [Int: Int] = [:]
        for k in source.keys { perLevel[k.level, default: 0] += 1 }
        var complete = -1
        while complete < layout.maxLevel, perLevel[complete + 1] == CubeSphere.tileCount(level: complete + 1) { complete += 1 }
        completeLevel = complete
        self.files = kept
        names = keptNames
        self.layout = layout
        self.source = source
        self.notes = notes
    }

    public var count: Int { source.count }
    public var maxLevel: Int { layout.maxLevel }

    public func contains(_ key: TileKey) -> Bool { source[key] != nil }

    /// Whether any child of `key` is stored: the quadtree refines there
    /// (`PlanetQuadtree.Parameters.refinable`).
    public func hasStoredChildren(_ key: TileKey) -> Bool { parents.contains(key) }

    /// `key` if stored, else its deepest stored ancestor.
    public func finestAvailable(_ key: TileKey) -> TileKey? {
        var level = min(key.level, maxLevel)
        while level >= 0 {
            let k = key.ancestor(atLevel: level)
            if source[k] != nil { return k }
            level -= 1
        }
        return nil
    }

    /// The file and index entry that hold `key`.
    public func entry(_ key: TileKey) -> (file: Int, entry: PlanetTileEntry)? {
        guard let i = source[key], let e = files[i].entry(key) else { return nil }
        return (i, e)
    }

    /// The payload of `key`, without copying from a mapped file.
    public func payload(_ key: TileKey) -> Data? {
        guard let i = source[key] else { return nil }
        return files[i].payload(key)
    }

    /// A metadata value from the first file that has it.
    public func metadata(_ key: String) -> String? {
        files.lazy.compactMap { $0.metadata[key] }.first
    }

    /// The tile files of the Earth's layers in `directory` (Application
    /// Support/OrbitSim/Tiles), month `month` for the albedo (the nearest
    /// one present). Missing layers are absent from the result; files that
    /// do not open are reported in `problems`.
    public static func earthLayers(in directory: URL, month: Int)
        -> (layers: [PlanetTileLayerKind: PlanetTileCatalog], month: Int?, problems: [String]) {
        let fm = FileManager.default
        var problems: [String] = []
        func open(_ name: String) -> PlanetTileFile? {
            let url = directory.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { return nil }
            do { return try PlanetTileFile(contentsOf: url) } catch {
                problems.append("\(name): \(error)")
                return nil
            }
        }
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        let months = names.compactMap { n -> Int? in
            guard n.hasPrefix("earth-bmng-2004-"), n.hasSuffix(".ostiles") else { return nil }
            return Int(n.dropFirst("earth-bmng-2004-".count).prefix(2))
        }.filter { (1 ... 12).contains($0) }
        var layers: [PlanetTileLayerKind: PlanetTileCatalog] = [:]
        let chosen = EarthTileFiles.nearestMonth(to: month, available: months)
        if let m = chosen, let base = open(EarthTileFiles.albedo(month: m)) {
            var files = [(EarthTileFiles.albedo(month: m), base)]
            if let cape = open(EarthTileFiles.capeInset) { files.append((EarthTileFiles.capeInset, cape)) }
            if let c = try? PlanetTileCatalog(files: files) { layers[.albedo] = c; problems += c.notes }
        }
        for (kind, name) in [(PlanetTileLayerKind.water, EarthTileFiles.water), (.relief, EarthTileFiles.relief)] {
            if let f = open(name), let c = try? PlanetTileCatalog(files: [(name, f)]) { layers[kind] = c }
        }
        return (layers, chosen, problems)
    }
}

/// A decoded tile's texels for the atlas: its mips, each (m/2^k)² texels of
/// `channels` 8-bit samples (1, 2 or 4), laid out one after another.
public enum TileTexelMips {
    /// Bytes of mip `level` of an `m`-texel tile.
    public static func size(across m: Int, channels: Int, level: Int) -> Int {
        let s = max(1, m >> level)
        return s * s * channels
    }

    /// Bytes of all `levels` mips.
    public static func totalSize(across m: Int, channels: Int, levels: Int) -> Int {
        (0 ..< levels).reduce(0) { $0 + size(across: m, channels: channels, level: $1) }
    }

    /// Fills mips 1 ..< levels of the buffer after mip 0 by 2 × 2 box
    /// filtering, in linear light when `srgb` (alpha, the 4th channel, is
    /// averaged as it is).
    public static func generate(_ p: UnsafeMutableRawPointer, across m: Int, channels: Int, levels: Int, srgb: Bool) {
        var src = p.assumingMemoryBound(to: UInt8.self), side = m
        let toLinear = SRGB.byteToLinear
        let toByte = SRGB.linearToByteTable
        for _ in 1 ..< max(levels, 1) {
            let half = max(1, side / 2)
            let dst = src + side * side * channels
            for y in 0 ..< half {
                for x in 0 ..< half {
                    for c in 0 ..< channels {
                        let i0 = ((2 * y) * side + 2 * x) * channels + c
                        let x1 = min(2 * x + 1, side - 1) - 2 * x, y1 = min(2 * y + 1, side - 1) - 2 * y
                        let i1 = i0 + x1 * channels, i2 = i0 + y1 * side * channels, i3 = i2 + x1 * channels
                        if srgb && c < 3 {
                            let l = (toLinear[Int(src[i0])] + toLinear[Int(src[i1])] + toLinear[Int(src[i2])]
                                     + toLinear[Int(src[i3])]) / 4
                            dst[(y * half + x) * channels + c] = toByte[Int(min(max(l, 0), 1) * 16_383 + 0.5)]
                        } else {
                            let v = (Float(src[i0]) + Float(src[i1]) + Float(src[i2]) + Float(src[i3])) / 4
                            dst[(y * half + x) * channels + c] = UInt8(min(255, max(0, v.rounded())))
                        }
                    }
                }
            }
            src = dst
            side = half
        }
    }
}
