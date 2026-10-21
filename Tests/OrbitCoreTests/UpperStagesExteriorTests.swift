import XCTest
@testable import OrbitCore

/// Track VG2's shapes against docs/SaturnV-CSM-exterior-datasheet.md §3-§8.2
/// (and the values scaled for the track, ApolloShapes+SII.swift and
/// +SIVB.swift): the S-II, the S-II/S-IVB interstage, the S-IVB, its ullage
/// rockets, the IU and the J-2s. Stations are STA (in), azimuths θ (deg) from
/// Position I towards II, as the datasheet has them.
///
/// The silhouette helper here (the maximum radius of the stack's section at
/// a station along an azimuth) stands in for L0's, which is not on main yet.
final class UpperStagesExteriorTests: XCTestCase {
    typealias S = ApolloShapeData
    let inch = 0.0254

    /// One stack for the class's read-only tests, and its triangles.
    static let stack = VesselLibrary.saturnV()
    static let triangles: [(Vec3, Vec3, Vec3)] = {
        var out: [(Vec3, Vec3, Vec3)] = []
        for p in stack.parts {
            for s in p.shapes {
                let t = s.triangles(offset: p.offset - stack.structureOrigin)
                for i in stride(from: 0, to: t.count, by: 3) {
                    out.append((t[i].position, t[i + 1].position, t[i + 2].position))
                }
            }
        }
        return out
    }()

    func part(_ name: String, of v: Vessel = UpperStagesExteriorTests.stack) throws -> VesselPart {
        try XCTUnwrap(v.parts.first { $0.name == name }, name)
    }

    func construction(_ p: VesselPart, of v: Vessel = UpperStagesExteriorTests.stack) -> Vec3 {
        p.offset - v.structureOrigin
    }

    /// Construction coordinates of a shape's vertices.
    func points(_ s: VisualShape, on p: VesselPart) -> [Vec3] {
        s.mesh(offset: construction(p)).vertices.map(\.position)
    }

    /// θ (deg, 0-360) of the construction point `c` about the vehicle's axis.
    func theta(_ c: Vec3) -> Double {
        let a = VisualShape.vehicleAzimuth(y: c.y, z: c.z) * 180 / Double.pi
        return a < 0 ? a + 360 : a
    }

    /// θ of the middle of a shape's span in azimuth (its vertices' range).
    func theta(of s: VisualShape, on p: VesselPart) -> Double {
        let v = points(s, on: p)
        let middle = theta(v.reduce(Vec3.zero, +) / Double(v.count))
        let off = v.map { angle(theta($0), middle) }
        let t = middle + (off.min()! + off.max()!) / 2
        return t < 0 ? t + 360 : (t >= 360 ? t - 360 : t)
    }

    /// The difference of two angles (deg), within half a turn.
    func angle(_ a: Double, _ b: Double) -> Double { remainder(a - b, 360) }

    func profile(_ s: VisualShape) -> [VisualShape.ProfilePoint]? {
        if case let .revolution(profile, _, _) = s.kind { return profile }
        return nil
    }

    func isPrism(_ s: VisualShape) -> Bool {
        if case .prism = s.kind { return true }
        return false
    }

    func isBox(_ s: VisualShape) -> Bool {
        if case .box = s.kind { return true }
        return false
    }

    /// The radius (in) of the stack's section at STA `sta`, along θ: the
    /// farthest crossing of the ray from the axis with the triangles cut by
    /// that plane.
    func silhouette(sta: Double, theta t: Double) -> Double {
        let x = sta * inch, a = t * Double.pi / 180
        let w = (y: -sin(a), z: cos(a))
        var reach = 0.0
        for (p0, p1, p2) in Self.triangles {
            let corners = [p0, p1, p2]
            var cut: [(y: Double, z: Double)] = []
            for k in 0..<3 {
                let p = corners[k], q = corners[(k + 1) % 3]
                let dp = p.x - x, dq = q.x - x
                guard (dp <= 0 && dq > 0) || (dp > 0 && dq <= 0) else { continue }
                let f = dp / (dp - dq)
                cut.append((p.y + f * (q.y - p.y), p.z + f * (q.z - p.z)))
            }
            guard cut.count == 2 else { continue }
            let b = (y: cut[1].y - cut[0].y, z: cut[1].z - cut[0].z)
            let wb = w.y * b.z - w.z * b.y
            guard abs(wb) > 1e-15 else { continue }
            let along = (cut[0].y * b.z - cut[0].z * b.y) / wb
            let f = (cut[0].y * w.z - cut[0].z * w.y) / wb
            if f >= -1e-12, f <= 1 + 1e-12, along > reach { reach = along }
        }
        return reach / inch
    }

