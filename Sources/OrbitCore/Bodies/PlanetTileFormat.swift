import Foundation

// OSTILES1: one layer of a body's cube-sphere tile pyramid (M1.6 Earth and
// Moon design §3) in one file: a header, the layer's provenance as JSON, the
// tiles' payloads, and an index sorted by tile identifier. Pure Foundation
// and memory-mappable, so the app streams tiles from it and OrbitCore reads
// heights from it on Linux: M2.5's landing queries the Moon's terrain here.
// All numbers are little-endian.
//
// Header, 128 bytes:
//     0  8  "OSTILES1"
//     8  4  UInt32  header size, 128
//    12  4  UInt32  sample format (`PlanetTileSampleFormat`)
//    16  4  UInt32  tile size n: texels across a tile, borders excluded
//    20  4  UInt32  border b: texels past each edge
//    24  4  UInt32  channels per texel
//    28  4  UInt32  the pyramid's deepest level
//    32  4  UInt32  tile count
//    36  4  Int32   the body's NAIF id
//    40  8  Float64 the figure's equatorial radius a, m
//    48  8  Float64 its flattening f = (a - b)/a
//    56  8  Float64 value scale     (value = raw × scale + offset)
//    64  8  Float64 value offset
//    72  4  Int32   the raw value that means no data
//    76  4  UInt32  flags: bit 0 set when the no-data value is in use
//    80  8  UInt64  index offset
//    88  8  UInt64  metadata offset
//    96  4  UInt32  metadata length: a UTF-8 JSON object of strings
//   100 28  zero
// Index: one 32-byte entry per tile, by ascending `TileKey.id`:
//     0  8  UInt64  tile id
//     8  8  UInt64  payload offset
//    16  4  UInt32  payload length
//    20  4  Float32 the least value of the tile's samples, borders included
//    24  4  Float32 the greatest (both 0 for images)
//    28  4  UInt32  the payload's CRC-32 (IEEE 802.3)
// Payloads start on 16-byte boundaries. A tile is (n + 2b)² texels: texel
// (i, j), column i and row j counted from the outer edge of the border, is
// centred at tile-local (u, v) = ((i - b + ½)/n, (j - b + ½)/n), so rows run
// along u and go up in v (row 0 is the minV border's outer row) and a GPU
// texture coordinate (s, t) is the local (u, v) as stored. Raw payloads hold
// the texels row by row with their channels interleaved; image payloads
// (JPEG, HEIC, PNG) are the same grid encoded, its first image row the
// minV border's. Borders hold the face's projection carried past the tile
// edge (`TileKey.direction(localU:localV:)`), the neighbours' texels within
// a face, so a texel-centred bilinear lookup anywhere on the tile stays in
// it. Heights are metres above the figure, along its normal.

/// How a tile file's samples are stored.
public enum PlanetTileSampleFormat: UInt32, Codable, CaseIterable {
    /// Encoded images, which the app decodes (ImageIO): colour layers.
    case jpeg = 1, heic = 2, png = 3
    /// Raw signed 16-bit samples: heights.
    case int16 = 16
    /// Raw unsigned 8-bit samples: masks, horizon angles.
    case uint8 = 17

    /// Bytes per raw sample; nil for images.
    public var bytesPerSample: Int? {
        switch self {
        case .int16: return 2
        case .uint8: return 1
        case .jpeg, .heic, .png: return nil
        }
    }

    /// The raw values a sample can hold; nil for images.
    public var rawRange: ClosedRange<Int>? {
        switch self {
        case .int16: return Int(Int16.min)...Int(Int16.max)
        case .uint8: return 0...255
        case .jpeg, .heic, .png: return nil
        }
    }
}

/// The shape of a tile file's layer: what its tiles hold and the body they cover.
public struct PlanetTileLayout: Equatable {
    public var format: PlanetTileSampleFormat
    /// Texels across a tile, borders excluded (256 or 512 in the design).
    public var tileSize: Int
    /// Texels past each tile edge (4 in the design).
    public var border: Int
    /// Samples per texel: 1 for heights, 16 for a horizon map's azimuths.
    public var channels: Int
    /// The pyramid's deepest level; a file may hold any subset of its tiles.
    public var maxLevel: Int
    /// The body's NAIF id: 399 the Earth, 301 the Moon.
    public var bodyID: Int
    /// The figure the tiles' directions are taken on (`Ellipsoid.surfacePoint(figureDirection:)`).
    public var figure: Ellipsoid
    /// value = raw × scale + offset, e.g. metres of height.
    public var scale: Double
    public var offset: Double
    /// The raw value that means no data, if any.
    public var noData: Int?

