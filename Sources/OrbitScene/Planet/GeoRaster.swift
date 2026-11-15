import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// Rasters on a latitude-longitude grid (equirectangular, "plate carrée"):
// what the Earth's sources are (BMNG, ETOPO 2022, the rasterised Natural
// Earth water), sampled by geodetic latitude and longitude when PlanetTiles
// builds the cube-sphere tiles (track E1). Pure Foundation, so the tile
// builder is tested on Linux on synthetic rasters.

/// A regular latitude-longitude grid, north-up: row 0 is the northernmost,
/// column 0 the westernmost. Pixels are areas (GeoTIFF's PixelIsArea):
/// pixel (c, r) spans longitudes west + c·Δλ to west + (c+1)·Δλ, and its
/// centre is half a pixel in.
public struct GeoGrid: Equatable, Codable {
    public var width: Int
    public var height: Int
    /// The west edge of column 0 and the north edge of row 0, degrees.
    public var west: Double
    public var north: Double
    /// Pixel size, degrees of longitude and of latitude.
    public var pixelWidth: Double
    public var pixelHeight: Double

    public init(width: Int, height: Int, west: Double, north: Double, pixelWidth: Double, pixelHeight: Double) {
        self.width = width; self.height = height; self.west = west; self.north = north
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
    }

    /// The whole globe, `width` × `width`/2 pixels from 180° W and 90° N.
    public static func global(width: Int) -> GeoGrid {
        GeoGrid(width: width, height: width / 2, west: -180, north: 90, pixelWidth: 360 / Double(width),
                pixelHeight: 360 / Double(width))
    }

    /// Whether the columns go once round the globe, so longitude wraps.
    public var wrapsLongitude: Bool { abs(Double(width) * pixelWidth - 360) < 1e-9 * 360 }

    /// The fractional column and row of a point (degrees), in pixel units
    /// from the grid's west and north edges: pixel centres are at k + ½.
    @inlinable public func position(latitudeDegrees lat: Double, longitudeDegrees lon: Double) -> (x: Double, y: Double) {
        ((lon - west) / pixelWidth, (north - lat) / pixelHeight)
    }

    /// The grid halved: each pixel the union of a 2 × 2 block (a last odd
    /// row or column is kept whole).
    public var halved: GeoGrid {
        GeoGrid(width: (width + 1) / 2, height: (height + 1) / 2, west: west, north: north,
                pixelWidth: pixelWidth * 2, pixelHeight: pixelHeight * 2)
    }
}

/// How a raster stores its samples.
public enum GeoSampleType: UInt32, Codable {
    case uint8 = 1, uint16 = 2, int16 = 3, float32 = 4

    public var size: Int {
        switch self {
        case .uint8: return 1
        case .uint16, .int16: return 2
        case .float32: return 4
        }
    }
}

/// Bytes a raster lives in: heap memory, or a file mapped into memory.
public final class RasterStorage {
    public let bytes: UnsafeMutableRawPointer
    public let count: Int
    private let mapping: (base: UnsafeMutableRawPointer, length: Int)?

    /// Zeroed heap memory.
    public init(count: Int) {
        self.count = count
        bytes = UnsafeMutableRawPointer.allocate(byteCount: max(count, 1), alignment: 16)
        bytes.initializeMemory(as: UInt8.self, repeating: 0, count: max(count, 1))
        mapping = nil
    }

    /// `count` bytes of the file at `path` from `offset`, mapped read-only,
    /// or read-write when `writable` (the file must be that long). The map
    /// starts at the file's start, so `offset` need not be page-aligned.
    public init(mapping path: String, offset: Int, count: Int, writable: Bool) throws {
        let fd = posixOpen(path, writable ? O_RDWR : O_RDONLY)
        guard fd >= 0 else { throw GeoRasterError.io("cannot open \(path)") }
        defer { close(fd) }
        let protection = writable ? PROT_READ | PROT_WRITE : PROT_READ
        let length = offset + count
        // MAP_FAILED, (void *)-1, which Swift's Glibc does not import.
        let p: UnsafeMutableRawPointer? = mmap(nil, length, protection, MAP_SHARED, fd, 0)
        guard let p, p != UnsafeMutableRawPointer(bitPattern: -1) else {
            throw GeoRasterError.io("cannot map \(path)")
        }
        mapping = (p, length)
        bytes = p + offset
        self.count = count
    }

    deinit {
        if let mapping { munmap(mapping.base, mapping.length) } else { bytes.deallocate() }
    }
}

