import Foundation
import OrbitCore

/// The outline of a vessel's shapes against station, measured on their
/// triangles: exact for the tessellation, at no image's resolution. For the
/// geometry tests (VG1-VG3) to check their shapes against the datasheet's
/// dimensions; `OrthoRasterTests` checks that the ortho gallery draws the
/// same outline.
///
/// Stations are construction x in metres (for the Apollo vehicles
/// `AS506.station(sta)` or `AS506.apolloStation(xa)`), azimuths θ in radians
/// round the vehicle's x axis from Position I (+z) towards Position II (-y),
/// as `VisualShape.vehicleAzimuth` measures them: II at π/2, III at π, IV at
/// 3π/2. Two measures:
///
/// - `radius(at:azimuth:)`: how far the outline reaches towards θ, the
///   largest p·radial(θ) over the shapes' cross-section. This is the
///   half-width an orthographic view or a drawing shows: a view from θ - π/2
///   has it on its right. A cylinder's radius at every θ; on a fin's
///   diagonal, its tip. `width(at:viewedFrom:)` is the sum of the two
///   sides, the span a drawing dimensions.
/// - `reach(at:azimuth:)`: the farthest surface point on the half-plane at
///   θ, a ray cast out from the axis. It does not see what lies off that
///   half-plane, so sweeping θ finds bumps (fairings, modules, ports) at
///   their azimuths.
///
/// Both include every triangle of the scene, back faces and insides too.
///
///     let s = Silhouette(VesselLibrary.saturnV())
///     s.width(at: AS506.station(1000), viewedFrom: 0)            // 396 in, in m
///     s.radius(over: AS506.station(81)...AS506.station(137), azimuth: .pi / 4)   // fin A's tip
///     s.reach(at: AS506.height(73.4), azimuth: 0)                // the APS module at Position I
struct Silhouette {
    /// The unit vector at azimuth θ in the construction frame: (0, -sin θ, cos θ).
    static func radial(_ azimuth: Double) -> Vec3 { Vec3(0, -sin(azimuth), cos(azimuth)) }

    /// The shapes' surface at one station: segments in the plane x = `x`.
    struct Section {
        let x: Double
        let segments: [(Vec3, Vec3)]

        var isEmpty: Bool { segments.isEmpty }

        /// The largest p·radial(θ) over the section; nil if it is empty.
        /// Negative when the section lies wholly beyond the axis.
        func radius(azimuth: Double) -> Double? {
            guard !segments.isEmpty else { return nil }
            let d = Silhouette.radial(azimuth)
            var best = -Double.infinity
            for (a, b) in segments { best = max(best, a.dot(d), b.dot(d)) }
            return best
        }

        /// The outline's width seen from azimuth θ: the radii towards θ ± π/2.
        func width(viewedFrom azimuth: Double) -> Double? {
            guard let r = radius(azimuth: azimuth + Double.pi / 2),
                  let l = radius(azimuth: azimuth - Double.pi / 2) else { return nil }
            return r + l
        }

        /// The farthest crossing of the ray from the axis at θ with the
        /// section; nil if the ray meets none.
        func reach(azimuth: Double) -> Double? {
            let d = Silhouette.radial(azimuth)
            // 2-D cross product in the (y, z) plane.
            func cross(_ u: Vec3, _ v: Vec3) -> Double { u.y * v.z - u.z * v.y }
            var best: Double?
            for (a, b) in segments {
                let e = b - a, ed = cross(e, d), ad = cross(a, d)
                let scale = max(e.length, a.length, 1e-9)
                if abs(ed) < 1e-12 * scale {
                    // Parallel to the ray: on it only if collinear.
                    guard abs(ad) < 1e-9 * scale else { continue }
                    for s in [a.dot(d), b.dot(d)] where s >= 0 { best = max(best ?? s, s) }
                    continue
                }
                let t = -ad / ed
                guard t >= -1e-9, t <= 1 + 1e-9 else { continue }
                let s = (a + e * t).dot(d)
                if s >= -1e-9 { best = max(best ?? s, s) }
            }
            return best
        }
    }