    // MARK: S-II

    // The skin's bands at the body's 396 in, BCD's stations; the thrust cone
    // from XB 112 to 223, 18 ft across at the bottom (datasheet §14 item 5:
    // it no longer starts at the gimbal plane); the bulkheads' ends at XB
    // 152 and 955.
    func testSIIStationsAndRadii() throws {
        let sII = try part("S-II"), at = construction(sII).x
        let skin = try XCTUnwrap(profile(sII.shapes[0]))
        XCTAssertEqual(skin.map { (($0.x + sII.shapes[0].origin.x + at) / inch * 100).rounded() / 100 },
                       [1_760, 1_890, 2_387, 2_519])
        for p in skin { XCTAssertEqual(p.r / inch, 198, accuracy: 1e-9) }
        XCTAssertFalse(sII.shapes[0].capBase || sII.shapes[0].capTop)

        let revolutions = sII.shapes.compactMap { s in profile(s).map { (s, $0) } }
        func stations(_ s: VisualShape, _ p: [VisualShape.ProfilePoint]) -> [(sta: Double, r: Double)] {
            p.map { ((s.origin.x + at + $0.x) / inch, $0.r / inch) }
        }
        let cone = try XCTUnwrap(revolutions.first { s, p in p.count == 2 && s.material == .apolloGreyMetal })
        let c = stations(cone.0, cone.1)
        XCTAssertEqual(c[0].sta, 1_676, accuracy: 1e-9)
        XCTAssertEqual(c[0].r, 108, accuracy: 1e-9)
        XCTAssertEqual(c[1].sta, 1_787, accuracy: 1e-9)
        XCTAssertEqual(c[1].r, 198, accuracy: 1e-9)

        let domes = revolutions.filter { s, p in p.count == 13 }.map { stations($0.0, $0.1) }
        XCTAssertEqual(domes.count, 2)
        let poles = domes.map { d in d.first { $0.r < 1e-9 }!.sta }.sorted()
        XCTAssertEqual(poles[0], 1_716, accuracy: 1e-9)   // XB 152
        XCTAssertEqual(poles[1], 2_519, accuracy: 1e-9)   // XB 955
    }

    // The systems tunnel: 22 in wide, semicircular, from about 60 ft below
    // its top at STA 2502.5 (H), at θ 32° between Positions I and II (L);
    // the five LH2 feed-line fairings from the aft skirt's joint to STA
    // 2015.75, engine 1's at 44° and engine 4's at 314° (H).
    func testSIITunnelAndFeedFairings() throws {
        let sII = try part("S-II")
        let prisms = sII.shapes.filter(isPrism)
        XCTAssertEqual(prisms.count, 6)
        func extent(_ s: VisualShape) -> (from: Double, to: Double) {
            let x = points(s, on: sII).map(\.x)
            return (x.min()! / inch, x.max()! / inch)
        }
        let tunnel = try XCTUnwrap(prisms.max { extent($0).to - extent($0).from < extent($1).to - extent($1).from })
        XCTAssertEqual(extent(tunnel).to, 2_502.5, accuracy: 1e-6)
        XCTAssertEqual(extent(tunnel).from, 2_502.5 - 720, accuracy: 1e-6)
        XCTAssertEqual(angle(theta(of: tunnel, on: sII), 32), 0, accuracy: 1e-6)
        XCTAssertGreaterThan(theta(of: tunnel, on: sII), 0)
        XCTAssertLessThan(theta(of: tunnel, on: sII), 45)
        // 22 in across at the skin, 11 in proud.
        let across = Vec3.unitX.cross(Vec3(0, -sin(32 * Double.pi / 180), cos(32 * Double.pi / 180)))
        let b = points(tunnel, on: sII).map { $0.dot(across) / inch }
        XCTAssertEqual(b.max()! - b.min()!, 22, accuracy: 1e-6)
        XCTAssertEqual(silhouette(sta: 2_200, theta: 32), 198 + 11, accuracy: 1e-6)

        let feeds = prisms.filter { $0.origin != tunnel.origin }
        XCTAssertEqual(feeds.map { (theta(of: $0, on: sII) * 1e6).rounded() / 1e6 }.sorted(),
                       [44, 97, 134, 224, 314])
        for f in feeds {
            XCTAssertEqual(extent(f).from, 1_760, accuracy: 1e-6)
            XCTAssertEqual(extent(f).to, 2_015.75, accuracy: 1e-6)
        }
        XCTAssertEqual(silhouette(sta: 1_900, theta: 44), 198 + S.sIIFeedFairingDepth, accuracy: 1e-6)
        XCTAssertEqual(silhouette(sta: 1_900, theta: 314), 198 + S.sIIFeedFairingDepth, accuracy: 1e-6)
        // Between them, the bare skin (a vertex of the 192-gon at 0°).
        XCTAssertEqual(silhouette(sta: 1_900, theta: 0), 198, accuracy: 1e-6)

        // Four command antennas at STA 2487 and four telemetry ones at 2466.
        let boxes = sII.shapes.filter(isBox)
        let stations = boxes.map { s -> Double in
            let x = points(s, on: sII).map(\.x)
            return ((x.min()! + x.max()!) / 2 / inch * 100).rounded() / 100
        }
        XCTAssertEqual(stations.filter { $0 == 2_487 }.count, 4)
        XCTAssertEqual(stations.filter { $0 == 2_466 }.count, 4)
    }

