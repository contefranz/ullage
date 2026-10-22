import Foundation

/// A decal row placed on its element's surface: lettering, a flag, a panel
/// or a plate, inside the row's box (a station range by an azimuth range).
///
/// Decal coordinates are in inches on the surface: x the arc length at
/// `radius` from the box's low-azimuth edge (to the right, seen from outside
/// with the nose up), y the station above the box's foot. The box is `width`
/// by `height`; `bounds` grows it where the lettering or the flag, laid out
/// to their own proportions, reach beyond it. The renderer bakes `colour`
/// and `distance` over `bounds` into its atlas.
public struct Decal {
    /// What the row asks for, before it is laid out in the box.
    public enum Content: Equatable {
        /// Upright capitals stacked top to bottom on the box's middle
        /// azimuth, the first letter's top at the box's top and the last
        /// one's foot at its foot (the Saturn V's lettering): the pitch
        /// between letters is what fills the box.
        case column(text: String, letterHeight: Double, letterWidth: Double, wordGap: Double, ink: PaintColour)
        /// Lines read left to right, the first at the box's top and the
        /// last at its foot (one line: centred), each centred across the
        /// box in cells of `lineWidth` over its longest line's letters
        /// (0.45 of the letter height when nil); on `background` when given.
        case lines([String], letterHeight: Double, lineWidth: Double?, ink: PaintColour, background: PaintColour?)
        /// An Executive Order 10834 flag, union at the upper hoist, the
        /// hoist on the low-azimuth side (the left seen from outside) or
        /// the high, fitted to its measured hoist and fly (in; the box's
        /// height and width where not measured apart).
        case flag(hoistAtLowAzimuth: Bool, hoist: Double?, fly: Double?)
        /// The box filled with one paint.
        case panel(PaintColour)
    }

    /// A glyph of the lettering, its box's lower-left corner at (x, y).
    public struct PlacedGlyph {
        public var glyph: StrokeFont.Glyph
        public var x: Double
        public var y: Double

        public func distance(x px: Double, y py: Double) -> Double { glyph.distance(x: px - x, y: py - y) }
    }

    /// A flag's rectangle: its hoist edge at x = `hoistX`, its foot at `y`,
    /// `hoist` tall and `USFlag.fly` × `hoist` long, away from the hoist
    /// edge towards higher x when `hoistAtLeft`, else towards lower x.
    public struct FlagPlacement: Equatable {
        public var hoistX: Double
        public var y: Double
        public var hoist: Double
        public var hoistAtLeft: Bool

        public var fly: Double { USFlag.fly * hoist }
        public var xRange: ClosedRange<Double> { hoistAtLeft ? hoistX...(hoistX + fly) : (hoistX - fly)...hoistX }

        /// The flag's colour at decal point (x, y), nil off the flag.
        public func colour(x: Double, y py: Double) -> PaintColour? {
            let along = hoistAtLeft ? x - hoistX : hoistX - x
            let down = y + hoist - py
            guard along >= 0, along <= fly, down >= 0, down <= hoist else { return nil }
            return USFlag.colour(x: along / hoist, y: down / hoist)
        }
    }

    public var id: String
    public var element: PaintElement
    /// The box: STA (in) and azimuths (degrees).
    public var stations: ClosedRange<Double>
    public var azimuths: AzimuthRange
    /// The surface radius (in) the box's azimuths are measured at.
    public var radius: Double
    public var paint: PaintName
    public var params: [String: String]
    public var grade: MarkingGrade
    public var content: Content

    /// The box's size (in).
    public var width: Double { azimuths.width * radius * Double.pi / 180 }
    public var height: Double { stations.upperBound - stations.lowerBound }

    /// The laid-out lettering, its colour, and the background.
    public private(set) var glyphs: [PlacedGlyph] = []
    public private(set) var ink: PaintColour?
    public private(set) var background: PaintColour?
    public private(set) var flag: FlagPlacement?
    /// For a column: the pitch (in, a letter's top to the next one's) that
    /// fills the box.
    public private(set) var pitch: Double?
    /// The extent (decal coordinates) that holds the box, the lettering
    /// and the flag.
    public private(set) var bounds: (x: ClosedRange<Double>, y: ClosedRange<Double>) = (0...0, 0...0)

