import Foundation
import OrbitCore

/// Where the Sun's shadow maps stand each frame, and how soft their shadows
/// are (track R4). Pure Swift, in double precision: ShadowPass (OrbitRender)
/// draws the maps `plan(_:settings:)` fits, and ShadowCommon's MSL samples
/// them as `mapIndex(for:in:)` and `filterRadius` say.
///
/// **What casts.** Vessels and body-fixed sites (`ShadowCaster`), each as a
/// bounding sphere about a point fixed to its structure: never a vessel's
/// centre of mass, which drifts as propellant drains, so the maps would
/// shimmer.
///
/// **Maps** (`ShadowMapFit`), each an orthographic view along the Sun, at
/// most `maximumMaps`, in the order receivers try them:
/// - **The detail map** about the camera target: half width
///   2·d·tan(fovY/2) for the camera d from the target, at least 2 m, up in
///   steps of √2 (`detailRadius`), so it changes only when the camera has
///   moved by a step. Its centre is the point the camera orbits, snapped to
///   its own texels on the grid of the target's cluster map, which the
///   target's structure carries: the window slides by whole texels and the
///   casters fall on the same texels.
/// - **A map per cluster** (`clusters`): vessels whose spheres come within
///   `ShadowSettings.clusterLink` of each other. The footprint is 2R across
///   for the cluster's radius R about its primary's anchor (the camera
///   target, or its largest vessel), up in 1/8-octave steps
///   (`quantizedUp`) and widened to leave room for the filter: 117 m for
///   the Saturn V, 2.9 cm texels at 4096². It is centred on the anchor
///   itself, so the vessel's own shadows never move on its texels.
/// - **A map per site**, its footprint its bounding sphere's.
/// - Clusters and sites get a map only when more than
///   `ShadowSettings.minimumPixels` across on screen, the camera target's
///   first, then the rest by their size on screen.
///
/// **Casters per map.** Every caster whose sphere reaches into the map's
/// footprint, wherever it is along the light, and the map's depth covers
/// them all. So a receiver anywhere in the footprint's column, even far
/// behind every caster (the long evening shadow on the pad), is served by
/// any map that holds it: it is in shadow exactly where a caster is drawn
/// in its texel, and its PCSS penumbra comes from the true distance.
///
/// **Matrices** (`ShadowMapFit.matrix`): camera-relative world to the map's
/// clip space, S = Ortho·R_sun·T(−centre), built in double and converted to
/// float only at the end. Both the centre and the receivers are
/// camera-relative, so S maps a point on a vessel to the same texel
/// wherever the camera is.
///
/// **Depth** is reversed, as the scene's: 1 at the map's Sun side, 0 at its
/// far side, cleared to 0, compared greater-equal (lit when the receiver
/// is at least as near the Sun as the stored caster).
///
/// **Softness.** PCSS (Fernando 2005) with the Sun's real disc: a straight
/// edge Δd in front of a receiver facing the Sun throws a penumbra
/// 2·Δd·tan α wide (`penumbraWidth`, 0.0093·Δd), whose profile is the share
/// of a uniform disc on one side of a chord (`edgeVisibility`). The LES
/// tower's shadow on the CM, Δd ≈ 3 m, is about 3 cm soft; the stack's on
/// the ground at Δd ≈ 100 m about 0.9 m.
public enum ShadowFitting {
    /// The Sun's mean angular radius, rad: the IAU 2015 nominal solar radius,
    /// 695,700 km, seen from 1 au (0.2665°, a 0.533° disc). It varies by
    /// ±1.7% over the year; ShadowCommon uses this mean.
    public static let sunAngularRadius = asin(695_700e3 / 149_597_870_700.0)

    /// `LightingUniforms.maxShadowMaps`.
    public static let maximumMaps = 4
    /// The detail map's smallest half width, m.
    public static let minimumDetailRadius = 2.0
    /// Footprints and depth ranges grow in steps of 2^(1/8), 9%.
    public static let radiusStepsPerOctave = 8.0
    /// The widest filter radius ShadowCommon uses while a coarser map also
    /// holds the receiver (texels); a wider penumbra is taken from that map.
    /// Footprints leave this much room, plus 2 texels, inside their edge.
    public static let maxFilterRadius = 24.0
    /// The widest blocker search ShadowCommon makes while a coarser map
    /// also holds the receiver (texels).
    public static let maxSearchRadius = 4 * maxFilterRadius
    /// The share of a map's half width, inside its usable edge, over which
    /// its receivers blend into the next map that holds them (ShadowCommon's
    /// ORBIT_SHADOW_BAND), so no seam shows.
    public static let blendBand = 0.1

