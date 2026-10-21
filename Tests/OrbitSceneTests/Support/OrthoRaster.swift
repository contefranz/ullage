import Foundation
@testable import OrbitCore

// The Linux ortho gallery (M1.6 track L0): a software rasteriser that draws
// flat-lit orthographic views of a vessel's VisualShape meshes, with no
// Metal, so cloud sessions can see the geometry they build. It reads only
// OrbitCore, so it could move to another test target's Support folder.
//
// - `OrthoScene`: a vessel's (or some shapes') triangles in its
//   construction frame, gimbals at null, as `VesselGeometry` places them
//   for the renderer.
// - `OrthoView`: Positions I-IV, any azimuth, top and bottom, each
//   optionally cropped to a band of stations.
// - `OrthoRaster.render`: the image, with a paint hook for the albedo
//   (`OrthoPaint`, the shape's colour until VM1's evaluator lands).
// - `OrthoSheet`: images on one file and where each landed in it.
// - `PNG` writes the images (PNG.swift); `Silhouette` measures the
//   outline from the same triangles (Silhouette.swift).
//
// `ORBITSIM_ORTHO_DIR=<dir> swift test --filter OrthoGallery` writes the
// gallery (OrthoGalleryTests.swift); docs/m16/ortho-gallery.md describes it.

/// A vessel's triangles in its construction frame (m; for the Apollo
/// vehicles the Saturn V station frame, x = STA × 0.0254), three vertices
/// each, counter-clockwise from outside, with the shape each came from.
struct OrthoScene {
    /// A shape as placed: its part (nil for loose shapes) and its index there.
    struct Surface {
        let part: VesselPart?
        let shapeIndex: Int
        let shape: VisualShape
    }

    let surfaces: [Surface]
    /// Three per triangle, positions in the construction frame.
    let vertices: [VisualShape.Vertex]
    /// The surface (index into `surfaces`) of each triangle.
    let triangleSurfaces: [Int]

    var triangleCount: Int { triangleSurfaces.count }

    /// The vessel's parts' shapes (those `include` accepts), each part at
    /// `part.offset - vessel.structureOrigin`, shapes linked to thrusters as
    /// mounted; then the loose shapes `adding` (stand-ins, markers), as
    /// they are in the construction frame.
    init(_ vessel: Vessel, where include: (VesselPart) -> Bool = { _ in true }, adding loose: [VisualShape] = []) {
        self.init(vessel.parts.filter(include).map { ($0, $0.offset - vessel.structureOrigin) }, adding: loose)
    }

    /// Loose shapes, shifted by `offset`.
    init(shapes: [VisualShape], offset: Vec3 = .zero) {
        var surfaces: [Surface] = [], vertices: [VisualShape.Vertex] = [], owners: [Int] = []
        for (i, shape) in shapes.enumerated() {
            Self.add(Surface(part: nil, shapeIndex: i, shape: shape), offset, &surfaces, &vertices, &owners)
        }
        self.surfaces = surfaces
        self.vertices = vertices
        triangleSurfaces = owners
    }

    init(_ parts: [(VesselPart, Vec3)], adding loose: [VisualShape] = []) {
        var surfaces: [Surface] = [], vertices: [VisualShape.Vertex] = [], owners: [Int] = []
        for (part, offset) in parts {
            for (i, shape) in part.shapes.enumerated() {
                Self.add(Surface(part: part, shapeIndex: i, shape: shape), offset, &surfaces, &vertices, &owners)
            }
        }
        for (i, shape) in loose.enumerated() {
            Self.add(Surface(part: nil, shapeIndex: i, shape: shape), .zero, &surfaces, &vertices, &owners)
        }
        self.surfaces = surfaces
        self.vertices = vertices
        triangleSurfaces = owners
    }

    private static func add(_ surface: Surface, _ offset: Vec3, _ surfaces: inout [Surface],
                            _ vertices: inout [VisualShape.Vertex], _ owners: inout [Int]) {
        let triangles = surface.shape.triangles(offset: offset)
        owners += [Int](repeating: surfaces.count, count: triangles.count / 3)
        vertices += triangles
        surfaces.append(surface)
    }

