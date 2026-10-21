import Foundation
import OrbitCore

// Track VM1's paint evaluator: what VD2's tables (docs/data/markings, bundled
// in Resources/markings) paint at a point of the Saturn V or the Apollo
// spacecraft. A point is named by its element, its vehicle station (STA, in)
// and its azimuth (degrees from Position I towards Position II), as the
// tables name them; `PaintCoordinates` turns a vertex's surface coordinates
// or construction-frame position into those. Rows apply in the tables'
// paint order, the last one that covers the point winning, decals over
// regions, and every answer carries the row that gave it and its grade.

/// A row's grade, as the datasheets grade them (docs/data/markings/README.md):
/// H two registered photos or a primary document with a photo, M one
/// registered photo or a sourced joint, L symmetry, analogy or a secondary
/// source. `H < M < L` orders them from the best.
public enum MarkingGrade: String, Comparable, CaseIterable {
    case high = "H", medium = "M", low = "L"

    public static func < (a: MarkingGrade, b: MarkingGrade) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// A paint or finish as the tables' `paint` column names it.
public enum PaintName: String, CaseIterable {
    case white, black
    /// The Saturn V's lettering.
    case red
    /// Inside an Executive Order 10834 flag (`USFlag` gives its colours).
    case flag
    /// Bare metal.
    case aluminium
    /// Aluminised Kapton tape (the CM).
    case kapton
    case zincChromate = "zinc chromate"
    case darkBrown = "dark brown"
}

/// What shows at a point: a paint, or one of the flag's three colours.
/// `linear` is a flat display albedo (linear RGB) for the gallery and the
/// renderer's fallback, a stand-in until VM2's material table gives the
/// paints' reflectance from their measured absorptance (L throughout).
public enum PaintColour: String, CaseIterable {
    case white, black, red, flagRed, flagWhite, flagBlue, aluminium, kapton, zincChromate, darkBrown
    /// Not a paint: the frost overlay's colour (`Frost`).
    case frost

    /// The colour the paint `name` shows, a flag's field aside (its red).
    public init(_ name: PaintName) {
        switch name {
        case .white: self = .white
        case .black: self = .black
        case .red: self = .red
        case .flag: self = .flagRed
        case .aluminium: self = .aluminium
        case .kapton: self = .kapton
        case .zincChromate: self = .zincChromate
        case .darkBrown: self = .darkBrown
        }
    }

    /// The paint table's name for this colour (the flag's three are `flag`).
    public var paint: PaintName? {
        switch self {
        case .white: return .white
        case .black: return .black
        case .red: return .red
        case .flagRed, .flagWhite, .flagBlue: return .flag
        case .aluminium: return .aluminium
        case .kapton: return .kapton
        case .zincChromate: return .zincChromate
        case .darkBrown: return .darkBrown
        case .frost: return nil
        }
    }

    /// Flat display albedo, linear RGB. The flag's red and blue (also the
    /// lettering's red) are Old Glory Red and Old Glory Blue (Standard
    /// Color Card of America Nos. 70180 and 70075, Federal Specification
    /// DDD-F-416E) at the sRGB the State Department's Bureau of
    /// Educational and Cultural Affairs gives them (ECA Design Guidelines,
    /// January 2017: PMS 193 C, #B31942; PMS 282 C, #0A3161); the rest are
    /// estimates (L).
    public var linear: RenderScene.RGB {
        switch self {
        case .white, .flagWhite: return RenderScene.RGB(0.80, 0.80, 0.78)
        case .black: return RenderScene.RGB(0.04, 0.04, 0.04)
        case .red, .flagRed: return Self.fromSRGB(0xB3, 0x19, 0x42)
        case .flagBlue: return Self.fromSRGB(0x0A, 0x31, 0x61)
        case .aluminium: return RenderScene.RGB(0.70, 0.71, 0.72)
        case .kapton: return RenderScene.RGB(0.85, 0.85, 0.87)
        case .zincChromate: return Self.fromSRGB(0xE3, 0xD2, 0x6E)
        case .darkBrown: return Self.fromSRGB(0x46, 0x2D, 0x1E)
        case .frost: return RenderScene.RGB(0.85, 0.87, 0.90)
        }
    }

