import Foundation

/// The colours of a multi-function display, as Orbiter's default MFD scheme
/// gives them (Config/MFD/Default.cfg): green for the own vessel, yellow for
/// a target, light grey for the reference body, labels and titles, red for
/// warnings and blue for auxiliary data, each bright and dim.
public enum MFDStyle: Hashable, Sendable {
    case own, ownDim
    case target, targetDim
    case reference, referenceDim
    case warn, warnDim
    case aux, auxDim
    /// The night side on a map: a dark translucent fill.
    case night

    /// sRGB components, 0...1, and opacity.
    public var rgba: (red: Double, green: Double, blue: Double, alpha: Double) {
        func c(_ hex: UInt32, _ alpha: Double = 1) -> (Double, Double, Double, Double) {
            (Double(hex >> 16 & 0xFF) / 255, Double(hex >> 8 & 0xFF) / 255, Double(hex & 0xFF) / 255, alpha)
        }
        // Orbiter's file lists COLORREFs (0xBBGGRR); these are the same colours as 0xRRGGBB.
        switch self {
        case .own: return c(0x00FF00)
        case .ownDim: return c(0x40A040)
        case .target: return c(0xFFFF00)
        case .targetDim: return c(0xA0A000)
        case .reference: return c(0xF0F0F0)
        case .referenceDim: return c(0x909090)
        case .warn: return c(0xFF6060)
        case .warnDim: return c(0xA02020)
        case .aux: return c(0x8080FF)
        case .auxDim: return c(0x0000A0)
        case .night: return c(0x10183A, 0.55)
        }
    }

    /// The dim variant of a bright style (itself if already dim).
    public var dim: MFDStyle {
        switch self {
        case .own: .ownDim
        case .target: .targetDim
        case .reference: .referenceDim
        case .warn: .warnDim
        case .aux: .auxDim
        default: self
        }
    }
}

/// A point on the display: x from the left edge and y down from the top, both
/// in units of the (square) screen's side, so 0...1 spans it.
public struct MFDPoint: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

/// A line of text on the character grid (`MFDPage.columns` x `MFDPage.rows`):
/// starting at `column` of `row`, or ending there with `.trailing`.
public struct MFDText: Hashable, Sendable {
    public enum Alignment: Hashable, Sendable { case leading, trailing, center }

    public var column: Int
    public var row: Int
    public var string: String
    public var style: MFDStyle
    public var alignment: Alignment

    public init(_ column: Int, _ row: Int, _ string: String, _ style: MFDStyle = .own,
                alignment: Alignment = .leading) {
        self.column = column
        self.row = row
        self.string = string
        self.style = style
        self.alignment = alignment
    }

    /// The first column the text covers.
    public var startColumn: Int {
        switch alignment {
        case .leading: column
        case .trailing: column - string.count + 1
        case .center: column - string.count / 2
        }
    }
}

/// Markers drawn at a point.
public enum MFDMarkerKind: Hashable, Sendable {
    /// The vessel: a small square with a cross.
    case vessel
    /// A cross (a target, a predicted point).
    case cross
    /// A small open diamond (apsides, nodes).
    case diamond
    /// A small open circle (the Sun, a site).
    case circle
    /// A larger circle crossed by four ticks that leave its centre clear (a
    /// recovery target).
    case crosshair
}

/// Vector graphics on the display, in screen units (`MFDPoint`).
public enum MFDShape: Hashable, Sendable {
    case polyline([MFDPoint], MFDStyle, dashed: Bool)
    /// A filled polygon.
    case polygon([MFDPoint], MFDStyle)
    case circle(center: MFDPoint, radius: Double, MFDStyle, filled: Bool)
    case marker(MFDPoint, MFDMarkerKind, MFDStyle)
    /// A rectangle's outline (or filled).
    case rect(MFDPoint, MFDPoint, MFDStyle, filled: Bool)
}

/// A rectangle in screen units.
public struct MFDRect: Hashable, Sendable {
    public var min: MFDPoint
    public var max: MFDPoint
    public init(_ min: MFDPoint, _ max: MFDPoint) {
        self.min = min
        self.max = max
    }

    public var width: Double { max.x - min.x }
    public var height: Double { max.y - min.y }
    public var center: MFDPoint { MFDPoint((min.x + max.x) / 2, (min.y + max.y) / 2) }

    public func contains(_ p: MFDPoint) -> Bool {
        p.x >= min.x && p.x <= max.x && p.y >= min.y && p.y <= max.y
    }

