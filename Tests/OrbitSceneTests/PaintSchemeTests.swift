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

    /// Every shape of the dressed Apollo 8 and Apollo 11 stacks gets an
    /// element or is unpainted by its material, and its vertices sample
    /// paint on the outer skins (Apollo 7's CSM: the next test). The "LES"
    /// part carries the BPC too: VG3's materials name the cover's shapes
    /// (`apollo.bpc.*`) and the tower's, skirt's, canards' and Q-ball's
    /// (`apollo.les.*`); a shape lying on the cover's shells (every vertex
    /// within an inch of them: its window and blow-out ports) is the BPC's,
    /// and no other shape is. The BPC's rows paint every vertex of the
    /// BPC's shapes, and the LES's rows paint each of the LES's.
    func testDressedShapesFindTheirElements() throws {
        let inch = 0.0254
        for variant in [ApolloVariant.apollo8, .apollo11] {
            let stack = VesselLibrary.saturnV()
            for p in stack.parts { p.appearance = variant }
            VesselLibrary.dressApollo(stack)
            let scheme = Markings.scheme(for: variant)
            var painted = 0, onCover = 0, elements: [PaintElement: Int] = [:]
            for part in stack.parts {
                let offset = part.offset - stack.structureOrigin
                let cover = part.name == "LES" ? Self.coverProfiles(part, offset: offset) : []
                if part.name == "LES" { XCTAssertEqual(cover.count, 2, "\(variant): the BPC's soft and hard sections") }
                for shape in part.shapes {
                    guard let element = PaintElement.of(part: part.name, shape: shape, partOffset: offset,
                                                        variant: variant) else {
                        XCTAssertTrue(PaintElement.unpaintedMaterials.contains(shape.material)
                                      || (part.name == "LM" && variant.payload != .ltaB) || part.name.hasSuffix("parachutes"),
                                      "\(part.name) \(shape.material)")
                        continue
                    }
                    elements[element, default: 0] += 1
                    let vertices = shape.mesh().vertices
                    var samples: [PaintSample?] = []
                    for v in vertices {
                        let s = scheme.sample(element, at: PaintCoordinates(v, of: shape, partOffset: offset))
                        XCTAssertEqual(Markings.sample(part: part.name, shape: shape, vertex: v, partOffset: offset,
                                                       variant: variant), s)
                        samples.append(s)
                        if s != nil { painted += 1 }
                    }
                    guard part.name == "LES" else { continue }
                    let key = shape.material.rawValue, label = "\(variant) LES \(key) at \(shape.origin + offset)"
                    let onShells = vertices.allSatisfy { Self.distance($0.position + offset, to: cover) < inch }
                    if key.hasPrefix("apollo.bpc.") { XCTAssertEqual(element, .bpc, label) }
                    if key.hasPrefix("apollo.les.") { XCTAssertEqual(element, .les, label) }
                    if onShells {
                        XCTAssertEqual(element, .bpc, label)
                        if !key.hasPrefix("apollo.bpc.") { onCover += 1 }
                    }
                    if element == .bpc {
                        XCTAssertTrue(key.hasPrefix("apollo.bpc.") || onShells, label)
                        XCTAssertTrue(samples.allSatisfy { $0 != nil }, label)
                    } else {
                        XCTAssertEqual(element, .les, label)
                        XCTAssertTrue(samples.contains { $0 != nil }, label)
                    }
                }
            }
            XCTAssertGreaterThan(painted, 1000, "\(variant)")
            // The cover's window and blow-out ports, in the CM's finishes.
            XCTAssertGreaterThan(onCover, 0, "\(variant)")
            for element in [PaintElement.launchVehicle, .sla, .sm, .cm, .bpc, .les] {
                XCTAssertGreaterThan(elements[element] ?? 0, 0, "\(variant) \(element)")
            }
            XCTAssertEqual(elements[.ltaB] != nil, variant == .apollo8, "\(variant)")
        }
    }

    /// VD2's probe points lie on the dressed stacks' shapes of their own
    /// elements: a ray out from the vehicle's axis at a probe's station and
    /// azimuth meets a shape the lookup gives the probe's element, and the
    /// colour hook at the outermost such hit, on the vertex the mesh
    /// interpolates there, gives the probe's paint.
    func testProbesLieOnTheirElementsShapes() throws {
        let inch = 0.0254
        var checked = 0
        let flights: [(ApolloVariant, [String])] = [(.apollo8, ["AS-503", "CSM-103"]), (.apollo11, ["AS-506", "CSM-107"])]
        for (variant, vehicles) in flights {
            let stack = VesselLibrary.saturnV()
            for p in stack.parts { p.appearance = variant }
            VesselLibrary.dressApollo(stack)
            var shapes: [(part: String, shape: VisualShape, element: PaintElement, offset: Vec3, mesh: VisualShape.Mesh,
                          x: ClosedRange<Double>)] = []
            for part in stack.parts {
                let offset = part.offset - stack.structureOrigin
                for shape in part.shapes {
                    guard let element = PaintElement.of(part: part.name, shape: shape, partOffset: offset,
                                                        variant: variant) else { continue }
                    let mesh = shape.mesh(), xs = mesh.vertices.map { $0.position.x + offset.x }
                    guard let lo = xs.min(), let hi = xs.max() else { continue }
                    shapes.append((part.name, shape, element, offset, mesh, lo...hi))
                }
            }
            for probe in try vehicles.flatMap({ try XCTUnwrap(Markings.scheme($0)).probes }) {
                let x = probe.station * inch, a = probe.azimuth * Double.pi / 180
                let from = Vec3(x, 0, 0), ray = Vec3(0, -sin(a), cos(a))
                var hit: (t: Double, index: Int, vertex: VisualShape.Vertex)?
                for (index, c) in shapes.enumerated() where c.element == probe.element && c.x.contains(x) {
                    let m = c.mesh
                    for k in stride(from: 0, to: m.indices.count, by: 3) {
                        let tri = (0..<3).map { m.vertices[Int(m.indices[k + $0])] }
                        guard let (t, b) = Self.intersect(from, ray, tri.map { $0.position + c.offset }),
                              t > (hit?.t ?? 0) else { continue }
                        hit = (t, index, Self.interpolate(tri, b))
                    }
                }
                let h = try XCTUnwrap(hit, "\(probe.id): no \(probe.element) shape at STA \(probe.station), \(probe.azimuth)°")
                let c = shapes[h.index]
                let s = Markings.sample(part: c.part, shape: c.shape, vertex: h.vertex, partOffset: c.offset, variant: variant)
                XCTAssertEqual(s?.paint, probe.expected,
                               "\(probe.id) on \(c.part) \(c.shape.material) at r \(h.t / inch) in: \(s?.row ?? "none")")
                checked += 1
            }
        }
        XCTAssertEqual(checked, 40)
    }

    /// The BPC's two shells of the dressed "LES" part as (x, r) polylines
    /// in the construction frame (m): its full-turn `apollo.bpc.*` surfaces
    /// of revolution about the vehicle's axis.
    static func coverProfiles(_ part: VesselPart, offset: Vec3) -> [[(x: Double, r: Double)]] {
        part.shapes.compactMap { shape in
            guard shape.material.rawValue.hasPrefix("apollo.bpc."),
                  case let .revolution(profile, _, sweep) = shape.kind,
                  sweep.upperBound - sweep.lowerBound >= 2 * Double.pi - 1e-9 else { return nil }
            let o = shape.origin + offset
            guard abs(shape.axis.x - 1) < 1e-9, (o.y * o.y + o.z * o.z).squareRoot() < 1e-9 else { return nil }
            return profile.map { (o.x + $0.x, $0.r) }
        }
    }

    /// The distance (m) from construction point `p` to the nearest of the
    /// surfaces of revolution about the vehicle's axis whose profiles are
    /// `profiles`.
    static func distance(_ p: Vec3, to profiles: [[(x: Double, r: Double)]]) -> Double {
        let x = p.x, r = (p.y * p.y + p.z * p.z).squareRoot()
        var best = Double.infinity
        for profile in profiles {
            for (a, b) in zip(profile, profile.dropFirst()) {
                let dx = b.x - a.x, dr = b.r - a.r, l2 = dx * dx + dr * dr
                let t = l2 > 0 ? max(0, min(1, ((x - a.x) * dx + (r - a.r) * dr) / l2)) : 0
                let ex = a.x + t * dx - x, er = a.r + t * dr - r
                best = min(best, (ex * ex + er * er).squareRoot())
            }
        }
        return best
    }

    /// Where the ray from `o` along `d` meets triangle `p` (Möller-Trumbore,
    /// edges included): its parameter and the hit's barycentric weights.
    static func intersect(_ o: Vec3, _ d: Vec3, _ p: [Vec3]) -> (Double, (Double, Double, Double))? {
        let e1 = p[1] - p[0], e2 = p[2] - p[0], q = d.cross(e2), det = e1.dot(q)
        guard abs(det) > 1e-15 else { return nil }
        let s = o - p[0], u = s.dot(q) / det, r = s.cross(e1), v = d.dot(r) / det, t = e2.dot(r) / det
        let eps = 1e-9
        guard u >= -eps, v >= -eps, u + v <= 1 + eps, t > 0 else { return nil }
        return (t, (1 - u - v, u, v))
    }

    /// The vertex at barycentric weights `b` of triangle `tri`: position and
    /// surface coordinates interpolated as the renderer does, v unwrapped
    /// about the first vertex's.
    static func interpolate(_ tri: [VisualShape.Vertex], _ b: (Double, Double, Double)) -> VisualShape.Vertex {
        let w = [b.0, b.1, b.2], v0 = tri[0].surface.v
        func mix(_ f: (VisualShape.Vertex) -> Double) -> Double { zip(tri, w).reduce(0) { $0 + f($1.0) * $1.1 } }
        var vertex = tri[0]
        vertex.position = zip(tri, w).reduce(Vec3.zero) { $0 + $1.0.position * $1.1 }
        vertex.surface = VisualShape.SurfaceCoordinates(u: mix { $0.surface.u },
                                                        v: mix { v0 + remainder($0.surface.v - v0, 2 * Double.pi) },
                                                        r: mix { $0.surface.r }, s: mix { $0.surface.s })
        return vertex
    }

    /// Apollo 7's CSM-101, as `apolloCSM(.apollo7)` builds and dresses it
    /// and as its CM flies alone (the entry scenario's): every part is
    /// CSM-101's, the SM's shapes are painted as the SM and the CM's and
    /// the apex cover's as the CM, by CSM-101's rows only (no launch
    /// vehicle, no SLA rows: its Saturn IB is not built), the parachutes
    /// and the SPS nozzle unpainted. A single "CSM" part (the dresser's
    /// name for the SM and CM as one part) splits the same way for
    /// CSM-101, `apollo.cm.*` to the CM.
    func testApollo7ShapesFindTheirElements() throws {
        let variant = ApolloVariant.apollo7
        let scheme = Markings.scheme(for: variant)
        XCTAssertEqual(scheme.vehicles, ["CSM-101"])
        let cm = VesselLibrary.commandModule(.apollo7)
        VesselLibrary.dressApollo(cm)
        let expected: [String: PaintElement] = ["SM": .sm, "CM": .cm, "Apex cover": .cm]
        for vessel in [VesselLibrary.apolloCSM(.apollo7), cm] {
            var painted: [PaintElement: Int] = [:], rows: Set<String> = []
            for part in vessel.parts {
                XCTAssertEqual(part.appearance, variant, part.name)
                let offset = part.offset - vessel.structureOrigin
                for shape in part.shapes {
                    let element = PaintElement.of(part: part.name, shape: shape, partOffset: offset, variant: variant)
                    if PaintElement.unpaintedMaterials.contains(shape.material) || part.name.hasSuffix("parachutes") {
                        XCTAssertNil(element, "\(part.name) \(shape.material)")
                        continue
                    }
                    XCTAssertEqual(element, try XCTUnwrap(expected[part.name], part.name), "\(part.name) \(shape.material)")
                    guard let element else { continue }
                    for v in shape.mesh().vertices {
                        let s = Markings.sample(part: part.name, shape: shape, vertex: v, partOffset: offset, variant: variant)
                        XCTAssertEqual(s, scheme.sample(element, at: PaintCoordinates(v, of: shape, partOffset: offset)))
                        if let s {
                            painted[element, default: 0] += 1
                            rows.insert(s.row)
                        }
                    }
                }
            }
            XCTAssertTrue(rows.allSatisfy { $0.hasPrefix("101-") }, "\(vessel.name): \(rows.sorted())")
            XCTAssertGreaterThan(painted[.cm] ?? 0, 100, vessel.name)
            if vessel.parts.contains(where: { $0.name == "SM" }) {
                XCTAssertGreaterThan(painted[.sm] ?? 0, 100, vessel.name)
                XCTAssertTrue(rows.contains("101-001"), "the SM's bare aluminium")
            }
            XCTAssertTrue(rows.contains("101-020"), "the CM's Kapton")
        }
        // A single "CSM" part (the dresser's contract name for SM and CM
        // together), CSM-101's: its CM shapes to the CM, the rest to the SM.
        let single = VesselPart(name: "CSM", dryMass: 1, offset: ApolloAxes.construction(xa: 1_000), length: 5, radius: 2)
        single.appearance = variant
        let csm = Vessel(name: "CSM-101", parts: [single], reference: cm.reference)
        VesselLibrary.dressApollo(csm)
        var split: [PaintElement: Int] = [:]
        let offset = single.offset - csm.structureOrigin
        for shape in single.shapes where !PaintElement.unpaintedMaterials.contains(shape.material) {
            let element = try XCTUnwrap(PaintElement.of(part: "CSM", shape: shape, partOffset: offset, variant: variant))
            XCTAssertEqual(element, shape.material.rawValue.hasPrefix("apollo.cm.") ? .cm : .sm, "\(shape.material)")
            for v in shape.mesh().vertices {
                let s = Markings.sample(part: "CSM", shape: shape, vertex: v, partOffset: offset, variant: variant)
                if let s {
                    XCTAssertTrue(s.row.hasPrefix("101-"), s.row)
                    split[element, default: 0] += 1
                }
            }
        }
        XCTAssertGreaterThan(split[.sm] ?? 0, 100)
        XCTAssertGreaterThan(split[.cm] ?? 0, 100)
        // No launch vehicle paints anything on Apollo 7.
        let stack = VesselLibrary.saturnV()
        VesselLibrary.dressApollo(stack)
        for part in stack.parts where PaintElement.launchVehicleParts.contains(part.name) {
            let offset = part.offset - stack.structureOrigin
            for shape in part.shapes {
                XCTAssertNil(PaintElement.of(part: part.name, shape: shape, partOffset: offset, variant: variant))
            }
        }
    }
}