/// POSIX open(2), out of the way of the types' own `open`.
func posixOpen(_ path: String, _ flags: Int32) -> Int32 { open(path, flags) }

public enum GeoRasterError: Error, CustomStringConvertible {
    case io(String)
    case format(String)

    public var description: String {
        switch self {
        case .io(let s): return "raster: \(s)"
        case .format(let s): return "raster: \(s)"
        }
    }
}

/// A raster: `channels` interleaved samples per pixel, rows north to south.
public final class GeoRaster {
    public let grid: GeoGrid
    public let channels: Int
    public let type: GeoSampleType
    public let storage: RasterStorage
    /// Sample value scale: a sample reads as raw × scale (1, or 1/255 for
    /// colour rasters read as fractions).
    public var scale: Float = 1
    /// The raw value that means no data, if any: it reads as NaN.
    public var noData: Float?

    public init(grid: GeoGrid, channels: Int, type: GeoSampleType, storage: RasterStorage? = nil) {
        self.grid = grid
        self.channels = channels
        self.type = type
        let count = grid.width * grid.height * channels * type.size
        self.storage = storage ?? RasterStorage(count: count)
        precondition(self.storage.count >= count, "raster storage too small")
    }

    public var bytesPerRow: Int { grid.width * channels * type.size }

    /// The samples as a value: what hot loops on many threads read, with
    /// no reference counting (the raster must outlive it).
    public var view: RasterView {
        RasterView(bytes: storage.bytes, grid: grid, channels: channels, type: type, scale: scale, noData: noData)
    }

    /// The raw sample of pixel (column, row), channel `channel`.
    public func raw(_ column: Int, _ row: Int, _ channel: Int = 0) -> Float { view.raw(column, row, channel) }

    /// The sample's value: raw × scale, NaN for no data.
    public func value(_ column: Int, _ row: Int, _ channel: Int = 0) -> Float { view.value(column, row, channel) }

    /// Writes a raw sample, rounded and clamped to the type's range.
    public func setRaw(_ column: Int, _ row: Int, _ channel: Int, _ v: Float) { view.setRaw(column, row, channel, v) }

    /// Bilinear values at a fractional pixel position (`RasterView.bilinear`).
    public func bilinear(x: Double, y: Double) -> SIMD4<Float> { view.bilinear(x: x, y: y) }

    /// The raster halved by averaging 2 × 2 blocks (no-data samples left
    /// out), in a new heap raster, or in `storage` when given. `linearize`
    /// maps samples to the space they are averaged in and `delinearize`
    /// back (sRGB colour is averaged in linear light).
    public func halved(storage: RasterStorage? = nil, linearize: ((Float) -> Float)? = nil,
                       delinearize: ((Float) -> Float)? = nil) -> GeoRaster {
        let g = grid.halved
        let out = GeoRaster(grid: g, channels: channels, type: type, storage: storage)
        out.scale = scale
        out.noData = noData
        let w = grid.width, h = grid.height
        let src = view, dst = out.view, noData = self.noData
        DispatchQueue.concurrentPerform(iterations: g.height) { r in
            for c in 0 ..< g.width {
                for ch in 0 ..< channels {
                    var sum: Float = 0, n: Float = 0
                    for dy in 0 ..< 2 {
                        let y = 2 * r + dy
                        guard y < h else { continue }
                        for dx in 0 ..< 2 {
                            let x = 2 * c + dx
                            guard x < w else { continue }
                            let v = src.raw(x, y, ch)
                            if let noData, v == noData { continue }
                            sum += linearize?(v) ?? v
                            n += 1
                        }
                    }
                    let v = n > 0 ? sum / n : (noData ?? 0)
                    dst.setRaw(c, r, ch, n > 0 ? (delinearize?(v) ?? v) : v)
                }
            }
        }
        return out
    }
}

/// A raster's samples as a plain value: a pointer, its shape and how to
/// read it. Copying it costs nothing and touches no reference count, so
/// sampling loops on many threads do not contend (the raster it came from
/// must stay alive).
public struct RasterView {
    public let bytes: UnsafeMutableRawPointer
    public let grid: GeoGrid
    public let channels: Int
    public let type: GeoSampleType
    public let scale: Float
    public let noData: Float?
    let width: Int, height: Int, wraps: Bool

    public init(bytes: UnsafeMutableRawPointer, grid: GeoGrid, channels: Int, type: GeoSampleType, scale: Float, noData: Float?) {
        self.bytes = bytes; self.grid = grid; self.channels = channels; self.type = type; self.scale = scale
        self.noData = noData
        width = grid.width; height = grid.height; wraps = grid.wrapsLongitude
    }