    // The heat shield, its aft face at S-II station 44 (STA 1608): 160 in
    // out, cut 48 in round each engine's axis, where each curtain hangs from
    // its edge. Its aft face's area is the disc's less the five holes, as
    // polygons: the rim a 48-gon, the outboard holes 16-gons, the centre
    // one a 32-gon.
    func testSIIHeatShieldAndCurtains() throws {
        let sII = try part("S-II")
        let shield = sII.shapes.filter { $0.material == .apolloSIIHeatShield }
        XCTAssertEqual(shield.count, 8)
        let axes = sII.thrusters.filter { $0.groups.contains(.main) }.map { $0.position + construction(sII) }
        XCTAssertEqual(axes.count, 5)
        var area = 0.0
        for plate in shield {
            let mesh = plate.mesh(offset: construction(sII))
            for v in mesh.vertices {
                XCTAssertGreaterThanOrEqual(v.position.x / inch, 1_608 - 1e-9)
                XCTAssertLessThanOrEqual(v.position.x / inch, 1_610 + 1e-9)
                XCTAssertLessThanOrEqual((v.position.y * v.position.y + v.position.z * v.position.z).squareRoot() / inch,
                                         160 + 1e-9)
                for a in axes {
                    let d = Vec3(0, v.position.y - a.y, v.position.z - a.z).length / inch
                    XCTAssertGreaterThanOrEqual(d, 48 * cos(Double.pi / 16) - 1e-9)
                }
            }
            let t = mesh.triangles
            for i in stride(from: 0, to: t.count, by: 3) where t[i].normal.x < -0.999 {
                area += 0.5 * (t[i + 1].position - t[i].position).cross(t[i + 2].position - t[i].position).length
            }
        }
        /// The area of an n-gon inscribed in a circle of radius r (in).
        func polygon(_ n: Double, _ r: Double) -> Double { n / 2 * r * r * sin(2 * Double.pi / n) }
        let expected = (polygon(48, 160) - 4 * polygon(16, 48) - polygon(32, 48)) * inch * inch
        XCTAssertEqual(area / expected, 1, accuracy: 1e-9)

        let curtains = sII.shapes.filter { $0.material == .apolloCanvas }
        XCTAssertEqual(curtains.count, 5)
        for c in curtains {
            let top = try XCTUnwrap(profile(c)?.first)
            XCTAssertEqual(top.r / inch, 48, accuracy: 1e-9)
            XCTAssertEqual((c.origin.x + construction(sII).x + top.x) / inch, 1_608, accuracy: 1e-9)
        }
    }