    /// Construction x (m) of the lowest and highest vertices.
    var stations: ClosedRange<Double>? {
        guard let first = vertices.first else { return nil }
        var lo = first.position.x, hi = lo
        for v in vertices {
            lo = min(lo, v.position.x)
            hi = max(hi, v.position.x)
        }
        return lo...hi
    }
}

/// Where an orthographic view looks from, its scale and its crop.
struct OrthoView {
    enum Direction: Equatable {
        /// From the side, nose up, the camera out at `azimuth` (rad, from
        /// Position I towards II, `VisualShape.vehicleAzimuth`) looking at
        /// the axis: that azimuth faces the viewer and azimuth + π/2 is on
        /// the right, so a Position I view has II on the right and IV on
        /// the left.
        case side(azimuth: Double)
        /// From above the nose looking aft, Position I at the bottom: II on
        /// the right, III at the top, IV on the left (θ anticlockwise).
        case top
        /// From below the base looking forward, Position I at the bottom: IV
        /// on the right, III at the top, II on the left (θ clockwise).
        case bottom
    }

    var direction: Direction
    /// Pixels a metre.
    var scale: Double
    /// Only the geometry between these construction x (m) is drawn: a crop
    /// of a side view, a section of a top or bottom view. Nil: all of it.
    var stations: ClosedRange<Double>?

    init(_ direction: Direction, scale: Double, stations: ClosedRange<Double>? = nil) {
        precondition(scale > 0, "a view's scale is positive")
        self.direction = direction
        self.scale = scale
        self.stations = stations
    }

    /// From Position `n` (1-4, I-IV): azimuth (n - 1)π/2.
    static func position(_ n: Int, scale: Double, stations: ClosedRange<Double>? = nil) -> OrthoView {
        precondition((1...4).contains(n), "Positions I-IV")
        return OrthoView(.side(azimuth: Double(n - 1) * Double.pi / 2), scale: scale, stations: stations)
    }

    /// The screen's axes in the construction frame: `right` and `up` across
    /// the image, `towards` the viewer (right × up).
    var basis: (right: Vec3, up: Vec3, towards: Vec3) {
        switch direction {
        case let .side(azimuth):
            let towards = Silhouette.radial(azimuth)
            return (Silhouette.radial(azimuth + Double.pi / 2), .unitX, towards)
        case .top:
            return (-Vec3.unitY, -Vec3.unitZ, .unitX)
        case .bottom:
            return (Vec3.unitY, -Vec3.unitZ, -Vec3.unitX)
        }
    }

    /// The Positions (1-4) seen on the image's right, top, left and bottom
    /// edges, nil where none lies (a side view's top and bottom, a diagonal
    /// view's sides), and the one facing the viewer.
    var positionLabels: (right: Int?, top: Int?, left: Int?, bottom: Int?, facing: Int?) {
        func position(_ d: Vec3) -> Int? {
            guard abs(d.x) < 1e-9 else { return nil }
            let a = VisualShape.vehicleAzimuth(y: d.y, z: d.z) / (Double.pi / 2)
            let n = a.rounded()
            guard abs(a - n) < 1e-9 else { return nil }
            return (Int(n) % 4 + 4) % 4 + 1
        }
        let b = basis
        return (position(b.right), position(b.up), position(-b.right), position(-b.up), position(b.towards))
    }
}

/// What the paint hook sees at a pixel: the visible surface there, its
/// surface coordinates and normal interpolated across the triangle as the
/// GPU interpolates them.
struct OrthoFragment {
    /// The part the shape belongs to; nil for loose shapes.
    let part: VesselPart?
    let shapeIndex: Int
    let shape: VisualShape
    /// In the shape's `surfaceFrame`.
    let surface: VisualShape.SurfaceCoordinates
    /// Construction frame (m).
    let position: Vec3
    /// Unit, towards the viewer's side of the surface (reversed on a
    /// two-sided shape's back face).
    let normal: Vec3
    /// The inside of a two-sided shape (an interstage's inner face).
    let isBackFace: Bool
}

/// A surface's albedo at a fragment, linear RGB in 0...1.
typealias OrthoPaint = (OrthoFragment) -> (Double, Double, Double)