    public init(id: String, element: PaintElement, stations: ClosedRange<Double>, azimuths: AzimuthRange, radius: Double,
                paint: PaintName, params: [String: String] = [:], grade: MarkingGrade, content: Content) {
        self.id = id
        self.element = element
        self.stations = stations
        self.azimuths = azimuths
        self.radius = radius
        self.paint = paint
        self.params = params
        self.grade = grade
        self.content = content
        layOut()
    }

    /// One copy (`azimuths`) of a decal row.
    init(row: MarkingRow, element: PaintElement, azimuths: AzimuthRange, radius: Double, content: Content) {
        self.init(id: row.id, element: element, stations: row.vehicleStations, azimuths: azimuths, radius: radius,
                  paint: row.paint, params: row.params, grade: row.grade, content: content)
    }

    // MARK: Evaluation

    /// Decal coordinates of STA `station` and `azimuth` (degrees), the
    /// azimuth taken within half a turn of the box's middle.
    public func local(station: Double, azimuth: Double) -> (x: Double, y: Double) {
        let fromMiddle = AzimuthRange.normalised(azimuth - azimuths.centre + 180) - 180
        let x = (fromMiddle + azimuths.width / 2) * radius * Double.pi / 180
        return (x, station - stations.lowerBound)
    }

    /// What the decal shows at STA `station` and `azimuth`; nil where it
    /// is clear.
    public func colour(station: Double, azimuth: Double) -> PaintColour? {
        let p = local(station: station, azimuth: azimuth)
        return colour(x: p.x, y: p.y)
    }

    /// What the decal shows at decal point (x, y); nil where it is clear.
    public func colour(x: Double, y: Double) -> PaintColour? {
        guard bounds.x.contains(x), bounds.y.contains(y) else { return nil }
        if let flag, let c = flag.colour(x: x, y: y) { return c }
        if let ink, distance(x: x, y: y) <= 0 { return ink }
        if let background, (0...width).contains(x), (0...height).contains(y) { return background }
        return nil
    }

    /// Signed distance (in) from decal point (x, y) to the lettering's
    /// edge, negative inside a stroke; infinity without lettering.
    public func distance(x: Double, y: Double) -> Double {
        var d = Double.infinity
        for g in glyphs {
            // Ink lies in its glyph's box: the box's distance bounds the
            // ink's from below, and is all that matters past the nearest.
            let bx = max(g.x - x, 0, x - g.x - g.glyph.width), by = max(g.y - y, 0, y - g.y - g.glyph.height)
            let toBox = (bx * bx + by * by).squareRoot()
            if toBox < d { d = min(d, g.distance(x: x, y: y)) }
        }
        return d
    }

    // MARK: Layout

    private mutating func layOut() {
        let w = width, h = height
        var xs = 0...w, ys = 0...h
        switch content {
        case let .column(text, letterHeight, letterWidth, wordGap, colour):
            let layout = Self.column(text, boxWidth: w, boxHeight: h, letterHeight: letterHeight,
                                     letterWidth: letterWidth, wordGap: wordGap)
            glyphs = layout.glyphs
            pitch = layout.pitch
            ink = colour
        case let .lines(lines, letterHeight, lineWidth, colour, fill):
            glyphs = Self.lines(lines, boxWidth: w, boxHeight: h, letterHeight: letterHeight, lineWidth: lineWidth)
            ink = colour
            background = fill
        case let .flag(hoistAtLowAzimuth, hoist, fly):
            let f = Self.flag(boxWidth: w, boxHeight: h, hoist: hoist ?? h, fly: fly ?? w, hoistAtLeft: hoistAtLowAzimuth)
            flag = f
            xs = min(xs.lowerBound, f.xRange.lowerBound)...max(xs.upperBound, f.xRange.upperBound)
            ys = min(0, f.y)...max(h, f.y + f.hoist)
        case let .panel(colour):
            background = colour
        }
        for g in glyphs {
            xs = min(xs.lowerBound, g.x)...max(xs.upperBound, g.x + g.glyph.width)
            ys = min(ys.lowerBound, g.y)...max(ys.upperBound, g.y + g.glyph.height)
        }
        bounds = (xs, ys)
    }

