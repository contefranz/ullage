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
/// 3π/2. Two measures, which part where something stands proud of a skin:
///
/// - `radius(at:azimuth:)`, the outline's support function: how far the
///   outline reaches towards θ, the largest p·radial(θ) over the shapes'
///   cross-section. This is the half-width an orthographic view or a
///   drawing shows: a view from θ - π/2 has it on its right. A cylinder's
///   radius at every θ; on a fin's diagonal, its tip. `width(at:viewedFrom:)`
///   is the sum of the two sides, the span a drawing dimensions. It is not
///   local to θ: a feature standing h proud of a skin of radius R, Δ away
///   from θ, reaches R cos Δ + h towards θ, so it raises `radius` wherever
///   Δ < acos(1 - h/R). For 11 in on the S-II's 198 in skin that is 19°:
///   VG2's systems tunnel at θ = 32° makes `radius` at 45° read 203.9 in.
///   Use it for outlines, spans, fin tips and what stands proudest, not for
///   a skin's diameter.
/// - `reach(at:azimuth:)`, local to the ray: the farthest surface point on
///   the half-plane at θ, a ray cast out from the axis. It does not see
///   what lies off that half-plane, so a skin's radius beside a tunnel or
///   fairing is the skin's, and sweeping θ finds bumps (fairings, modules,
///   ports) at their azimuths. `diameter(at:azimuth:)` adds the two rays of
///   the line through the axis. Measure stage and skin diameters with these,
///   on rays that miss the features themselves: the ray at 45° misses the
///   S-II's tunnel at 32° and VG1's S-II ullage-motor fairings, 24 in across
///   and centred 4° past each fin.
///
/// Both include every triangle of the scene, back faces and insides too.
///
/// An image samples each pixel at its centre (`OrthoRaster`, as the GPU
/// does without antialiasing), so it shows a feature only where the feature
/// is a pixel or more across, or happens to cover a centre. A side view's
/// row at station x crosses the shapes along the section's `cover`; its
/// last covered pixel's centre lies at most `radius` out, and less than a
/// pixel inside `radius(at:azimuth:resolving:)`, the far end of the
/// farthest stretch at least a pixel long. The two differ where what
/// reaches farthest is a sliver at x: at 40 px/m, the row 0.005 in above
/// the lowest point of an APS pitch engine's 6.43 in exit (P1's) crosses
/// its lip, 0.5 in proud of the module's face, along 0.34 mm, a seventieth
/// of a pixel, and the image shows the face there.
///
///     let s = Silhouette(VesselLibrary.saturnV())
///     s.diameter(at: AS506.station(1000), azimuth: .pi / 4)      // the S-IC's skin: 396 in, in m
///     s.width(at: AS506.station(1000), viewedFrom: 0)            // the outline's span seen from Position I
///     s.radius(over: AS506.station(81)...AS506.station(137), azimuth: .pi / 4)   // fin A's tip
///     s.reach(at: AS506.height(73.4), azimuth: 0)                // the APS module at Position I
///     s.radius(at: x, azimuth: .pi / 2, resolving: 1 / 40)      // what a 40 px/m view from I must show on its right
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

        /// The stretches of the line towards θ that the section covers:
        /// each segment's projection on radial(θ), merged where they touch
        /// (to within `Silhouette.touching`), in increasing order. In a
        /// side view with θ on its right (from θ - π/2), the row at this
        /// station crosses the shapes along them, so a pixel of the row
        /// whose centre lies in one is covered.
        func cover(azimuth: Double) -> [ClosedRange<Double>] {
            let d = Silhouette.radial(azimuth)
            let spans = segments.map { a, b -> ClosedRange<Double> in
                let (p, q) = (a.dot(d), b.dot(d))
                return min(p, q)...max(p, q)
            }.sorted { $0.lowerBound < $1.lowerBound }
            var merged: [ClosedRange<Double>] = []
            for span in spans {
                if let last = merged.last, span.lowerBound <= last.upperBound + Silhouette.touching {
                    merged[merged.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
                } else {
                    merged.append(span)
                }
            }
            return merged
        }

        /// The outline's reach towards θ that a drawing sampling the line
        /// every `pixel` (m) must show: the far end of the farthest stretch
        /// of `cover` at least `pixel` long, since such a stretch holds a
        /// sample within `pixel` of its end. It is `radius` where what
        /// reaches farthest is a pixel or more across at this station, and
        /// less where that is a sliver the samples can straddle (a nozzle's
        /// lip cut just above its lowest point); nil if no stretch is that
        /// long.
        func radius(azimuth: Double, resolving pixel: Double) -> Double? {
            cover(azimuth: azimuth).last { $0.upperBound - $0.lowerBound >= pixel }?.upperBound
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

    /// Section stretches closer than this (m) touch: the crossings of an
    /// edge two triangles share, which each computes on its own.
    static let touching = 1e-9

    /// The outline's reach towards θ at station `x`; see `Section.radius`.
    func radius(at x: Double, azimuth: Double) -> Double? { section(at: x).radius(azimuth: azimuth) }

    /// The outline's reach towards θ at station `x` that an image at
    /// 1/`pixel` px/m must show; see `Section.radius(azimuth:resolving:)`.
    func radius(at x: Double, azimuth: Double, resolving pixel: Double) -> Double? {
        section(at: x).radius(azimuth: azimuth, resolving: pixel)
    }

    /// The outline's width at station `x` seen from θ; see `Section.width`.
    func width(at x: Double, viewedFrom azimuth: Double) -> Double? { section(at: x).width(viewedFrom: azimuth) }

    /// The farthest surface point on the half-plane at θ, at station `x`;
    /// see `Section.reach`.
    func reach(at x: Double, azimuth: Double) -> Double? { section(at: x).reach(azimuth: azimuth) }

    /// The skin's diameter at station `x` along the line through the axis
    /// at θ: `reach` at θ plus `reach` at θ + π, so that what stands off
    /// the line does not count (as it counts in `width`); nil if either ray
    /// meets nothing.
    func diameter(at x: Double, azimuth: Double) -> Double? {
        let cut = section(at: x)
        guard let near = cut.reach(azimuth: azimuth), let far = cut.reach(azimuth: azimuth + Double.pi) else {
            return nil
        }
        return near + far
    }

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