    /// Linear RGB of an 8-bit sRGB colour (IEC 61966-2-1).
    public static func fromSRGB(_ r: Int, _ g: Int, _ b: Int) -> RenderScene.RGB {
        func channel(_ c: Int) -> Float {
            let x = Double(c) / 255
            let l = x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
            return Float(l)
        }
        return RenderScene.RGB(channel(r), channel(g), channel(b))
    }
}

/// What a table row paints. On the Saturn V a row applies by station to
/// whatever surface lies there, so every launch-vehicle shape is one
/// element; on the spacecraft a row applies to its own element's shapes,
/// since the BPC and the SLA's panels cover other parts at the same
/// stations (`PaintElement.of(part:shape:variant:)` picks a shape's).
public enum PaintElement: String, CaseIterable {
    case launchVehicle = "Saturn V"
    case sla = "SLA"
    case ltaB = "LTA-B"
    case sm = "SM"
    case cm = "CM"
    case bpc = "BPC"
    case les = "LES"
}

/// The side of a shell a row paints: its outer surface, or (`face=inner`)
/// the inner skin seen through an open end, such as an interstage's.
public enum PaintFace: Equatable {
    case outer, inner
}

/// An azimuth range in degrees from Position I towards Position II; `from`
/// above `to` wraps through 0 (357 to 3 is 6°), and 0 to 360 is all round.
public struct AzimuthRange: Equatable {
    public var from: Double
    public var to: Double

    public init(_ from: Double, _ to: Double) {
        self.from = from
        self.to = to
    }

    /// `a` (degrees) in 0..<360.
    public static func normalised(_ a: Double) -> Double {
        let r = a.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// Its extent, degrees.
    public var width: Double {
        if to - from >= 360 { return 360 }
        let w = Self.normalised(to - from)
        return w == 0 && to != from ? 360 : w
    }

    /// Its middle, degrees in 0..<360.
    public var centre: Double { Self.normalised(from + width / 2) }

    public func contains(_ azimuth: Double) -> Bool {
        if width >= 360 { return true }
        return Self.normalised(azimuth - from) <= width
    }

    /// Degrees from `from` to `azimuth`, anticlockwise seen from the nose
    /// (to the right seen from outside), in 0..<360.
    public func offset(of azimuth: Double) -> Double { Self.normalised(azimuth - from) }
}

/// One row of a markings table, as written, its stations in the row's own
/// frame (`frame`) and `vehicleStations` in STA.
public struct MarkingRow: Equatable {
    public enum Kind: String {
        case base, region, decal, probe
    }

    public enum Frame: String {
        /// Saturn V vehicle stations, in.
        case sta = "STA"
        /// Apollo spacecraft stations, in: STA = Xa + 2756.56.
        case xa = "Xa"
    }

    /// STA = Xa + 2756.56 in: the SLA base, Xa 502, is the IU top, STA
    /// 3258.56 (AS-501 FER Fig. B-1; AOH Fig. 1-1; `AS506.apolloStationOffset`), H.
    public static let apolloStationOffset = 2_756.56

    public var id: String
    public var vehicle: String
    public var element: String
    public var kind: Kind
    public var feature: String
    public var frame: Frame
    public var stations: ClosedRange<Double>
    public var azimuths: AzimuthRange
    public var paint: PaintName
    /// `params`'s `key=value` pairs.
    public var params: [String: String]
    public var photos: [String]
    public var sources: String
    public var grade: MarkingGrade
    public var note: String

    /// The row's stations in STA, in.
    public var vehicleStations: ClosedRange<Double> {
        let offset = frame == .xa ? Self.apolloStationOffset : 0
        return (stations.lowerBound + offset)...(stations.upperBound + offset)
    }

    public var face: PaintFace { params["face"] == "inner" ? .inner : .outer }

    /// Each copy's azimuths: `copies=from-to/from-to/...`, else the row's own.
    public var copies: [AzimuthRange] {
        guard let list = params["copies"] else { return [azimuths] }
        return list.split(separator: "/").compactMap { item -> AzimuthRange? in
            let ends = item.split(separator: "-").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            return ends.count == 2 ? AzimuthRange(ends[0], ends[1]) : nil
        }
    }

    /// A parameter as a number.
    public func number(_ key: String) -> Double? { params[key].flatMap { Double($0) } }
}

/// The markings tables' CSV form: `#` comment lines, then a header line and
/// one row per line, fields in double quotes where they hold commas ("" is a
/// quote).
public enum MarkingTable {
    public struct ParseError: Error, CustomStringConvertible {
        public var description: String
    }

    /// The rows of `text`, in its order.
    public static func rows(_ text: String) throws -> [MarkingRow] {
        var header: [String]?
        var rows: [MarkingRow] = []
        for record in records(text) {
            guard let columns = header else {
                header = record
                continue
            }
            guard record.count == columns.count else {
                throw ParseError(description: "\(record.first ?? "?"): \(record.count) fields, \(columns.count) expected")
            }
            rows.append(try row(Dictionary(uniqueKeysWithValues: zip(columns, record))))
        }
        return rows
    }

