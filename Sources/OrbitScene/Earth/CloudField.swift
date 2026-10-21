import Foundation
import OrbitCore

// Track C1: the cloud field. A mission's weather is ERA5 for its dates,
// written as OSCLOUD1 by tools/make_clouds_era5.py (fetched by the owner,
// not committed), the zonal climatology where the field has no data
// (CloudClimatology.swift), and the observed sky at the pad at launch from
// NASA TM X-64796 Table 1 (CloudOverride). The renderer (C2) reads the
// planes it uploads and the layer model (CloudOptics.swift); the rest of
// the app asks `CloudWeather` for a place and time.

/// The clouds at one place and time.
public struct CloudSample: Equatable {
    /// Cover, 0...1, of ERA5's three layers: low below 0.8 of the surface
    /// pressure (about 2 km), mid from 0.8 to 0.45 (about 2-6 km), high
    /// above 0.45 (about 6 km).
    public var low: Double
    public var mid: Double
    public var high: Double
    /// The lowest cloud's base above the surface, m; nil when unknown or
    /// there is no cloud.
    public var baseHeight: Double?
    /// Whether the low cloud is cumulonimbus (an observation says so).
    public var convective: Bool
    /// The 10 m wind and the steering winds of the low, mid and high layers
    /// (850, 500 and 250 hPa); nil when unknown.
    public var surfaceWind: LayerWind?
    public var lowWind: LayerWind?
    public var midWind: LayerWind?
    public var highWind: LayerWind?

    public init(low: Double, mid: Double, high: Double, baseHeight: Double? = nil, convective: Bool = false,
                surfaceWind: LayerWind? = nil, lowWind: LayerWind? = nil, midWind: LayerWind? = nil,
                highWind: LayerWind? = nil) {
        self.low = low
        self.mid = mid
        self.high = high
        self.baseHeight = baseHeight
        self.convective = convective
        self.surfaceWind = surfaceWind
        self.lowWind = lowWind
        self.midWind = midWind
        self.highWind = highWind
    }

    /// `a` with weight 1 - w and `b` with weight w. A value only one side
    /// has comes from that side when its weight is at least one half.
    public static func mix(_ a: CloudSample, _ b: CloudSample, _ w: Double) -> CloudSample {
        func lerp(_ x: Double, _ y: Double) -> Double { x + w * (y - x) }
        func pick<T>(_ x: T?, _ y: T?, _ both: (T, T) -> T) -> T? {
            if let x, let y { return both(x, y) }
            return w < 0.5 ? x : y
        }
        return CloudSample(
            low: lerp(a.low, b.low), mid: lerp(a.mid, b.mid), high: lerp(a.high, b.high),
            baseHeight: pick(a.baseHeight, b.baseHeight, lerp),
            convective: w < 0.5 ? a.convective : b.convective,
            surfaceWind: pick(a.surfaceWind, b.surfaceWind) { LayerWind.mix($0, $1, w) },
            lowWind: pick(a.lowWind, b.lowWind) { LayerWind.mix($0, $1, w) },
            midWind: pick(a.midWind, b.midWind) { LayerWind.mix($0, $1, w) },
            highWind: pick(a.highWind, b.highWind) { LayerWind.mix($0, $1, w) })
    }
}

/// A horizontal wind, m/s towards the east and the north.
public struct LayerWind: Equatable {
    public var east: Double
    public var north: Double

    public init(east: Double, north: Double) {
        self.east = east
        self.north = north
    }

    public static func mix(_ a: LayerWind, _ b: LayerWind, _ w: Double) -> LayerWind {
        LayerWind(east: a.east + w * (b.east - a.east), north: a.north + w * (b.north - a.north))
    }
}

/// An OSCLOUD1 file: global planes of bytes (cover, cloud base, winds) at
/// a list of UTC times. The format is tools/make_clouds_era5.py's
/// docstring; in short, little endian:
///
///     "OSCLOUD1", uint32 header bytes H, uint32 snapshots N, uint32 planes P, uint32 0,
///     P × (8-byte name, uint32 columns, uint32 rows, float64 offset, float64 scale),
///     N × int64 POSIX seconds (UTC), uint32 note bytes, the note (UTF-8),
///     then from H, snapshot by snapshot, each plane's rows × columns bytes.
///
/// Row r of a plane is at latitude 90° - 180° r / (rows - 1), column c at
/// longitude 360° c / columns east; a byte b means offset + scale × b, and
/// 255 means no value. Snapshots are read when first asked for and the
/// last `residentSnapshots` kept.
public final class CloudField {
    public struct Plane: Equatable {
        public var name: String
        public var columns: Int
        public var rows: Int
        public var offset: Double
        public var scale: Double