    // The S-II ullage motors' fairings and exits, for the S-IC/S-II
    // interstage: about 16 in (4-5°) anticlockwise of the fin lines (VD2),
    // from STA 1563.56 to 1710.65, 24 in wide; the exits at the motors'
    // nozzles just above STA 1564, at the physics' radius, aft and 10° out.
    func testSIIUllageFairingsForTheInterstage() throws {
        let interstage = try part("S-IC/S-II interstage")
        let dresser = ApolloDresser(part: interstage, construction: construction(interstage), apexCovered: true,
                                    variant: .apollo11)
        let offset = 16 / 198.0 * 180 / Double.pi
        XCTAssertEqual(offset, 4.63, accuracy: 0.01)
        let fairings = dresser.sIIUllageFairings()
        XCTAssertEqual(fairings.count, 4)
        for (k, f) in fairings.enumerated() {
            XCTAssertEqual(angle(theta(of: f, on: interstage), 45 + 90 * Double(k) + offset), 0, accuracy: 1e-6)
            let x = points(f, on: interstage).map { $0.x / inch }
            XCTAssertEqual(x.min()!, 1_563.56, accuracy: 1e-6)
            XCTAssertEqual(x.max()!, 1_710.65, accuracy: 1e-6)
        }
        let exits = dresser.sIIUllageExits()
        XCTAssertEqual(exits.compactMap(\.thruster), (1...4).map { "S-II ullage motor \($0)" })
        for (k, e) in exits.enumerated() {
            let c = e.position + construction(interstage)
            XCTAssertEqual(e.kind, .ullageExit)
            XCTAssertEqual(c.x / inch, 1_565, accuracy: 1e-9)
            XCTAssertEqual(Vec3(0, c.y, c.z).length, AS506.sIIUllageMotorRadius, accuracy: 1e-12)
            XCTAssertEqual(angle(theta(c), 45 + 90 * Double(k) + offset), 0, accuracy: 1e-9)
            XCTAssertEqual(acos(-e.direction.x) * 180 / Double.pi, 10, accuracy: 1e-9)
            XCTAssertGreaterThan(Vec3(0, e.direction.y, e.direction.z).dot(Vec3(0, c.y, c.z)), 0)
        }
    }

    // MARK: S-II/S-IVB interstage

    // The cone from 396 to 260 in over STA 2519-2746.5, a 16°44′ half-angle
    // (TMX) to 0.1°; four retro fairings on the fin diagonals, each leaving
    // the cone at STA 2582.7 (VD2) and standing 6 in proud by 2600.
    func testInterstageAndRetroFairings() throws {
        let interstage = try part("S-II/S-IVB interstage")
        let cone = try XCTUnwrap(profile(interstage.shapes[0]))
        XCTAssertEqual(cone[0].r / inch, 198, accuracy: 1e-9)
        XCTAssertEqual(cone[1].r / inch, 130, accuracy: 1e-9)
        let length = (cone[1].x - cone[0].x) / inch
        XCTAssertEqual(length, 2_746.5 - 2_519, accuracy: 1e-9)
        XCTAssertEqual(atan(68 / length) * 180 / Double.pi, 16 + 44.0 / 60, accuracy: 0.1)

        let fairings = interstage.shapes.filter(isPrism)
        XCTAssertEqual(fairings.map { (theta(of: $0, on: interstage) * 1e6).rounded() / 1e6 }, [45, 135, 225, 315])
        let slope = 68 / (2_746.5 - 2_519)
        func coneRadius(_ sta: Double) -> Double { 198 - (sta - 2_519) * slope }
        for t in [45.0, 135, 225, 315] {
            XCTAssertEqual(silhouette(sta: 2_582.0, theta: t), coneRadius(2_582.0), accuracy: 1e-6)
            let proud = silhouette(sta: 2_600, theta: t) - coneRadius(2_600)
            XCTAssertEqual(proud, 6.1, accuracy: 0.2)
        }
        XCTAssertEqual(silhouette(sta: 2_600, theta: 0), coneRadius(2_600), accuracy: 1e-6)
    }