    // MARK: Penumbra

    /// The full width (m) of the penumbra a straight edge `separation` (m)
    /// in front of a receiver throws across it, the receiver facing the
    /// light: 2·Δd·tan α, 0.0093·Δd for the Sun. On a receiver tilted
    /// to the light it stretches by 1/cos of the tilt.
    public static func penumbraWidth(separation: Double, angularRadius: Double = sunAngularRadius) -> Double {
        2 * separation * tan(angularRadius)
    }

    /// The light's visible share at a signed distance `s` from a straight
    /// edge's geometric shadow line, in half widths of the penumbra (−1 at
    /// the umbra's edge, +1 at the penumbra's outer edge): the area of a
    /// uniform unit disc with x < s, over π.
    public static func edgeVisibility(_ s: Double) -> Double {
        let t = min(max(s, -1), 1)
        return (t * (1 - t * t).squareRoot() + asin(t) + Double.pi / 2) / Double.pi
    }

    /// Tap `k` of `n` of ShadowCommon's filter, in a unit disc (Vogel 2007):
    /// radius √((k + ½)/n), turned by the golden angle per tap and by
    /// `rotation`, which ShadowCommon draws per texel of the map. Equal-area
    /// rings, so n taps weigh the disc uniformly, as the Sun's disc is.
    public static func vogel(_ k: Int, of n: Int, rotation: Double) -> (x: Double, y: Double) {
        let r = ((Double(k) + 0.5) / Double(n)).squareRoot()
        let a = Double(k) * goldenAngle + rotation
        return (r * cos(a), r * sin(a))
    }

    /// Blocker-search tap `k` of `n` (k ≥ 1; tap 0 is the receiver's own
    /// texel), in texels out to `radius`: radii spaced logarithmically from
    /// one texel, so the search is dense near the receiver, where a thin
    /// caster close by throws a narrow penumbra, and sparse far out, where
    /// only a broad caster matters; turned as `vogel`.
    public static func searchTap(_ k: Int, of n: Int, radius: Double, rotation: Double) -> (x: Double, y: Double) {
        let r = pow(max(radius, 1), Double(k) / Double(n - 1))
        let a = Double(k) * goldenAngle + rotation
        return (r * cos(a), r * sin(a))
    }

    /// π(3 − √5), rad.
    public static let goldenAngle = Double.pi * (3 - 5.0.squareRoot())

    /// PCSS's filter radius (texels): the penumbra's half width, tan α·Δd,
    /// for a receiver at map depth `receiver` behind blockers at mean depth
    /// `blocker` (depths as the maps store them: 1 on the Sun's side), in a
    /// map `depthRange` deep with `texel`-sized texels (m).
    public static func filterRadius(blocker: Double, receiver: Double, depthRange: Double, texel: Double,
                                    angularRadius: Double = sunAngularRadius) -> Double {
        max(blocker - receiver, 0) * depthRange * tan(angularRadius) / texel
    }

    // MARK: Steps

    /// The smallest 2^(k/stepsPerOctave) metres at or above `x` (k an
    /// integer), so a size that changes a little keeps its step.
    public static func quantizedUp(_ x: Double, stepsPerOctave: Double = radiusStepsPerOctave) -> Double {
        guard x > 0 else { return 0 }
        let k = (log2(x) * stepsPerOctave - 1e-9).rounded(.up)
        return pow(2, k / stepsPerOctave)
    }

    /// The detail map's half width (m) for the camera `distance` (m) from
    /// its target and its vertical field of view `fovY` (rad): 2·d·tan(fovY/2),
    /// at least `minimumDetailRadius`, up in steps of √2; nil when that is
    /// not below the cluster map's half width, which is then as fine.
    public static func detailRadius(distance: Double, fovY: Double, clusterRadius: Double) -> Double? {
        let r = quantizedUp(max(2 * distance * tan(fovY / 2), minimumDetailRadius), stepsPerOctave: 2)
        return r < clusterRadius ? r : nil
    }