        public init(name: String, columns: Int, rows: Int, offset: Double, scale: Double) {
            self.name = name
            self.columns = columns
            self.rows = rows
            self.offset = offset
            self.scale = scale
        }

        /// A plane's grid step, degrees.
        public var step: Double { 360 / Double(columns) }
        public var count: Int { columns * rows }

        /// The byte for `value` (255 for nil), rounded half to even as the
        /// tool rounds.
        public func byte(_ value: Double?) -> UInt8 {
            guard let value, value.isFinite else { return 255 }
            let b = ((value - offset) / scale).rounded(.toNearestOrEven)
            return UInt8(min(max(b, 0), 254))
        }

        /// The value a byte stands for (nil for 255).
        public func value(_ byte: UInt8) -> Double? {
            byte == 255 ? nil : offset + scale * Double(byte)
        }
    }

    public enum FormatError: Error, Equatable {
        case notOSCLOUD1
        case truncated
        case badPlane(String)
        case timesNotIncreasing
    }

    public static let magic = Array("OSCLOUD1".utf8)
    /// The cover planes a field must have.
    public static let coverPlanes = ["lcc", "mcc", "hcc"]

    public let planes: [Plane]
    /// The snapshots' times as stored: POSIX seconds, UTC.
    public let utcSeconds: [Int64]
    /// The snapshots' times.
    public let times: [Epoch]
    /// The file's note: its source and the ERA5 attribution line.
    public let note: String
    /// Snapshots held in memory at once.
    public var residentSnapshots = 3

    private let headerBytes: Int
    private let snapshotBytes: Int
    private let planeOffsets: [Int]
    private let index: [String: Int]
    private let source: Source
    private let lock = NSLock()
    private var cache: [(snapshot: Int, bytes: [UInt8])] = []

    private enum Source {
        case data(Data)
        case file(FileHandle)
    }

    /// The field in `data` (a whole file).
    public convenience init(data: Data) throws {
        try self.init(header: data, source: .data(data), length: data.count)
    }

    /// The field in the file at `url`, read a snapshot at a time.
    public convenience init(contentsOf url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        let length = Int(try handle.seekToEnd())
        try handle.seek(toOffset: 0)
        guard let first = try handle.read(upToCount: 24), first.count == 24 else { throw FormatError.truncated }
        let size = Int(Self.uint32(first, 8))
        try handle.seek(toOffset: 0)
        guard let head = try handle.read(upToCount: size), head.count == size else { throw FormatError.truncated }
        try self.init(header: head, source: .file(handle), length: length)
    }

