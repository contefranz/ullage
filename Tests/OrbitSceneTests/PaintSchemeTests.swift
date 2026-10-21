import XCTest
import OrbitCore
@testable import OrbitScene

/// The paint evaluator against VD2's probe rows and its conventions
/// (docs/data/markings/README.md).
final class PaintSchemeTests: XCTestCase {
    /// Every probe point of every table gives the paint VD2 expects there,
    /// on its own vehicle's scheme and on its flight's.
    func testEveryProbeGivesItsExpectedPaint() throws {
        var probes: [PaintProbe] = []
        for vehicle in ["AS-501", "AS-502", "AS-503", "AS-506", "CSM-101", "CSM-103", "CSM-107"] {
            let scheme = try XCTUnwrap(Markings.scheme(vehicle))
            for p in scheme.probes {
                let s = scheme.sample(p.element, station: p.station, azimuth: p.azimuth)
                XCTAssertEqual(s?.paint, p.expected, "\(p.id) at STA \(p.station), \(p.azimuth)°: \(s?.row ?? "none")")
            }
            probes += scheme.probes
        }
        XCTAssertEqual(probes.count, 40)
        XCTAssertEqual(Set(probes.map(\.id)).count, 40)

        let flights: [String: ApolloVariant] = ["AS-503": .apollo8, "CSM-103": .apollo8, "AS-506": .apollo11,
                                                "CSM-107": .apollo11]
        for p in probes {
            let variant = try XCTUnwrap(flights[p.vehicle], p.vehicle)
            let s = Markings.sample(p.element, of: variant, station: p.station, azimuth: p.azimuth)
            XCTAssertEqual(s?.paint, p.expected, p.id)
        }
    }

    /// A sample carries the row that painted it and that row's grade.
    func testGradesComeThrough() throws {
        let as503 = try XCTUnwrap(Markings.scheme("AS-503")), as506 = try XCTUnwrap(Markings.scheme("AS-506"))
        let csm107 = try XCTUnwrap(Markings.scheme("CSM-107"))
        let cases: [(PaintScheme, PaintElement, Double, Double, String, MarkingGrade)] = [
            (as503, .launchVehicle, 250, 22.5, "503-010", .high),     // a measured stripe
            (as503, .launchVehicle, 1820, 160, "503-031", .medium),   // a cap on one photo
            (as503, .launchVehicle, 1800, 22.5, "503-020", .high),    // the stripe, clear of the caps
            (as503, .launchVehicle, 1600, 229, "503-052", .low),      // fin C's ullage fairing, by symmetry
            (as503, .launchVehicle, 3240, 90, "503-070", .medium),    // the IU band over its placeholder
            (as503, .launchVehicle, 2200, 112.5, "503-121", .low),    // UNITED STATES, sector B: not seen
            (as503, .launchVehicle, 1000, 100, "503-001", .high),     // the stage's base white
            (as506, .launchVehicle, 500, 112.5, "506-011", .low),     // as AS-503's, not seen on AS-506
            (as506, .launchVehicle, 1820, 260, "506-033", .medium),   // the disputed C-sector cap
            (csm107, .sm, 920 + MarkingRow.apolloStationOffset, 300, "107-001", .medium),
            (csm107, .les, 1480 + MarkingRow.apolloStationOffset, 10, "107-034", .low),
        ]
        for (scheme, element, station, azimuth, row, grade) in cases {
            let s = try XCTUnwrap(scheme.sample(element, station: station, azimuth: azimuth), row)
            XCTAssertEqual(s.row, row)
            XCTAssertEqual(s.grade, grade, row)
        }
        // Every row's grade reaches the regions and decals built from it.
        for vehicle in ["AS-501", "AS-502", "AS-503", "AS-506", "CSM-101", "CSM-103", "CSM-107"] {
            let scheme = try XCTUnwrap(Markings.scheme(vehicle))
            let rows = Dictionary(MarkingTable.bundledNames.flatMap { (try? MarkingTable.bundled($0)) ?? [] }
                .map { ($0.id, $0.grade) }, uniquingKeysWith: { a, _ in a })
            for r in scheme.regions { XCTAssertEqual(rows[r.id], r.grade, r.id) }
            for d in scheme.decals { XCTAssertEqual(rows[d.id], d.grade, d.id) }
        }
    }

    /// Later rows win where rows overlap: the white ridge across a black
    /// stripe, the white fairings over the cap, the IU band over the IU's
    /// placeholder white, a quadrant's black over the interstage's white.
    func testLastMatchWins() throws {
        let s = try XCTUnwrap(Markings.scheme("AS-503"))
        func paint(_ station: Double, _ azimuth: Double) -> PaintName? { s.sample(.launchVehicle, station: station, azimuth: azimuth)?.paint }
        XCTAssertEqual(paint(1564, 22.5), .white)     // 503-040 over 503-020
        XCTAssertEqual(paint(1600, 22.5), .black)
        XCTAssertEqual(paint(1820, 45), .white)       // 503-055 over 503-020 and the cap
        XCTAssertEqual(paint(1820, 70), .black)       // 503-030
        XCTAssertEqual(paint(1700, 49), .white)       // 503-050 over the stripe's edge...
        XCTAssertEqual(paint(1700, 40), .black)
        XCTAssertEqual(paint(3230, 270), .black)      // 503-070 over 503-006
        XCTAssertEqual(paint(2600, 45), .white)       // 503-064 in quadrant A's black
        XCTAssertEqual(paint(2600, 30), .black)
    }