    // MARK: Frames

    /// Rows: the map's right, up and the unit vector to the Sun (world), a
    /// right-handed frame. Right is perpendicular to the celestial pole
    /// (ICRF z), which the Sun never comes near, so it turns only as the
    /// Sun does.
    public static func lightBasis(toSun: Vec3) -> Mat3 {
        let z = toSun.normalized
        let x = (abs(z.z) < 0.9 ? Vec3.unitZ : Vec3.unitX).cross(z).normalized
        return Mat3(rows: x, z.cross(x), z)
    }

    /// `p` moved across the light, on a map's grid of `texel`-sized texels
    /// laid from `origin` along `basis`'s right and up, to the nearest grid
    /// point; its depth along the light is kept.
    public static func snapped(_ p: Vec3, to origin: Vec3, basis: Mat3, texel: Double) -> Vec3 {
        let d = p - origin
        let x = (basis.r0.dot(d) / texel).rounded() * texel
        let y = (basis.r1.dot(d) / texel).rounded() * texel
        return origin + basis.r0 * x + basis.r1 * y + basis.r2 * basis.r2.dot(d)
    }

    /// The sphere about the centre of the points' bounding box that holds
    /// them all (a caster's sphere, from its mesh), nil for none.
    public static func boundingSphere<S: Sequence>(_ points: S) -> (centre: Vec3, radius: Double)?
        where S.Element == Vec3 {
        var lo = Vec3(.infinity, .infinity, .infinity), hi = -lo, any = false
        for p in points {
            lo = Vec3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z))
            hi = Vec3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
            any = true
        }
        guard any else { return nil }
        let c = (lo + hi) * 0.5
        var r = 0.0
        for p in points { r = max(r, (p - c).length) }
        return (c, r)
    }

    /// The sphere holding every one of `spheres`, about the centre of their
    /// bounding box; nil for none.
    public static func enclosing(_ spheres: [(centre: Vec3, radius: Double)]) -> (centre: Vec3, radius: Double)? {
        guard let box = boundingSphere(spheres.flatMap { s in
            [Vec3.unitX, -.unitX, .unitY, -.unitY, .unitZ, -.unitZ].map { s.centre + $0 * s.radius }
        }) else { return nil }
        return (box.centre, spheres.map { ($0.centre - box.centre).length + $0.radius }.max() ?? 0)
    }

    /// Groups of the casters `members` (indices into `casters`) whose
    /// spheres come within `link` (m) of each other, directly or through
    /// others; each group in index order, groups by their first index.
    public static func clusters(_ casters: [ShadowCaster], members: [Int], link: Double) -> [[Int]] {
        var parent = Dictionary(uniqueKeysWithValues: members.map { ($0, $0) })
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i]! != i { i = parent[i]! }
            return i
        }
        for (a, i) in members.enumerated() {
            for j in members[(a + 1)...] {
                let gap = (casters[i].centre - casters[j].centre).length - casters[i].radius - casters[j].radius
                if gap <= link {
                    let ri = root(i), rj = root(j)
                    if ri != rj { parent[max(ri, rj)] = min(ri, rj) }
                }
            }
        }
        var groups: [Int: [Int]] = [:]
        for i in members { groups[root(i), default: []].append(i) }
        return groups.values.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    }

    /// Pixels across a sphere of `radius` at camera-relative `centre`;
    /// infinite with the camera inside it.
    public static func pixelSize(centre: Vec3, radius: Double, pixelsPerRadian: Double) -> Double {
        let d = centre.length
        return d <= radius ? .infinity : 2 * asin(radius / d) * pixelsPerRadian
    }

    // MARK: Plan

    /// The frame's maps, in the order receivers try them: the detail map,
    /// the camera target's cluster, then the other clusters and the sites
    /// by their size on screen, at most `settings.maxMaps`.
    public static func plan(_ view: ShadowView, settings s: ShadowSettings) -> [ShadowMapFit] {
        guard s.enabled, s.maxMaps > 0, s.mapSize > 0, !view.casters.isEmpty else { return [] }
        let casters = view.casters, size = Double(s.mapSize)
        // Room for the filter inside the footprint's edge.
        let widen = 1 + 2 * (maxFilterRadius + 2) / size

        struct Candidate {
            var centre: Vec3
            var halfWidth: Double
            var pixels: Double
            var isTarget: Bool
        }
        var candidates: [Candidate] = []
        let vessels = casters.indices.filter { if case .vessel = casters[$0].kind { true } else { false } }
        for group in clusters(casters, members: vessels, link: s.clusterLink) {
            let isTarget = view.target.map { group.contains($0.caster) } ?? false
            let primary = isTarget ? view.target!.caster : group.max { casters[$0].radius < casters[$1].radius }!
            let centre = casters[primary].centre
            let radius = group.map { (casters[$0].centre - centre).length + casters[$0].radius }.max()!
            candidates.append(Candidate(centre: centre, halfWidth: quantizedUp(radius * widen),
                                        pixels: pixelSize(centre: centre, radius: radius,
                                                          pixelsPerRadian: view.pixelsPerRadian),
                                        isTarget: isTarget))
        }
        for c in casters {
            guard case .site = c.kind else { continue }
            candidates.append(Candidate(centre: c.centre, halfWidth: quantizedUp(c.radius * widen),
                                        pixels: pixelSize(centre: c.centre, radius: c.radius,
                                                          pixelsPerRadian: view.pixelsPerRadian),
                                        isTarget: false))
        }
        candidates = candidates.filter { $0.pixels > s.minimumPixels }
            .sorted { ($0.isTarget ? 1 : 0, $0.pixels) > ($1.isTarget ? 1 : 0, $1.pixels) }

        let limit = min(s.maxMaps, maximumMaps)
        var maps: [ShadowMapFit] = []
        func fit(_ level: ShadowMapFit.Level, centre: Vec3, halfWidth: Double, basis: Mat3) -> ShadowMapFit {
            var drawn: [Int] = [], near = 0.0, far = 0.0
            for (j, c) in casters.enumerated() {
                let d = c.centre - centre
                guard abs(basis.r0.dot(d)) <= halfWidth + c.radius, abs(basis.r1.dot(d)) <= halfWidth + c.radius
                else { continue }
                drawn.append(j)
                let z = basis.r2.dot(d)
                near = max(near, z + c.radius)
                far = max(far, c.radius - z)
            }
            return ShadowMapFit(level: level, casters: drawn, centre: centre, basis: basis, halfWidth: halfWidth,
                                near: quantizedUp(max(near, 1)), far: quantizedUp(max(far, 1)),
                                resolution: s.mapSize)
        }
        let basisOf = { (c: Candidate) in lightBasis(toSun: view.sun - c.centre) }
        if s.detailMap, limit >= 2, let target = view.target, let cluster = candidates.first, cluster.isTarget,
           let r = detailRadius(distance: target.point.length, fovY: view.fovY, clusterRadius: cluster.halfWidth) {
            // On the cluster map's grid, which the target's structure carries.
            let basis = basisOf(cluster)
            let centre = snapped(target.point, to: cluster.centre, basis: basis, texel: 2 * r / size)
            maps.append(fit(.detail, centre: centre, halfWidth: r, basis: basis))
        }
        for c in candidates where maps.count < limit {
            maps.append(fit(.cluster, centre: c.centre, halfWidth: c.halfWidth, basis: basisOf(c)))
        }
        return maps
    }

    // MARK: Receivers

    /// Whether a map's footprint holds a receiver whose clip position is `c`,
    /// with room for the filter: ShadowCommon's `orbit_shadowHolds`.
    public static func holds(_ c: Vec3, resolution: Int) -> Bool {
        max(abs(c.x), abs(c.y)) < usableEdge(resolution: resolution)
    }

    /// The clip-space half width of a map's usable footprint, inside the
    /// filter's room at its edge.
    public static func usableEdge(resolution: Int) -> Double {
        1 - 2 * (maxFilterRadius + 2) / Double(resolution)
    }

    /// The map a receiver at camera-relative `p` samples first: the first
    /// that holds it; nil when none does (it is lit).
    public static func mapIndex(for p: Vec3, in maps: [ShadowMapFit]) -> Int? {
        maps.firstIndex { holds($0.clip(p), resolution: $0.resolution) }
    }
}