/// The look of a render.
struct OrthoStyle {
    enum Lighting {
        /// The paint's albedo as it is: for probing colours.
        case albedo
        /// Ambient plus a Lambert key light from the viewer's upper left.
        case flat
    }

    var lighting = Lighting.flat
    /// A dark line where the visible surface changes or the depth jumps.
    var outlines = true
    /// Station ticks in a strip on a side view's left: every 100 in STA,
    /// longer and labelled every 500 in; and the Positions' numerals round
    /// the edges.
    var annotations = true
    /// sRGB.
    var background: (UInt8, UInt8, UInt8) = (28, 31, 38)
    /// Pixels of background round the geometry (at least 28 with
    /// annotations, which the labels need).
    var margin = 12

    /// For probing colours (as the Mac gallery's `--verify` probes its
    /// albedo views): no light, lines or labels.
    static let albedo = OrthoStyle(lighting: .albedo, outlines: false, annotations: false)
}

/// An image with its mapping back to the construction frame and, per pixel,
/// the surface seen there.
struct OrthoImage {
    var image: RGBImage
    let view: OrthoView
    /// The screen coordinates (m along the view's right and up) of the
    /// image's top-left corner.
    let left: Double
    let top: Double
    /// Per pixel, the index into the scene's `surfaces` of the surface seen
    /// at its centre; -1 for none.
    let surfaces: [Int32]

    var width: Int { image.width }
    var height: Int { image.height }

    /// The surface seen at pixel (`x`, `y`), nil for background.
    func surface(_ x: Int, _ y: Int) -> Int? {
        let s = surfaces[y * width + x]
        return s < 0 ? nil : Int(s)
    }

    /// Screen coordinates (m) of pixel (`x`, `y`)'s centre.
    func screen(_ x: Int, _ y: Int) -> (right: Double, up: Double) {
        (left + (Double(x) + 0.5) / view.scale, top - (Double(y) + 0.5) / view.scale)
    }

    /// The pixel (column, row; fractional, 0 at the top-left edge) where
    /// the construction point `p` projects.
    func pixel(_ p: Vec3) -> (x: Double, y: Double) {
        let b = view.basis
        return ((p.dot(b.right) - left) * view.scale, (top - p.dot(b.up)) * view.scale)
    }
}

/// Ortho images on one image file, and where each landed in it, so that a
/// pixel of the file maps back to its panel's screen frame.
///
/// A single image is the sheet as it is, its panel at (0, 0). Several sit
/// side by side with their tops aligned (a contact sheet): `gap` pixels of
/// `gutter` round them and between them, so the first panel's top-left
/// pixel is (8, 8), not (0, 0), and each later one starts after the earlier
/// ones' widths and gutters. Pixel (X, Y) of the file, in the panel whose
/// top-left pixel is (X0, Y0) and whose corner is (left, top) at k px/m, is
/// at right = left + (X - X0 + 0.5) / k, up = top - (Y - Y0 + 0.5) / k
/// (`screen`). The gallery's `index.txt` gives each panel's (X0, Y0), size
/// and corner (`indexLine`).
struct OrthoSheet {
    /// The border round a contact sheet's panels and the gutters between them (px).
    static let gap = 8
    /// The border and gutters: lighter than the panels' background
    /// (`OrthoStyle.background`), so that the panels' edges show.
    static let gutter: (UInt8, UInt8, UInt8) = (74, 79, 90)

    let panels: [OrthoImage]
    /// Each panel's top-left pixel (column, row) in the sheet.
    let origins: [(x: Int, y: Int)]
    let image: RGBImage

    init(_ panels: [OrthoImage], gap: Int = OrthoSheet.gap, gutter: (UInt8, UInt8, UInt8) = OrthoSheet.gutter) {
        precondition(!panels.isEmpty, "a sheet has a panel")
        self.panels = panels
        guard panels.count > 1 else {
            origins = [(0, 0)]
            image = panels[0].image
            return
        }
        let width = panels.reduce(gap) { $0 + $1.width + gap }
        let height = (panels.map(\.height).max() ?? 0) + 2 * gap
        var sheet = RGBImage(width: width, height: height, fill: gutter)
        var origins: [(x: Int, y: Int)] = []
        var left = gap
        for panel in panels {
            sheet.paste(panel.image, at: left, gap)
            origins.append((left, gap))
            left += panel.width + gap
        }
        self.origins = origins
        image = sheet
    }