    /// The black intertank band belongs to SA-500F only: on every flown
    /// vehicle the intertank (STA 628.8-885.2) is white all round, and so
    /// is the LOX tank (the README's seed hypothesis 2).
    func testNoSA500FIntertankBand() throws {
        for vehicle in ["AS-501", "AS-502", "AS-503", "AS-506"] {
            let s = try XCTUnwrap(Markings.scheme(vehicle))
            for station in stride(from: 640.0, through: 1400, by: 20) {
                for azimuth in stride(from: 0.0, to: 360, by: 5) {
                    let p = s.sample(.launchVehicle, station: station, azimuth: azimuth)
                    // The flags sit on the LOX tank; everything else there is white.
                    XCTAssertTrue(p?.paint == .white || p?.paint == .flag, "\(vehicle) \(station) \(azimuth): \(p?.row ?? "-")")
                }
            }
        }
    }

    /// The roll pattern is four-fold: each quarter from a Position to the
    /// next fin black from the base to the intertank, the next quarter
    /// white, on the flown vehicles.
    func testRollPatternIsFourFold() throws {
        for vehicle in ["AS-501", "AS-502", "AS-503", "AS-506"] {
            let s = try XCTUnwrap(Markings.scheme(vehicle))
            for k in 0..<4 {
                let black = 90 * Double(k) + 22.5, white = black + 45
                XCTAssertEqual(s.sample(.launchVehicle, station: 200, azimuth: black)?.paint, .black, "\(vehicle) \(black)")
                XCTAssertEqual(s.sample(.launchVehicle, station: 200, azimuth: white)?.paint, .white, "\(vehicle) \(white)")
                XCTAssertEqual(s.sample(.launchVehicle, station: 1500, azimuth: black)?.paint, .black, "\(vehicle) \(black)")
            }
        }
    }

    /// Inner skins are painted only by `face=inner` rows, outer skins only
    /// by the others.
    func testInnerFaces() throws {
        let s = try XCTUnwrap(Markings.scheme("AS-503"))
        let inner = s.sample(.launchVehicle, station: 1600, azimuth: 22.5, face: .inner)
        XCTAssertEqual(inner?.paint, .zincChromate)
        XCTAssertEqual(inner?.row, "503-090")
        XCTAssertEqual(s.sample(.launchVehicle, station: 1000, azimuth: 0, face: .inner), nil)
        let csm = try XCTUnwrap(Markings.scheme("CSM-103"))
        XCTAssertEqual(csm.sample(.sla, station: 700 + MarkingRow.apolloStationOffset, azimuth: 45, face: .inner)?.paint,
                       .darkBrown)
        XCTAssertEqual(csm.sample(.sla, station: 700 + MarkingRow.apolloStationOffset, azimuth: 45)?.paint, .white)
    }

    /// Spacecraft rows paint their own element only: the SM's white fairing
    /// band and the CM's Kapton share stations, and so do the BPC and the
    /// tower.
    func testSpacecraftElementsAreKeptApart() throws {
        let station = 1000 + MarkingRow.apolloStationOffset
        let a11 = ApolloVariant.apollo11
        XCTAssertEqual(Markings.sample(.sm, of: a11, station: station, azimuth: 0)?.paint, .white)
        XCTAssertEqual(Markings.sample(.cm, of: a11, station: station, azimuth: 0)?.paint, .kapton)
        XCTAssertEqual(Markings.sample(.bpc, of: a11, station: station + 50, azimuth: 0)?.row, "107-030")
        XCTAssertEqual(Markings.sample(.les, of: a11, station: station + 100, azimuth: 0)?.row, "107-031")
        XCTAssertNil(Markings.sample(.launchVehicle, of: .apollo7, station: 500, azimuth: 0))
        XCTAssertEqual(Markings.sample(.sm, of: .apollo7, station: 920 + MarkingRow.apolloStationOffset,
                                       azimuth: 0)?.row, "101-001")
        XCTAssertNil(Markings.sample(.ltaB, of: a11, station: 600 + MarkingRow.apolloStationOffset, azimuth: 0))
        XCTAssertEqual(Markings.sample(.ltaB, of: .apollo8, station: 600 + MarkingRow.apolloStationOffset,
                                       azimuth: 0)?.row, "103-050")
    }