    @inline(__always) public func raw(_ column: Int, _ row: Int, _ channel: Int = 0) -> Float {
        let k = (row * width + column) * channels + channel
        switch type {
        case .uint8: return Float(bytes.load(fromByteOffset: k, as: UInt8.self))
        case .uint16: return Float(bytes.load(fromByteOffset: 2 * k, as: UInt16.self))
        case .int16: return Float(bytes.load(fromByteOffset: 2 * k, as: Int16.self))
        case .float32: return bytes.load(fromByteOffset: 4 * k, as: Float.self)
        }
    }

    @inline(__always) public func value(_ column: Int, _ row: Int, _ channel: Int = 0) -> Float {
        let r = raw(column, row, channel)
        if let noData, r == noData { return .nan }
        return r * scale
    }

    public func setRaw(_ column: Int, _ row: Int, _ channel: Int, _ v: Float) {
        let k = (row * width + column) * channels + channel
        switch type {
        case .uint8: bytes.storeBytes(of: UInt8(clamping: Int(v.isFinite ? v.rounded() : 0)), toByteOffset: k, as: UInt8.self)
        case .uint16: bytes.storeBytes(of: UInt16(clamping: Int(v.isFinite ? v.rounded() : 0)), toByteOffset: 2 * k, as: UInt16.self)
        case .int16: bytes.storeBytes(of: Int16(clamping: Int(v.isFinite ? v.rounded() : 0)), toByteOffset: 2 * k, as: Int16.self)
        case .float32: bytes.storeBytes(of: v, toByteOffset: 4 * k, as: Float.self)
        }
    }

    /// Bilinear values at a fractional pixel position (pixel units from the
    /// grid's edges, centres at k + ½), one lane per channel (at most 4).
    /// Longitude wraps on a global grid; rows and other columns clamp. A
    /// no-data neighbour is left out and the weights renormalised; with none
    /// left the value is NaN.
    public func bilinear(x: Double, y: Double) -> SIMD4<Float> {
        let w = width, h = height
        let fx = x - 0.5, fy = y - 0.5
        let fx0 = fx.rounded(.down), fy0 = fy.rounded(.down)
        let tx = Float(fx - fx0), ty = Float(fy - fy0)
        var x0 = Int(fx0), y0 = Int(fy0)
        var x1 = x0 + 1, y1 = y0 + 1
        if wraps {
            x0 = ((x0 % w) + w) % w; x1 = ((x1 % w) + w) % w
        } else {
            x0 = min(max(x0, 0), w - 1); x1 = min(max(x1, 0), w - 1)
        }
        y0 = min(max(y0, 0), h - 1); y1 = min(max(y1, 0), h - 1)
        let w00 = (1 - tx) * (1 - ty), w10 = tx * (1 - ty), w01 = (1 - tx) * ty, w11 = tx * ty
        var out = SIMD4<Float>(repeating: .nan)
        for c in 0 ..< min(channels, 4) {
            let v00 = value(x0, y0, c), v10 = value(x1, y0, c), v01 = value(x0, y1, c), v11 = value(x1, y1, c)
            if v00.isFinite && v10.isFinite && v01.isFinite && v11.isFinite {
                out[c] = v00 * w00 + v10 * w10 + v01 * w01 + v11 * w11
                continue
            }
            var sum: Float = 0, weight: Float = 0
            if v00.isFinite { sum += v00 * w00; weight += w00 }
            if v10.isFinite { sum += v10 * w10; weight += w10 }
            if v01.isFinite { sum += v01 * w01; weight += w01 }
            if v11.isFinite { sum += v11 * w11; weight += w11 }
            out[c] = weight > 0 ? sum / weight : .nan
        }
        return out
    }
}

// MARK: - Raw raster files

/// The tool's intermediate raster file, "OSRASTR1": a 4,096-byte header,
/// then the samples row by row (north first), little-endian, so the
/// samples can be mapped in place at a page boundary.
///     0  8  "OSRASTR1"
///     8  4  UInt32 width
///    12  4  UInt32 height
///    16  4  UInt32 channels
///    20  4  UInt32 sample type (`GeoSampleType`)
///    24  8  Float64 west edge, degrees
///    32  8  Float64 north edge
///    40  8  Float64 pixel width, degrees
///    48  8  Float64 pixel height
///    56  4  Float32 scale
///    60  4  UInt32 flags: bit 0 set when the no-data value is in use
///    64  4  Float32 no-data raw value
public enum GeoRasterFile {
    public static let magic = "OSRASTR1"
    public static let headerSize = 4096