/// Something that casts a shadow: a vessel or a body-fixed site, as a
/// sphere about a point fixed to its structure.
public struct ShadowCaster: Equatable {
    public enum Kind: Hashable {
        case vessel(UUID)
        /// A body-fixed site, by name.
        case site(String)
    }

    public var kind: Kind
    /// Camera-relative centre of its bounding sphere, m: fixed to its
    /// structure (not its centre of mass).
    public var centre: Vec3
    public var radius: Double

    public init(kind: Kind, centre: Vec3, radius: Double) {
        self.kind = kind
        self.centre = centre
        self.radius = radius
    }
}

/// What a frame's maps are fitted to. Camera-relative, m.
public struct ShadowView {
    /// The caster the camera looks at and the point it orbits.
    public struct Target: Equatable {
        public var caster: Int
        public var point: Vec3

        public init(caster: Int, point: Vec3) {
            self.caster = caster
            self.point = point
        }
    }

    public var casters: [ShadowCaster]
    /// The Sun's centre.
    public var sun: Vec3
    /// Nil when the camera looks at a body.
    public var target: Target?
    /// Vertical field of view, rad.
    public var fovY: Double
    /// Pixels per radian at the centre of the view.
    public var pixelsPerRadian: Double

    public init(casters: [ShadowCaster], sun: Vec3, target: Target?, fovY: Double, pixelsPerRadian: Double) {
        self.casters = casters
        self.sun = sun
        self.target = target
        self.fovY = fovY
        self.pixelsPerRadian = pixelsPerRadian
    }
}