    /// The bundled table `name` (e.g. "as503.csv").
    public static func bundled(_ name: String) throws -> [MarkingRow] {
        guard let url = bundledURL(name) else {
            throw ParseError(description: "Resources/markings/\(name) is not bundled")
        }
        return try rows(String(contentsOf: url, encoding: .utf8))
    }

    /// Where the bundled table `name` is.
    public static func bundledURL(_ name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources/markings")
    }

    /// The bundled tables' file names.
    public static let bundledNames = ["as501.csv", "as502.csv", "as503.csv", "as506.csv", "csm.csv"]

    /// The fields of each line that is not a comment.
    static func records(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = [], field = "", quoted = false, atLineStart = true, comment = false
        var scalars = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil
        func endRecord() {
            record.append(field)
            if !(record.count == 1 && record[0].isEmpty) { records.append(record) }
            record = []
            field = ""
        }
        while let c = pending ?? scalars.next() {
            pending = nil
            if comment {
                if c == "\n" { comment = false; atLineStart = true }
                continue
            }
            if atLineStart && c == "#" && !quoted {
                comment = true
                continue
            }
            atLineStart = false
            if quoted {
                if c == "\"" {
                    let next = scalars.next()
                    if next == "\"" {
                        field.unicodeScalars.append("\"")
                    } else {
                        quoted = false
                        pending = next
                    }
                } else {
                    field.unicodeScalars.append(c)
                }
            } else if c == "\"" {
                quoted = true
            } else if c == "," {
                record.append(field)
                field = ""
            } else if c == "\n" {
                endRecord()
                atLineStart = true
            } else if c != "\r" {
                field.unicodeScalars.append(c)
            }
        }
        if !field.isEmpty || !record.isEmpty { endRecord() }
        return records
    }

    static func row(_ cell: [String: String]) throws -> MarkingRow {
        let id = cell["id"] ?? "?"
        func text(_ key: String) -> String { cell[key] ?? "" }
        func number(_ key: String) throws -> Double {
            guard let x = Double(text(key).trimmingCharacters(in: .whitespaces)) else {
                throw ParseError(description: "\(id): \(key) '\(text(key))' is not a number")
            }
            return x
        }
        func value<T: RawRepresentable>(_ key: String, _ type: T.Type) throws -> T where T.RawValue == String {
            guard let v = T(rawValue: text(key)) else {
                throw ParseError(description: "\(id): \(key) '\(text(key))' is not known")
            }
            return v
        }
        var params: [String: String] = [:]
        for pair in text("params").split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            params[kv[0]] = kv.count > 1 ? kv[1] : ""
        }
        let from = try number("sta_from"), to = try number("sta_to")
        guard from <= to else { throw ParseError(description: "\(id): sta_from above sta_to") }
        return MarkingRow(id: id, vehicle: text("vehicle"), element: text("element"), kind: try value("kind", MarkingRow.Kind.self),
                          feature: text("feature"), frame: try value("frame", MarkingRow.Frame.self), stations: from...to,
                          azimuths: AzimuthRange(try number("az_from"), try number("az_to")),
                          paint: try value("paint", PaintName.self), params: params,
                          photos: text("photos").split(separator: ";").map(String.init), sources: text("sources"),
                          grade: try value("grade", MarkingGrade.self), note: text("note"))
    }
}

/// A patch of paint: a station range by an azimuth range of one element's
/// surface (a `base` or `region` row; one per copy).
public struct PaintRegion: Equatable {
    public var id: String
    public var element: PaintElement
    /// STA, in.
    public var stations: ClosedRange<Double>
    public var azimuths: AzimuthRange
    public var face: PaintFace
    public var paint: PaintName
    public var params: [String: String]
    public var grade: MarkingGrade

    public func contains(station: Double, azimuth: Double) -> Bool {
        stations.contains(station) && azimuths.contains(azimuth)
    }
}

/// A probe row: the paint expected at a point (`orbitsnap --verify` and the
/// tests compare the evaluator with it).
public struct PaintProbe: Equatable {
    public var id: String
    public var vehicle: String
    public var element: PaintElement
    /// STA, in.
    public var station: Double
    public var azimuth: Double
    public var expected: PaintName
    public var grade: MarkingGrade
}

/// The paint at a point.
public struct PaintSample: Equatable {
    /// As the table names it (`flag` anywhere inside a flag).
    public var paint: PaintName
    /// What shows there: the paint's colour, or the flag's own.
    public var colour: PaintColour
    /// The row that painted it, and its grade.
    public var row: String
    public var grade: MarkingGrade
    /// The row's finish and other parameters (`finish`, `tone`, ...).
    public var params: [String: String]
    /// Whether a decal (lettering, flag, plate, panel) painted it.
    public var isDecal: Bool
}

/// One vehicle's (or one flight's) paint: its regions and decals in paint
/// order, and its probes.
public struct PaintScheme {
    public var vehicles: [String]
    public var regions: [PaintRegion]
    public var decals: [Decal]
    public var probes: [PaintProbe]

