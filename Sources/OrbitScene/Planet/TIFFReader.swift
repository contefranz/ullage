import Foundation

/// A reader for the TIFF and GeoTIFF files the Earth's sources come in
/// (BMNG's `_geo.tif` tiles, ETOPO 2022, Landsat Collection 2 bands): one
/// image of chunky samples in strips or tiles, uncompressed, LZW or Deflate
/// (zlib), with the horizontal (2) or floating-point (3) predictor, and the
/// GeoTIFF tie point and pixel scale. Deflate is handed in by the caller
/// (`inflate`), so the container and LZW are pure Swift, tested on Linux.
/// Classic TIFF only (files under 4 GB); BigTIFF is refused.
public struct TIFFImage {
    public enum Failure: Error, CustomStringConvertible {
        case notTIFF, unsupported(String), corrupt(String)

        public var description: String {
            switch self {
            case .notTIFF: return "not a TIFF file"
            case .unsupported(let s): return "TIFF: unsupported \(s)"
            case .corrupt(let s): return "TIFF: corrupt \(s)"
            }
        }
    }

    /// Inflates a zlib stream (RFC 1950) to exactly `count` bytes.
    public typealias Inflate = (_ zlib: Data, _ count: Int) throws -> Data

    public let width: Int
    public let height: Int
    public let samplesPerPixel: Int
    public let bitsPerSample: Int
    /// 1 unsigned integer, 2 signed integer, 3 IEEE float.
    public let sampleFormat: Int
    public let compression: Int
    public let predictor: Int
    /// Strip (rowsPerStrip × width) or tile (tileWidth × tileHeight) blocks.
    public let blockWidth: Int
    public let blockHeight: Int
    public let isTiled: Bool
    let offsets: [Int]
    let counts: [Int]
    let bigEndian: Bool
    let data: Data
    let inflate: Inflate?
    /// GeoTIFF ModelTiepoint (i, j, k, x, y, z) and ModelPixelScale (sx, sy, sz).
    public let tiePoint: [Double]?
    public let pixelScale: [Double]?
    /// GDAL_NODATA, if given.
    public let noData: Double?

