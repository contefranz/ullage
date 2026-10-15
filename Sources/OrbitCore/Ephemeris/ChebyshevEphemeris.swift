import Foundation

public enum EphemerisError: Error, CustomStringConvertible {
    case resourceMissing(String)
    case badFormat(String)
    case segmentMissing(target: Int, center: Int)
    case outOfRange(Epoch)

    public var description: String {
        switch self {
        case .resourceMissing(let n): return "ephemeris resource \(n) not found"
        case .badFormat(let m): return "bad ephemeris file: \(m)"
        case .segmentMissing(let t, let c): return "no ephemeris segment for \(t) w.r.t. \(c)"
        case .outOfRange(let e): return "epoch \(e) outside ephemeris span"
        }
    }
}

/// One body's (or frame's) Chebyshev series: fixed-length records spanning
/// `[start, start + recordCount * interval)` TDB seconds past J2000.
public struct ChebyshevSegment {
    public let target: Int
    public let center: Int
    public let coefficientCount: Int
    public let recordCount: Int
    public let start: Double
    public let interval: Double
    /// recordCount * 3 * coefficientCount, record-major then component.
    let coefficients: [Double]

    public var end: Double { start + Double(recordCount) * interval }

    /// Value (x, y, z) and its time derivative per second at `t` (TDB s past J2000).
    public func evaluate(_ t: Double) -> (value: Vec3, rate: Vec3) {
        var index = Int(floor((t - start) / interval))
        index = min(max(index, 0), recordCount - 1)
        let recordStart = start + Double(index) * interval
        let tau = 2 * (t - recordStart) / interval - 1
        let base = index * 3 * coefficientCount
        let n = coefficientCount

        // Chebyshev polynomials T_k(tau) and derivatives T'_k(tau).
        var value = [0.0, 0.0, 0.0]
        var rate = [0.0, 0.0, 0.0]
        coefficients.withUnsafeBufferPointer { c in
            var t0 = 1.0, t1 = tau
            var d0 = 0.0, d1 = 1.0
            for comp in 0..<3 {
                value[comp] = c[base + comp * n]
                if n > 1 { value[comp] += c[base + comp * n + 1] * tau; rate[comp] = c[base + comp * n + 1] }
            }
            var k = 2
            while k < n {
                let t2 = 2 * tau * t1 - t0
                let d2 = 2 * t1 + 2 * tau * d1 - d0
                for comp in 0..<3 {
                    let ck = c[base + comp * n + k]
                    value[comp] += ck * t2
                    rate[comp] += ck * d2
                }
                t0 = t1; t1 = t2
                d0 = d1; d1 = d2
                k += 1
            }
        }
        let scale = 2 / interval
        return (Vec3(value[0], value[1], value[2]),
                Vec3(rate[0] * scale, rate[1] * scale, rate[2] * scale))
    }
}

/// Reader for the compact ephemeris produced by `tools/make_ephemeris.py`
/// from JPL DE421 (positions in km, ICRF) plus the DE421 lunar orientation.
public final class ChebyshevEphemeris {
    public private(set) var segments: [Int: ChebyshevSegment] = [:]  // key = target*1000003 + center

    public static let lunarFrameID = 31006