    public init(format: PlanetTileSampleFormat, tileSize: Int, border: Int, channels: Int = 1, maxLevel: Int,
                bodyID: Int, figure: Ellipsoid, scale: Double = 1, offset: Double = 0, noData: Int? = nil) {
        self.format = format; self.tileSize = tileSize; self.border = border; self.channels = channels
        self.maxLevel = maxLevel; self.bodyID = bodyID; self.figure = figure
        self.scale = scale; self.offset = offset; self.noData = noData
    }

    /// Texels across a tile with its borders: n + 2b.
    public var samplesAcross: Int { tileSize + 2 * border }

    /// Bytes of a raw tile's payload; nil for images.
    public var rawPayloadLength: Int? {
        format.bytesPerSample.map { samplesAcross * samplesAcross * channels * $0 }
    }

    func validate() throws {
        guard tileSize > 0, border >= 0, channels > 0, scale.isFinite, scale != 0, offset.isFinite,
              maxLevel >= 0, maxLevel <= TileKey.maxLevel,
              figure.equatorialRadius > 0, figure.flattening >= 0, figure.flattening < 1 else {
            throw PlanetTileError.badFormat("layout \(self)")
        }
        if let noData, let range = format.rawRange, !range.contains(noData) {
            throw PlanetTileError.badFormat("no-data value \(noData) outside \(range)")
        }
    }
}

/// What went wrong reading or writing a tile file.
public enum PlanetTileError: Error, Equatable, CustomStringConvertible {
    case badFormat(String)
    case badTile(TileKey, String)

    public var description: String {
        switch self {
        case .badFormat(let what): return "tile file: \(what)"
        case .badTile(let key, let what): return "tile \(key): \(what)"
        }
    }
}

/// One tile's place in a file.
public struct PlanetTileEntry: Equatable {
    public let key: TileKey
    /// Byte offset and length of the payload in the file.
    public let offset: Int
    public let length: Int
    /// The least and greatest value of the tile's samples, borders included,
    /// no-data samples excluded: bounds for culling and LOD (0 for images).
    public let minimum: Double
    public let maximum: Double
    /// CRC-32 of the payload.
    public let checksum: UInt32
}

/// A tile file, read from memory or mapped from disk.
public struct PlanetTileFile {
    public static let magic = "OSTILES1"
    static let headerSize = 128
    static let entrySize = 32

    public let layout: PlanetTileLayout
    /// The layer's provenance: source, date, SOURCES.txt line, tool.
    public let metadata: [String: String]
    /// The tiles, by ascending id.
    public let entries: [PlanetTileEntry]
    let ids: [UInt64]
    let data: Data