    public init(data: Data, inflate: Inflate? = nil) throws {
        guard data.count >= 8 else { throw Failure.notTIFF }
        let b0 = data[data.startIndex], b1 = data[data.startIndex + 1]
        guard (b0 == 0x49 && b1 == 0x49) || (b0 == 0x4D && b1 == 0x4D) else { throw Failure.notTIFF }
        let big = b0 == 0x4D
        let r = Reader(data: data, big: big)
        let magic = r.u16(2)
        if magic == 43 { throw Failure.unsupported("BigTIFF") }
        guard magic == 42 else { throw Failure.notTIFF }
        let ifd = Int(r.u32(4))
        guard ifd + 2 <= data.count else { throw Failure.corrupt("IFD offset") }
        var tags: [Int: [Double]] = [:]
        var ascii: [Int: String] = [:]
        let n = Int(r.u16(ifd))
        guard ifd + 2 + 12 * n <= data.count else { throw Failure.corrupt("IFD") }
        for k in 0 ..< n {
            let e = ifd + 2 + 12 * k
            let tag = Int(r.u16(e)), type = Int(r.u16(e + 2)), count = Int(r.u32(e + 4))
            let size: Int
            switch type {
            case 1, 2, 6, 7: size = 1
            case 3, 8: size = 2
            case 4, 9, 11: size = 4
            case 5, 10, 12: size = 8
            default: continue
            }
            let total = size * count
            let at = total <= 4 ? e + 8 : Int(r.u32(e + 8))
            guard at >= 0, at + total <= data.count else { throw Failure.corrupt("tag \(tag)") }
            if type == 2 {
                ascii[tag] = String(decoding: data[(data.startIndex + at) ..< (data.startIndex + at + total)].prefix { $0 != 0 },
                                    as: UTF8.self)
                continue
            }
            var values: [Double] = []
            values.reserveCapacity(count)
            for i in 0 ..< count {
                let o = at + i * size
                switch type {
                case 1, 7: values.append(Double(data[data.startIndex + o]))
                case 6: values.append(Double(Int8(bitPattern: data[data.startIndex + o])))
                case 3: values.append(Double(r.u16(o)))
                case 8: values.append(Double(Int16(bitPattern: r.u16(o))))
                case 4: values.append(Double(r.u32(o)))
                case 9: values.append(Double(Int32(bitPattern: r.u32(o))))
                case 11: values.append(Double(Float(bitPattern: r.u32(o))))
                case 12: values.append(Double(bitPattern: r.u64(o)))
                case 5: values.append(Double(r.u32(o)) / max(Double(r.u32(o + 4)), 1))
                case 10: values.append(Double(Int32(bitPattern: r.u32(o))) / Double(Int32(bitPattern: r.u32(o + 4))))
                default: break
                }
            }
            tags[tag] = values
        }
        func one(_ t: Int, _ d: Int? = nil) throws -> Int {
            if let v = tags[t]?.first { return Int(v) }
            if let d { return d }
            throw Failure.corrupt("missing tag \(t)")
        }
        width = try one(256)
        height = try one(257)
        samplesPerPixel = try one(277, 1)
        let bps = tags[258] ?? [1]
        guard Set(bps).count == 1 else { throw Failure.unsupported("mixed bits per sample") }
        bitsPerSample = Int(bps[0])
        sampleFormat = Int(tags[339]?.first ?? 1)
        compression = try one(259, 1)
        predictor = try one(317, 1)
        guard try one(284, 1) == 1 || samplesPerPixel == 1 else { throw Failure.unsupported("planar configuration") }
        guard [8, 16, 32].contains(bitsPerSample) else { throw Failure.unsupported("\(bitsPerSample) bits per sample") }
        guard [1, 5, 8, 32946].contains(compression) else { throw Failure.unsupported("compression \(compression)") }
        guard [1, 2, 3].contains(predictor) else { throw Failure.unsupported("predictor \(predictor)") }
        if let tw = tags[322]?.first, let th = tags[323]?.first {
            isTiled = true
            blockWidth = Int(tw); blockHeight = Int(th)
            offsets = (tags[324] ?? []).map { Int($0) }
            counts = (tags[325] ?? []).map { Int($0) }
        } else {
            isTiled = false
            blockWidth = width
            blockHeight = min(try one(278, height), height)
            offsets = (tags[273] ?? []).map { Int($0) }
            counts = (tags[279] ?? []).map { Int($0) }
        }
        let across = isTiled ? (width + blockWidth - 1) / max(blockWidth, 1) : 1
        let down = (height + blockHeight - 1) / max(blockHeight, 1)
        guard blockWidth > 0, blockHeight > 0, offsets.count == counts.count, offsets.count == across * down else {
            throw Failure.corrupt("block table")
        }
        for (o, c) in zip(offsets, counts) where o < 0 || c < 0 || o + c > data.count {
            throw Failure.corrupt("block past the end")
        }
        tiePoint = tags[33922]
        pixelScale = tags[33550]
        noData = ascii[42113].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        bigEndian = big
        self.data = data
        self.inflate = inflate
    }

    public var blocksAcross: Int { isTiled ? (width + blockWidth - 1) / blockWidth : 1 }
    public var blocksDown: Int { (height + blockHeight - 1) / blockHeight }
    public var blockCount: Int { offsets.count }
    public var bytesPerSample: Int { bitsPerSample / 8 }
    public var bytesPerPixel: Int { bytesPerSample * samplesPerPixel }

    /// The grid of a GeoTIFF on latitude and longitude (degrees; the tie
    /// point at pixel (0, 0)'s corner, PixelIsArea), nil without one.
    public var geoGrid: GeoGrid? {
        guard let t = tiePoint, t.count >= 6, let s = pixelScale, s.count >= 2 else { return nil }
        return GeoGrid(width: width, height: height, west: t[3] - t[0] * s[0], north: t[4] + t[1] * s[1],
                       pixelWidth: s[0], pixelHeight: s[1])
    }

