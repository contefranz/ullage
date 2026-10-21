import Foundation

/// An 8-bit sRGB image, rows from the top, three bytes (R, G, B) a pixel.
struct RGBImage: Equatable {
    let width: Int
    let height: Int
    var bytes: [UInt8]

    init(width: Int, height: Int, fill: (UInt8, UInt8, UInt8) = (0, 0, 0)) {
        precondition(width > 0 && height > 0, "an image has pixels")
        self.width = width
        self.height = height
        bytes = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            bytes[3 * i] = fill.0
            bytes[3 * i + 1] = fill.1
            bytes[3 * i + 2] = fill.2
        }
    }

    init(width: Int, height: Int, bytes: [UInt8]) {
        precondition(bytes.count == width * height * 3, "three bytes a pixel")
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    subscript(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
        get {
            let i = 3 * (y * width + x)
            return (bytes[i], bytes[i + 1], bytes[i + 2])
        }
        set {
            let i = 3 * (y * width + x)
            bytes[i] = newValue.0
            bytes[i + 1] = newValue.1
            bytes[i + 2] = newValue.2
        }
    }

    /// Copies `image` in with its top-left pixel at (`x`, `y`); it must fit.
    mutating func paste(_ image: RGBImage, at x: Int, _ y: Int) {
        precondition(x >= 0 && y >= 0 && x + image.width <= width && y + image.height <= height,
                     "a pasted image fits")
        for row in 0..<image.height {
            let from = 3 * row * image.width, to = 3 * ((y + row) * width + x)
            bytes.replaceSubrange(to..<(to + 3 * image.width), with: image.bytes[from..<(from + 3 * image.width)])
        }
    }
}

/// A PNG encoder and decoder needing no compression library, so that they
/// run on Linux: the image data go into the zlib stream as stored
/// (uncompressed) deflate blocks, each scanline unfiltered (filter type 0).
/// The files are about as large as the raw pixels.
///
/// The decoder reads what the encoder writes, and any PNG of 8-bit RGB or
/// RGBA without interlacing whose deflate blocks are stored, whatever its
/// scanlines' filters; it checks every chunk's CRC and the stream's Adler-32.
enum PNG {
    enum DecodeError: Error, Equatable {
        case notPNG
        case truncated
        case badCRC(String)
        case missing(String)
        case unsupported(String)
        case badZlib(String)
        case badAdler
    }

    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    /// The most a stored deflate block holds.
    static let storedBlockLimit = 65_535

    static func encode(_ image: RGBImage) -> [UInt8] {
        var ihdr: [UInt8] = []
        append32(image.width, to: &ihdr)
        append32(image.height, to: &ihdr)
        ihdr += [8, 2, 0, 0, 0]   // bit depth 8, RGB, deflate, adaptive filters, no interlace

        let stride = 3 * image.width
        var raw: [UInt8] = []
        raw.reserveCapacity((stride + 1) * image.height)
        for y in 0..<image.height {
            raw.append(0)         // filter type 0: none
            raw += image.bytes[(y * stride)..<((y + 1) * stride)]
        }

        var png = signature
        appendChunk("IHDR", ihdr, to: &png)
        appendChunk("IDAT", zlibStored(raw), to: &png)
        appendChunk("IEND", [], to: &png)
        return png
    }

    static func write(_ image: RGBImage, to url: URL) throws {
        try Data(encode(image)).write(to: url)
    }

    static func read(_ url: URL) throws -> RGBImage {
        try decode([UInt8](Data(contentsOf: url)))
    }