    private init(header h: Data, source: Source, length: Int) throws {
        guard h.count >= 24, Array(h.prefix(8)) == Self.magic else { throw FormatError.notOSCLOUD1 }
        let size = Int(Self.uint32(h, 8)), n = Int(Self.uint32(h, 12)), p = Int(Self.uint32(h, 16))
        guard h.count >= size, size >= 28 + 32 * p + 8 * n else { throw FormatError.truncated }
        var planes: [Plane] = []
        for i in 0..<p {
            let at = 24 + 32 * i
            let nameBytes = h.subdata(in: h.startIndex + at..<h.startIndex + at + 8).prefix { $0 != 0 }
            let plane = Plane(name: String(decoding: nameBytes, as: UTF8.self),
                              columns: Int(Self.uint32(h, at + 8)), rows: Int(Self.uint32(h, at + 12)),
                              offset: Double(bitPattern: Self.uint64(h, at + 16)),
                              scale: Double(bitPattern: Self.uint64(h, at + 24)))
            guard plane.columns > 0, plane.rows >= 2 else { throw FormatError.badPlane(plane.name) }
            planes.append(plane)
        }
        let timesAt = 24 + 32 * p
        let seconds = (0..<n).map { Int64(bitPattern: Self.uint64(h, timesAt + 8 * $0)) }
        guard zip(seconds, seconds.dropFirst()).allSatisfy({ $0 < $1 }) else { throw FormatError.timesNotIncreasing }
        let noteAt = timesAt + 8 * n
        let noteBytes = Int(Self.uint32(h, noteAt))
        guard noteAt + 4 + noteBytes <= size else { throw FormatError.truncated }
        let noteStart = h.startIndex + noteAt + 4
        note = String(decoding: h.subdata(in: noteStart..<noteStart + noteBytes), as: UTF8.self)

        var offsets: [Int] = [], total = 0
        for plane in planes {
            offsets.append(total)
            total += plane.count
        }
        guard length >= size + n * total else { throw FormatError.truncated }
        for name in Self.coverPlanes where !planes.contains(where: { $0.name == name }) {
            throw FormatError.badPlane(name)
        }
        self.planes = planes
        utcSeconds = seconds
        times = seconds.map { Epoch(julianDateUTC: 2_440_587.5 + Double($0) / 86_400) }
        headerBytes = size
        snapshotBytes = total
        planeOffsets = offsets
        index = Dictionary(planes.enumerated().map { ($1.name, $0) }, uniquingKeysWith: { a, _ in a })
        self.source = source
    }

    /// The file `encode` writes: `snapshots[n][p]` is snapshot n's plane p,
    /// rows × columns bytes from the north.
    public static func encode(planes: [Plane], utcSeconds: [Int64], note: String, snapshots: [[[UInt8]]]) -> Data {
        precondition(snapshots.count == utcSeconds.count)
        let noteBytes = Array(note.utf8)
        var out = Data(magic)
        let size = 28 + 32 * planes.count + 8 * utcSeconds.count + noteBytes.count
        for v in [size, utcSeconds.count, planes.count, 0] { append(&out, UInt32(v)) }
        for plane in planes {
            var name = Array(plane.name.utf8.prefix(8))
            name += [UInt8](repeating: 0, count: 8 - name.count)
            out.append(contentsOf: name)
            append(&out, UInt32(plane.columns))
            append(&out, UInt32(plane.rows))
            append(&out, plane.offset.bitPattern)
            append(&out, plane.scale.bitPattern)
        }
        for t in utcSeconds { append(&out, UInt64(bitPattern: t)) }
        append(&out, UInt32(noteBytes.count))
        out.append(contentsOf: noteBytes)
        for snapshot in snapshots {
            for (plane, bytes) in zip(planes, snapshot) {
                precondition(bytes.count == plane.count)
                out.append(contentsOf: bytes)
            }
        }
        return out
    }

    // MARK: Reading

    /// The plane called `name`, if the field has it.
    public func plane(_ name: String) -> Int? { index[name] }

    /// Plane `plane` of snapshot `snapshot`, rows × columns bytes from the
    /// north (for upload as a texture).
    public func bytes(plane: Int, snapshot: Int) -> ArraySlice<UInt8> {
        let all = load(snapshot)
        let start = planeOffsets[plane]
        return all[start..<start + planes[plane].count]
    }

