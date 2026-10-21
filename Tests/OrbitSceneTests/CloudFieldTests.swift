import Foundation
import XCTest
import OrbitCore
@testable import OrbitScene

final class CloudFieldTests: XCTestCase {
    static let deg = Double.pi / 180

    // MARK: A synthetic OSCLOUD1 file

    /// A 10° field (36 × 19) with 30° winds, snapshots at 0, 1 and 4 h past
    /// `t0` (hourly, then 3-hourly). Bytes: lcc 10 × row + 20 × snapshot,
    /// mcc 5 × column, hcc 127, cbh 255 (none) except a 2 × 2 block, winds
    /// constant.
    static let t0: Int64 = -95_000_000   // 1966-12-28 11:06:40 UTC
    static let planes = [
        CloudField.Plane(name: "lcc", columns: 36, rows: 19, offset: 0, scale: 1 / 254),
        CloudField.Plane(name: "mcc", columns: 36, rows: 19, offset: 0, scale: 1 / 254),
        CloudField.Plane(name: "hcc", columns: 36, rows: 19, offset: 0, scale: 1 / 254),
        CloudField.Plane(name: "cbh", columns: 36, rows: 19, offset: 0, scale: 60),
        CloudField.Plane(name: "u850", columns: 12, rows: 7, offset: -127, scale: 1),
        CloudField.Plane(name: "v850", columns: 12, rows: 7, offset: -127, scale: 1),
    ]

    static func synthetic() -> Data {
        let times = [t0, t0 + 3600, t0 + 4 * 3600]
        let snapshots: [[[UInt8]]] = (0..<times.count).map { n in
            planes.map { p in
                (0..<p.count).map { i -> UInt8 in
                    let row = i / p.columns, column = i % p.columns
                    switch p.name {
                    case "lcc": return UInt8(10 * row + 20 * n)
                    case "mcc": return UInt8(5 * column)
                    case "hcc": return 127
                    case "cbh": return row >= 6 && row <= 7 && column >= 27 && column <= 28 ? 20 : 255
                    case "u850": return 137
                    default: return 122
                    }
                }
            }
        }
        return CloudField.encode(planes: planes, utcSeconds: times, note: "synthetic", snapshots: snapshots)
    }

    static func epoch(_ posix: Int64) -> Epoch { Epoch(julianDateUTC: 2_440_587.5 + Double(posix) / 86_400) }

