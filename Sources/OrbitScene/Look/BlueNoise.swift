import Foundation

/// A tileable blue-noise threshold map, built with Ulichney's void-and-cluster
/// method (1993, "The void-and-cluster method for dither array generation",
/// Proc. SPIE 1913): every value 0..<n² once, as (rank + 0.5) / n², with
/// little energy at low frequencies, so the post shader's dither leaves no
/// pattern the eye picks up. Track R1; seeded, so every run builds the same
/// map.
public struct BlueNoise {
    public let size: Int
    /// Row by row, in (0, 1).
    public let values: [Float]

    /// The renderer's map, 64², built once per process.
    public static let shared = BlueNoise(size: 64)

    /// `n` must be a multiple of 8.
    public init(size n: Int, sigma: Double = 1.5, seed: UInt64 = 0x5EED_B1E5) {
        precondition(n % 8 == 0 && n >= 16)
        size = n
        var field = Field(n: n, sigma: sigma)

        // A random initial pattern of about a tenth of the cells.
        var state = seed
        func random() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        let count = n * n, initial = max(1, count / 10)
        var placed = 0
        while placed < initial {
            let i = Int(random() % UInt64(count))
            if !field.on[i] {
                field.toggle(i)
                placed += 1
            }
        }
        field.refreshAll()
        // Even it out: move the tightest cluster's point to the largest void
        // until that would put it back.
        for _ in 0..<(count * 4) {
            let c = field.tightestCluster()
            field.toggle(c)
            let v = field.largestVoid()
            field.toggle(v)
            if v == c { break }
        }
        var rank = [Int](repeating: 0, count: count)
        let prototype = field
        // Rank the initial points, the tightest cluster last; then fill the
        // largest voids in turn (on the torus the zeros' tightest cluster,
        // Ulichney's third phase, is the ones' largest void).
        for r in stride(from: initial - 1, through: 0, by: -1) {
            let c = field.tightestCluster()
            field.toggle(c)
            rank[c] = r
        }
        field = prototype
        for r in initial..<count {
            let v = field.largestVoid()
            field.toggle(v)
            rank[v] = r
        }
        values = rank.map { Float((Double($0) + 0.5) / Double(count)) }
    }

    public subscript(x: Int, y: Int) -> Float { values[((y % size + size) % size) * size + (x % size + size) % size] }

    /// The binary pattern, its Gaussian energy on the torus, and per 8×8
    /// block the tightest cluster and the largest void, so a toggle
    /// refreshes only the blocks its kernel reaches.
    private struct Field {
        let n: Int
        let reach: Int
        let kernel: [Double]       // (2 reach + 1)², row by row
        var on: [Bool]
        var energy: [Double]
        let blocks: Int            // per side
        var cluster: [Int]         // per block: its "on" cell of most energy, -1 for none
        var void: [Int]            // per block: its "off" cell of least energy, -1 for none

        init(n: Int, sigma: Double) {
            self.n = n
            reach = min(n / 2 - 1, Int((sigma * 4).rounded(.up)))
            var k: [Double] = []
            for dy in -reach...reach {
                for dx in -reach...reach { k.append(exp(-Double(dx * dx + dy * dy) / (2 * sigma * sigma))) }
            }
            kernel = k
            on = [Bool](repeating: false, count: n * n)
            energy = [Double](repeating: 0, count: n * n)
            blocks = n / 8
            cluster = [Int](repeating: -1, count: blocks * blocks)
            void = [Int](repeating: -1, count: blocks * blocks)
        }

        mutating func toggle(_ i: Int) {
            on[i].toggle()
            let sign: Double = on[i] ? 1 : -1, x = i % n, y = i / n, w = 2 * reach + 1
            for dy in -reach...reach {
                let row = ((y + dy + n) % n) * n
                for dx in -reach...reach {
                    energy[row + (x + dx + n) % n] += sign * kernel[(dy + reach) * w + dx + reach]
                }
            }
            // The blocks the kernel reached.
            let lo = (-reach - 7) / 8 - 1, hi = (reach + 7) / 8 + 1
            var seen = Set<Int>()
            for by in lo...hi {
                for bx in lo...hi {
                    let cx = ((x / 8 + bx) % blocks + blocks) % blocks, cy = ((y / 8 + by) % blocks + blocks) % blocks
                    let b = cy * blocks + cx
                    if seen.insert(b).inserted, touches(block: b, x: x, y: y) { refresh(b) }
                }
            }
        }

        /// Whether block `b` holds a cell within `reach` of (x, y) on the torus.
        func touches(block b: Int, x: Int, y: Int) -> Bool {
            func near(_ c: Int, _ lo: Int) -> Bool {
                for o in 0..<8 {
                    let d = abs(c - (lo + o)) % n
                    if min(d, n - d) <= reach { return true }
                }
                return false
            }
            return near(x, (b % blocks) * 8) && near(y, (b / blocks) * 8)
        }

        mutating func refresh(_ b: Int) {
            let x0 = (b % blocks) * 8, y0 = (b / blocks) * 8
            var c = -1, v = -1, ce = -Double.infinity, ve = Double.infinity
            for y in y0..<(y0 + 8) {
                for x in x0..<(x0 + 8) {
                    let i = y * n + x, e = energy[i]
                    if on[i] {
                        if e > ce { (c, ce) = (i, e) }
                    } else if e < ve {
                        (v, ve) = (i, e)
                    }
                }
            }
            cluster[b] = c
            void[b] = v
        }

        mutating func refreshAll() {
            for b in 0..<(blocks * blocks) { refresh(b) }
        }

        func tightestCluster() -> Int {
            var best = -1, e = -Double.infinity
            for c in cluster where c >= 0 && energy[c] > e { (best, e) = (c, energy[c]) }
            return best
        }

        func largestVoid() -> Int {
            var best = -1, e = Double.infinity
            for v in void where v >= 0 && energy[v] < e { (best, e) = (v, energy[v]) }
            return best
        }
    }
}