    /// `data` as a zlib stream of stored deflate blocks: the header for the
    /// fastest level (0x78 0x01, as zlib's level 0 writes it), the blocks,
    /// the Adler-32.
    static func zlibStored(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]
        out.reserveCapacity(data.count + data.count / storedBlockLimit * 5 + 11)
        var start = 0
        repeat {
            let count = min(storedBlockLimit, data.count - start)
            let final = start + count == data.count
            out.append(final ? 1 : 0)     // BFINAL, BTYPE 00 (stored)
            out += [UInt8(count & 0xFF), UInt8(count >> 8)]
            out += [UInt8(~count & 0xFF), UInt8((~count >> 8) & 0xFF)]
            out += data[start..<(start + count)]
            start += count
        } while start < data.count
        append32(Int(adler32(data)), to: &out)
        return out
    }

    static func decode(_ png: [UInt8]) throws -> RGBImage {
        guard png.count >= 8, Array(png[0..<8]) == signature else { throw DecodeError.notPNG }
        var at = 8
        var header: [UInt8]?
        var stream: [UInt8] = []
        var ended = false
        while !ended {
            guard at + 12 <= png.count else { throw DecodeError.truncated }
            let length = read32(png, at)
            let type = String(decoding: png[(at + 4)..<(at + 8)], as: UTF8.self)
            guard at + 12 + length <= png.count else { throw DecodeError.truncated }
            let body = Array(png[(at + 8)..<(at + 8 + length)])
            guard UInt32(read32(png, at + 8 + length)) == crc32(Array(png[(at + 4)..<(at + 8)]) + body) else {
                throw DecodeError.badCRC(type)
            }
            switch type {
            case "IHDR": header = body
            case "IDAT": stream += body
            case "IEND": ended = true
            default: break
            }
            at += 12 + length
        }
        guard let ihdr = header, ihdr.count == 13 else { throw DecodeError.missing("IHDR") }
        let width = read32(ihdr, 0), height = read32(ihdr, 4)
        guard width > 0, height > 0 else { throw DecodeError.unsupported("an empty image") }
        guard ihdr[8] == 8, ihdr[9] == 2 || ihdr[9] == 6, ihdr[10] == 0, ihdr[11] == 0, ihdr[12] == 0 else {
            throw DecodeError.unsupported("bit depth \(ihdr[8]), colour type \(ihdr[9]), interlace \(ihdr[12])")
        }
        let channels = ihdr[9] == 6 ? 4 : 3
        let raw = try inflateStored(stream)
        let stride = channels * width
        guard raw.count == (stride + 1) * height else { throw DecodeError.truncated }

        var pixels = [UInt8](repeating: 0, count: stride * height)
        for y in 0..<height {
            let filter = raw[y * (stride + 1)]
            for i in 0..<stride {
                let byte = raw[y * (stride + 1) + 1 + i]
                let a = i >= channels ? Int(pixels[y * stride + i - channels]) : 0
                let b = y > 0 ? Int(pixels[(y - 1) * stride + i]) : 0
                let c = i >= channels && y > 0 ? Int(pixels[(y - 1) * stride + i - channels]) : 0
                let predicted: Int
                switch filter {
                case 0: predicted = 0
                case 1: predicted = a
                case 2: predicted = b
                case 3: predicted = (a + b) / 2
                case 4: predicted = paeth(a, b, c)
                default: throw DecodeError.unsupported("filter type \(filter)")
                }
                pixels[y * stride + i] = UInt8((Int(byte) + predicted) & 0xFF)
            }
        }
        if channels == 3 { return RGBImage(width: width, height: height, bytes: pixels) }
        var rgb = [UInt8](repeating: 0, count: 3 * width * height)
        for i in 0..<(width * height) {
            rgb[3 * i] = pixels[4 * i]
            rgb[3 * i + 1] = pixels[4 * i + 1]
            rgb[3 * i + 2] = pixels[4 * i + 2]
        }
        return RGBImage(width: width, height: height, bytes: rgb)
    }

    /// The data of a zlib stream of stored deflate blocks.
    static func inflateStored(_ stream: [UInt8]) throws -> [UInt8] {
        guard stream.count >= 6 else { throw DecodeError.badZlib("too short") }
        let cmf = Int(stream[0]), flg = Int(stream[1])
        guard cmf & 0x0F == 8, (cmf << 8 | flg) % 31 == 0, flg & 0x20 == 0 else {
            throw DecodeError.badZlib("header \(cmf) \(flg)")
        }
        var out: [UInt8] = []
        var at = 2
        var final = false
        while !final {
            guard at < stream.count else { throw DecodeError.truncated }
            let head = stream[at]
            final = head & 1 == 1
            guard (head >> 1) & 3 == 0 else { throw DecodeError.unsupported("a compressed deflate block") }
            guard at + 5 <= stream.count else { throw DecodeError.truncated }
            let count = Int(stream[at + 1]) | Int(stream[at + 2]) << 8
            let check = Int(stream[at + 3]) | Int(stream[at + 4]) << 8
            guard count ^ check == 0xFFFF else { throw DecodeError.badZlib("LEN and NLEN disagree") }
            guard at + 5 + count <= stream.count else { throw DecodeError.truncated }
            out += stream[(at + 5)..<(at + 5 + count)]
            at += 5 + count
        }
        guard at + 4 <= stream.count else { throw DecodeError.truncated }
        guard UInt32(read32(stream, at)) == adler32(out) else { throw DecodeError.badAdler }
        return out
    }

    // MARK: Checksums

    /// CRC-32 (ISO 3309, the PNG and zlib polynomial 0xEDB88320, reflected).
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// Adler-32 (RFC 1950).
    static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        // 5552 bytes keep the sums inside 32 bits between reductions.
        var start = 0
        while start < bytes.count {
            let end = min(start + 5552, bytes.count)
            for i in start..<end {
                a += UInt32(bytes[i])
                b += a
            }
            a %= 65_521
            b %= 65_521
            start = end
        }
        return b << 16 | a
    }

    // MARK: Bytes

    static func append32(_ value: Int, to bytes: inout [UInt8]) {
        bytes += [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF),
                  UInt8(value & 0xFF)]
    }

    static func read32(_ bytes: [UInt8], _ at: Int) -> Int {
        Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
    }

    static func appendChunk(_ type: String, _ body: [UInt8], to png: inout [UInt8]) {
        let typeBytes = Array(type.utf8)
        append32(body.count, to: &png)
        png += typeBytes
        png += body
        append32(Int(crc32(typeBytes + body)), to: &png)
    }

    static func paeth(_ a: Int, _ b: Int, _ c: Int) -> Int {
        let p = a + b - c, pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
        if pa <= pb && pa <= pc { return a }
        return pb <= pc ? b : c
    }
}