    /// The Saturn's column: `text`'s letters `letterHeight` tall and
    /// `letterWidth` wide (an I its stroke), stacked on x = `boxWidth` / 2,
    /// `wordGap` between a word's last letter's foot and the next one's
    /// top, at the pitch that puts the first top at `boxHeight` and the
    /// last foot at 0.
    public static func column(_ text: String, boxWidth: Double, boxHeight: Double, letterHeight: Double,
                              letterWidth: Double, wordGap: Double) -> (glyphs: [PlacedGlyph], pitch: Double) {
        let words = text.split(separator: " ").map(Array.init)
        let steps = words.reduce(0) { $0 + max($1.count - 1, 0) }
        let fixed = Double(words.count) * letterHeight + Double(max(words.count - 1, 0)) * wordGap
        let pitch = steps > 0 ? (boxHeight - fixed) / Double(steps) : 0
        var glyphs: [PlacedGlyph] = []
        var top = boxHeight
        for (i, word) in words.enumerated() {
            if i > 0 { top -= letterHeight + wordGap - pitch }
            for c in word {
                if let g = StrokeFont.glyph(c, width: letterWidth, height: letterHeight) {
                    glyphs.append(PlacedGlyph(glyph: g, x: boxWidth / 2 - g.width / 2, y: top - letterHeight))
                }
                top -= pitch
            }
        }
        return (glyphs, pitch)
    }

    /// Lines of letters `letterHeight` tall in cells of `lineWidth` over
    /// the longest line's count (0.45 `letterHeight` when nil), each glyph
    /// 0.8 of its cell wide and centred in it, the lines centred across the
    /// box, the first at its top and the last at its foot (one: centred).
    public static func lines(_ lines: [String], boxWidth: Double, boxHeight: Double, letterHeight: Double,
                             lineWidth: Double?) -> [PlacedGlyph] {
        let longest = lines.map(\.count).max() ?? 0
        guard longest > 0 else { return [] }
        let cell = lineWidth.map { $0 / Double(longest) } ?? 0.45 * letterHeight
        let gap = lines.count > 1 ? (boxHeight - Double(lines.count) * letterHeight) / Double(lines.count - 1) : 0
        var glyphs: [PlacedGlyph] = []
        for (i, line) in lines.enumerated() {
            let foot = lines.count > 1 ? boxHeight - letterHeight - Double(i) * (letterHeight + gap)
                                       : (boxHeight - letterHeight) / 2
            let start = boxWidth / 2 - Double(line.count) * cell / 2
            for (j, c) in line.enumerated() {
                guard let g = StrokeFont.glyph(c, width: 0.8 * cell, height: letterHeight) else { continue }
                glyphs.append(PlacedGlyph(glyph: g, x: start + (Double(j) + 0.5) * cell - g.width / 2, y: foot))
            }
        }
        return glyphs
    }

    /// A flag of EO 10834's proportions fitted to a measured `hoist` and
    /// `fly`: its hoist their geometric mean once the fly is divided by the
    /// ratio (so the two measurements are missed by the same factor), its
    /// hoist edge on the box's edge, centred on the box's height.
    public static func flag(boxWidth: Double, boxHeight: Double, hoist measuredHoist: Double, fly measuredFly: Double,
                            hoistAtLeft: Bool) -> FlagPlacement {
        let hoist = (measuredHoist * measuredFly / USFlag.fly).squareRoot()
        return FlagPlacement(hoistX: hoistAtLeft ? 0 : boxWidth, y: (boxHeight - hoist) / 2, hoist: hoist,
                             hoistAtLeft: hoistAtLeft)
    }
}