    /// Block `index`'s pixels, decompressed and un-predicted, in the host's
    /// byte order: blockWidth × blockHeight pixels (a strip at the bottom
    /// may be shorter; tiles are always whole).
    public func block(_ index: Int) throws -> Data {
        let rows = isTiled ? blockHeight : min(blockHeight, height - index * blockHeight)
        let expected = blockWidth * rows * bytesPerPixel
        let start = data.startIndex + offsets[index]
        let raw = data.subdata(in: start ..< start + counts[index])
        var bytes: Data
        switch compression {
        case 1: bytes = raw
        case 5: bytes = try TIFFLZW.decode(raw, expected: expected)
        default:
            guard let inflate else { throw Failure.unsupported("Deflate without an inflater") }
            bytes = try inflate(raw, expected)
        }
        guard bytes.count >= expected else { throw Failure.corrupt("block \(index): \(bytes.count) of \(expected) bytes") }
        if bytes.count > expected { bytes = bytes.prefix(expected) }
        bytes.withUnsafeMutableBytes { p in
            Self.unpredict(p, width: blockWidth, rows: rows, samples: samplesPerPixel, bytes: bytesPerSample,
                           predictor: predictor, bigEndian: bigEndian, float: sampleFormat == 3)
        }
        return bytes
    }

    /// Undoes the predictor and byte-swaps to the host's order.
    static func unpredict(_ p: UnsafeMutableRawBufferPointer, width: Int, rows: Int, samples: Int, bytes: Int,
                          predictor: Int, bigEndian: Bool, float: Bool) {
        let rowBytes = width * samples * bytes
        let hostBig = 1.bigEndian == 1
        for r in 0 ..< rows {
            let row = p.baseAddress! + r * rowBytes
            if predictor == 3 {
                // Floating point (Adobe TN 3): bytes differenced across the
                // row, then stored most significant byte plane first.
                let b = row.assumingMemoryBound(to: UInt8.self)
                for i in samples ..< rowBytes { b[i] = b[i] &+ b[i - samples] }
                let copy = [UInt8](UnsafeBufferPointer(start: b, count: rowBytes))
                let count = width * samples
                for k in 0 ..< count {
                    for byte in 0 ..< bytes {
                        // Plane 0 holds the most significant bytes.
                        let v = copy[byte * count + k]
                        let dst = hostBig ? byte : bytes - 1 - byte
                        b[k * bytes + dst] = v
                    }
                }
                continue
            }
            if bigEndian != hostBig && bytes > 1 {
                let b = row.assumingMemoryBound(to: UInt8.self)
                for k in stride(from: 0, to: rowBytes, by: bytes) {
                    var lo = k, hi = k + bytes - 1
                    while lo < hi { let t = b[lo]; b[lo] = b[hi]; b[hi] = t; lo += 1; hi -= 1 }
                }
            }
            if predictor == 2 {
                switch bytes {
                case 1:
                    let b = row.assumingMemoryBound(to: UInt8.self)
                    for i in samples ..< width * samples { b[i] = b[i] &+ b[i - samples] }
                case 2:
                    let b = row.assumingMemoryBound(to: UInt16.self)
                    for i in samples ..< width * samples { b[i] = b[i] &+ b[i - samples] }
                default:
                    let b = row.assumingMemoryBound(to: UInt32.self)
                    for i in samples ..< width * samples { b[i] = b[i] &+ b[i - samples] }
                }
            }
        }
    }