    /// The panel (index into `panels`) holding pixel (`x`, `y`) of the sheet
    /// and the screen coordinates (m) of the pixel's centre in its view; nil
    /// on the border, in a gutter or below a shorter panel.
    func screen(_ x: Int, _ y: Int) -> (panel: Int, right: Double, up: Double)? {
        for (i, panel) in panels.enumerated() {
            let px = x - origins[i].x, py = y - origins[i].y
            guard (0..<panel.width).contains(px), (0..<panel.height).contains(py) else { continue }
            let s = panel.screen(px, py)
            return (i, s.right, s.up)
        }
        return nil
    }

    /// `index.txt`'s header, which says how to read `indexLine`.
    static let indexHeader = [
        "# Ortho gallery: file, what it shows, scale k (px/m), then each panel of the file: its top-left pixel",
        "# (X0, Y0) in the file and its size (px), and its top-left corner (left, top) in the view's screen frame",
        "# (m). A file of several panels has an 8 px border and 8 px gutters, so its first panel is at (8, 8).",
        "# Pixel (X, Y) in a panel is at right = left + (X - X0 + 0.5) / k, up = top - (Y - Y0 + 0.5) / k;",
        "# a side view's up is construction x, STA = x / 0.0254.",
    ]

    /// The sheet's line in `index.txt`: `file`, `what`, the scale and one
    /// tab-separated field a panel,
    /// `panel n at (X0, Y0) px, W x H px, corner (left, top) m`.
    func indexLine(file: String, what: String) -> String {
        let fields = panels.enumerated().map { i, panel -> String in
            let corner = String(format: "(%.3f, %.3f)", panel.left, panel.top)
            return "panel \(i + 1) at (\(origins[i].x), \(origins[i].y)) px, \(panel.width) x \(panel.height) px, corner \(corner) m"
        }
        return ([file, what, "\(panels[0].view.scale) px/m"] + fields).joined(separator: "\t")
    }
}

enum OrthoRaster {
    /// The default paint: each shape's colour.
    static let shapeColour: OrthoPaint = { $0.shape.color }

    /// Width (px) of the station-tick strip on a side view's left.
    static let tickStrip = 44

    /// A fragment must be this much nearer (m) to hide one drawn before it,
    /// so that coplanar faces (a cap in another shape's end plane) show the
    /// first one drawn instead of speckling.
    static let coplanar = 1e-5