    public init(data: Data) throws {
        guard data.count >= 16 else { throw EphemerisError.badFormat("truncated header") }
        let magic = String(decoding: data.prefix(8), as: UTF8.self)
        guard magic == "OSEPH001" else { throw EphemerisError.badFormat("magic \(magic)") }

        var offset = 8
        func readInt32() -> Int {
            let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int32.self) }
            offset += 4
            return Int(Int32(littleEndian: v))
        }
        func readDouble() -> Double {
            let bits = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
            offset += 8
            return Double(bitPattern: UInt64(littleEndian: bits))
        }

        let count = readInt32()
        _ = readInt32()
        for _ in 0..<count {
            let target = readInt32(), center = readInt32()
            let ncoef = readInt32(), nrec = readInt32()
            let start = readDouble(), interval = readDouble()
            let n = nrec * 3 * ncoef
            guard offset + n * 8 <= data.count else { throw EphemerisError.badFormat("truncated segment \(target)") }
            var coeffs = [Double](repeating: 0, count: n)
            data.withUnsafeBytes { raw in
                for i in 0..<n {
                    let bits = raw.loadUnaligned(fromByteOffset: offset + i * 8, as: UInt64.self)
                    coeffs[i] = Double(bitPattern: UInt64(littleEndian: bits))
                }
            }
            offset += n * 8
            segments[Self.key(target, center)] = ChebyshevSegment(
                target: target, center: center, coefficientCount: ncoef, recordCount: nrec,
                start: start, interval: interval, coefficients: coeffs)
        }
    }

    /// Load the copy bundled with OrbitCore.
    public static func bundled() throws -> ChebyshevEphemeris {
        guard let url = Bundle.module.url(forResource: "ephem", withExtension: "bin") else {
            throw EphemerisError.resourceMissing("ephem.bin")
        }
        return try ChebyshevEphemeris(data: Data(contentsOf: url))
    }

    static func key(_ target: Int, _ center: Int) -> Int { target * 1_000_003 + center }

    public func segment(target: Int, center: Int) -> ChebyshevSegment? {
        segments[Self.key(target, center)]
    }

    /// Time span (TDB seconds past J2000) covered by every segment.
    public var span: ClosedRange<Double> {
        let lo = segments.values.map(\.start).max() ?? 0
        let hi = segments.values.map(\.end).min() ?? 0
        return lo...hi
    }

    /// Position (m) and velocity (m/s) of `target` relative to `center` for the
    /// raw segments stored in the file.
    public func rawState(target: Int, center: Int, at t: Epoch) -> (position: Vec3, velocity: Vec3)? {
        guard let s = segment(target: target, center: center) else { return nil }
        let (p, v) = s.evaluate(t.tdb)
        return (p * 1000, v * 1000)
    }

    /// Barycentric (SSB) position and velocity, in metres and m/s, for a NAIF id
    /// in {10 Sun, 199/299/499 (via barycentres), 1...6 barycentres, 3 EMB, 399 Earth, 301 Moon}.
    public func barycentricState(naif id: Int, at t: Epoch) -> (position: Vec3, velocity: Vec3) {
        switch id {
        case 0:
            return (.zero, .zero)
        case 399, 301:
            let emb = rawState(target: 3, center: 0, at: t)!
            let rel = rawState(target: id, center: 3, at: t)!
            return (emb.position + rel.position, emb.velocity + rel.velocity)
        case 199, 299, 499:
            // Planet centres are within metres of their barycentres for these.
            return rawState(target: id / 100, center: 0, at: t)!
        default:
            guard let s = rawState(target: id, center: 0, at: t) else {
                preconditionFailure("ephemeris has no data for NAIF id \(id)")
            }
            return s
        }
    }

    /// Rotation matrix from ICRF to the Moon's principal-axis frame (MOON_PA_DE421),
    /// and the PA-frame angular velocity of the Moon (rad/s, in ICRF).
    public func lunarPrincipalAxes(at t: Epoch) -> (icrfToPA: Mat3, angularVelocity: Vec3) {
        guard let s = segment(target: Self.lunarFrameID, center: 1) else {
            preconditionFailure("ephemeris has no lunar orientation segment")
        }
        let (angles, rates) = s.evaluate(t.tdb)
        let phi = angles.x, theta = angles.y, psi = angles.z
        let m = Mat3.frameZ(psi) * Mat3.frameX(theta) * Mat3.frameZ(phi)
        // Angular velocity of a 3-1-3 Euler sequence, expressed in the inertial frame.
        let zAxis = Vec3.unitZ
        let nodeAxis = Mat3.rotZ(phi) * Vec3.unitX          // line of nodes after first rotation
        let poleAxis = m.transposed * Vec3.unitZ            // body z in inertial
        let omega = zAxis * rates.x + nodeAxis * rates.y + poleAxis * rates.z
        return (m, omega)
    }
}