    /// Written and read back, from memory and from a file, the field is
    /// the same: planes, times, note and every byte; damaged files throw.
    func testFormatRoundTrip() throws {
        let data = Self.synthetic()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudfield-\(UUID()).oscloud")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        for field in [try CloudField(data: data), try CloudField(contentsOf: url)] {
            XCTAssertEqual(field.planes, Self.planes)
            XCTAssertEqual(field.utcSeconds, [Self.t0, Self.t0 + 3600, Self.t0 + 4 * 3600])
            XCTAssertEqual(field.note, "synthetic")
            // Before 1972 a UTC second was not an SI second: 1966's hour is
            // 3600.0001 s (TAI-UTC grew 0.002592 s a day). A UTC Julian date
            // in a Double resolves 40 µs.
            XCTAssertEqual(field.times[1] - field.times[0], 3600 + 0.002592 / 24, accuracy: 1e-4)
            let lcc = try XCTUnwrap(field.plane("lcc"))
            XCTAssertEqual(Array(field.bytes(plane: lcc, snapshot: 2).prefix(3)), [40, 40, 40])
            XCTAssertEqual(field.bytes(plane: try XCTUnwrap(field.plane("v850")), snapshot: 1).count, 84)
        }
        XCTAssertThrowsError(try CloudField(data: data.prefix(data.count - 1))) {
            XCTAssertEqual($0 as? CloudField.FormatError, .truncated)
        }
        var bad = data
        bad[0] = UInt8(ascii: "X")
        XCTAssertThrowsError(try CloudField(data: bad)) { XCTAssertEqual($0 as? CloudField.FormatError, .notOSCLOUD1) }
        let byte = Self.planes[3].byte(1_000)
        XCTAssertEqual(byte, 17)
        XCTAssertEqual(Self.planes[3].value(byte), 1_020)
        XCTAssertNil(Self.planes[3].value(Self.planes[3].byte(nil)))
    }

    /// Bilinear in space reproduces a field linear across its grid, linear
    /// in time between the snapshots around a time, wrapping in longitude.
    func testInterpolationInSpaceTimeAndLongitudeWrap() throws {
        let field = try CloudField(data: Self.synthetic())
        // 1.75 h is a quarter of the way from the 1 h snapshot to the 4 h one.
        let t = Self.epoch(Self.t0 + 6300)
        // Row 2.5 (latitude 65°): 25 + 20 × 1.25.
        let lcc = try XCTUnwrap(field.value("lcc", latitude: 65 * Self.deg, longitude: 12 * Self.deg, at: t))
        XCTAssertEqual(lcc, (25 + 25) / 254, accuracy: 1e-9)
        // Longitude 355° is half-way from column 35 (350°, byte 175) to column 0.
        let wrap = try XCTUnwrap(field.value("mcc", latitude: 0, longitude: 355 * Self.deg, at: t))
        XCTAssertEqual(wrap, 87.5 / 254, accuracy: 1e-9)
        let west = try XCTUnwrap(field.value("mcc", latitude: 0, longitude: -5 * Self.deg, at: t))
        XCTAssertEqual(west, wrap, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(field.value("mcc", latitude: 0, longitude: 2 * .pi, at: t)), 0, accuracy: 1e-12)
        // The poles are rows 0 and 18.
        XCTAssertEqual(try XCTUnwrap(field.value("lcc", latitude: -.pi / 2, longitude: 1, at: t)), 205 / 254,
                       accuracy: 1e-9)
        // At a snapshot's time, that snapshot exactly; outside the span, nothing.
        let first = try XCTUnwrap(field.value("lcc", latitude: 90 * Self.deg, longitude: 0, at: field.times[0]))
        XCTAssertEqual(first, 0)
        XCTAssertNil(field.value("lcc", latitude: 0, longitude: 0, at: field.times[0] + -1))
        XCTAssertNil(field.value("lcc", latitude: 0, longitude: 0, at: field.times[2] + 1))
        let around = try XCTUnwrap(field.bracket(t))
        XCTAssertEqual(around.first, 1)
        XCTAssertEqual(around.second, 2)
        XCTAssertEqual(around.weight, 0.25, accuracy: 1e-9)
        // The winds, 1 m/s steps from -127: (10, -5) m/s.
        let s = try XCTUnwrap(field.sample(latitude: 0.3, longitude: 2, at: t))
        XCTAssertEqual(try XCTUnwrap(s.lowWind).east, 10, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(s.lowWind).north, -5, accuracy: 1e-9)
        XCTAssertNil(s.highWind)
        XCTAssertEqual(s.high, 0.5, accuracy: 1e-9)
    }

    /// Grid points with no value are left out of the bilinear sum; none at
    /// all is nil.
    func testMissingValuesAreLeftOut() throws {
        let field = try CloudField(data: Self.synthetic())
        let cbh = try XCTUnwrap(field.plane("cbh"))
        // Rows 6-7 (30°, 20° N), columns 27-28 (270°, 280°) hold 1,200 m.
        let inside = field.value(plane: cbh, snapshot: 0, latitude: 25 * Self.deg, longitude: 275 * Self.deg)
        XCTAssertEqual(try XCTUnwrap(inside), 1_200, accuracy: 1e-9)
        // Half-way out of the block in latitude: still the block's value.
        let edge = field.value(plane: cbh, snapshot: 0, latitude: 15 * Self.deg, longitude: 275 * Self.deg)
        XCTAssertEqual(try XCTUnwrap(edge), 1_200, accuracy: 1e-9)
        XCTAssertNil(field.value(plane: cbh, snapshot: 0, latitude: -40 * Self.deg, longitude: 1))
        let sample = try XCTUnwrap(field.sample(latitude: -40 * Self.deg, longitude: 1, at: field.times[0]))
        XCTAssertNil(sample.baseHeight)
    }

    // MARK: The climatology

    /// Every cover is a fraction; the bands are where they belong: the
    /// ITCZ's high cloud north of the equator in July and south of it in
    /// January, the subtropical highs clearer, the Southern Ocean's low
    /// cloud the densest; and the year wraps without a step.
    func testClimatologyIsBoundedAndBanded() {
        for table in [CloudClimatology.low, CloudClimatology.mid, CloudClimatology.high] {
            XCTAssertEqual(table.count, 12)
            for row in table {
                XCTAssertEqual(row.count, 37)
                XCTAssertTrue(row.allSatisfy { $0 <= 100 })
            }
        }
        for k in 0...72 {
            for m in 0...24 {
                let c = CloudClimatology.cover(latitude: Double(k - 36) * 2.5 * Self.deg, yearFraction: Double(m) / 24)
                for v in [c.low, c.mid, c.high] { XCTAssertTrue((0...1).contains(v)) }
            }
        }
        func high(_ lat: Double, _ year: Double) -> Double {
            CloudClimatology.cover(latitude: lat * Self.deg, yearFraction: year).high
        }
        func low(_ lat: Double, _ year: Double) -> Double {
            CloudClimatology.cover(latitude: lat * Self.deg, yearFraction: year).low
        }
        let july = 196.5 / 365.25, january = 15.5 / 365.25
        XCTAssertGreaterThan(high(10, july), high(-10, july) + 0.1)
        XCTAssertGreaterThan(high(-10, january), high(10, january))
        XCTAssertGreaterThan(high(10, july), 2 * high(-25, july))
        XCTAssertGreaterThan(low(-60, july), low(-25, july))
        XCTAssertGreaterThan(low(-60, january), low(-25, january))
        let dec31 = CloudClimatology.cover(latitude: 0.5, yearFraction: 0.99999)
        let jan1 = CloudClimatology.cover(latitude: 0.5, yearFraction: 0.00001)
        XCTAssertEqual(dec31.low, jan1.low, accuracy: 1e-3)
        XCTAssertEqual(dec31.high, jan1.high, accuracy: 1e-3)
        let s = CloudClimatology.sample(latitude: 0.5, at: Epoch(utcYear: 1968, month: 12, day: 21, hour: 12))
        XCTAssertNil(s.baseHeight)
        XCTAssertNil(s.lowWind)
    }

    // MARK: Physics

    /// β = 3 LWC / (2 ρ r_eff): 0.075 /m at 0.5 g/m³ and 10 µm, which is a
    /// monodisperse cloud's number density times twice the drops' cross
    /// section.
    func testExtinctionFromLiquidWaterContent() {
        let beta = CloudOptics.extinction(waterContent: 0.5e-3, effectiveRadius: 10e-6)
        XCTAssertEqual(beta, 0.075, accuracy: 1e-12)
        let r = 10e-6
        let n = 0.5e-3 / (CloudOptics.waterDensity * 4 / 3 * .pi * r * r * r)
        XCTAssertEqual(n * 2 * .pi * r * r, beta, accuracy: 1e-12)
        // The layer model's cumulus and cirrus sit in the design's ranges.
        let layers = CloudLayerModel.layers(CloudSample(low: 1, mid: 1, high: 1))
        XCTAssertTrue((0.05...0.1).contains(layers[0].extinction), "\(layers[0].extinction)")
        XCTAssertTrue((1e-4...1e-3).contains(layers[2].extinction), "\(layers[2].extinction)")
    }

    /// R(τ = 10, g = 0.85) = 0.43, and the closed form is the two-stream
    /// equations' solution: doubling a thin layer (R = bδ, T = 1 - bδ, with
    /// b = (1 - g)/2) twenty times gives the same slab.
    func testTwoStreamSlabReflectance() {
        let r = CloudOptics.slabReflectance(opticalDepth: 10, asymmetry: 0.85)
        XCTAssertEqual(r, 0.43, accuracy: 0.0015)
        XCTAssertEqual(r, 1.5 / 3.5, accuracy: 1e-12)
        XCTAssertEqual(CloudOptics.slabTransmittance(opticalDepth: 10, asymmetry: 0.85), 2 / 3.5, accuracy: 1e-12)
        let b = (1 - 0.85) / 2
        let delta = 10 / Double(1 << 20)
        var rd = b * delta, td = 1 - b * delta
        for _ in 0..<20 {
            let denominator: Double = 1 - rd * rd
            (rd, td) = (rd + td * td * rd / denominator, td * td / denominator)
        }
        XCTAssertEqual(rd, r, accuracy: 1e-6)
        XCTAssertEqual(rd + td, 1, accuracy: 1e-9)
        // A 0.5 g/m³, 10 µm slab 133.3 m deep is that slab.
        let slab = CloudLayer(kind: .low, base: 1_000, top: 1_000 + 10 / 0.075, cover: 1, waterContent: 0.5e-3,
                              effectiveRadius: 10e-6, density: CloudOptics.waterDensity, asymmetry: 0.85)
        XCTAssertEqual(slab.opticalDepth, 10, accuracy: 1e-9)
        XCTAssertEqual(CloudOptics.slabReflectance(opticalDepth: slab.opticalDepth, asymmetry: slab.asymmetry), r,
                       accuracy: 1e-12)
    }

    /// The low layer's base is the sample's cloud base below the mid layer,
    /// 1 km otherwise; a cumulonimbus tops out at 12 km.
    func testLayerModel() {
        let layers = CloudLayerModel.layers(CloudSample(low: 0.4, mid: 0, high: 0.2, baseHeight: 600))
        XCTAssertEqual(layers.map(\.kind), [.low, .mid, .high])
        XCTAssertEqual(layers[0].base, 600)
        XCTAssertEqual(layers[0].top, 2_100)
        XCTAssertEqual(layers[0].cover, 0.4)
        XCTAssertEqual(layers[2].cover, 0.2)
        XCTAssertEqual(CloudLayerModel.layers(CloudSample(low: 0, mid: 0, high: 1, baseHeight: 9_000))[0].base, 1_000)
        XCTAssertEqual(CloudLayerModel.layers(CloudSample(low: 0.3, mid: 0, high: 0, convective: true))[0].top, 12_000)
    }

    // MARK: Pad truth, TM X-64796 Table 1

    /// The CSV's rows, comment lines dropped.
    func tableRows() throws -> [[String: String]] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("tools/data/tmx64796_table1_saturn.csv")
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n").filter { !$0.hasPrefix("#") }
        let header = lines[0].split(separator: ",").map(String.init)
        return lines.dropFirst().map { line in
            var cells: [String] = [], cell = "", quoted = false
            for ch in line {
                if ch == "\"" {
                    quoted.toggle()
                } else if ch == "," && !quoted {
                    cells.append(cell)
                    cell = ""
                } else {
                    cell.append(ch)
                }
            }
            cells.append(cell)
            return Dictionary(uniqueKeysWithValues: zip(header, cells))
        }
    }

    /// The table parses: the Saturn rows 125-155, every sky in "n/10
    /// genus" words but SA-7's, whose first amount is illegible; AS-503
    /// reads 4/10 cirrus; and the launch overrides are its rows.
    func testTMX64796TableParses() throws {
        let rows = try tableRows()
        XCTAssertEqual(rows.compactMap { $0["seq"].flatMap(Int.init) }, Array(125...155))
        XCTAssertEqual(rows.filter { ($0["clouds"] ?? "").contains("?") }.map { $0["vehicle"] }, ["SA-7"])
        for row in rows where !(row["clouds"] ?? "").contains("?") {
            XCTAssertNotNil(CloudObservation(table: row["clouds"] ?? ""), "\(row["vehicle"] ?? "?"): \(row["clouds"] ?? "")")
        }
        func row(_ vehicle: String) throws -> [String: String] {
            try XCTUnwrap(rows.first { $0["vehicle"] == vehicle })
        }
        let as503 = try row("AS-503")
        XCTAssertEqual(as503["clouds"], "4/10 cirrus")
        XCTAssertEqual(as503["launch_utc"], "1968-12-21T12:51Z")
        XCTAssertEqual(as503["pad"], "39A")
        XCTAssertEqual(CloudObservation(table: "4/10 cirrus"), CloudObservation(low: 0, mid: 0, high: 0.4))
        XCTAssertEqual(CloudObservation(table: "clear"), CloudObservation(low: 0, mid: 0, high: 0))
        let two = try XCTUnwrap(CloudObservation(table: "3/10 cumulus, 3/10 stratocumulus"))
        XCTAssertEqual(two.low, 0.51, accuracy: 1e-12)
        XCTAssertNil(CloudObservation(table: "some cirrus"))

        for (mission, vehicle) in [("apollo7", "AS-205"), ("apollo8", "AS-503"), ("apollo11", "AS-506")] {
            let r = try row(vehicle)
            let o = try XCTUnwrap(CloudOverride.launches[mission])
            XCTAssertEqual(o.observation, CloudObservation(table: r["clouds"] ?? ""), mission)
            let c = o.time.utc
            func two(_ x: Int) -> String { x < 10 ? "0\(x)" : "\(x)" }
            let stamp = "\(c.year)-\(two(c.month))-\(two(c.day))T\(two(c.hour)):\(two(c.minute))Z"
            XCTAssertEqual(stamp, r["launch_utc"], mission)
        }
        XCTAssertEqual(try XCTUnwrap(CloudObservation(table: try row("AS-205")["clouds"] ?? "")).convective, true)
    }

    /// ERA5 at the pad at launch (`make_clouds_era5.py pad`, run on
    /// 2026-10-21: bilinear at the pad, linear between the hours around the
    /// launch) against Table 1. They agree on which layers are cloudy: a
    /// layer the observer did not report is under 0.2 in ERA5, unless the
    /// observer saw cumulonimbus, which spans them. Each layer's cover
    /// agrees within 0.4: one grid box against an observer's tenths of sky,
    /// in a reanalysis without satellite data. AS-503's cirrus (0.77
    /// against 0.4) is the largest gap; the pad override makes up for it.
    static let era5AtPad: [String: (low: Double, mid: Double, high: Double)] = [
        "apollo7": (0.151, 0.186, 0.003),
        "apollo8": (0.000, 0.003, 0.766),
        "apollo11": (0.053, 0.032, 1.000),
    ]

    func testERA5AgreesWithPadTruth() throws {
        for (mission, e) in Self.era5AtPad {
            let o = try XCTUnwrap(CloudOverride.launches[mission]).observation
            for (era5, seen) in [(e.low, o.low), (e.mid, o.mid), (e.high, o.high)] {
                XCTAssertEqual(era5, seen, accuracy: 0.4, mission)
                if seen == 0 && !o.convective { XCTAssertLessThan(era5, 0.2, mission) }
            }
        }
    }

    /// The fetched field (on the Mac, after `make_clouds_era5.py mission`)
    /// gives the values above at the pad at launch; skipped without it.
    func testFetchedFieldAtPadAtLaunch() throws {
        var found = 0
        for (mission, e) in Self.era5AtPad {
            guard let url = OrbitSceneResources.url(mission + ".oscloud") else { continue }
            found += 1
            let field = try CloudField(contentsOf: url)
            XCTAssertTrue(field.note.contains("Copernicus"), mission)
            let o = try XCTUnwrap(CloudOverride.launches[mission])
            let s = try XCTUnwrap(field.sample(latitude: o.latitude, longitude: o.longitude, at: o.time), mission)
            // Bytes are 1/254 steps; bilinear on them differs from the tool's
            // bilinear on ERA5's floats by under one step.
            XCTAssertEqual(s.low, e.low, accuracy: 0.005, mission)
            XCTAssertEqual(s.mid, e.mid, accuracy: 0.005, mission)
            XCTAssertEqual(s.high, e.high, accuracy: 0.005, mission)
            if mission == "apollo8" {
                // Hourly from 1968-12-21 12:00 UTC through TLI (15:41) to
                // 18:00, then 3-hourly to 12-27 18:00, past the splashdown.
                let steps = zip(field.utcSeconds, field.utcSeconds.dropFirst()).map { $1 - $0 }
                XCTAssertEqual(field.utcSeconds.first, -32_443_200)
                XCTAssertEqual(field.utcSeconds.last, -31_903_200)
                XCTAssertEqual(steps, Array(repeating: 3600, count: 6) + Array(repeating: 10_800, count: 48))
            }
        }
        if found == 0 { throw XCTSkip("no fetched .oscloud in Sources/OrbitScene/Resources") }
    }

    // MARK: The weather: field, fallback, override

    /// A uniform field (0.5 in every layer) spanning Apollo 8's launch.
    static func uniformField(from start: Int64, hours: Int) throws -> CloudField {
        let planes = Array(Self.planes.prefix(3))
        let times = (0...hours).map { start + Int64($0) * 3600 }
        let snapshot = planes.map { [UInt8](repeating: 127, count: $0.count) }
        let data = CloudField.encode(planes: planes, utcSeconds: times, note: "uniform",
                                     snapshots: Array(repeating: snapshot, count: times.count))
        return try CloudField(data: data)
    }

    /// At the pad at launch the sky is the observer's; 60 km away, or 4 h
    /// later, it is the field's; in between it moves from one to the other
    /// without a step.
    func testPadOverrideTakesTheObservation() throws {
        let launch = try XCTUnwrap(CloudOverride.launches["apollo8"])
        let field = try Self.uniformField(from: -32_450_400, hours: 8)   // 1968-12-21 10:00 UTC
        let weather = CloudWeather(field: field, overrides: [launch])
        let lat = launch.latitude, lon = launch.longitude
        let atPad = weather.sample(latitude: lat, longitude: lon, at: launch.time)
        XCTAssertEqual(atPad.low, 0, accuracy: 1e-12)
        XCTAssertEqual(atPad.high, 0.4, accuracy: 1e-12)
        XCTAssertEqual(weather.sample(latitude: lat, longitude: lon, at: launch.time + 3000).high, 0.4, accuracy: 1e-12)
        let north = 60_000.0 / 6_371_000
        XCTAssertEqual(weather.sample(latitude: lat + north, longitude: lon, at: launch.time).high, 0.5,
                       accuracy: 1e-12)
        XCTAssertEqual(weather.sample(latitude: lat, longitude: lon, at: launch.time + 4 * 3600).high, 0.5,
                       accuracy: 1e-12)
        var last = 0.4
        for k in 1...30 {
            let away = Double(k) * 2_000 / 6_371_000
            let high = weather.sample(latitude: lat + away, longitude: lon, at: launch.time).high
            XCTAssertGreaterThanOrEqual(high, last - 1e-12)
            XCTAssertLessThan(high - last, 0.03)
            last = high
        }
    }

    /// Outside its span the field fades into the climatology over 3 h.
    func testWeatherFallsBackToTheClimatology() throws {
        let field = try Self.uniformField(from: -32_450_400, hours: 2)
        let weather = CloudWeather(field: field)
        let end = try XCTUnwrap(field.times.last)
        let lat = 0.4
        let climate = CloudClimatology.sample(latitude: lat, at: end + 36_000)
        XCTAssertEqual(weather.sample(latitude: lat, longitude: 1, at: end + 36_000), climate)
        XCTAssertEqual(weather.sample(latitude: lat, longitude: 1, at: end).low, 0.5, accuracy: 1e-12)
        let half = weather.sample(latitude: lat, longitude: 1, at: end + 5_400)
        let climateThen = CloudClimatology.sample(latitude: lat, at: end + 5_400)
        XCTAssertEqual(half.low, (0.5 + climateThen.low) / 2, accuracy: 1e-12)
        XCTAssertEqual(CloudWeather().sample(latitude: lat, longitude: 1, at: end), CloudClimatology.sample(latitude: lat, at: end))
        // A mission without a fetched file still has its observed launch sky.
        let apollo8 = CloudWeather.mission("apollo8")
        XCTAssertEqual(apollo8.overrides, [try XCTUnwrap(CloudOverride.launches["apollo8"])])
        XCTAssertNil(CloudWeather.mission("no-such-mission").field)
    }
}