    // The retro ports: at each motor's nozzle, the forward end (STA 2629)
    // of a 104.68 in motor that starts after STA 2519, outside the cone,
    // on the motor's diagonal, the exhaust against its thrust. They stay
    // put when the S-II and the interstage leave.
    func testRetroPorts() throws {
        let stack = VesselLibrary.saturnV()
        let interstage = try part("S-II/S-IVB interstage", of: stack)
        let ports = interstage.attachments.filter { $0.kind == .retroPort }
        XCTAssertEqual(ports.compactMap(\.thruster), (1...4).map { "S-II retro motor \($0)" })
        let slope = 68 / (2_746.5 - 2_519)
        var before: [Vec3] = []
        for (k, port) in ports.enumerated() {
            let motor = try XCTUnwrap(interstage.thrusters.first { $0.name == port.thruster })
            let c = port.position + construction(interstage, of: stack)
            before.append(c)
            XCTAssertEqual(c.x / inch, 2_629, accuracy: 1e-9)
            let r = Vec3(0, c.y, c.z).length / inch
            XCTAssertGreaterThan(r, 198 - (2_629 - 2_519) * slope + 4)
            XCTAssertEqual(angle(theta(c), 45 + 90 * Double(k)), 0, accuracy: 1e-9)
            XCTAssertEqual((port.direction + motor.direction).length, 0, accuracy: 1e-12)
            XCTAssertEqual(port.radius / inch, 3.5, accuracy: 1e-12)
        }
        let spent = try XCTUnwrap(stack.jettison(event: 4))
        VesselLibrary.dressApollo(spent)
        let after = interstage.attachments.filter { $0.kind == .retroPort }.map {
            $0.position + interstage.offset - spent.structureOrigin
        }
        XCTAssertEqual(after.count, 4)
        for (a, b) in zip(before, after) { XCTAssertEqual((a - b).length, 0, accuracy: 1e-9) }
    }

    // MARK: S-IVB

    // The skin's bands at 260 in, BCD's stations; the R 130 in domes from
    // STA 2702 to 3230.56; the thrust structure 5.2 ft from the gimbal to
    // the aft dome (datasheet §14 item 9: it no longer runs to the aft
    // skirt), its large end on the dome about 40 in out; eight helium
    // spheres round it.
    func testSIVBStationsAndRadii() throws {
        let sIVB = try part("S-IVB"), at = construction(sIVB).x
        let skin = try XCTUnwrap(profile(sIVB.shapes[0]))
        XCTAssertEqual(skin.map { (($0.x + sIVB.shapes[0].origin.x + at) / inch * 100).rounded() / 100 },
                       [2_746.5, 2_832, 3_100.56, 3_222.56])
        for p in skin { XCTAssertEqual(p.r / inch, 130, accuracy: 1e-9) }

        let revolutions = sIVB.shapes.compactMap { s in profile(s).map { (s, $0) } }
        func stations(_ s: VisualShape, _ p: [VisualShape.ProfilePoint]) -> [(sta: Double, r: Double)] {
            p.map { ((s.origin.x + at + $0.x) / inch, $0.r / inch) }
        }
        let domes = revolutions.filter { $0.1.count == 13 }.map { stations($0.0, $0.1) }
        let poles = domes.map { d in d.first { $0.r < 1e-9 }!.sta }.sorted()
        XCTAssertEqual(poles[0], 2_702, accuracy: 1e-9)
        XCTAssertEqual(poles[1], 3_230.56, accuracy: 1e-9)

        let thrust = try XCTUnwrap(revolutions.first { $0.1.count == 2 && $0.0.material == .apolloGreyMetal })
        let t = stations(thrust.0, thrust.1)
        XCTAssertEqual(t[0].sta, 2_645.85, accuracy: 1e-9)
        XCTAssertEqual(t[1].sta - t[0].sta, 5.2 * 12, accuracy: 1e-9)
        XCTAssertEqual(pow(t[1].r / 129, 2) + pow((2_832 - t[1].sta) / 130, 2), 1, accuracy: 1e-12)
        XCTAssertEqual(t[1].r, 40, accuracy: 1)
        XCTAssertTrue(thrust.0.capBase)

        let spheres = sIVB.shapes.filter { if case .sphere = $0.kind { return true }; return false }
        XCTAssertEqual(spheres.count, 8)
    }

    // The APS modules at Positions I and III, 24 in deep on the aft skirt
    // from STA 2748 to 2862; an aligned cone near each APS engine, which
    // `VesselGeometry` takes as its nozzle (within 0.6 m, along its thrust).
    func testAPSModules() throws {
        let sIVB = try part("S-IVB")
        let modules = sIVB.shapes.filter { isPrism($0) && $0.origin.y == 0 && $0.origin.z != 0 }
        XCTAssertEqual(modules.map { (theta(of: $0, on: sIVB) * 1e9).rounded() / 1e9 }.sorted(), [0, 180])
        for m in modules {
            let x = points(m, on: sIVB).map { $0.x / inch }
            XCTAssertEqual(x.min()!, 2_748, accuracy: 1e-6)
            XCTAssertEqual(x.max()!, 2_862, accuracy: 1e-6)
        }
        XCTAssertEqual(silhouette(sta: 2_760, theta: 0), 130 + 24, accuracy: 1e-6)
        XCTAssertEqual(silhouette(sta: 2_760, theta: 180), 130 + 24, accuracy: 1e-6)
        XCTAssertEqual(silhouette(sta: 2_760, theta: 45), 130, accuracy: 1e-6)

        let aps = sIVB.thrusters.filter { $0.name.hasPrefix("APS") }
        XCTAssertEqual(aps.count, 8)
        for t in aps {
            let nozzle = sIVB.shapes.first { s in
                guard case let .frustum(base, top) = s.kind, base > top, s.axis.dot(t.direction) > 0.98 else {
                    return false
                }
                return (s.origin + s.axis * s.length - t.position).length < 0.6
            }
            XCTAssertNotNil(nozzle, t.name)
        }
    }

