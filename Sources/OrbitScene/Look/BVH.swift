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
        var boxes: [Box] = [], centres: [Point] = []
        boxes.reserveCapacity(n)
        centres.reserveCapacity(n)
        for t in 0..<n {
            let a = positions[Int(indices[3 * t])], b = positions[Int(indices[3 * t + 1])]
            let c = positions[Int(indices[3 * t + 2])]
            let box = Box(lo0: Self.least(a.x, b.x, c.x), lo1: Self.least(a.y, b.y, c.y),
                          lo2: Self.least(a.z, b.z, c.z), hi0: Self.most(a.x, b.x, c.x),
                          hi1: Self.most(a.y, b.y, c.y), hi2: Self.most(a.z, b.z, c.z))
            boxes.append(box)
            centres.append(Point(x: 0.5 * (box.lo0 + box.hi0), y: 0.5 * (box.lo1 + box.hi1),
                                 z: 0.5 * (box.lo2 + box.hi2)))
        }
        var items = (0..<n).map { Int32($0) }
        let tree = boxes.withUnsafeBufferPointer { b in
            centres.withUnsafeBufferPointer { c in
                items.withUnsafeMutableBufferPointer { i in
                    Builder.build(boxes: b.baseAddress.unsafelyUnwrapped, centres: c.baseAddress.unsafelyUnwrapped,
                                  items: i.baseAddress.unsafelyUnwrapped, count: n)
                }
            }
        }
        bounds = tree.bounds
        links = tree.links
        order = items
        // In tree order: v0, then v1 - v0 and v2 - v0.
        triangles = [Double](repeating: 0, count: 9 * n)
        triangles.withUnsafeMutableBufferPointer { out in
            for (k, t) in items.enumerated() {
                let i = Int(t)
                let a = positions[Int(indices[3 * i])], b = positions[Int(indices[3 * i + 1])]
                let c = positions[Int(indices[3 * i + 2])]
                let e1 = b - a, e2 = c - a
                out[9 * k] = a.x; out[9 * k + 1] = a.y; out[9 * k + 2] = a.z
                out[9 * k + 3] = e1.x; out[9 * k + 4] = e1.y; out[9 * k + 5] = e1.z
                out[9 * k + 6] = e2.x; out[9 * k + 7] = e2.y; out[9 * k + 8] = e2.z
            }
        }
    }

    /// Swift's min(x, min(y, z)) and max(x, max(y, z)) on Doubles, which the
    /// unoptimised build would otherwise call generically.
    static func least(_ x: Double, _ y: Double, _ z: Double) -> Double {
        let yz = z < y ? z : y
        return yz < x ? yz : x
    }

    static func most(_ x: Double, _ y: Double, _ z: Double) -> Double {
        let yz = z >= y ? z : y
        return yz >= x ? yz : x
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
        // An empty array may still have a base address: no tree, no node 0.
        guard !links.isEmpty else { return body(Traversal.empty) }
        return bounds.withUnsafeBufferPointer { b in
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
            stack[0] = 0
            var top = 1
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

    /// A box: min x, y, z, then max x, y, z (m). Empty, its minimum is +∞
    /// and its maximum -∞.
    struct Box {
        var lo0 = Double.infinity, lo1 = Double.infinity, lo2 = Double.infinity
        var hi0 = -Double.infinity, hi1 = -Double.infinity, hi2 = -Double.infinity

        /// Grows over box `b`, as Swift's min and max would.
        mutating func add(_ b: Box) {
            lo0 = b.lo0 < lo0 ? b.lo0 : lo0
            lo1 = b.lo1 < lo1 ? b.lo1 : lo1
            lo2 = b.lo2 < lo2 ? b.lo2 : lo2
            hi0 = b.hi0 >= hi0 ? b.hi0 : hi0
            hi1 = b.hi1 >= hi1 ? b.hi1 : hi1
            hi2 = b.hi2 >= hi2 ? b.hi2 : hi2
        }

        /// Grows over point `p`.
        mutating func add(_ p: Point) {
            lo0 = p.x < lo0 ? p.x : lo0
            lo1 = p.y < lo1 ? p.y : lo1
            lo2 = p.z < lo2 ? p.z : lo2
            hi0 = p.x >= hi0 ? p.x : hi0
            hi1 = p.y >= hi1 ? p.y : hi1
            hi2 = p.z >= hi2 ? p.z : hi2
        }

        /// Half the surface area (the heuristic only compares areas).
        var halfArea: Double {
            guard hi0 >= lo0 else { return 0 }
            let x = hi0 - lo0, y = hi1 - lo1, z = hi2 - lo2
            return x * y + y * z + z * x
        }
    }

    /// A triangle's centre (m).
    struct Point {
        var x = 0.0, y = 0.0, z = 0.0
    }

    /// The top-down build: each node's triangles are split where the binned
    /// surface-area heuristic is lowest, until splitting costs more than a
    /// leaf of at most `leafSize` (or a leaf is forced at `maxDepth`).
    ///
    /// One pass over a node's triangles bins them on all three axes, and it
    /// works on raw buffers of small structs with non-generic arithmetic,
    /// for the unoptimised build, which neither specialises `min` and `max`
    /// nor drops array checks: the Saturn V's 900,000 triangles take 8 s in
    /// Debug on the M3 Pro (0.27 s at -O).
    private struct Builder {
        /// Per triangle (input order): its box and its centre.
        let boxes: UnsafePointer<Box>
        let centres: UnsafePointer<Point>
        /// The triangles' indices, put in tree order by the build.
        let items: UnsafeMutablePointer<Int32>
        /// Per axis and bin, reused from node to node: the triangles' box
        /// and their count; per bin, the cost of everything from it up.
        let bins: UnsafeMutablePointer<Box>
        let binCounts: UnsafeMutablePointer<Int>
        let rightCost: UnsafeMutablePointer<Double>

        /// The tree over the `count` triangles of `boxes` and `centres`,
        /// whose indices `items` it puts in tree order: per node, its bounds
        /// and its links (`TriangleBVH`'s).
        static func build(boxes: UnsafePointer<Box>, centres: UnsafePointer<Point>,
                          items: UnsafeMutablePointer<Int32>, count: Int) -> (bounds: [Double], links: [Int32]) {
            let m = TriangleBVH.binCount
            return withUnsafeTemporaryAllocation(of: Box.self, capacity: 3 * m) { bins in
                withUnsafeTemporaryAllocation(of: Int.self, capacity: 3 * m) { counts in
                    withUnsafeTemporaryAllocation(of: Double.self, capacity: m) { costs in
                        bins.initialize(repeating: Box())
                        counts.initialize(repeating: 0)
                        costs.initialize(repeating: 0)
                        return Builder(boxes: boxes, centres: centres, items: items,
                                       bins: bins.baseAddress.unsafelyUnwrapped,
                                       binCounts: counts.baseAddress.unsafelyUnwrapped,
                                       rightCost: costs.baseAddress.unsafelyUnwrapped).build(count)
                    }
                }
            }
        }

        func build(_ n: Int) -> (bounds: [Double], links: [Int32]) {
            // Every leaf holds a triangle at least: under 2n nodes.
            var bounds = [Double](repeating: 0, count: 6 * (2 * n - 1))
            var links = [Int32](repeating: 0, count: 2 * (2 * n - 1))
            var nodes = 1
            bounds.withUnsafeMutableBufferPointer { boundsBuffer in
                links.withUnsafeMutableBufferPointer { linksBuffer in
                    let bounds = boundsBuffer.baseAddress.unsafelyUnwrapped
                    let links = linksBuffer.baseAddress.unsafelyUnwrapped
                    // Work list: node, first item, count, depth.
                    var work: [(Int, Int, Int, Int)] = [(0, 0, n, 0)]
                    while let item = work.popLast() {
                        let (node, first, count, depth) = item
                        var box = Box(), centreBox = Box()
                        for i in first..<(first + count) {
                            let t = Int(items[i])
                            box.add(boxes[t])
                            centreBox.add(centres[t])
                        }
                        let b = bounds + 6 * node
                        b[0] = box.lo0; b[1] = box.lo1; b[2] = box.lo2
                        b[3] = box.hi0; b[4] = box.hi1; b[5] = box.hi2
                        let split = count > TriangleBVH.leafSize && depth < TriangleBVH.maxDepth
                            ? bestSplit(first, count, box, centreBox) : nil
                        guard let split else {
                            links[2 * node] = Int32(first)
                            links[2 * node + 1] = Int32(count)
                            continue
                        }
                        let mid = partition(first, count, split)
                        let left = nodes
                        nodes += 2
                        links[2 * node] = Int32(left)
                        links[2 * node + 1] = 0
                        work.append((left + 1, mid, first + count - mid, depth + 1))
                        work.append((left, first, mid - first, depth + 1))
                    }
                }
            }
            return (Array(bounds[0..<(6 * nodes)]), Array(links[0..<(2 * nodes)]))
        }

        /// A split: an axis and the bin boundary, or (for centres that
        /// coincide) an even split by position in the list.
        enum Split {
            case bin(axis: Int, lo: Double, scale: Double, below: Int)
            case half
        }

        /// The bin of centre coordinate `x`, the bins starting at `lo`,
        /// `scale` of them per metre.
        static func bin(_ x: Double, lo: Double, scale: Double) -> Int {
            let b = Int((x - lo) * scale)
            return b < 0 ? 0 : (b > TriangleBVH.binCount - 1 ? TriangleBVH.binCount - 1 : b)
        }

        static func coordinate(_ p: Point, _ axis: Int) -> Double {
            axis == 0 ? p.x : (axis == 1 ? p.y : p.z)
        }

        /// The split of the items `first..<first + count`, in `box` with
        /// their centres in `centreBox`, where the binned SAH is lowest, or
        /// nil for a leaf.
        func bestSplit(_ first: Int, _ count: Int, _ box: Box, _ centreBox: Box) -> Split? {
            let m = TriangleBVH.binCount
            let lo = Point(x: centreBox.lo0, y: centreBox.lo1, z: centreBox.lo2)
            // Per axis, the bins per metre (and the axis's bins emptied), or 0
            // where the centres coincide.
            func scale(_ axis: Int, _ extent: Double) -> Double {
                guard extent > 1e-12 else { return 0 }
                for k in (axis * m)..<((axis + 1) * m) {
                    bins[k] = Box()
                    binCounts[k] = 0
                }
                return Double(m) / extent
            }
            let scales = Point(x: scale(0, centreBox.hi0 - centreBox.lo0), y: scale(1, centreBox.hi1 - centreBox.lo1),
                               z: scale(2, centreBox.hi2 - centreBox.lo2))
            for i in first..<(first + count) {
                let t = Int(items[i])
                let b = boxes[t], c = centres[t]
                if scales.x > 0 {
                    let k = Self.bin(c.x, lo: lo.x, scale: scales.x)
                    bins[k].add(b)
                    binCounts[k] += 1
                }
                if scales.y > 0 {
                    let k = m + Self.bin(c.y, lo: lo.y, scale: scales.y)
                    bins[k].add(b)
                    binCounts[k] += 1
                }
                if scales.z > 0 {
                    let k = 2 * m + Self.bin(c.z, lo: lo.z, scale: scales.z)
                    bins[k].add(b)
                    binCounts[k] += 1
                }
            }
            var best: (cost: Double, axis: Int, below: Int)?
            for axis in 0..<3 where Self.coordinate(scales, axis) > 0 {
                let axisBins = bins + axis * m, axisCounts = binCounts + axis * m
                // Area times count of everything right of each boundary.
                var accumulated = Box(), accCount = 0
                for k in stride(from: m - 1, to: 0, by: -1) {
                    accumulated.add(axisBins[k])
                    accCount += axisCounts[k]
                    rightCost[k] = accumulated.halfArea * Double(accCount)
                }
                accumulated = Box()
                accCount = 0
                for k in 1..<m {
                    accumulated.add(axisBins[k - 1])
                    accCount += axisCounts[k - 1]
                    guard accCount > 0, accCount < count else { continue }
                    let cost = accumulated.halfArea * Double(accCount) + rightCost[k]
                    if best == nil || cost < best!.cost { best = (cost, axis, k) }
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
            return .bin(axis: best.axis, lo: Self.coordinate(lo, best.axis),
                        scale: Self.coordinate(scales, best.axis), below: best.below)
        }

        /// Puts the items below the split first; returns where the rest begin.
        func partition(_ first: Int, _ count: Int, _ split: Split) -> Int {
            guard case let .bin(axis, lo, scale, below) = split else { return first + count / 2 }
            var i = first, j = first + count - 1
            while i <= j {
                if Self.bin(Self.coordinate(centres[Int(items[i])], axis), lo: lo, scale: scale) < below {
                    i += 1
                } else {
                    let swap = items[i]
                    items[i] = items[j]
                    items[j] = swap
                    j -= 1
                }
            }
            return i
        }
    }
}