    /// Copies the whole image into `raster`'s rows (same width and height,
    /// samples per pixel and sample size), decoding blocks in parallel.
    public func read(into raster: GeoRaster) throws {
        guard raster.grid.width == width, raster.grid.height == height, raster.channels == samplesPerPixel,
              raster.type.size == bytesPerSample else { throw Failure.unsupported("raster shape") }
        let dst = raster.storage.bytes, rowBytes = width * bytesPerPixel
        var failure: Error?
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: blockCount) { index in
            do {
                let b = try block(index)
                let bx = (index % blocksAcross) * blockWidth, by = (index / blocksAcross) * blockHeight
                let w = min(blockWidth, width - bx), rows = min(blockHeight, height - by)
                b.withUnsafeBytes { src in
                    for r in 0 ..< rows {
                        (dst + (by + r) * rowBytes + bx * bytesPerPixel)
                            .copyMemory(from: src.baseAddress! + r * blockWidth * bytesPerPixel, byteCount: w * bytesPerPixel)
                    }
                }
            } catch {
                lock.lock(); failure = failure ?? error; lock.unlock()
            }
        }
        if let failure { throw failure }
    }

    struct Reader {
        let data: Data
        let big: Bool
        func u16(_ o: Int) -> UInt16 {
            let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt16.self) }
            return big ? UInt16(bigEndian: v) : UInt16(littleEndian: v)
        }
        func u32(_ o: Int) -> UInt32 {
            let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) }
            return big ? UInt32(bigEndian: v) : UInt32(littleEndian: v)
        }
        func u64(_ o: Int) -> UInt64 {
            let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt64.self) }
            return big ? UInt64(bigEndian: v) : UInt64(littleEndian: v)
        }
    }
}

/// TIFF's LZW (TIFF 6.0 §13): codes most significant bit first, 9 to 12
/// bits wide, the width growing one code early; 256 clears, 257 ends.
public enum TIFFLZW {
    public static func decode(_ input: Data, expected: Int) throws -> Data {
        var out = [UInt8]()
        out.reserveCapacity(expected)
        // The table as (prefix code, last byte, first byte, length).
        var prefix = [Int32](repeating: -1, count: 4096)
        var suffix = [UInt8](repeating: 0, count: 4096)
        var first = [UInt8](repeating: 0, count: 4096)
        var length = [Int32](repeating: 0, count: 4096)
        for i in 0 ..< 256 { suffix[i] = UInt8(i); first[i] = UInt8(i); length[i] = 1 }
        var next = 258, width = 9, old = -1
        var bitBuffer: UInt32 = 0, bits = 0
        var scratch = [UInt8](repeating: 0, count: 4096)
        func emit(_ code: Int) {
            let n = Int(length[code])
            var c = code
            for k in stride(from: n - 1, through: 0, by: -1) { scratch[k] = suffix[c]; c = Int(prefix[c]) }
            out.append(contentsOf: scratch[0 ..< n])
        }
        for byte in input {
            bitBuffer = bitBuffer << 8 | UInt32(byte)
            bits += 8
            while bits >= width {
                let code = Int(bitBuffer >> UInt32(bits - width)) & ((1 << width) - 1)
                bits -= width
                if code == 257 { return Data(out) }
                if code == 256 {
                    next = 258; width = 9; old = -1
                    continue
                }
                if old < 0 {
                    guard code < 256 else { throw TIFFImage.Failure.corrupt("LZW first code") }
                    emit(code); old = code
                    continue
                }
                guard next < 4096 else { throw TIFFImage.Failure.corrupt("LZW table full") }
                if code < next {
                    emit(code)
                    prefix[next] = Int32(old); suffix[next] = first[code]
                } else if code == next {
                    prefix[next] = Int32(old); suffix[next] = first[old]
                    first[next] = first[old]; length[next] = length[old] + 1
                    emit(next)
                } else {
                    throw TIFFImage.Failure.corrupt("LZW code \(code)")
                }
                if code < next { first[next] = first[old]; length[next] = length[old] + 1 }
                next += 1
                old = code
                // "Early change": the width grows one code before it must.
                if next + 1 >= 1 << width && width < 12 { width += 1 }
                if out.count >= expected { return Data(out) }
            }
        }
        return Data(out)
    }
}