    // The two TX-280 fairings, diametrically opposite, 17.5° off the fin B
    // and D diagonals towards Positions II and IV (D5: 15-20°), on the aft
    // skirt from STA 2748; their exits at the nozzles below, aft and 35°
    // out. They leave with their part, where they were.
    func testTX280Fairings() throws {
        let rockets = try part("S-IVB ullage rockets")
        let fairings = rockets.shapes.filter(isPrism)
        let thetas = fairings.map { theta(of: $0, on: rockets) }
        XCTAssertEqual(thetas.count, 2)
        XCTAssertEqual(thetas[0], 117.5, accuracy: 1e-6)
        XCTAssertEqual(thetas[1], 297.5, accuracy: 1e-6)
        XCTAssertGreaterThan(thetas[0], 90)    // between Position II
        XCTAssertLessThan(thetas[0], 135)      // and fin B
        XCTAssertGreaterThan(thetas[1], 270)   // between Position IV
        XCTAssertLessThan(thetas[1], 315)      // and fin D
        XCTAssertEqual(silhouette(sta: 2_760, theta: 117.5), 130 + 10.5, accuracy: 1e-6)
        XCTAssertEqual(silhouette(sta: 2_760, theta: 297.5), 130 + 10.5, accuracy: 1e-6)

        let exits = rockets.attachments.filter { $0.kind == .ullageExit }
        XCTAssertEqual(exits.compactMap(\.thruster), ["S-IVB ullage motor 1", "S-IVB ullage motor 2"])
        let cant = AS506.sIVBUllageMotorCant * Double.pi / 180
        for (e, t) in zip(exits, thetas) {
            let c = e.position + construction(rockets)
            XCTAssertEqual(c.x / inch, 2_748 - 5 * cos(cant), accuracy: 1e-9)
            XCTAssertEqual(Vec3(0, c.y, c.z).length / inch, AS506.sIVBUllageMotorRadius / inch + 5 * sin(cant),
                           accuracy: 1e-9)
            XCTAssertEqual(angle(theta(c), t), 0, accuracy: 1e-9)
            XCTAssertEqual(acos(-e.direction.x), cant, accuracy: 1e-12)
        }
    }

    // The tunnels and the forward skirt's telemetry antennas: the systems
    // tunnel at θ 100° from STA 2783 to 3152, the helium one at 74° from
    // 2984 to 3094 (scaled, L), the antennas at 79° and 259° (M) on STA
    // 3193.56 (H).
    func testSIVBTunnelsAndAntennas() throws {
        let sIVB = try part("S-IVB")
        let tunnels = sIVB.shapes.filter { isPrism($0) && $0.origin.y != 0 }
        XCTAssertEqual(tunnels.count, 2)
        for (t, expected) in zip(tunnels, [(100.0, 2_783.0, 3_152.0), (74, 2_984, 3_094)]) {
            XCTAssertEqual(theta(of: t, on: sIVB), expected.0, accuracy: 1e-6)
            let x = points(t, on: sIVB).map { $0.x / inch }
            XCTAssertEqual(x.min()!, expected.1, accuracy: 1e-6)
            XCTAssertEqual(x.max()!, expected.2, accuracy: 1e-6)
        }
        let rods = sIVB.shapes.filter { s in
            if case .frustum = s.kind { return s.material == .apolloGreyMetal && abs(s.axis.x) < 1e-9 }
            return false
        }
        XCTAssertEqual(rods.map { (theta(of: $0, on: sIVB) * 1e9).rounded() / 1e9 }, [79, 259])
        for r in rods { XCTAssertEqual((r.origin.x + construction(sIVB).x) / inch, 3_193.56, accuracy: 1e-9) }
    }

    // MARK: IU