    /// The decals: red USA letters with white between them, the flag's
    /// three colours, the SM's black lettering on its white panel, the
    /// Position plates' numerals.
    func testDecals() throws {
        let s = try XCTUnwrap(Markings.scheme("AS-503"))
        func sample(_ station: Double, _ azimuth: Double) -> PaintSample? { s.sample(.launchVehicle, station: station, azimuth: azimuth) }
        // 503-101's S: its middle stroke red, its counters white.
        let usa = try XCTUnwrap(s.decals.first { $0.id == "503-101" })
        let sGlyph = try XCTUnwrap(usa.glyphs.dropFirst().first)
        let middle = sGlyph.y + sGlyph.glyph.height / 2 + usa.stations.lowerBound
        XCTAssertEqual(sample(middle, usa.azimuths.centre)?.colour, .red)
        XCTAssertEqual(sample(middle + sGlyph.glyph.height / 4, usa.azimuths.centre)?.colour, .white)
        XCTAssertEqual(sample(middle + sGlyph.glyph.height / 4, usa.azimuths.centre)?.isDecal, false)
        // 503-111's flag: union blue at its upper hoist, red top stripe, white second stripe.
        let flag = try XCTUnwrap(s.decals.first { $0.id == "503-111" }?.flag)
        let f = try XCTUnwrap(s.decals.first { $0.id == "503-111" })
        func at(_ x: Double, _ yDown: Double) -> PaintColour? {
            let station = f.stations.lowerBound + flag.y + flag.hoist * (1 - yDown)
            let azimuth = f.azimuths.from + (flag.hoistX + x * flag.hoist) / f.radius * 180 / Double.pi
            return sample(station, azimuth)?.colour
        }
        XCTAssertEqual(at(0.063 * 1.5, 0.054 * 1.5), .flagBlue)
        XCTAssertEqual(at(0.063, 0.054), .flagWhite)            // the first star
        XCTAssertEqual(at(1.5, 0.03), .flagRed)
        XCTAssertEqual(at(1.5, 0.11), .flagWhite)
        XCTAssertEqual(at(1.5, 0.97), .flagRed)
        // The SM: black letters on the white panel, the flag below.
        let csm = try XCTUnwrap(Markings.scheme("CSM-107"))
        let text = try XCTUnwrap(csm.decals.first { $0.id == "107-011" })
        XCTAssertEqual(text.glyphs.count, 12)
        let u = text.glyphs[0]
        let uStem = (x: u.x + u.glyph.stroke / 2, y: u.y + u.glyph.height / 2)
        let uAzimuth = text.azimuths.centre + (uStem.x - text.width / 2) / text.radius * 180 / Double.pi
        XCTAssertEqual(csm.sample(.sm, station: text.stations.lowerBound + uStem.y, azimuth: uAzimuth)?.colour, .black)
        XCTAssertEqual(csm.sample(.sm, station: 989 + MarkingRow.apolloStationOffset - 0.5, azimuth: 122.5)?.colour, .white)
        // The plates: III at Position III, II and IV by their place.
        let plates = s.decals.filter { $0.id == "503-130" || $0.id == "503-131" }
        XCTAssertEqual(plates.map { String($0.glyphs.map(\.glyph.character)) }.sorted(), ["I", "II", "III", "IV"])
    }

    /// Paint coordinates of a vertex: the surface's when it is measured in
    /// the vehicle's frame, the position's otherwise; Position I is +z and
    /// Position II is -y.
    func testPaintCoordinates() {
        let p = PaintCoordinates(construction: Vec3(1000 * 0.0254, -5, 0))
        XCTAssertEqual(p.station, 1000, accuracy: 1e-9)
        XCTAssertEqual(p.azimuth, 90, accuracy: 1e-9)
        XCTAssertEqual(PaintCoordinates(construction: Vec3(0, 0, 3)).azimuth, 0, accuracy: 1e-9)
        XCTAssertEqual(PaintCoordinates(construction: Vec3(0, 0, -3)).azimuth, 180, accuracy: 1e-9)
        XCTAssertEqual(PaintCoordinates(construction: Vec3(0, 3, 0)).azimuth, 270, accuracy: 1e-9)
    }

    /// Every shape of the dressed Apollo 8 and Apollo 11 stacks and of
    /// Apollo 7's CSM gets an element or is unpainted by its material, and
    /// its vertices sample paint on the outer skins.
    func testDressedShapesFindTheirElements() throws {
        for variant in [ApolloVariant.apollo8, .apollo11] {
            let stack = VesselLibrary.saturnV()
            for p in stack.parts { p.appearance = variant }
            VesselLibrary.dressApollo(stack)
            let scheme = Markings.scheme(for: variant)
            var painted = 0
            for part in stack.parts {
                let offset = part.offset - stack.structureOrigin
                for shape in part.shapes {
                    guard let element = PaintElement.of(part: part.name, shape: shape, variant: variant) else {
                        XCTAssertTrue(PaintElement.unpaintedMaterials.contains(shape.material)
                                      || (part.name == "LM" && variant.payload != .ltaB) || part.name.hasSuffix("parachutes"),
                                      "\(part.name) \(shape.material)")
                        continue
                    }
                    if part.name == "LES" && shape.surfaceFrame != .local && shape.capBase == false {
                        XCTAssertEqual(element, .bpc)
                    }
                    for v in shape.mesh().vertices {
                        if scheme.sample(element, at: PaintCoordinates(v, of: shape, partOffset: offset)) != nil { painted += 1 }
                    }
                }
            }
            XCTAssertGreaterThan(painted, 1000, "\(variant)")
        }
    }
}