    /// The two snapshots around `epoch` and the weight of the second, nil
    /// outside the field's span. A single snapshot covers its own instant.
    public func bracket(_ epoch: Epoch) -> (first: Int, second: Int, weight: Double)? {
        guard let first = times.first, let last = times.last, epoch >= first, epoch <= last else { return nil }
        var lo = 0, hi = times.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if times[mid] <= epoch { lo = mid } else { hi = mid }
        }
        guard hi > lo else { return (lo, lo, 0) }
        let w = (epoch - times[lo]) / (times[hi] - times[lo])
        return (lo, hi, min(max(w, 0), 1))
    }

    /// Plane `plane` of snapshot `snapshot` at a point (geodetic latitude
    /// and east longitude, rad): bilinear between the four grid points
    /// around it, leaving out those with no value; nil when all four have
    /// none.
    public func value(plane: Int, snapshot: Int, latitude: Double, longitude: Double) -> Double? {
        let p = planes[plane]
        let latStep = Double.pi / Double(p.rows - 1), lonStep = 2 * Double.pi / Double(p.columns)
        let r = min(max((Double.pi / 2 - latitude) / latStep, 0), Double(p.rows - 1))
        let r0 = min(Int(r), p.rows - 2)
        let fr = r - Double(r0)
        var c = longitude.truncatingRemainder(dividingBy: 2 * Double.pi) / lonStep
        if c < 0 { c += Double(p.columns) }
        let c0 = Int(c) % p.columns, c1 = (c0 + 1) % p.columns
        let fc = c - c.rounded(.down)
        let all = load(snapshot)
        let base = planeOffsets[plane] + r0 * p.columns
        let corners: [(Int, Double)] = [(base + c0, (1 - fr) * (1 - fc)), (base + c1, (1 - fr) * fc),
                                        (base + p.columns + c0, fr * (1 - fc)), (base + p.columns + c1, fr * fc)]
        var total = 0.0, weight = 0.0
        for (i, w) in corners {
            guard let v = p.value(all[i]) else { continue }
            total += w * v
            weight += w
        }
        return weight > 1e-12 ? total / weight : nil
    }

    /// Plane `name` at a point and time, linear in time between the
    /// snapshots around it; nil outside the field's span, when the field
    /// has no such plane, or when neither snapshot has a value there.
    public func value(_ name: String, latitude: Double, longitude: Double, at epoch: Epoch) -> Double? {
        guard let plane = index[name], let around = bracket(epoch) else { return nil }
        let w = around.weight
        let a = value(plane: plane, snapshot: around.first, latitude: latitude, longitude: longitude)
        guard around.second != around.first, w > 0 else { return a }
        let b = value(plane: plane, snapshot: around.second, latitude: latitude, longitude: longitude)
        if let a, let b { return a + w * (b - a) }
        return w < 0.5 ? a : b
    }

    /// The clouds at a point and time; nil outside the field's span or where
    /// it has no cover.
    public func sample(latitude: Double, longitude: Double, at epoch: Epoch) -> CloudSample? {
        func v(_ name: String) -> Double? { value(name, latitude: latitude, longitude: longitude, at: epoch) }
        func cover(_ name: String) -> Double? { v(name).map { min(max($0, 0), 1) } }
        func wind(_ u: String, _ v: String) -> LayerWind? {
            guard let east = value(u, latitude: latitude, longitude: longitude, at: epoch),
                  let north = value(v, latitude: latitude, longitude: longitude, at: epoch) else { return nil }
            return LayerWind(east: east, north: north)
        }
        guard let low = cover("lcc"), let mid = cover("mcc"), let high = cover("hcc") else { return nil }
        return CloudSample(low: low, mid: mid, high: high, baseHeight: v("cbh"), convective: false,
                           surfaceWind: wind("u10", "v10"), lowWind: wind("u850", "v850"),
                           midWind: wind("u500", "v500"), highWind: wind("u250", "v250"))
    }

    // MARK: Storage

    private func load(_ snapshot: Int) -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache.firstIndex(where: { $0.snapshot == snapshot }) {
            let entry = cache.remove(at: hit)
            cache.append(entry)
            return entry.bytes
        }
        let start = headerBytes + snapshot * snapshotBytes
        let bytes: [UInt8]
        switch source {
        case .data(let data):
            bytes = [UInt8](data[data.startIndex + start..<data.startIndex + start + snapshotBytes])
        case .file(let handle):
            // The size was checked when the header was read.
            try? handle.seek(toOffset: UInt64(start))
            let read = (try? handle.read(upToCount: snapshotBytes)) ?? Data()
            bytes = read.count == snapshotBytes ? [UInt8](read) : [UInt8](repeating: 255, count: snapshotBytes)
        }
        cache.append((snapshot, bytes))
        if cache.count > max(residentSnapshots, 1) { cache.removeFirst() }
        return bytes
    }

    private static func uint32(_ d: Data, _ at: Int) -> UInt32 {
        var v: UInt32 = 0
        for k in 0..<4 { v |= UInt32(d[d.startIndex + at + k]) << (8 * k) }
        return v
    }

    private static func uint64(_ d: Data, _ at: Int) -> UInt64 {
        UInt64(uint32(d, at)) | UInt64(uint32(d, at + 4)) << 32
    }

    private static func append<T: FixedWidthInteger>(_ out: inout Data, _ v: T) {
        withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) }
    }
}