    /// The file at `url`, memory-mapped.
    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    public init(data: Data) throws {
        let h = PlanetTileFile.headerSize
        guard data.count >= h, String(decoding: data.prefix(8), as: UTF8.self) == PlanetTileFile.magic else {
            throw PlanetTileError.badFormat("not an OSTILES1 file")
        }
        let r = LittleEndianReader(data)
        guard r.u32(8) == UInt32(h), let format = PlanetTileSampleFormat(rawValue: r.u32(12)) else {
            throw PlanetTileError.badFormat("header")
        }
        let flags = r.u32(76)
        var layout = PlanetTileLayout(
            format: format, tileSize: Int(r.u32(16)), border: Int(r.u32(20)), channels: Int(r.u32(24)),
            maxLevel: Int(r.u32(28)), bodyID: Int(r.i32(36)),
            figure: Ellipsoid(equatorialRadius: r.f64(40), flattening: r.f64(48)),
            scale: r.f64(56), offset: r.f64(64))
        layout.noData = flags & 1 != 0 ? Int(r.i32(72)) : nil
        try layout.validate()
        let count = Int(r.u32(32)), indexOffset = r.u64(80)
        let metadataOffset = r.u64(88), metadataLength = Int(r.u32(96))
        guard indexOffset <= UInt64(data.count), metadataOffset <= UInt64(data.count),
              count <= (data.count - Int(indexOffset)) / PlanetTileFile.entrySize,
              metadataLength <= data.count - Int(metadataOffset) else {
            throw PlanetTileError.badFormat("index or metadata past the end")
        }
        var metadata: [String: String] = [:]
        if metadataLength > 0 {
            let start = data.startIndex + Int(metadataOffset)
            let json = data.subdata(in: start ..< start + metadataLength)
            guard let decoded = try? JSONDecoder().decode([String: String].self, from: json) else {
                throw PlanetTileError.badFormat("metadata")
            }
            metadata = decoded
        }
        var entries: [PlanetTileEntry] = [], ids: [UInt64] = []
        entries.reserveCapacity(count); ids.reserveCapacity(count)
        for k in 0 ..< count {
            let e = Int(indexOffset) + k * PlanetTileFile.entrySize
            let id = r.u64(e), offset = r.u64(e + 8), length = Int(r.u32(e + 16))
            guard let key = TileKey(id: id), key.level <= layout.maxLevel, ids.last.map({ $0 < id }) ?? true else {
                throw PlanetTileError.badFormat("index entry \(k)")
            }
            guard offset <= UInt64(data.count), length <= data.count - Int(offset) else {
                throw PlanetTileError.badTile(key, "payload past the end")
            }
            if let expected = layout.rawPayloadLength, length != expected {
                throw PlanetTileError.badTile(key, "payload of \(length) bytes, not \(expected)")
            }
            entries.append(PlanetTileEntry(key: key, offset: Int(offset), length: length,
                                           minimum: Double(r.f32(e + 20)), maximum: Double(r.f32(e + 24)),
                                           checksum: r.u32(e + 28)))
            ids.append(id)
        }
        self.layout = layout; self.metadata = metadata; self.entries = entries; self.ids = ids; self.data = data
    }

    /// Tiles in the file.
    public var count: Int { entries.count }

    /// The entry of `key`, nil if the file has no such tile.
    public func entry(_ key: TileKey) -> PlanetTileEntry? {
        let id = key.id
        var lo = 0, hi = ids.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ids[mid] < id { lo = mid + 1 } else { hi = mid }
        }
        return lo < ids.count && ids[lo] == id ? entries[lo] : nil
    }

    public func contains(_ key: TileKey) -> Bool { entry(key) != nil }

    /// The payload of `key`, without copying from a mapped file.
    public func payload(_ key: TileKey) -> Data? {
        entry(key).map { payload($0) }
    }

    func payload(_ e: PlanetTileEntry) -> Data {
        let start = data.startIndex + e.offset
        return data[start ..< start + e.length]
    }

    /// The raw tile of `key`, nil if it is missing or the layer holds images.
    public func tile(_ key: TileKey) -> PlanetTile? {
        guard layout.format.bytesPerSample != nil, let e = entry(key) else { return nil }
        return PlanetTile(key: key, layout: layout, bytes: payload(e))
    }

    /// `key` itself if the file holds it, else its deepest ancestor that the
    /// file holds; nil if there is none.
    public func finestAvailable(_ key: TileKey) -> TileKey? {
        var level = min(key.level, layout.maxLevel)
        while level >= 0 {
            let k = key.ancestor(atLevel: level)
            if contains(k) { return k }
            level -= 1
        }
        return nil
    }

    /// The deepest tile the file holds that contains `direction` (figure
    /// coordinates), at most `maxLevel` deep.
    public func finestTile(containing direction: Vec3, maxLevel: Int? = nil) -> TileKey? {
        let level = min(maxLevel ?? layout.maxLevel, layout.maxLevel)
        return finestAvailable(TileKey.containing(direction, level: level))
    }

    /// The range of values over `key`'s area: its own entry's, or that of
    /// the deepest ancestor the file holds, whose samples interpolate there.
    public func valueRange(_ key: TileKey) -> ClosedRange<Double>? {
        guard let k = finestAvailable(key), let e = entry(k) else { return nil }
        return e.minimum ... e.maximum
    }

    /// The value at `direction` (figure coordinates), bilinear in the
    /// deepest tile that holds it: nil where the file has no tile or the
    /// texels are no data.
    public func value(at direction: Vec3, channel: Int = 0, maxLevel: Int? = nil) -> Double? {
        guard let key = finestTile(containing: direction, maxLevel: maxLevel), let t = tile(key) else { return nil }
        return t.value(at: direction, channel: channel)
    }

    /// The terrain height (m above the figure) at geodetic `latitude` and
    /// `longitude` (rad).
    public func height(latitude: Double, longitude: Double, maxLevel: Int? = nil) -> Double? {
        value(at: layout.figure.figureDirection(latitude: latitude, longitude: longitude), maxLevel: maxLevel)
    }

    /// The terrain height (m above the figure) under a body-fixed point:
    /// at the foot of its normal on the figure.
    public func height(below position: Vec3, maxLevel: Int? = nil) -> Double? {
        let g = layout.figure.geodetic(position)
        return height(latitude: g.latitude, longitude: g.longitude, maxLevel: maxLevel)
    }

    /// Checks every payload against its CRC-32.
    public func verify() throws {
        for e in entries where CRC32.checksum(payload(e)) != e.checksum {
            throw PlanetTileError.badTile(e.key, "checksum")
        }
    }
}