    /// The scene drawn in `view`, its albedo from `paint`.
    ///
    /// Each pixel shows the nearest surface at its centre. Back faces are
    /// culled except on two-sided shapes, as the vessel pass culls them; a
    /// fragment outside the view's stations is dropped. The image spans the
    /// projected bounds of what is drawn (a side view's crop: the crop's
    /// stations) plus the style's margin and, on a side view, the tick strip.
    static func render(_ scene: OrthoScene, _ view: OrthoView, style: OrthoStyle = OrthoStyle(),
                       paint: OrthoPaint = shapeColour) -> OrthoImage {
        let (right, up, towards) = view.basis
        let crop = view.stations
        let side: Bool
        if case .side = view.direction { side = true } else { side = false }

        // The window: the projected bounds of the triangles clipped to the
        // crop (and, for a side view's crop, the crop itself).
        var minR = Double.infinity, maxR = -Double.infinity, minU = Double.infinity, maxU = -Double.infinity
        func include(_ p: Vec3) {
            let r = p.dot(right), u = p.dot(up)
            minR = min(minR, r)
            maxR = max(maxR, r)
            minU = min(minU, u)
            maxU = max(maxU, u)
        }
        if let crop {
            let v = scene.vertices
            for t in 0..<scene.triangleCount {
                for p in Silhouette.clipped(v[3 * t].position, v[3 * t + 1].position, v[3 * t + 2].position, to: crop) {
                    include(p)
                }
            }
            if side {
                minU = crop.lowerBound
                maxU = crop.upperBound
            }
        } else {
            for v in scene.vertices { include(v.position) }
        }
        if !minR.isFinite { minR = 0; maxR = 0; minU = 0; maxU = 0 }
        let k = view.scale, margin = Double(style.annotations ? max(style.margin, 28) : style.margin)
        let strip = side && style.annotations ? Double(tickStrip) : 0
        let left = minR - (margin + strip) / k, top = maxU + margin / k
        let width = max(1, Int(((maxR - minR) * k + 2 * margin + strip).rounded(.up)))
        let height = max(1, Int(((maxU - minU) * k + 2 * margin).rounded(.up)))

        // Visibility: per pixel the nearest triangle and its barycentrics.
        var depth = [Double](repeating: -Double.infinity, count: width * height)
        var owner = [Int32](repeating: -1, count: width * height)
        var weights = [(Double, Double)](repeating: (0, 0), count: width * height)
        var backFacing = [Bool](repeating: false, count: scene.triangleCount)
        // Each triangle's depth gradient (m a pixel, along x and y), for the outlines.
        var slopes = [(Double, Double)](repeating: (0, 0), count: scene.triangleCount)
        let verts = scene.vertices

        for t in 0..<scene.triangleCount {
            let p0 = verts[3 * t].position, p1 = verts[3 * t + 1].position, p2 = verts[3 * t + 2].position
            if let crop, max(p0.x, p1.x, p2.x) < crop.lowerBound || min(p0.x, p1.x, p2.x) > crop.upperBound {
                continue
            }
            let face = (p1 - p0).cross(p2 - p0)
            let facing = face.dot(towards)
            backFacing[t] = facing < 0
            if facing < 0 && !scene.surfaces[scene.triangleSurfaces[t]].shape.twoSided { continue }

            let x0 = (p0.dot(right) - left) * k, y0 = (top - p0.dot(up)) * k
            let x1 = (p1.dot(right) - left) * k, y1 = (top - p1.dot(up)) * k
            let x2 = (p2.dot(right) - left) * k, y2 = (top - p2.dot(up)) * k
            let area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
            guard abs(area) > 1e-12 else { continue }
            let d0 = p0.dot(towards), d1 = p1.dot(towards), d2 = p2.dot(towards)
            let gx: Double = ((d1 - d0) * (y2 - y0) - (d2 - d0) * (y1 - y0)) / area
            let gy: Double = ((d2 - d0) * (x1 - x0) - (d1 - d0) * (x2 - x0)) / area
            slopes[t] = (gx, gy)

            let xs = max(0, Int((min(x0, x1, x2) - 0.5).rounded(.up)))
            let xe = min(width - 1, Int((max(x0, x1, x2) - 0.5).rounded(.down)))
            let ys = max(0, Int((min(y0, y1, y2) - 0.5).rounded(.up)))
            let ye = min(height - 1, Int((max(y0, y1, y2) - 0.5).rounded(.down)))
            guard xs <= xe, ys <= ye else { continue }
            for y in ys...ye {
                let py = Double(y) + 0.5
                for x in xs...xe {
                    let px = Double(x) + 0.5
                    // Barycentrics of the pixel's centre: b1 on p1, b2 on p2.
                    let b1 = ((px - x0) * (y2 - y0) - (x2 - x0) * (py - y0)) / area
                    let b2 = ((x1 - x0) * (py - y0) - (px - x0) * (y1 - y0)) / area
                    let b0 = 1 - b1 - b2
                    guard b0 >= -1e-9, b1 >= -1e-9, b2 >= -1e-9 else { continue }
                    let d = b0 * d0 + b1 * d1 + b2 * d2
                    let i = y * width + x
                    guard d > depth[i] + coplanar else { continue }
                    if let crop {
                        let sx = b0 * p0.x + b1 * p1.x + b2 * p2.x
                        guard crop.contains(sx) else { continue }
                    }
                    depth[i] = d
                    owner[i] = Int32(t)
                    weights[i] = (b1, b2)
                }
            }
        }

        // Shading: once per pixel, for the surface seen there.
        var image = RGBImage(width: width, height: height, fill: style.background)
        var seen = [Int32](repeating: -1, count: width * height)
        let light = (towards * 1.0 + up * 0.6 - right * 0.45).normalized
        for i in 0..<(width * height) where owner[i] >= 0 {
            let t = Int(owner[i])
            let (b1, b2) = weights[i], b0 = 1 - b1 - b2
            let v0 = verts[3 * t], v1 = verts[3 * t + 1], v2 = verts[3 * t + 2]
            let surfaceIndex = scene.triangleSurfaces[t]
            let placed = scene.surfaces[surfaceIndex]
            let back = backFacing[t]
            var n = (v0.normal * b0 + v1.normal * b1 + v2.normal * b2).normalized
            if back { n = -n }
            let fragment = OrthoFragment(part: placed.part, shapeIndex: placed.shapeIndex, shape: placed.shape,
                                         surface: interpolate(v0.surface, v1.surface, v2.surface, b0, b1, b2),
                                         position: v0.position * b0 + v1.position * b1 + v2.position * b2,
                                         normal: n, isBackFace: back)
            var colour = paint(fragment)
            if style.lighting == .flat {
                let lit = 0.32 + 0.68 * max(0, n.dot(light))
                colour = (colour.0 * lit, colour.1 * lit, colour.2 * lit)
            }
            image[i % width, i / width] = (srgb(colour.0), srgb(colour.1), srgb(colour.2))
            seen[i] = Int32(surfaceIndex)
        }

        var result = OrthoImage(image: image, view: view, left: left, top: top, surfaces: seen)
        if style.outlines {
            outline(&result, depth: depth, slope: { i in owner[i] < 0 ? (0, 0) : slopes[Int(owner[i])] })
        }
        if style.annotations { annotate(&result, background: style.background) }
        return result
    }

