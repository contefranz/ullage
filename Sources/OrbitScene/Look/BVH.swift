import Foundation
import OrbitCore

/// A bounding volume hierarchy over triangles, for the AO baker's rays
/// (`AmbientOcclusion`, track R5): binned surface-area-heuristic splits,
/// leaves of a few triangles, and two queries, any hit within a distance
/// (`occluded`) and the nearest hit (`intersect`). Both faces of every
/// triangle are hit. Pure Swift on Doubles, no simd, so it builds and tests
/// on Linux.
public struct TriangleBVH {
    /// Per node: min x, y, z, then max x, y, z (m).
    private var bounds: [Double] = []
    /// Per node: for a leaf, its first triangle (tree order) and its count;
    /// for an inner node, its left child and 0 (the right child follows the
    /// left).
    private var links: [Int32] = []
    /// Per triangle in tree order: v0, then edges v1 - v0 and v2 - v0.
    private var triangles: [Double] = []
    /// For each triangle in tree order, its index in the input.
    public private(set) var order: [Int32] = []

    public var triangleCount: Int { order.count }
    public var nodeCount: Int { links.count / 2 }

    static let leafSize = 4
    static let binCount = 16
    /// The deepest node the build makes (it makes a leaf there), so a
    /// traversal stack of `stackSize` entries cannot overflow.
    static let maxDepth = 60
    static let stackSize = 64

    /// The triangles `indices` (three per triangle) over `positions` (m).
    public init(positions: [Vec3], indices: [UInt32]) {
        let n = indices.count / 3
        guard n > 0 else { return }
        var lo = [Double](repeating: 0, count: 3 * n), hi = lo, centre = lo
        for t in 0..<n {
            let a = positions[Int(indices[3 * t])], b = positions[Int(indices[3 * t + 1])]
            let c = positions[Int(indices[3 * t + 2])]
            lo[3 * t] = min(a.x, b.x, c.x); hi[3 * t] = max(a.x, b.x, c.x)
            lo[3 * t + 1] = min(a.y, b.y, c.y); hi[3 * t + 1] = max(a.y, b.y, c.y)
            lo[3 * t + 2] = min(a.z, b.z, c.z); hi[3 * t + 2] = max(a.z, b.z, c.z)
            for k in 0..<3 { centre[3 * t + k] = 0.5 * (lo[3 * t + k] + hi[3 * t + k]) }
        }
        var items = (0..<n).map { Int32($0) }
        var builder = Builder(lo: lo, hi: hi, centre: centre)
        builder.build(&items)
        bounds = builder.bounds
        links = builder.links
        order = items
        triangles.reserveCapacity(9 * n)
        for t in items {
            let i = Int(t)
            let a = positions[Int(indices[3 * i])], b = positions[Int(indices[3 * i + 1])]
            let c = positions[Int(indices[3 * i + 2])]
            let e1 = b - a, e2 = c - a
            triangles += [a.x, a.y, a.z, e1.x, e1.y, e1.z, e2.x, e2.y, e2.z]
        }
    }

    /// Whether the ray from `origin` along `direction` hits a triangle at a
    /// distance in (0, `maxDistance`] (m, in units of `direction`'s length).
    public func occluded(origin: Vec3, direction: Vec3, maxDistance: Double) -> Bool {
        withTraversal { $0.occluded(origin, direction, maxDistance) }
    }

    /// The nearest hit in (0, `maxDistance`]: its distance and the input
    /// index of the triangle hit.
    public func intersect(origin: Vec3, direction: Vec3,
                          maxDistance: Double = .infinity) -> (distance: Double, triangle: Int)? {
        withTraversal { traversal in
            traversal.nearest(origin, direction, maxDistance).map { ($0.distance, Int(order[$0.triangle])) }
        }
    }

    /// Runs `body` with a traversal over this tree, for casting many rays
    /// without re-entering the arrays for each.
    func withTraversal<R>(_ body: (Traversal) -> R) -> R {
        bounds.withUnsafeBufferPointer { b in
            links.withUnsafeBufferPointer { l in
                triangles.withUnsafeBufferPointer { t in
                    withUnsafeTemporaryAllocation(of: Int32.self, capacity: Self.stackSize) { stack in
                        guard let bb = b.baseAddress, let lb = l.baseAddress, let tb = t.baseAddress,
                              let sb = stack.baseAddress else {
                            return body(Traversal.empty)
                        }
                        return body(Traversal(bounds: bb, links: lb, triangles: tb, stack: sb))
                    }
                }
            }
        }
    }

    /// A tree's arrays as pointers, valid inside `withTraversal`.
    struct Traversal {
        let bounds: UnsafePointer<Double>?
        let links: UnsafePointer<Int32>?
        let triangles: UnsafePointer<Double>?
        let stack: UnsafeMutablePointer<Int32>?

        static let empty = Traversal(bounds: nil, links: nil, triangles: nil, stack: nil)