    /// Creates the file at `path` for `grid`, its samples zero, and maps it
    /// read-write.
    public static func create(path: String, grid: GeoGrid, channels: Int, type: GeoSampleType,
                              scale: Float = 1, noData: Float? = nil) throws -> GeoRaster {
        let count = grid.width * grid.height * channels * type.size
        guard FileManager.default.createFile(atPath: path, contents: header(grid, channels, type, scale, noData)) else {
            throw GeoRasterError.io("cannot create \(path)")
        }
        let fd = posixOpen(path, O_RDWR)
        guard fd >= 0, ftruncate(fd, off_t(headerSize + count)) == 0 else {
            if fd >= 0 { close(fd) }
            throw GeoRasterError.io("cannot size \(path)")
        }
        close(fd)
        let storage = try RasterStorage(mapping: path, offset: headerSize, count: count, writable: true)
        let r = GeoRaster(grid: grid, channels: channels, type: type, storage: storage)
        r.scale = scale
        r.noData = noData
        return r
    }

    /// A raster file at `path` that is always complete: made by `fill` in
    /// `path`.partial and renamed to `path` only when `fill` returns. With
    /// `reuse`, a complete file of the same shape at `path` is returned as
    /// it is and `fill` is not called. A run interrupted in `fill` (an
    /// error, a signal, a full disk) leaves at most the .partial file,
    /// which the next build starts over. Returns the raster, mapped
    /// read-write, and whether it was reused.
    public static func build(path: String, grid: GeoGrid, channels: Int, type: GeoSampleType, scale: Float = 1,
                             noData: Float? = nil, reuse: Bool = true,
                             fill: (GeoRaster) throws -> Void) throws -> (raster: GeoRaster, reused: Bool) {
        if reuse, FileManager.default.fileExists(atPath: path), let r = try? open(path: path, writable: true),
           r.grid == grid, r.channels == channels, r.type == type {
            return (r, true)
        }
        let partial = path + ".partial"
        try? FileManager.default.removeItem(atPath: path)
        let r = try create(path: partial, grid: grid, channels: channels, type: type, scale: scale, noData: noData)
        do {
            try fill(r)
        } catch {
            try? FileManager.default.removeItem(atPath: partial)
            throw error
        }
        guard rename(partial, path) == 0 else { throw GeoRasterError.io("cannot rename \(partial)") }
        return (r, false)
    }

    /// Maps the file at `path` read-only (or read-write).
    public static func open(path: String, writable: Bool = false) throws -> GeoRaster {
        let head = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? head.close() }
        let h = head.readData(ofLength: 68)
        guard h.count == 68, String(decoding: h.prefix(8), as: UTF8.self) == magic else {
            throw GeoRasterError.format("\(path) is not an OSRASTR1 file")
        }
        func u32(_ o: Int) -> UInt32 { h.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt32.self)) } }
        func f64(_ o: Int) -> Double { h.withUnsafeBytes { Double(bitPattern: UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt64.self))) } }
        guard let type = GeoSampleType(rawValue: u32(20)) else { throw GeoRasterError.format("sample type") }
        let grid = GeoGrid(width: Int(u32(8)), height: Int(u32(12)), west: f64(24), north: f64(32),
                           pixelWidth: f64(40), pixelHeight: f64(48))
        let channels = Int(u32(16))
        let count = grid.width * grid.height * channels * type.size
        let storage = try RasterStorage(mapping: path, offset: headerSize, count: count, writable: writable)
        let r = GeoRaster(grid: grid, channels: channels, type: type, storage: storage)
        r.scale = Float(bitPattern: u32(56))
        r.noData = u32(60) & 1 != 0 ? Float(bitPattern: u32(64)) : nil
        return r
    }

    static func header(_ g: GeoGrid, _ channels: Int, _ type: GeoSampleType, _ scale: Float, _ noData: Float?) -> Data {
        var d = Data(magic.utf8)
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        put(UInt32(g.width)); put(UInt32(g.height)); put(UInt32(channels)); put(type.rawValue)
        put(g.west.bitPattern); put(g.north.bitPattern); put(g.pixelWidth.bitPattern); put(g.pixelHeight.bitPattern)
        put(scale.bitPattern); put(UInt32(noData == nil ? 0 : 1)); put((noData ?? 0).bitPattern)
        d.append(Data(count: headerSize - d.count))
        return d
    }
}