    let scene: OrthoScene
    /// Construction x (m) of the lowest and highest points.
    let stations: ClosedRange<Double>?
    /// Triangles by station, for `section(at:)`.
    private let bins: [[Int]]
    private let binWidth: Double

    init(_ scene: OrthoScene) {
        self.scene = scene
        stations = scene.stations
        let count = 1024
        let span = stations.map { max($0.upperBound - $0.lowerBound, 1e-9) } ?? 1
        binWidth = span / Double(count)
        var bins = [[Int]](repeating: [], count: count)
        if let lo = stations?.lowerBound {
            for t in 0..<scene.triangleCount {
                let xs = (0..<3).map { scene.vertices[3 * t + $0].position.x }
                let first = min(count - 1, Int((xs.min()! - lo) / binWidth))
                let last = min(count - 1, Int((xs.max()! - lo) / binWidth))
                for b in first...last { bins[b].append(t) }
            }
        }
        self.bins = bins
    }

    init(_ vessel: Vessel) { self.init(OrthoScene(vessel)) }

    /// The cross-section at construction x `x` (m).
    func section(at x: Double) -> Section {
        guard let range = stations, range.contains(x) else { return Section(x: x, segments: []) }
        let bin = min(bins.count - 1, Int((x - range.lowerBound) / binWidth))
        var segments: [(Vec3, Vec3)] = []
        for t in bins[bin] {
            let p = (0..<3).map { scene.vertices[3 * t + $0].position }
            let s = p.map { $0.x - x }
            if s[0] == 0 && s[1] == 0 && s[2] == 0 {
                segments += [(p[0], p[1]), (p[1], p[2]), (p[2], p[0])]
                continue
            }
            var points: [Vec3] = []
            for i in 0..<3 {
                let j = (i + 1) % 3
                if s[i] == 0 { points.append(p[i]) }
                if s[i] * s[j] < 0 { points.append(p[i] + (p[j] - p[i]) * (s[i] / (s[i] - s[j]))) }
            }
            if points.count == 2 { segments.append((points[0], points[1])) }
            if points.count == 1 { segments.append((points[0], points[0])) }
        }
        return Section(x: x, segments: segments)
    }

    /// The outline's reach towards θ at station `x`; see `Section.radius`.
    func radius(at x: Double, azimuth: Double) -> Double? { section(at: x).radius(azimuth: azimuth) }

    /// The outline's width at station `x` seen from θ; see `Section.width`.
    func width(at x: Double, viewedFrom azimuth: Double) -> Double? { section(at: x).width(viewedFrom: azimuth) }

    /// The farthest surface point on the half-plane at θ, at station `x`;
    /// see `Section.reach`.
    func reach(at x: Double, azimuth: Double) -> Double? { section(at: x).reach(azimuth: azimuth) }

    /// The largest `radius` towards θ over the stations `xs` (m): exact,
    /// from the triangles clipped to the band.
    func radius(over xs: ClosedRange<Double>, azimuth: Double) -> Double? {
        let d = Self.radial(azimuth)
        var best: Double?
        for t in 0..<scene.triangleCount {
            let a = scene.vertices[3 * t].position, b = scene.vertices[3 * t + 1].position
            let c = scene.vertices[3 * t + 2].position
            for p in Self.clipped(a, b, c, to: xs) {
                let r = p.dot(d)
                best = max(best ?? r, r)
            }
        }
        return best
    }

    /// The corners of triangle (`a`, `b`, `c`) clipped to the stations
    /// `xs`: its vertices inside them and its edges' crossings of the two
    /// planes.
    static func clipped(_ a: Vec3, _ b: Vec3, _ c: Vec3, to xs: ClosedRange<Double>) -> [Vec3] {
        let p = [a, b, c]
        var out: [Vec3] = []
        for i in 0..<3 {
            let u = p[i], v = p[(i + 1) % 3]
            if xs.contains(u.x) { out.append(u) }
            for plane in [xs.lowerBound, xs.upperBound] where (u.x - plane) * (v.x - plane) < 0 {
                out.append(u + (v - u) * ((plane - u.x) / (v.x - u.x)))
            }
        }
        return out
    }
}
