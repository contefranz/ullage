import Foundation

/// The lettering's font: block capitals and digits drawn as strokes of one
/// width along lines and circular arcs, enough for "UNITED STATES", "USA",
/// the Position plates' numerals (I, V) and the stage stencils (S-IC-6).
///
/// A glyph fills a box `width` by `height` (in, or any unit): its strokes'
/// centre lines run in the box inset by half a stroke, lines with square
/// ends (so corners are sharp) and arcs with flat ends, and the ink is cut
/// to the box (an A's feet and apex, an N's diagonal). `distance` is the
/// signed distance to the ink's edge, negative inside, which the renderer
/// bakes into its SDF atlas and the tests read directly.
///
/// The Saturn's letters were measured as boxes (VD2's `letter_h`,
/// `letter_w`); their stroke weight was not, and is taken as a sixth of the
/// height (L). The shapes are generic block letters, not traced from any
/// typeface.
public enum StrokeFont {
    /// Stroke width over letter height (L: not measured).
    public static let strokeRatio = 1.0 / 6

    /// The characters it draws (a space is drawn as nothing).
    public static let characters: Set<Character> = Set("UNITEDSAVC-0123456789")

    /// Whether every character of `text` but spaces has a glyph.
    public static func covers(_ text: String) -> Bool {
        text.allSatisfy { $0 == " " || characters.contains($0) }
    }

    /// A glyph's width over the nominal letter width it is set at: an I is
    /// its stroke alone, an E and the digits a little narrower.
    public static func widthFactor(_ c: Character) -> Double {
        switch c {
        case "I": return 0
        case "E": return 0.85
        case "-": return 0.6
        case "0"..."9": return 0.85
        default: return 1
        }
    }

    /// The glyph of `c` in a box `width` (the nominal letter width, which
    /// `widthFactor` scales) by `height`, strokes `stroke` wide
    /// (`strokeRatio` × `height` when nil). Nil for a character it does not
    /// draw.
    public static func glyph(_ c: Character, width: Double, height: Double, stroke: Double? = nil) -> Glyph? {
        guard characters.contains(c) else { return nil }
        let s = stroke ?? strokeRatio * height
        let w = max(widthFactor(c) * width, s)
        return Glyph(character: c, width: w, height: height, stroke: s,
                     strokes: skeleton(c, w: max(w - s, 0), h: max(height - s, 0), stroke: s))
    }

    /// A stroke's centre line.
    public enum Stroke: Equatable {
        /// From `a` to `b`, each end square (extended by half a stroke) or flat.
        case line(a: Point, b: Point, squareA: Bool, squareB: Bool)
        /// About `centre`, from angle `from` to `to` (rad, `from` < `to`,
        /// anticlockwise), flat at both ends.
        case arc(centre: Point, radius: Double, from: Double, to: Double)
    }

    public struct Point: Equatable {
        public var x: Double
        public var y: Double

        public init(_ x: Double, _ y: Double) {
            self.x = x
            self.y = y
        }
    }

    public struct Glyph {
        public var character: Character
        /// The ink's box: x from 0 to `width`, y from 0 (the foot) to `height`.
        public var width: Double
        public var height: Double
        public var stroke: Double
        /// Centre lines, in the box inset by half a stroke (its origin at
        /// the box's (stroke / 2, stroke / 2)).
        public var strokes: [Stroke]

        /// Signed distance from (x, y) in the box's frame to the ink's
        /// edge, negative inside: the strokes' union cut to the box.
        public func distance(x: Double, y: Double) -> Double {
            let hw = stroke / 2, px = x - hw, py = y - hw
            var d = Double.infinity
            for s in strokes {
                switch s {
                case let .line(a, b, squareA, squareB):
                    d = min(d, StrokeFont.lineDistance(px, py, a, b, squareA ? hw : 0, squareB ? hw : 0, hw))
                case let .arc(c, r, from, to):
                    d = min(d, StrokeFont.arcDistance(px, py, c, r, from, to, hw))
                }
            }
            return max(d, StrokeFont.boxDistance(x - width / 2, y - height / 2, width / 2, height / 2))
        }
    }

    // MARK: Distances