    // The IU's ring over STA 3222.56-3258.56; its doors between Positions I
    // and II near II; its antennas in the datasheet's groups.
    func testInstrumentUnit() throws {
        let iu = try part("IU")
        let ring = try XCTUnwrap(profile(iu.shapes[0]))
        XCTAssertEqual(ring.map { (($0.x + iu.shapes[0].origin.x + construction(iu).x) / inch * 100).rounded() / 100 },
                       [3_222.56, 3_258.56])
        let doors = iu.shapes.filter(isPrism).map { theta(of: $0, on: iu) }
        XCTAssertEqual(doors.count, 2)
        for d in doors {
            XCTAssertGreaterThan(d, 45)
            XCTAssertLessThan(d, 90)
        }
        let antennas = iu.shapes.filter(isBox).map { s -> Double in
            let t = (theta(of: s, on: iu) * 1e6).rounded() / 1e6
            return t == 360 ? 0 : t
        }
        XCTAssertEqual(antennas.sorted(), [0, 0, 96, 111, 128, 128, 276, 291, 308, 308])
        XCTAssertEqual(silhouette(sta: 3_240.56, theta: 96), 133, accuracy: 1e-6)
        XCTAssertEqual(silhouette(sta: 3_240.56, theta: 45), 130, accuracy: 1e-6)
    }

    // MARK: J-2

    // Every J-2 at RJ1's dimensions (datasheet §8.2, §14 item 15): an 80.75
    // in envelope, the exit 77 in across (the rating's, 1 mm off), a 14.7 in
    // throat and an 18.3 in chamber; gimbal to exit 116 ± 3 in (M), the
    // fuel inlet manifold 61 in across 65 in aft of the gimbal; one shape
    // linked to its thruster; the turbopumps clear of the bell.
    func testJ2() throws {
        var engines = 0
        for name in ["S-II", "S-IVB"] {
            let p = try part(name)
            for t in p.thrusters where t.groups.contains(.main) {
                engines += 1
                let linked = p.shapes.filter { $0.thruster == t.name }
                XCTAssertEqual(linked.count, 1)
                let shape = try XCTUnwrap(linked.first), j2 = try XCTUnwrap(profile(shape))
                XCTAssertEqual(j2[0].r * 2 / inch, 77, accuracy: 0.1)
                XCTAssertEqual(j2[0].r, (AS506.j2ExitArea / Double.pi).squareRoot(), accuracy: 1e-12)
                XCTAssertEqual(j2.map(\.r).max()! * 2 / inch, 80.75, accuracy: 1e-9)
                let length = shape.length / inch
                XCTAssertEqual(length, 116, accuracy: 3)
                XCTAssertEqual((construction(p).x + shape.origin.x) / inch + length,
                               name == "S-II" ? AS506.sIIJ2GimbalStation : AS506.sIVBJ2GimbalStation,
                               accuracy: 1e-9)
                // The inside: from the injector face's rim down the chamber and
                // the bell (past the top's centre and the face's).
                let inside = j2.drop { $0.r > 0 }.dropFirst(2)
                XCTAssertEqual(inside.map(\.r).min()! * 2 / inch, 14.7, accuracy: 1e-9)
                XCTAssertEqual(inside.first!.r * 2 / inch, 18.3, accuracy: 1e-9)
                let manifold = j2.filter { abs(length - $0.x / inch - 65) < 3.6 }.map(\.r).max()!
                XCTAssertEqual(manifold * 2 / inch, 61, accuracy: 1e-9)

                // The pumps stand clear of the bell's wall along their length.
                let pumps = p.shapes.filter { s in
                    guard case .frustum = s.kind, s.material == .apolloGreyMetal else { return false }
                    return (Vec3(0, s.origin.y, s.origin.z) - Vec3(0, t.position.y, t.position.z)).length < 0.6
                }
                XCTAssertEqual(pumps.count, 2)
                for pump in pumps {
                    guard case let .frustum(radius, _) = pump.kind else { continue }
                    let off = (Vec3(0, pump.origin.y, pump.origin.z) - Vec3(0, t.position.y, t.position.z)).length
                    for k in 0...10 {
                        let x = pump.origin.x + pump.length * Double(k) / 10 - shape.origin.x
                        XCTAssertGreaterThan(off - radius, ApolloDresser.outerRadius(of: j2, at: x))
                    }
                }
            }
        }
        XCTAssertEqual(engines, 6)
    }
}