    public init(vehicles: [String], regions: [PaintRegion], decals: [Decal], probes: [PaintProbe]) {
        self.vehicles = vehicles
        self.regions = regions
        self.decals = decals
        self.probes = probes
    }

    /// The schemes' rows together, in order: their elements keep them apart.
    public init(merging schemes: [PaintScheme]) {
        self.init(vehicles: schemes.flatMap(\.vehicles), regions: schemes.flatMap(\.regions),
                  decals: schemes.flatMap(\.decals), probes: schemes.flatMap(\.probes))
    }

    /// The paint at STA `station` (in) and `azimuth` (degrees) on
    /// `element`'s `face`: the last region that covers the point, then the
    /// last decal that inks it. Nil where no row does (the shape's material
    /// shows).
    public func sample(_ element: PaintElement, station: Double, azimuth: Double,
                       face: PaintFace = .outer) -> PaintSample? {
        let az = AzimuthRange.normalised(azimuth)
        var result: PaintSample?
        for r in regions.reversed() where r.element == element && r.face == face {
            if r.contains(station: station, azimuth: az) {
                result = PaintSample(paint: r.paint, colour: PaintColour(r.paint), row: r.id, grade: r.grade,
                                     params: r.params, isDecal: false)
                break
            }
        }
        guard face == .outer else { return result }
        for d in decals.reversed() where d.element == element {
            if let colour = d.colour(station: station, azimuth: az) {
                return PaintSample(paint: d.paint, colour: colour, row: d.id, grade: d.grade, params: d.params,
                                   isDecal: true)
            }
        }
        return result
    }

    /// `sample` at a vertex's surface coordinates or construction position.
    public func sample(_ element: PaintElement, at point: PaintCoordinates, face: PaintFace = .outer) -> PaintSample? {
        sample(element, station: point.station, azimuth: point.azimuth, face: face)
    }
}

/// Where a point is in the tables' terms: its vehicle station (STA, in) and
/// its azimuth (degrees from Position I towards Position II, 0..<360).
public struct PaintCoordinates: Equatable {
    public var station: Double
    public var azimuth: Double

    public init(station: Double, azimuth: Double) {
        self.station = station
        self.azimuth = AzimuthRange.normalised(azimuth)
    }

    /// Of a construction-frame point (m): the Saturn V's construction frame
    /// is its station frame in metres, and the spacecraft's parts are placed
    /// in it too (`ApolloAxes`).
    public init(construction c: Vec3) {
        self.init(station: c.x / Self.inch, azimuth: VisualShape.vehicleAzimuth(y: c.y, z: c.z) * 180 / Double.pi)
    }

    /// Of a vertex of `shape`, whose part's origin is at `partOffset` in the
    /// construction frame: its surface coordinates when the shape measures
    /// them in the vehicle's frame (u is construction x, v the azimuth),
    /// else its position.
    public init(_ vertex: VisualShape.Vertex, of shape: VisualShape, partOffset: Vec3) {
        if case .vehicle = shape.surfaceFrame {
            self.init(station: vertex.surface.u / Self.inch, azimuth: vertex.surface.v * 180 / Double.pi)
        } else {
            self.init(construction: vertex.position + partOffset)
        }
    }

    static let inch = 0.0254
}

/// VD2's tables as the evaluator reads them: one `PaintScheme` per vehicle
/// the tables name ("AS-503", "CSM-103", ...), and one per flight
/// (`ApolloVariant`) joining its launch vehicle's and its CSM's.
/// Markings+SaturnV.swift and Markings+CSM.swift say how each kind of row
/// becomes regions and decals.
public enum Markings {
    /// Every bundled row, by table, in order.
    public static let tables: [String: [MarkingRow]] = {
        var tables: [String: [MarkingRow]] = [:]
        for name in MarkingTable.bundledNames {
            do {
                tables[name] = try MarkingTable.bundled(name)
            } catch {
                preconditionFailure("markings table \(name): \(error)")
            }
        }
        return tables
    }()