    static func interpolate(_ a: VisualShape.SurfaceCoordinates, _ b: VisualShape.SurfaceCoordinates,
                            _ c: VisualShape.SurfaceCoordinates, _ wa: Double, _ wb: Double,
                            _ wc: Double) -> VisualShape.SurfaceCoordinates {
        let u: Double = a.u * wa + b.u * wb + c.u * wc
        let v: Double = a.v * wa + b.v * wb + c.v * wc
        let r: Double = a.r * wa + b.r * wb + c.r * wc
        let s: Double = a.s * wa + b.s * wb + c.s * wc
        return VisualShape.SurfaceCoordinates(u: u, v: v, r: r, s: s)
    }

    /// Linear 0...1 to an sRGB byte.
    static func srgb(_ linear: Double) -> UInt8 {
        let c = min(1, max(0, linear))
        let e = c <= 0.003_130_8 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        return UInt8((e * 255).rounded())
    }

    /// Darkens the covered pixel at the silhouette and, of each pair of
    /// neighbours, the farther where the depth jumps: where neither pixel's
    /// triangle, carried on to the other's centre, comes within 2 px (and
    /// 2 cm) of its depth, so that a steep surface seen nearly edge-on is
    /// not a jump. Where two surfaces meet at one depth it darkens the lower
    /// or right one, so a joint is a straight line.
    static func outline(_ result: inout OrthoImage, depth: [Double], slope: (Int) -> (Double, Double)) {
        let w = result.width, h = result.height, tolerance = max(0.02, 2 / result.view.scale)
        var dark = [Bool](repeating: false, count: w * h)
        /// Pixel `j` is (`dx`, `dy`) from pixel `i`.
        func compare(_ i: Int, _ j: Int, _ dx: Double, _ dy: Double) {
            let a = result.surfaces[i], b = result.surfaces[j]
            if a < 0 && b < 0 { return }
            if a < 0 || b < 0 {
                dark[a < 0 ? j : i] = true
                return
            }
            let (gi, gj) = (slope(i), slope(j))
            let fromI: Double = depth[i] + gi.0 * dx + gi.1 * dy - depth[j]
            let fromJ: Double = depth[j] - gj.0 * dx - gj.1 * dy - depth[i]
            if min(abs(fromI), abs(fromJ)) > tolerance {
                dark[depth[i] < depth[j] ? i : j] = true
            } else if a != b {
                dark[j] = true
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                if x + 1 < w { compare(y * w + x, y * w + x + 1, 1, 0) }
                if y + 1 < h { compare(y * w + x, (y + 1) * w + x, 0, 1) }
            }
        }
        for i in 0..<(w * h) where dark[i] {
            let (r, g, b) = result.image[i % w, i / w]
            result.image[i % w, i / w] = (UInt8(Int(r) * 2 / 5), UInt8(Int(g) * 2 / 5), UInt8(Int(b) * 2 / 5))
        }
    }