/// One raw tile: its texels, with borders, read in place.
public struct PlanetTile {
    public let key: TileKey
    public let layout: PlanetTileLayout
    let bytes: Data

    /// The raw sample of texel (column, row), counted from the border's outer edge.
    public func raw(column: Int, row: Int, channel: Int = 0) -> Int {
        let m = layout.samplesAcross
        precondition(column >= 0 && column < m && row >= 0 && row < m && channel >= 0 && channel < layout.channels)
        let k = (row * m + column) * layout.channels + channel
        return bytes.withUnsafeBytes { buffer in
            switch layout.format {
            case .int16: return Int(Int16(littleEndian: buffer.loadUnaligned(fromByteOffset: 2 * k, as: Int16.self)))
            default: return Int(buffer[k])
            }
        }
    }

    /// The value of texel (column, row), nil for no data.
    public func value(column: Int, row: Int, channel: Int = 0) -> Double? {
        let r = raw(column: column, row: row, channel: channel)
        if let noData = layout.noData, r == noData { return nil }
        return Double(r) * layout.scale + layout.offset
    }

    /// The bilinear value at tile-local (u, v), from the four nearest texel
    /// centres as a GPU's filter takes them; outside the borders it clamps
    /// to the edge texels. nil if any of the four is no data.
    public func value(localU u: Double, localV v: Double, channel: Int = 0) -> Double? {
        let n = Double(layout.tileSize), b = Double(layout.border), last = layout.samplesAcross - 1
        let x = min(max(u * n - 0.5 + b, 0), Double(last)), y = min(max(v * n - 0.5 + b, 0), Double(last))
        let i = min(Int(x), max(last - 1, 0)), j = min(Int(y), max(last - 1, 0))
        let fx = x - Double(i), fy = y - Double(j)
        let i1 = min(i + 1, last), j1 = min(j + 1, last)
        guard let v00 = value(column: i, row: j, channel: channel), let v10 = value(column: i1, row: j, channel: channel),
              let v01 = value(column: i, row: j1, channel: channel), let v11 = value(column: i1, row: j1, channel: channel)
        else { return nil }
        let bottom = v00 + (v10 - v00) * fx, top = v01 + (v11 - v01) * fx
        return bottom + (top - bottom) * fy
    }

    /// The bilinear value at `direction` (figure coordinates), on this
    /// tile's face; a direction past the tile reads its borders.
    public func value(at direction: Vec3, channel: Int = 0) -> Double? {
        let local = key.localCoordinates(direction)
        return value(localU: local.u, localV: local.v, channel: channel)
    }
}

extension TileKey {
    /// Tile-local coordinates of `direction` along this tile's face's
    /// projection, also past the face's edges (within 45° of its centre).
    func localCoordinates(_ direction: Vec3) -> (u: Double, v: Double) {
        let axes = face.axes
        let k = direction.dot(axes.normal.vector)
        let a = direction.dot(axes.u.vector) / k, b = direction.dot(axes.v.vector) / k
        return localCoordinates(u: (CubeSphere.warp(a) + 1) / 2, v: (CubeSphere.warp(b) + 1) / 2)
    }
}