    /// Every vehicle's scheme, by the name the tables give it.
    public static let schemes: [String: PaintScheme] = {
        var rows: [String: [MarkingRow]] = [:]
        var order: [String] = []
        for name in MarkingTable.bundledNames {
            for row in tables[name] ?? [] {
                if rows[row.vehicle] == nil { order.append(row.vehicle) }
                rows[row.vehicle, default: []].append(row)
            }
        }
        var schemes: [String: PaintScheme] = [:]
        for vehicle in order { schemes[vehicle] = scheme(vehicle, rows[vehicle] ?? []) }
        return schemes
    }()

    /// The scheme of `vehicle` ("AS-503", "CSM-107", ...).
    public static func scheme(_ vehicle: String) -> PaintScheme? { schemes[vehicle] }

    /// A flight's scheme: its launch vehicle's (none for Apollo 7's Saturn
    /// IB, which the tables do not cover) and its CSM's, with the SLA, BPC,
    /// LES and LTA-B rows the CSM's table carries.
    public static func scheme(for variant: ApolloVariant) -> PaintScheme {
        var parts: [PaintScheme] = []
        if let lv = variant.launchVehicle, let s = schemes[lv.rawValue] { parts.append(s) }
        if let s = schemes[variant.csm.rawValue] { parts.append(s) }
        return PaintScheme(merging: parts)
    }

    /// The paint of `element` of `variant` at STA `station` (in) and
    /// `azimuth` (degrees).
    public static func sample(_ element: PaintElement, of variant: ApolloVariant, station: Double, azimuth: Double,
                              face: PaintFace = .outer) -> PaintSample? {
        flightSchemes[variant, default: scheme(for: variant)].sample(element, station: station, azimuth: azimuth, face: face)
    }

    /// The paint of a vertex of `shape`, on the part named `part` whose
    /// origin is at `partOffset` in the construction frame, of `variant`:
    /// the colour hook for galleries and the renderer's fallback. Nil where
    /// no row paints it and the shape's own material shows. Frost and char
    /// are overlays on top (`Frost`, `Char`).
    public static func sample(part: String, shape: VisualShape, vertex: VisualShape.Vertex, partOffset: Vec3,
                              variant: ApolloVariant, face: PaintFace = .outer) -> PaintSample? {
        guard let element = PaintElement.of(part: part, shape: shape, variant: variant) else { return nil }
        let point = PaintCoordinates(vertex, of: shape, partOffset: partOffset)
        return sample(element, of: variant, station: point.station, azimuth: point.azimuth, face: face)
    }

    static let flightSchemes: [ApolloVariant: PaintScheme] = {
        var s: [ApolloVariant: PaintScheme] = [:]
        for v in [ApolloVariant.apollo7, .apollo8, .apollo11] { s[v] = scheme(for: v) }
        return s
    }()

    /// A table's rows as regions, decals and probes.
    static func scheme(_ vehicle: String, _ rows: [MarkingRow]) -> PaintScheme {
        var regions: [PaintRegion] = [], decals: [Decal] = [], probes: [PaintProbe] = []
        for row in rows {
            guard let element = element(of: row) else {
                preconditionFailure("markings row \(row.id): element '\(row.element)' is not known")
            }
            switch row.kind {
            case .base, .region:
                for azimuths in row.copies {
                    regions.append(PaintRegion(id: row.id, element: element, stations: row.vehicleStations,
                                               azimuths: azimuths, face: row.face, paint: row.paint,
                                               params: row.params, grade: row.grade))
                }
            case .decal:
                decals += row.copies.map { decal(row, element: element, azimuths: $0) }
            case .probe:
                probes.append(PaintProbe(id: row.id, vehicle: row.vehicle, element: element,
                                         station: row.vehicleStations.lowerBound, azimuth: row.azimuths.from,
                                         expected: row.paint, grade: row.grade))
            }
        }
        return PaintScheme(vehicles: [vehicle], regions: regions, decals: decals, probes: probes)
    }

    /// The element a row paints: the launch vehicle for every station row.
    static func element(of row: MarkingRow) -> PaintElement? {
        row.frame == .sta ? .launchVehicle : PaintElement(rawValue: row.element)
    }

    /// One copy of a decal row, placed on its element's surface.
    static func decal(_ row: MarkingRow, element: PaintElement, azimuths: AzimuthRange) -> Decal {
        let stations = row.vehicleStations
        let middle = (stations.lowerBound + stations.upperBound) / 2
        let radius = element == .launchVehicle ? saturnRadius(station: middle) : spacecraftRadius(element, station: middle)
        return Decal(row: row, element: element, azimuths: azimuths, radius: radius,
                     content: element == .launchVehicle ? saturnDecalContent(row, azimuths: azimuths)
                                                       : spacecraftDecalContent(row))
    }
}