// MARK: - Sampling over a footprint

/// A raster and its halvings: samples it over a footprint, so a tile texel
/// that covers many source pixels averages them instead of aliasing.
public final class GeoRasterPyramid {
    /// Level 0 the full raster, each next one halved.
    public let levels: [GeoRaster]
    /// Their samples, read without reference counting.
    let views: [RasterView]
    let base: GeoGrid

    public init(levels: [GeoRaster]) {
        precondition(!levels.isEmpty)
        self.levels = levels
        views = levels.map(\.view)
        base = levels[0].grid
    }

    /// A pyramid of in-memory halvings down to `minimumWidth` pixels.
    public convenience init(_ base: GeoRaster, minimumWidth: Int = 64, linearize: ((Float) -> Float)? = nil,
                            delinearize: ((Float) -> Float)? = nil) {
        var levels = [base]
        while levels.last!.grid.width > minimumWidth && levels.last!.grid.height > 1 {
            levels.append(levels.last!.halved(linearize: linearize, delinearize: delinearize))
        }
        self.init(levels: levels)
    }

    public var channels: Int { views[0].channels }

    /// The values (one lane per channel) at geodetic `latitude`,
    /// `longitude` (rad) averaged over a footprint `dLatitude` ×
    /// `dLongitude` (rad): the level whose pixels match the footprint's
    /// shorter side, interpolated with the next (trilinear), with taps
    /// spread along the longer side. NaN where only no data is found.
    public func sample(latitude: Double, longitude: Double, dLatitude: Double, dLongitude: Double) -> SIMD4<Float> {
        let base = self.base
        let toDeg = 180 / Double.pi
        let lat = latitude * toDeg, lon = longitude * toDeg
        let fLat = abs(dLatitude) * toDeg, fLon = abs(dLongitude) * toDeg
        let pxLat = fLat / base.pixelHeight, pxLon = fLon / base.pixelWidth
        let minor = min(pxLat, pxLon), major = max(pxLat, pxLon)
        let taps = min(16, max(1, Int((major / max(minor, 1)).rounded(.up))))
        let lod = max(0, log2(max(minor, 1)))
        let l0 = min(Int(lod), views.count - 1), l1 = min(l0 + 1, views.count - 1)
        let t = Float(min(max(lod - Double(l0), 0), 1))
        let alongLatitude = pxLat > pxLon
        let v0 = views[l0], v1 = views[l1]
        @inline(__always) func at(_ r: RasterView, _ la: Double, _ lo: Double) -> SIMD4<Float> {
            r.bilinear(x: (lo - r.grid.west) / r.grid.pixelWidth, y: (r.grid.north - la) / r.grid.pixelHeight)
        }
        var acc = SIMD4<Float>(repeating: 0), n: Float = 0
        let lanes = min(channels, 4)
        for k in 0 ..< taps {
            let f = taps == 1 ? 0 : (Double(k) + 0.5) / Double(taps) - 0.5
            let la = min(max(alongLatitude ? lat + f * fLat : lat, -90), 90)
            let lo = alongLatitude ? lon : lon + f * fLon
            var v = at(v0, la, lo)
            if t > 0 && l1 != l0 { v = v + (at(v1, la, lo) - v) * t }
            var finite = true
            for c in 0 ..< lanes where !v[c].isFinite { finite = false }
            if finite { acc += v; n += 1 }
        }
        return n > 0 ? acc / n : SIMD4<Float>(repeating: .nan)
    }
}

/// The sRGB transfer function and its inverse, on fractions 0...1.
public enum SRGB {
    @inlinable public static func toLinear(_ v: Float) -> Float {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    @inlinable public static func fromLinear(_ v: Float) -> Float {
        v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    /// 8-bit sRGB to linear, by table.
    public static let byteToLinear: [Float] = (0 ..< 256).map { toLinear(Float($0) / 255) }

    /// Linear 0...1 to 8-bit sRGB, by a table of 16,384 steps (within half
    /// a code everywhere, the curve's steep toe included).
    public static let linearToByteTable: [UInt8] = (0 ..< 16_384).map {
        UInt8(min(255, max(0, (fromLinear(Float($0) / 16_383) * 255).rounded())))
    }

    @inlinable public static func linearToByte(_ v: Float) -> UInt8 {
        linearToByteTable[Int(min(max(v, 0), 1) * 16_383 + 0.5)]
    }
}