    /// Signed distance to an axis-aligned box of half-sizes (hx, hy) from
    /// a point (x, y) relative to its centre.
    static func boxDistance(_ x: Double, _ y: Double, _ hx: Double, _ hy: Double) -> Double {
        let qx = abs(x) - hx, qy = abs(y) - hy
        let outside = (max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)).squareRoot()
        return outside + min(max(qx, qy), 0)
    }

    /// Signed distance to the stroke along a to b, `hw` either side,
    /// extended by `ea` before a and `eb` past b.
    static func lineDistance(_ x: Double, _ y: Double, _ a: Point, _ b: Point, _ ea: Double, _ eb: Double,
                             _ hw: Double) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 1e-12 else { return boxDistance(x - a.x, y - a.y, hw, hw) }
        let ux = dx / length, uy = dy / length
        let mid = (length + eb - ea) / 2
        let cx = a.x + ux * mid, cy = a.y + uy * mid
        let along = (x - cx) * ux + (y - cy) * uy
        let across = -(x - cx) * uy + (y - cy) * ux
        return boxDistance(along, across, (length + ea + eb) / 2, hw)
    }

    /// Signed distance to the arc's stroke, `hw` either side, flat-ended.
    static func arcDistance(_ x: Double, _ y: Double, _ c: Point, _ r: Double, _ from: Double, _ to: Double,
                            _ hw: Double) -> Double {
        let dx = x - c.x, dy = y - c.y
        let rho = (dx * dx + dy * dy).squareRoot()
        var phi = atan2(dy, dx)
        let turn = 2 * Double.pi
        phi -= turn * ((phi - from) / turn).rounded(.down)
        if phi <= to { return abs(rho - r) - hw }
        // Off the arc's span: the nearest point is on an end.
        func end(_ angle: Double) -> Double {
            let ex = cos(angle), ey = sin(angle)
            let a = Point(c.x + ex * (r - hw), c.y + ey * (r - hw)), b = Point(c.x + ex * (r + hw), c.y + ey * (r + hw))
            return segmentDistance(x, y, a, b)
        }
        return min(end(from), end(to))
    }

    static func segmentDistance(_ x: Double, _ y: Double, _ a: Point, _ b: Point) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let l2 = dx * dx + dy * dy
        let t = l2 > 0 ? max(0, min(1, ((x - a.x) * dx + (y - a.y) * dy) / l2)) : 0
        let ex = x - a.x - t * dx, ey = y - a.y - t * dy
        return (ex * ex + ey * ey).squareRoot()
    }

    // MARK: Glyphs

    /// The centre lines of `c` in a `w` by `h` box.
    static func skeleton(_ c: Character, w: Double, h: Double, stroke s: Double) -> [Stroke] {
        var b = Builder()
        switch c {
        case "U":
            let r = min(w / 2, h)
            b.line(0, h, 0, r, square: (true, false))
            b.arc(r, r, r, 180, 360)
            b.line(w, r, w, h, square: (false, true))
        case "N":
            b.line(0, 0, 0, h)
            b.line(w, 0, w, h)
            b.line(0, h, w, 0)
        case "I":
            b.line(0, 0, 0, h)
        case "T":
            b.line(0, h, w, h)
            b.line(w / 2, h, w / 2, 0)
        case "E":
            b.line(0, 0, 0, h)
            b.line(0, h, w, h)
            b.line(0, 0, w, 0)
            b.line(0, h / 2, 0.9 * w, h / 2)
        case "D":
            let r = min(0.45 * w, h / 2)
            b.line(0, 0, 0, h)
            b.line(0, h, w - r, h, square: (true, false))
            b.arc(w - r, h - r, r, 0, 90)
            b.line(w, h - r, w, r, square: (false, false))
            b.arc(w - r, r, r, 270, 360)
            b.line(w - r, 0, 0, 0, square: (false, true))
        case "S":
            let r = min(h / 4, w / 2)
            b.arc(w - r, h - r, r, 0, 90)
            b.line(w - r, h, r, h, square: (false, false))
            b.arc(r, h - r, r, 90, 180)
            b.line(0, h - r, 0, h / 2 + r, square: (false, false))
            b.arc(r, h / 2 + r, r, 180, 270)
            b.line(r, h / 2, w - r, h / 2, square: (false, false))
            b.arc(w - r, h / 2 - r, r, 0, 90)
            b.line(w, h / 2 - r, w, r, square: (false, false))
            b.arc(w - r, r, r, 270, 360)
            b.line(w - r, 0, r, 0, square: (false, false))
            b.arc(r, r, r, 180, 270)
        case "A":
            let bar = 0.3 * h, inset = w / 2 * bar / h
            b.line(0, 0, w / 2, h)
            b.line(w / 2, h, w, 0)
            b.line(inset, bar, w - inset, bar, square: (false, false))
        case "V":
            b.line(0, h, w / 2, 0)
            b.line(w / 2, 0, w, h)
        case "C":
            let r = min(0.45 * w, h / 2)
            b.line(w, h, r, h, square: (true, false))
            b.arc(r, h - r, r, 90, 180)
            b.line(0, h - r, 0, r, square: (false, false))
            b.arc(r, r, r, 180, 270)
            b.line(r, 0, w, 0, square: (false, true))
        case "-":
            b.line(0, h / 2, w, h / 2)
        case "0":
            b.loop(0, 0, w, h, r: 0.45 * min(w, h))
        case "1":
            b.line(0.6 * w, 0, 0.6 * w, h)
            b.line(0.6 * w, h, 0.1 * w, 0.75 * h, square: (true, false))
        case "2":
            let r = min(w / 2, h / 2)
            let a = -45.0 * Double.pi / 180
            b.arc(r, h - r, r, -45, 180)
            b.line(r + r * cos(a), h - r + r * sin(a), 0, 0, square: (false, true))
            b.line(0, 0, w, 0)
        case "3":
            let r = min(w / 2, h / 4), x = w - r
            b.line(0, h, x, h, square: (true, false))
            b.arc(x, h - r, r, 0, 90)
            b.line(w, h - r, w, h / 2 + r, square: (false, false))
            b.arc(x, h / 2 + r, r, 270, 360)
            b.line(x, h / 2, 0.3 * w, h / 2, square: (false, true))
            b.arc(x, h / 2 - r, r, 0, 90)
            b.line(w, h / 2 - r, w, r, square: (false, false))
            b.arc(x, r, r, 270, 360)
            b.line(x, 0, 0, 0, square: (false, true))
        case "4":
            b.line(0.7 * w, h, 0, 0.3 * h, square: (true, false))
            b.line(0, 0.3 * h, w, 0.3 * h)
            b.line(0.7 * w, h, 0.7 * w, 0)
        case "5":
            let top = 0.55 * h, r = min(w / 2, top / 2)
            b.line(w, h, 0, h)
            b.line(0, h, 0, top, square: (true, false))
            b.line(0, top, w - r, top, square: (true, false))
            b.arc(w - r, top - r, r, 0, 90)
            b.line(w, top - r, w, r, square: (false, false))
            b.arc(w - r, r, r, 270, 360)
            b.line(w - r, 0, 0, 0, square: (false, true))
        case "6":
            let bowl = 0.55 * h, r = min(w / 2, bowl / 2)
            b.loop(0, 0, w, bowl, r: r)
            b.line(0, r, 0, h - r, square: (false, false))
            b.arc(r, h - r, r, 90, 180)
            b.line(r, h, w, h, square: (false, true))
        case "7":
            b.line(0, h, w, h)
            b.line(w, h, 0.3 * w, 0)
        case "8":
            b.loop(0, 0, w, h / 2, r: 0.45 * min(w, h / 2))
            b.loop(0.08 * w, h / 2, 0.92 * w, h, r: 0.45 * min(0.84 * w, h / 2))
        case "9":
            let bowl = 0.55 * h, r = min(w / 2, bowl / 2)
            b.loop(0, h - bowl, w, h, r: r)
            b.line(w, h - r, w, r, square: (false, false))
            b.arc(w - r, r, r, 270, 360)
            b.line(w - r, 0, 0, 0, square: (false, true))
        default:
            break
        }
        return b.strokes
    }

    /// Collects strokes; angles in degrees.
    struct Builder {
        var strokes: [Stroke] = []

        mutating func line(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, square: (Bool, Bool) = (true, true)) {
            let dx = x1 - x0, dy = y1 - y0
            guard dx * dx + dy * dy > 1e-18 else { return }
            strokes.append(.line(a: Point(x0, y0), b: Point(x1, y1), squareA: square.0, squareB: square.1))
        }

        mutating func arc(_ cx: Double, _ cy: Double, _ r: Double, _ from: Double, _ to: Double) {
            guard r > 1e-9 else { return }
            let deg = Double.pi / 180
            strokes.append(.arc(centre: Point(cx, cy), radius: r, from: from * deg, to: to * deg))
        }

        /// A closed round-cornered rectangle from (x0, y0) to (x1, y1).
        mutating func loop(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, r: Double) {
            let flat = (false, false)
            line(x0 + r, y0, x1 - r, y0, square: flat)
            arc(x1 - r, y0 + r, r, 270, 360)
            line(x1, y0 + r, x1, y1 - r, square: flat)
            arc(x1 - r, y1 - r, r, 0, 90)
            line(x1 - r, y1, x0 + r, y1, square: flat)
            arc(x0 + r, y1 - r, r, 90, 180)
            line(x0, y1 - r, x0, y0 + r, square: flat)
            arc(x0 + r, y0 + r, r, 180, 270)
        }
    }
}