/// Writes a tile file: tiles in any order, the index sorted at `finish`.
public final class PlanetTileWriter {
    public let layout: PlanetTileLayout
    let handle: FileHandle
    let metadata: Data
    var position: UInt64
    var entries: [UInt64: PlanetTileEntry] = [:]
    var finished = false

    public init(url: URL, layout: PlanetTileLayout, metadata: [String: String] = [:]) throws {
        try layout.validate()
        self.layout = layout
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.metadata = metadata.isEmpty ? Data() : try encoder.encode(metadata)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw PlanetTileError.badFormat("cannot create \(url.path)")
        }
        handle = try FileHandle(forWritingTo: url)
        // The header is written last, when the index's place is known.
        try handle.write(contentsOf: Data(count: PlanetTileFile.headerSize))
        try handle.write(contentsOf: self.metadata)
        position = UInt64(PlanetTileFile.headerSize + self.metadata.count)
    }

    deinit { if !finished { try? handle.close() } }

    /// Adds a tile's encoded payload. For raw formats it must be the tile's
    /// samples as stored, and its value range is computed; images take the
    /// range given (none: 0...0).
    public func add(_ key: TileKey, payload: Data, range: ClosedRange<Double>? = nil) throws {
        guard !finished, key.level <= layout.maxLevel, entries[key.id] == nil else {
            throw PlanetTileError.badTile(key, finished ? "file finished" : "duplicate or deeper than maxLevel")
        }
        var lo = range?.lowerBound ?? 0, hi = range?.upperBound ?? 0
        if let expected = layout.rawPayloadLength {
            guard payload.count == expected else {
                throw PlanetTileError.badTile(key, "payload of \(payload.count) bytes, not \(expected)")
            }
            let r = rawRange(payload)
            if let r {
                lo = Double(r.lowerBound) * layout.scale + layout.offset
                hi = Double(r.upperBound) * layout.scale + layout.offset
                if lo > hi { swap(&lo, &hi) }
            } else {
                lo = 0; hi = 0
            }
        }
        let padding = Int((16 - position % 16) % 16)
        try handle.write(contentsOf: Data(count: padding))
        position += UInt64(padding)
        try handle.write(contentsOf: payload)
        entries[key.id] = PlanetTileEntry(key: key, offset: Int(position), length: payload.count,
                                          minimum: lo, maximum: hi, checksum: CRC32.checksum(payload))
        position += UInt64(payload.count)
    }

    /// Adds a raw tile from its samples, row by row with channels interleaved.
    public func add(_ key: TileKey, rawSamples samples: [Int]) throws {
        guard let range = layout.format.rawRange, samples.count * layout.format.bytesPerSample! == layout.rawPayloadLength,
              samples.allSatisfy(range.contains) else {
            throw PlanetTileError.badTile(key, "\(samples.count) samples for \(layout.format)")
        }
        let payload: Data
        switch layout.format {
        case .int16: payload = samples.map { Int16($0).littleEndian }.withUnsafeBufferPointer { Data(buffer: $0) }
        default: payload = Data(samples.map { UInt8($0) })
        }
        try add(key, payload: payload)
    }

    /// Adds a raw tile from values in the layer's units, quantised to the
    /// nearest raw sample (clamped to the format); nil is no data.
    public func add(_ key: TileKey, values: [Double?]) throws {
        guard let range = layout.format.rawRange else { throw PlanetTileError.badTile(key, "values for an image layer") }
        let raw = values.map { value -> Int in
            guard let value else { return layout.noData ?? range.lowerBound }
            let r = ((value - layout.offset) / layout.scale).rounded()
            return Int(min(max(r, Double(range.lowerBound)), Double(range.upperBound)))
        }
        if values.contains(where: { $0 == nil }) && layout.noData == nil {
            throw PlanetTileError.badTile(key, "no data in a layer without a no-data value")
        }
        try add(key, rawSamples: raw)
    }

    /// The least and greatest raw sample of a raw payload, no data excluded;
    /// nil if every sample is no data.
    func rawRange(_ payload: Data) -> ClosedRange<Int>? {
        var lo = Int.max, hi = Int.min
        let noData = layout.noData
        payload.withUnsafeBytes { bytes in
            switch layout.format {
            case .int16:
                for k in 0 ..< bytes.count / 2 {
                    let r = Int(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: 2 * k, as: Int16.self)))
                    if r != noData { lo = min(lo, r); hi = max(hi, r) }
                }
            default:
                for b in bytes where Int(b) != noData { lo = min(lo, Int(b)); hi = max(hi, Int(b)) }
            }
        }
        return lo <= hi ? lo ... hi : nil
    }

    /// Writes the index and the header; the file is complete after this.
    public func finish() throws {
        guard !finished else { return }
        finished = true
        let padding = Int((16 - position % 16) % 16)
        try handle.write(contentsOf: Data(count: padding))
        let indexOffset = position + UInt64(padding)
        var index = Data(capacity: entries.count * PlanetTileFile.entrySize)
        for id in entries.keys.sorted() {
            let e = entries[id]!
            index.appendLittleEndian(id)
            index.appendLittleEndian(UInt64(e.offset))
            index.appendLittleEndian(UInt32(e.length))
            index.appendLittleEndian(PlanetTileWriter.float(e.minimum, .down).bitPattern)
            index.appendLittleEndian(PlanetTileWriter.float(e.maximum, .up).bitPattern)
            index.appendLittleEndian(e.checksum)
        }
        try handle.write(contentsOf: index)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header(count: entries.count, indexOffset: indexOffset))
        try handle.close()
    }

    func header(count: Int, indexOffset: UInt64) -> Data {
        var h = Data(PlanetTileFile.magic.utf8)
        h.appendLittleEndian(UInt32(PlanetTileFile.headerSize))
        h.appendLittleEndian(layout.format.rawValue)
        h.appendLittleEndian(UInt32(layout.tileSize))
        h.appendLittleEndian(UInt32(layout.border))
        h.appendLittleEndian(UInt32(layout.channels))
        h.appendLittleEndian(UInt32(layout.maxLevel))
        h.appendLittleEndian(UInt32(count))
        h.appendLittleEndian(Int32(layout.bodyID))
        h.appendLittleEndian(layout.figure.equatorialRadius.bitPattern)
        h.appendLittleEndian(layout.figure.flattening.bitPattern)
        h.appendLittleEndian(layout.scale.bitPattern)
        h.appendLittleEndian(layout.offset.bitPattern)
        h.appendLittleEndian(Int32(layout.noData ?? 0))
        h.appendLittleEndian(UInt32(layout.noData == nil ? 0 : 1))
        h.appendLittleEndian(indexOffset)
        h.appendLittleEndian(UInt64(PlanetTileFile.headerSize))
        h.appendLittleEndian(UInt32(metadata.count))
        h.append(Data(count: PlanetTileFile.headerSize - h.count))
        return h
    }

    /// `x` as a Float32 rounded outward, so the stored range still bounds it.
    static func float(_ x: Double, _ direction: FloatingPointRoundingRule) -> Float {
        let f = Float(x)
        if direction == .down && Double(f) > x { return f.nextDown }
        if direction == .up && Double(f) < x { return f.nextUp }
        return f
    }
}

/// CRC-32 (IEEE 802.3, reflected, polynomial 0xEDB88320), as zip and PNG use.
enum CRC32 {
    static let table: [UInt32] = (0 ..< 256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0 ..< 8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { bytes in
            for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFF_FFFF
    }
}

/// Reads little-endian fields at byte offsets.
struct LittleEndianReader {
    let data: Data
    init(_ data: Data) { self.data = data }

    func load<T: FixedWidthInteger>(_ offset: Int, _ type: T.Type) -> T {
        data.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }
    func u32(_ o: Int) -> UInt32 { load(o, UInt32.self) }
    func i32(_ o: Int) -> Int32 { load(o, Int32.self) }
    func u64(_ o: Int) -> UInt64 { load(o, UInt64.self) }
    func f32(_ o: Int) -> Float { Float(bitPattern: u32(o)) }
    func f64(_ o: Int) -> Double { Double(bitPattern: u64(o)) }
}

extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