/// One shadow map: an orthographic view along the Sun over a square
/// footprint, `2·halfWidth` across, centred on `centre`.
public struct ShadowMapFit: Equatable {
    public enum Level: Equatable {
        /// About the camera target.
        case detail
        /// A cluster of vessels, or a site.
        case cluster
    }

    public var level: Level
    /// The casters it draws (indices into `ShadowView.casters`): every one
    /// whose sphere reaches into the footprint.
    public var casters: [Int]
    /// Camera-relative centre of the footprint, m.
    public var centre: Vec3
    /// Rows: the map's right, up and the unit vector to the Sun (world).
    public var basis: Mat3
    /// Half the footprint's side, m.
    public var halfWidth: Double
    /// How far its depth reaches from `centre` towards the Sun (depth 1) and
    /// away from it (depth 0), m: over every caster it draws.
    public var near: Double
    public var far: Double
    /// Texels per side.
    public var resolution: Int

    public init(level: Level, casters: [Int], centre: Vec3, basis: Mat3, halfWidth: Double, near: Double,
                far: Double, resolution: Int) {
        self.level = level
        self.casters = casters
        self.centre = centre
        self.basis = basis
        self.halfWidth = halfWidth
        self.near = near
        self.far = far
        self.resolution = resolution
    }

    /// A texel's side, m.
    public var texel: Double { 2 * halfWidth / Double(resolution) }
    /// Its depth, m.
    public var depthRange: Double { near + far }

    /// Camera-relative world to clip space: x, y in −1...1 across the
    /// footprint (right, up), z from 1 on the Sun's side to 0 on the far
    /// side (running past either for receivers beyond).
    public func clip(_ p: Vec3) -> Vec3 {
        let d = p - centre
        return Vec3(basis.r0.dot(d) / halfWidth, basis.r1.dot(d) / halfWidth, (basis.r2.dot(d) + far) / depthRange)
    }

    /// Clip space to the texture's: u, v in 0...1, v down; depth as is.
    public static func texture(_ c: Vec3) -> Vec3 { Vec3(0.5 + 0.5 * c.x, 0.5 - 0.5 * c.y, c.z) }

    /// `clip` as a row-major 4×4 matrix, the last row 0, 0, 0, 1.
    public var matrix: [Double] { matrix(rotation: .identity, translation: .zero) }

    /// The clip matrix of a mesh placed by `rotation` and camera-relative
    /// `translation` (a point p of it is at rotation·p + translation),
    /// composed in double: row-major, from the mesh's own frame.
    public func matrix(rotation: Mat3, translation: Vec3) -> [Double] {
        let rows = [basis.r0 / halfWidth, basis.r1 / halfWidth, basis.r2 / depthRange]
        let offsets = [0, 0, far / depthRange]
        var m: [Double] = []
        for (a, b) in zip(rows, offsets) {
            let linear = rotation.transposed * a
            m += [linear.x, linear.y, linear.z, a.dot(translation - centre) + b]
        }
        return m + [0, 0, 0, 1]
    }
}
