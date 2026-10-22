import Foundation

// The Saturn V's markings (as501/502/503/506.csv): regions by station on
// whatever surface lies there, and decals laid out on the outer mould line.

extension Markings {
    /// The Saturn V's outer radius (in) at STA `station`: 198 in (the 33 ft
    /// stages) to the S-II's top, STA 2519, the S-II/S-IVB interstage's cone
    /// from there to 130 in at 2746.5, then the S-IVB's and the IU's 130 in
    /// (BCD; datasheet §5, H).
    public static func saturnRadius(station: Double) -> Double {
        let top = 2_519.0, bottom = 2_746.5, body = 198.0, upper = 130.0
        if station <= top { return body }
        if station >= bottom { return upper }
        return body + (upper - body) * (station - top) / (bottom - top)
    }

    /// A Saturn lettering size, inches: as measured on its own row, else the
    /// mean of the rows of every launch-vehicle table that measured the
    /// same text.
    public struct LetterSize: Equatable {
        public var height: Double
        public var width: Double
        /// From a word's last letter's foot to the next one's top.
        public var wordGap: Double
        /// A letter's top to the next one's, where measured.
        public var pitch: Double?
    }

    /// The mean measured size of `text`'s letters on the Saturn V.
    public static func measuredLetters(_ text: String) -> LetterSize? { saturnLetters[text] }

    static let saturnLetters: [String: LetterSize] = {
        var rows: [String: [MarkingRow]] = [:]
        for (name, table) in tables where name != "csm.csv" {
            for row in table where row.kind == .decal && row.number("letter_h") != nil {
                if let text = row.params["text"] { rows[text, default: []].append(row) }
            }
        }
        return rows.mapValues { rows in
            func mean(_ key: String) -> Double? {
                let values = rows.compactMap { $0.number(key) }
                return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
            }
            return LetterSize(height: mean("letter_h") ?? 0, width: mean("letter_w") ?? 0,
                              wordGap: mean("word_gap") ?? 0, pitch: mean("pitch"))
        }
    }()

    /// A Saturn decal row's content:
    /// - `text` with `letters=upright stacked top to bottom`: the column of
    ///   red capitals, at the row's measured letter size where it has one
    ///   (`letter_h`, `letter_w`, `word_gap`) and the mean of the measured
    ///   rows where not;
    /// - a Position plate (`plate=light with dark numeral`, or a feature
    ///   named "Position ... plate"): a light plate with the Roman numeral of
    ///   the Position it sits on (one row stands for the plates at several
    ///   Positions, `copies`, and 503-131's `text=I` names only the
    ///   first), dark, 0.55 of the plate's height (L: the numerals are not
    ///   legible in the photos);
    /// - `plate=white stencil on ...`: the text in white, 0.8 of the box's
    ///   height, on whatever is painted there;
    /// - `flag`: an EO 10834 flag (`flagContent`);
    /// - anything else: the box in the row's paint.
    static func saturnDecalContent(_ row: MarkingRow, azimuths: AzimuthRange) -> Decal.Content {
        let p = row.params, colour = PaintColour(row.paint)
        if row.paint == .flag { return flagContent(row, radius: saturnRadius(station: row.vehicleStations.lowerBound)) }
        let height = row.vehicleStations.upperBound - row.vehicleStations.lowerBound
        if row.feature.hasPrefix("Position") || p["plate"]?.hasPrefix("light") == true {
            let numeral = positionNumeral(azimuth: azimuths.centre)
            return .lines([numeral], letterHeight: 0.55 * height, lineWidth: nil, ink: .black, background: colour)
        }
        if p["plate"] != nil {
            return .lines([p["text"] ?? ""], letterHeight: 0.8 * height, lineWidth: nil, ink: colour, background: nil)
        }
        if let text = p["text"], p["letters"]?.hasPrefix("upright stacked") == true {
            let measured = measuredLetters(text)
            return .column(text: text, letterHeight: row.number("letter_h") ?? measured?.height ?? 0,
                           letterWidth: row.number("letter_w") ?? measured?.width ?? 0,
                           wordGap: row.number("word_gap") ?? measured?.wordGap ?? 0, ink: colour)
        }
        return .panel(colour)
    }

    /// The Roman numeral of the Position nearest `azimuth` (I at 0°, II at
    /// 90°, III at 180°, IV at 270°).
    public static func positionNumeral(azimuth: Double) -> String {
        let index = Int((AzimuthRange.normalised(azimuth) / 90).rounded()) % 4
        return ["I", "II", "III", "IV"][index]
    }

    /// A flag row's content: `union=upper hoist`, the hoist on the side
    /// `hoist` names, fitted to the flag's measured size where the row gives
    /// it (`hoist_in`; `fly_in`, or `fly_deg` at `radius`), else to its box.
    static func flagContent(_ row: MarkingRow, radius: Double) -> Decal.Content {
        let fly = row.number("fly_in") ?? row.number("fly_deg").map { $0 * radius * Double.pi / 180 }
        return .flag(hoistAtLowAzimuth: row.params["hoist"] != "high azimuth", hoist: row.number("hoist_in"), fly: fly)
    }
}