    /// The rectangle spanning character rows `rows` and columns `columns`.
    public static func cells(columns: ClosedRange<Int>, rows: ClosedRange<Int>) -> MFDRect {
        MFDRect(MFDPoint(Double(columns.lowerBound) / Double(MFDPage.columns),
                         Double(rows.lowerBound) / Double(MFDPage.rows)),
                MFDPoint(Double(columns.upperBound + 1) / Double(MFDPage.columns),
                         Double(rows.upperBound + 1) / Double(MFDPage.rows)))
    }
}

/// A group of shapes, clipped to a graph area when `clip` is set.
public struct MFDLayer: Hashable, Sendable {
    public var clip: MFDRect?
    public var shapes: [MFDShape]

    public init(clip: MFDRect? = nil, shapes: [MFDShape] = []) {
        self.clip = clip
        self.shapes = shapes
    }
}

/// A side button's label on the screen's edge, beside the button.
public struct MFDButtonLabel: Hashable, Sendable {
    public var label: String
    /// Drawn dim: the button does nothing now.
    public var inactive: Bool
    public init(_ label: String, inactive: Bool = false) {
        self.label = label
        self.inactive = inactive
    }
}

/// What one display shows: a display list of text on a character grid and
/// vector graphics, with the labels of its twelve side buttons (0-5 down the
/// left, 6-11 down the right). Built by the modes as data, so it is tested on
/// Linux and drawn by the app.
public struct MFDPage: Hashable, Sendable {
    /// The character grid: 40 columns by 24 rows over the square screen. The
    /// button labels take columns 0-2 and 37-39 at their rows (`buttonRow`),
    /// so the pages keep their text in columns 4-35, apart from the title row
    /// 0 and the bottom row 23.
    public static let columns = 40
    public static let rows = 24
    /// The columns a page's body may use beside the button labels.
    public static let bodyColumns = 4...35

    /// Shown in the top row at the left, in the reference colour.
    public var title: String
    public var text: [MFDText]
    public var layers: [MFDLayer]
    public var buttons: [MFDButtonLabel?]
    /// The display is switched off: draw nothing.
    public var powered: Bool

    public init(title: String, text: [MFDText] = [], layers: [MFDLayer] = [], buttons: [MFDButtonLabel?] = [],
                powered: Bool = true) {
        self.title = title
        self.text = text
        self.layers = layers
        self.buttons = buttons
        self.powered = powered
    }

    public static let off = MFDPage(title: "", powered: false)

    /// The character row beside which side button `index` (0-5 down either
    /// side) sits: rows 4, 7, ... 19, centred on the screen.
    public static func buttonRow(_ index: Int) -> Int { 4 + 3 * (index % 6) }

    /// The screen point at the centre of character cell (`column`, `row`).
    public static func cell(_ column: Double, _ row: Double) -> MFDPoint {
        MFDPoint((column + 0.5) / Double(columns), (row + 0.5) / Double(rows))
    }

    // MARK: Building

    public mutating func add(_ column: Int, _ row: Int, _ string: String, _ style: MFDStyle = .own,
                             alignment: MFDText.Alignment = .leading) {
        text.append(MFDText(column, row, string, style, alignment: alignment))
    }

    /// A label and its value: the label at `column`, the value ending at
    /// `valueEnd` (right-aligned, as Orbiter lists its numbers).
    public mutating func field(_ column: Int, _ row: Int, _ label: String, _ value: String, valueEnd: Int,
                               _ style: MFDStyle = .own, labelStyle: MFDStyle? = nil) {
        add(column, row, label, labelStyle ?? style)
        add(valueEnd, row, value, style, alignment: .trailing)
    }

    // MARK: Reading (tests, logs)

    /// The text as the grid shows it, one string per row, without the
    /// button labels or graphics; the title is in row 0.
    public var lines: [String] {
        var grid = Array(repeating: Array(repeating: Character(" "), count: Self.columns), count: Self.rows)
        let all = [MFDText(0, 0, title, .reference)] + text
        for t in all where (0..<Self.rows).contains(t.row) {
            for (k, ch) in t.string.enumerated() {
                let c = t.startColumn + k
                if (0..<Self.columns).contains(c) { grid[t.row][c] = ch }
            }
        }
        return grid.map { String($0).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
    }

    /// `lines` with runs of spaces collapsed to one: "PeA 185.0k".
    public var compactLines: [String] {
        lines.map {
            $0.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
    }

    /// Whether some row reads `s` once its spaces are collapsed.
    public func shows(_ s: String) -> Bool { compactLines.contains { $0.contains(s) } }

    /// Every shape, in drawing order.
    public var shapes: [MFDShape] { layers.flatMap(\.shapes) }
}