        /// 1/d, with zero components made tiny so that the slab test never
        /// multiplies zero by infinity.
        @inline(__always)
        static func inverse(_ d: Vec3) -> Vec3 {
            let tiny = 1e-300
            let x = d.x == 0 ? tiny : d.x, y = d.y == 0 ? tiny : d.y, z = d.z == 0 ? tiny : d.z
            return Vec3(1 / x, 1 / y, 1 / z)
        }

        /// Whether the ray enters node `node`'s box within (0, `tMax`].
        @inline(__always)
        func enters(_ node: Int, _ o: Vec3, _ inv: Vec3, _ tMax: Double) -> Bool {
            let b = bounds.unsafelyUnwrapped + 6 * node
            let x0 = (b[0] - o.x) * inv.x, x1 = (b[3] - o.x) * inv.x
            let y0 = (b[1] - o.y) * inv.y, y1 = (b[4] - o.y) * inv.y
            let z0 = (b[2] - o.z) * inv.z, z1 = (b[5] - o.z) * inv.z
            let near = max(max(min(x0, x1), min(y0, y1)), max(min(z0, z1), 0))
            let far = min(min(max(x0, x1), max(y0, y1)), min(max(z0, z1), tMax))
            return near <= far
        }

        /// The distance at which the ray hits triangle `t` (tree order), if
        /// it does in (0, `tMax`]: Möller and Trumbore, both faces.
        @inline(__always)
        func hit(_ t: Int, _ o: Vec3, _ d: Vec3, _ tMax: Double) -> Double? {
            let p = triangles.unsafelyUnwrapped + 9 * t
            let e1 = Vec3(p[3], p[4], p[5]), e2 = Vec3(p[6], p[7], p[8])
            let q = d.cross(e2)
            let det = e1.dot(q)
            guard det != 0 else { return nil }
            let invDet = 1 / det
            let s = Vec3(o.x - p[0], o.y - p[1], o.z - p[2])
            let u = s.dot(q) * invDet
            guard u >= 0, u <= 1 else { return nil }
            let r = s.cross(e1)
            let v = d.dot(r) * invDet
            guard v >= 0, u + v <= 1 else { return nil }
            let distance = e2.dot(r) * invDet
            return distance > 0 && distance <= tMax ? distance : nil
        }

        func occluded(_ o: Vec3, _ d: Vec3, _ tMax: Double) -> Bool {
            guard let links, let stack else { return false }
            let inv = Self.inverse(d)
            var top = 0
            stack[0] = 0
            top = 1
            while top > 0 {
                top -= 1
                let node = Int(stack[top])
                guard enters(node, o, inv, tMax) else { continue }
                let first = Int(links[2 * node]), count = Int(links[2 * node + 1])
                if count > 0 {
                    for t in first..<(first + count) where hit(t, o, d, tMax) != nil { return true }
                } else {
                    stack[top] = Int32(first + 1)
                    stack[top + 1] = Int32(first)
                    top += 2
                }
            }
            return false
        }

        func nearest(_ o: Vec3, _ d: Vec3, _ tMax: Double) -> (distance: Double, triangle: Int)? {
            guard let links, let stack else { return nil }
            let inv = Self.inverse(d)
            var best: (distance: Double, triangle: Int)?
            var limit = tMax
            stack[0] = 0
            var top = 1
            while top > 0 {
                top -= 1
                let node = Int(stack[top])
                guard enters(node, o, inv, limit) else { continue }
                let first = Int(links[2 * node]), count = Int(links[2 * node + 1])
                if count > 0 {
                    for t in first..<(first + count) {
                        if let distance = hit(t, o, d, limit) {
                            best = (distance, t)
                            limit = distance
                        }
                    }
                } else {
                    stack[top] = Int32(first + 1)
                    stack[top + 1] = Int32(first)
                    top += 2
                }
            }
            return best
        }
    }

    /// The top-down build: each node's triangles are split where the binned
    /// surface-area heuristic is lowest, until splitting costs more than a
    /// leaf of at most `leafSize` (or a leaf is forced at `maxDepth`).
    private struct Builder {
        let lo: [Double], hi: [Double], centre: [Double]
        var bounds: [Double] = []
        var links: [Int32] = []

        init(lo: [Double], hi: [Double], centre: [Double]) {
            self.lo = lo
            self.hi = hi
            self.centre = centre
        }

        /// A box as min x, y, z, max x, y, z.
        struct Box {
            var lo = (Double.infinity, Double.infinity, Double.infinity)
            var hi = (-Double.infinity, -Double.infinity, -Double.infinity)

            mutating func add(_ l: (Double, Double, Double), _ h: (Double, Double, Double)) {
                lo = (min(lo.0, l.0), min(lo.1, l.1), min(lo.2, l.2))
                hi = (max(hi.0, h.0), max(hi.1, h.1), max(hi.2, h.2))
            }

            mutating func add(_ b: Box) { add(b.lo, b.hi) }

            /// Half the surface area (the heuristic only compares areas).
            var halfArea: Double {
                guard hi.0 >= lo.0 else { return 0 }
                let x = hi.0 - lo.0, y = hi.1 - lo.1, z = hi.2 - lo.2
                return x * y + y * z + z * x
            }
        }