    // MARK: Annotations

    static let ink: (UInt8, UInt8, UInt8) = (170, 176, 188)

    /// Station ticks on a side view, the Positions' numerals round the edges.
    static func annotate(_ result: inout OrthoImage, background: (UInt8, UInt8, UInt8)) {
        let labels = result.view.positionLabels
        let w = result.width, h = result.height
        if case .side = result.view.direction {
            // Every 100 in STA down the strip.
            let inch = AS506.inch, k = result.view.scale
            let lowest = result.top - Double(h) / k
            var sta = (lowest / inch / 100).rounded(.up) * 100
            while sta * inch <= result.top {
                let y = Int(((result.top - sta * inch) * k).rounded(.down))
                let major = Int(sta.rounded()) % 500 == 0
                let length = major ? 10 : 5
                if (0..<h).contains(y) {
                    for x in (tickStrip - length)..<tickStrip { result.image[x, y] = ink }
                    if major { text(String(Int(sta.rounded())), at: (2, y - 3), into: &result.image) }
                }
                sta += 100
            }
        }
        // A side view's top shows the Position facing the viewer.
        let scale = 2, mid = (h - 5 * scale) / 2
        func roman(_ n: Int?) -> String? { n.map { ["I", "II", "III", "IV"][$0 - 1] } }
        if let s = roman(labels.top ?? labels.facing) {
            text(s, at: ((w - textWidth(s, scale)) / 2, 4), scale: scale, into: &result.image)
        }
        if let s = roman(labels.bottom) {
            text(s, at: ((w - textWidth(s, scale)) / 2, h - 5 * scale - 4), scale: scale, into: &result.image)
        }
        if let s = roman(labels.left) {
            let strip: Int
            if case .side = result.view.direction { strip = tickStrip } else { strip = 0 }
            text(s, at: (strip + 3, mid), scale: scale, into: &result.image)
        }
        if let s = roman(labels.right) { text(s, at: (w - textWidth(s, scale) - 3, mid), scale: scale, into: &result.image) }
    }

    /// 3×5 glyphs, rows from the top, bit 2 the left column.
    static let glyphs: [Character: [UInt8]] = [
        "0": [7, 5, 5, 5, 7], "1": [2, 6, 2, 2, 7], "2": [7, 1, 7, 4, 7], "3": [7, 1, 3, 1, 7],
        "4": [5, 5, 7, 1, 1], "5": [7, 4, 7, 1, 7], "6": [7, 4, 7, 5, 7], "7": [7, 1, 1, 2, 2],
        "8": [7, 5, 7, 5, 7], "9": [7, 5, 7, 1, 7], "-": [0, 0, 7, 0, 0], "I": [7, 2, 2, 2, 7],
        "V": [5, 5, 5, 5, 2],
    ]

    static func textWidth(_ s: String, _ scale: Int) -> Int { max(0, s.count * 4 * scale - scale) }

    /// `s` in the glyph font with its top-left at `at`, clipped to the image.
    static func text(_ s: String, at: (x: Int, y: Int), scale: Int = 1, into image: inout RGBImage) {
        var x0 = at.x
        for ch in s {
            if let rows = glyphs[ch] {
                for (row, bits) in rows.enumerated() {
                    for col in 0..<3 where bits & (4 >> col) != 0 {
                        for dy in 0..<scale {
                            for dx in 0..<scale {
                                let x = x0 + col * scale + dx, y = at.y + row * scale + dy
                                if (0..<image.width).contains(x) && (0..<image.height).contains(y) { image[x, y] = ink }
                            }
                        }
                    }
                }
            }
            x0 += 4 * scale
        }
    }
}