        func box(of t: Int) -> ((Double, Double, Double), (Double, Double, Double)) {
            ((lo[3 * t], lo[3 * t + 1], lo[3 * t + 2]), (hi[3 * t], hi[3 * t + 1], hi[3 * t + 2]))
        }

        mutating func build(_ items: inout [Int32]) {
            // Work list: node, first item, count, depth.
            var work: [(Int, Int, Int, Int)] = [(0, 0, items.count, 0)]
            bounds = [Double](repeating: 0, count: 6)
            links = [0, 0]
            while let item = work.popLast() {
                let (node, first, count, depth) = item
                var box = Box(), centres = Box()
                for i in first..<(first + count) {
                    let t = Int(items[i])
                    let b = self.box(of: t)
                    box.add(b.0, b.1)
                    let c = (centre[3 * t], centre[3 * t + 1], centre[3 * t + 2])
                    centres.add(c, c)
                }
                bounds[6 * node] = box.lo.0
                bounds[6 * node + 1] = box.lo.1
                bounds[6 * node + 2] = box.lo.2
                bounds[6 * node + 3] = box.hi.0
                bounds[6 * node + 4] = box.hi.1
                bounds[6 * node + 5] = box.hi.2
                let split = count > TriangleBVH.leafSize && depth < TriangleBVH.maxDepth
                    ? bestSplit(items, first, count, box, centres) : nil
                guard let split else {
                    links[2 * node] = Int32(first)
                    links[2 * node + 1] = Int32(count)
                    continue
                }
                let mid = partition(&items, first, count, split)
                let left = links.count / 2
                links[2 * node] = Int32(left)
                links[2 * node + 1] = 0
                links += [0, 0, 0, 0]
                bounds += [Double](repeating: 0, count: 12)
                work.append((left + 1, mid, first + count - mid, depth + 1))
                work.append((left, first, mid - first, depth + 1))
            }
        }

        /// A split: an axis and the bin boundary, or (for centres that
        /// coincide) an even split by position in the list.
        enum Split {
            case bin(axis: Int, lo: Double, scale: Double, below: Int)
            case half
        }

        func bin(_ t: Int, axis: Int, lo: Double, scale: Double) -> Int {
            let b = Int((centre[3 * t + axis] - lo) * scale)
            return min(max(b, 0), TriangleBVH.binCount - 1)
        }

        func bestSplit(_ items: [Int32], _ first: Int, _ count: Int, _ box: Box, _ centres: Box) -> Split? {
            let n = TriangleBVH.binCount
            let cl = [centres.lo.0, centres.lo.1, centres.lo.2], ch = [centres.hi.0, centres.hi.1, centres.hi.2]
            var best: (cost: Double, split: Split)?
            for axis in 0..<3 {
                let extent = ch[axis] - cl[axis]
                guard extent > 1e-12 else { continue }
                let scale = Double(n) / extent
                var boxes = [Box](repeating: Box(), count: n), counts = [Int](repeating: 0, count: n)
                for i in first..<(first + count) {
                    let t = Int(items[i])
                    let k = bin(t, axis: axis, lo: cl[axis], scale: scale)
                    let b = self.box(of: t)
                    boxes[k].add(b.0, b.1)
                    counts[k] += 1
                }
                // Area times count of everything right of each boundary.
                var rightCost = [Double](repeating: 0, count: n)
                var acc = Box(), accCount = 0
                for k in stride(from: n - 1, to: 0, by: -1) {
                    acc.add(boxes[k])
                    accCount += counts[k]
                    rightCost[k] = acc.halfArea * Double(accCount)
                }
                acc = Box()
                accCount = 0
                for k in 1..<n {
                    acc.add(boxes[k - 1])
                    accCount += counts[k - 1]
                    guard accCount > 0, accCount < count else { continue }
                    let cost = acc.halfArea * Double(accCount) + rightCost[k]
                    if best == nil || cost < best!.cost {
                        best = (cost, .bin(axis: axis, lo: cl[axis], scale: scale, below: k))
                    }
                }
            }
            guard let best else {
                // Every centre in one point: split the list in two, or make
                // a leaf if it is small enough.
                return count > 2 * TriangleBVH.leafSize ? .half : nil
            }
            // A node costs one box test plus its children's triangles in
            // proportion to their areas; a leaf, its triangles.
            let leafCost = box.halfArea * Double(count)
            if count <= 2 * TriangleBVH.leafSize, best.cost >= leafCost { return nil }
            return best.split
        }

        /// Puts the items below the split first; returns where the rest begin.
        func partition(_ items: inout [Int32], _ first: Int, _ count: Int, _ split: Split) -> Int {
            guard case let .bin(axis, lo, scale, below) = split else { return first + count / 2 }
            var i = first, j = first + count - 1
            while i <= j {
                if bin(Int(items[i]), axis: axis, lo: lo, scale: scale) < below {
                    i += 1
                } else {
                    items.swapAt(i, j)
                    j -= 1
                }
            }
            return i
        }
    }
}
