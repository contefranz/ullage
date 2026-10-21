import XCTest
@testable import OrbitCore

/// The spacecraft as `VesselLibrary.dressApollo` draws it (track VG3),
/// against the VD3 datasheet (docs/SaturnV-CSM-exterior-datasheet.md §9-§13):
/// the stations of the SLA, SM, SPS and LES; the LES truss; which vehicle
/// shows which item (HGA, probe, LTA-B); the CM's face and diameter.
/// Stations are Apollo stations Xa (in), azimuths θ the vehicle's (deg from
/// Position I towards Position II; θ = θ_A + 90°, the AOH's θ_A from +Y_A
/// towards +Z_A).
final class CSMExteriorTests: XCTestCase {
    let inch = 0.0254

    // MARK: Helpers

    /// The Apollo station (in) of construction x (m).
    func xa(_ x: Double) -> Double { x / inch - 2_756.56 }

    /// The distance (in) of construction point `c` from the vehicle's axis.
    func radius(_ c: Vec3) -> Double { (c.y * c.y + c.z * c.z).squareRoot() / inch }

    /// The vehicle azimuth (deg, 0-360) of construction point `c`.
    func theta(_ c: Vec3) -> Double {
        let t = atan2(-c.y, c.z) * 180 / Double.pi
        return t < 0 ? t + 360 : t
    }

    /// The angle (deg) between azimuths `a` and `b`.
    func apart(_ a: Double, _ b: Double) -> Double { abs(remainder(a - b, 360)) }

    /// The Saturn V with every part dressed as `variant`.
    func stack(_ variant: ApolloVariant) -> Vessel {
        let v = VesselLibrary.saturnV()
        for p in v.parts { p.appearance = variant }
        VesselLibrary.dressApollo(v)
        return v
    }

    func part(_ v: Vessel, _ name: String) throws -> VesselPart {
        try XCTUnwrap(v.parts.first { $0.name == name }, name)
    }

    /// The construction-frame vertices of `shapes` on `p`, a part of `v`.
    func points(_ shapes: [VisualShape], on p: VesselPart, of v: Vessel) -> [Vec3] {
        shapes.flatMap { $0.mesh(offset: p.offset - v.structureOrigin).vertices.map(\.position) }
    }

    /// A shape's origin in the construction frame.
    func origin(_ s: VisualShape, on p: VesselPart, of v: Vessel) -> Vec3 { s.origin + p.offset - v.structureOrigin }

    /// A revolution's profile in inches.
    func profile(_ s: VisualShape) -> [(x: Double, r: Double)] {
        guard case let .revolution(profile, _, _) = s.kind else { return [] }
        return profile.map { (x: $0.x / inch, r: $0.r / inch) }
    }

    /// The SLA's radius (in) at `station`: 260 in at Xa 502 to 154 in at Xa
    /// 838 (datasheet §12).
    func slaRadius(_ station: Double) -> Double { 130 - 53 * (station - 502) / 336 }

    // MARK: SLA

    // The SLA, Xa 502 to 838 (28 ft), 260 to 154 in, its panels hinged at Xa
    // 583.2, where it is 234.4 in across; the seams on the diagonals, each
    // carrying its splice strip, half on each panel; the hinge line's frame.
    func testSLAStationsAndSeams() throws {
        let v = stack(.apollo11)
        let ring = try part(v, "SLA ring")
        let shell = profile(ring.shapes[0]), base = xa(origin(ring.shapes[0], on: ring, of: v).x)
        XCTAssertEqual(base, 502, accuracy: 1e-6)
        XCTAssertEqual(base + shell.last!.x, 583.2, accuracy: 1e-6)
        XCTAssertEqual(2 * shell.first!.r, 260, accuracy: 1e-6)
        XCTAssertEqual(2 * shell.last!.r, 234.4, accuracy: 0.05)
        let frame = points([ring.shapes[1]], on: ring, of: v)
        XCTAssertEqual(xa(frame.map(\.x).max()!), 583.2, accuracy: 1e-6)
        XCTAssertEqual(ring.shapes[1].material, .apolloSLASeam)

        var seams: [Double] = []
        for n in 1...4 {
            let panel = try part(v, "SLA panel \(n)")
            let skin = profile(panel.shapes[0]), at = xa(origin(panel.shapes[0], on: panel, of: v).x)
            XCTAssertEqual(at, 583.2, accuracy: 1e-6)
            XCTAssertEqual(at + skin.last!.x, 838, accuracy: 1e-6)
            XCTAssertEqual((at + skin.last!.x - base) / 12, 28, accuracy: 1e-6)
            XCTAssertEqual(2 * skin.last!.r, 154, accuracy: 1e-6)
            let strips = panel.shapes.filter { $0.material == .apolloSLASeam }
            XCTAssertEqual(strips.count, 2, "panel \(n)")
            for strip in strips {
                let c = points([strip], on: panel, of: v)
                XCTAssertEqual(xa(c.map(\.x).min()!), 583.2, accuracy: 0.1, "panel \(n)")
                XCTAssertEqual(xa(c.map(\.x).max()!), 838, accuracy: 0.1, "panel \(n)")
                // On the skin, just off it, and within 2.1 in of its seam.
                for p in c {
                    XCTAssertEqual(radius(p), slaRadius(xa(p.x)), accuracy: 0.45, "panel \(n)")
                }
                let mean = c.reduce(Vec3.zero, +) / Double(c.count)
                seams.append((theta(mean) / 45).rounded() * 45)
                XCTAssertLessThan(apart(theta(mean), seams.last!), 2.1 / 77 * 180 / Double.pi, "panel \(n)")
            }
        }
        // Each diagonal seam twice, once from each of its panels.
        XCTAssertEqual(seams.sorted(), [45, 45, 135, 135, 225, 225, 315, 315])
    }

    // MARK: LTA-B and the LM stand-in

    // Apollo 8's "LM" part draws LTA-B: about 160 in across its flange, Xa
    // 509 to 635, its "#" of four beams and the fitting on its deck, hung on
    // four V-strut pairs from the fixed panels' rim at Xa 583.2 at the LM
    // support points; inside the SLA and clear of the SPS. Apollo 11's
    // draws the LM-5 stand-in as before.
    func testLTABOnApollo8Only() throws {
        let v = stack(.apollo8)
        let lm = try part(v, "LM")
        XCTAssertTrue(lm.shapes.allSatisfy { $0.material == .apolloLTAB })
        let c = points(lm.shapes, on: lm, of: v)
        let onAxis = lm.shapes.filter { s in let o = origin(s, on: lm, of: v); return abs(o.y) + abs(o.z) < 1e-9 }
        XCTAssertEqual(2 * points(onAxis, on: lm, of: v).map(radius).max()!, 160, accuracy: 1e-6)   // the flange's corners
        XCTAssertEqual(xa(c.map(\.x).min()!), 509, accuracy: 0.5)
        XCTAssertEqual(xa(c.map(\.x).max()!), 635, accuracy: 0.1)
        for p in c { XCTAssertLessThan(radius(p), slaRadius(xa(p.x))) }
        XCTAssertLessThan(xa(c.map(\.x).max()!), 721.3)   // the SPS's exit
        XCTAssertEqual(lm.shapes.filter { if case .box = $0.kind { true } else { false } }.count, 4)
        // The struts: four V pairs, each pair's apex at the rim on ±Y_A or ±Z_A.
        let struts = lm.shapes.filter { s in profile(s).count == 2 && abs(s.axis.x) < 0.99 }
        XCTAssertEqual(struts.count, 8)
        var apexes: [Double] = []
        for s in struts {
            let top = origin(s, on: lm, of: v) + s.axis * s.length
            XCTAssertEqual(xa(top.x), 583.2, accuracy: 1e-6)
            XCTAssertEqual(radius(top), slaRadius(583.2) - 2, accuracy: 0.01)
            apexes.append(theta(top).rounded().truncatingRemainder(dividingBy: 360))
        }
        XCTAssertEqual(Set(apexes), [0, 90, 180, 270])

        let a11 = stack(.apollo11), stand = try part(a11, "LM")
        XCTAssertFalse(stand.shapes.contains { $0.material == .apolloLTAB })
        XCTAssertEqual(stand.shapes.count, 3)
        XCTAssertEqual(profile(stand.shapes[0]).first!.r * inch, AS506.lmRadius, accuracy: 1e-12)
        XCTAssertTrue(stand.shapes[0].faceted)

        // An SLA that flew empty draws nothing in its "LM" part.
        let empty = VesselLibrary.saturnV()
        for p in empty.parts { p.appearance = ApolloVariant(launchVehicle: .as503, csm: .csm103, payload: .empty) }
        VesselLibrary.dressApollo(empty)
        XCTAssertTrue(try part(empty, "LM").shapes.isEmpty)
    }

    // MARK: Service module

    // The SM's cylinder from its aft bulkhead, Xa 838, to its forward one,
    // Xa 993, 154 in across; the fairing to Xa 1014.72 in sixteen pieces,
    // eight EPS radiators alternating with eight panels; the ECS radiators
    // over bays 2-3 and 5-6; the scimitars near ±Y_A.
    func testSMShellRadiatorsAndScimitars() throws {
        let v = stack(.apollo11), sm = try part(v, "SM")
        let shell = sm.shapes[0], at = xa(origin(shell, on: sm, of: v).x)
        XCTAssertEqual(at, 838, accuracy: 1e-6)
        XCTAssertEqual(at + profile(shell).last!.x, 993, accuracy: 1e-6)
        XCTAssertEqual(profile(shell)[0].r, 77, accuracy: 1e-9)

        let fairing = sm.shapes.filter { s in
            abs(xa(origin(s, on: sm, of: v).x) - 993) < 1e-6 && s.twoSided
        }
        XCTAssertEqual(fairing.count, 16)
        XCTAssertEqual(fairing.filter { $0.material == .apolloSMRadiator }.count, 8)
        for (i, piece) in fairing.enumerated() {
            guard case let .revolution(p, _, sweep) = piece.kind else { return XCTFail() }
            XCTAssertEqual(xa(origin(piece, on: sm, of: v).x) + p.last!.x / inch, 1014.72, accuracy: 1e-6)
            XCTAssertEqual((sweep.upperBound - sweep.lowerBound) * 180 / Double.pi, 22.5, accuracy: 1e-9)
            XCTAssertEqual(piece.material == .apolloSMRadiator, i % 2 == 0)
        }

        // ECS radiators: θ_A 332.75-102.75 and 152.75-282.75, Xa 838.5-880.
        let ecs = sm.shapes.filter { $0.material == .apolloSMRadiator && !$0.twoSided }
        XCTAssertEqual(ecs.count, 2)
        for (radiator, bays) in zip(ecs, [(332.75, 102.75), (152.75, 282.75)]) {
            let c = points([radiator], on: sm, of: v)
            XCTAssertEqual(xa(c.map(\.x).min()!), 838.5, accuracy: 1e-6)
            XCTAssertEqual(xa(c.map(\.x).max()!), 880, accuracy: 1e-6)
            let start = bays.0 + 90, end = bays.1 + 90
            let azimuths = c.map(theta)
            XCTAssertTrue(azimuths.contains { apart($0, start) < 1e-6 })
            XCTAssertTrue(azimuths.contains { apart($0, end) < 1e-6 })
            XCTAssertTrue(azimuths.allSatisfy { apart($0, (start + end) / 2 + (end < start ? 180 : 0)) <= 65 + 1e-6 })
        }

        let scimitars = sm.shapes.filter { $0.material == .apolloSMScimitar }
        XCTAssertEqual(scimitars.count, 2)
        for (blade, azimuth) in zip(scimitars, [24.0, 204.0]) {
            let c = points([blade], on: sm, of: v)
            XCTAssertEqual(c.map(\.x).max()! - c.map(\.x).min()!, 19 * inch, accuracy: 1e-9)
            XCTAssertEqual(c.map(radius).max()!, 77 + 9, accuracy: 0.1)
            let mean = c.reduce(Vec3.zero, +) / Double(c.count)
            XCTAssertLessThan(apart(theta(mean), azimuth + 90), 2)
        }
    }

    // The SM RCS quads at Xa 958.97, each 7°15′ off its axis (θ_A 262.75°,
    // 352.75°, 82.75°, 172.75°), their housings' faces 83.56 in from the
    // axis; the fore and aft R-4Ds canted 10° outwards with their thrust
    // lines meeting 82.36 in out, the roll engines' at 83.00 in; each of the
    // stack's sixteen SM RCS thrusters linked to its own nozzle.
    func testSMRCSQuads() throws {
        let v = stack(.apollo11), sm = try part(v, "SM")
        let housings = sm.shapes.filter { $0.material == .apolloSMRCSHousing }
        XCTAssertEqual(housings.count, 4)
        for (housing, azimuth) in zip(housings, [262.75, 352.75, 82.75, 172.75]) {
            let c = points([housing], on: sm, of: v), out = SpacecraftGeometry.radial((azimuth + 90) * Double.pi / 180)
            XCTAssertEqual(c.map { $0.dot(out) }.max()! / inch, 83.56, accuracy: 1e-6)
            XCTAssertEqual(xa((c.map(\.x).max()! + c.map(\.x).min()!) / 2), 958.97, accuracy: 1e-6)
            XCTAssertEqual(xa(c.map(\.x).max()!) - xa(c.map(\.x).min()!), 13.5, accuracy: 1e-6)
            let mean = c.reduce(Vec3.zero, +) / Double(c.count)
            XCTAssertLessThan(apart(theta(mean), azimuth + 90), 1e-6)
        }

        let nozzles = sm.shapes.filter { $0.material == .apolloEngineBell }
        XCTAssertEqual(nozzles.count, 16)
        XCTAssertEqual(Set(nozzles.compactMap(\.thruster)).count, 16)
        for nozzle in nozzles {
            let exit = origin(nozzle, on: sm, of: v), back = nozzle.axis   // into the engine
            XCTAssertEqual(profile(nozzle)[0].r, 2.8, accuracy: 1e-9)
            let t = try XCTUnwrap(sm.thrusters.first { $0.name == nozzle.thruster })
            XCTAssertGreaterThan(back.dot(t.direction), cos(10.01 * Double.pi / 180), t.name)
            // The thrust line through the exit meets the quad's point.
            let quad = ["A": 262.75, "B": 352.75, "C": 82.75, "D": 172.75][String(t.name.dropFirst(7).prefix(1))]!
            let roll = abs(back.x) < 1e-9
            let out = SpacecraftGeometry.radial((quad + 90) * Double.pi / 180)
            let meet = Vec3(AS506.apolloStation(958.97), 0, 0) + out * ((roll ? 83.0 : 82.36) * inch)
            let d = meet - exit, miss = d - back * d.dot(back)
            XCTAssertEqual(miss.length, 0, accuracy: 1e-9, t.name)
            XCTAssertEqual(abs(back.x), roll ? 0 : cos(10 * Double.pi / 180), accuracy: 1e-12, t.name)
            if !roll { XCTAssertLessThan(back.dot(out), 0, t.name) }   // canted away from the panel
        }
    }

    // The SPS: its exit at Xa 721.3, 98.4 in across inside, its bell to the
    // gimbal plane at Xa 833.2, 159.944 in of engine in all, so what shows
    // is the nozzle extension, 28.8 in across at the top; the columbium band
    // from the joint (Xa 760, L) up to the 6:1 chamber exit; all of it turns
    // with the thruster.
    func testSPS() throws {
        let v = stack(.apollo11), sm = try part(v, "SM")
        let linked = sm.shapes.filter { $0.thruster == "SPS" }
        XCTAssertEqual(linked.count, 3)
        let bell = linked.last!, band = try XCTUnwrap(linked.first { $0.material == .apolloSPSColumbium })
        let exit = xa(origin(bell, on: sm, of: v).x), b = profile(bell)
        XCTAssertEqual(exit, 721.3, accuracy: 1e-9)
        XCTAssertEqual(2 * b.first!.r, 98.4, accuracy: 1e-9)
        XCTAssertEqual(exit + b.last!.x, 833.2, accuracy: 1e-9)
        XCTAssertEqual(2 * b.last!.r, 28.8, accuracy: 0.05)
        // The bell's throat, 62.5:1 down from the exit, lies above the gimbal
        // in the 159.944 in engine.
        XCTAssertGreaterThan(b.last!.r, 49.2 / 62.5.squareRoot())
        let c = profile(band), bandBase = xa(origin(band, on: sm, of: v).x)
        XCTAssertEqual(bandBase + c.first!.x, 760, accuracy: 1e-9)
        XCTAssertEqual(c.last!.r - 0.08, 49.2 * (6 / 62.5).squareRoot(), accuracy: 1e-6)   // 6:1
        XCTAssertLessThan(bandBase + c.last!.x, 833.2)
        guard case .torus = linked[0].kind else { return XCTFail("the stiffener") }
        XCTAssertEqual(xa(origin(linked[0], on: sm, of: v).x), 760, accuracy: 1e-9)
    }

    // MARK: High-gain antenna

    // The HGA: none on CSM-101; four 31 in (79 cm) dishes round an 11 in
    // horn on CSM-103 and CSM-107, its root at θ_A 127.75°. On the stack it
    // is stowed inside the SLA, clear of the SPS nozzle; on the CSM alone,
    // or once a re-dress follows the CSM's separation (event 6), it is
    // deployed at right angles to X, the array 38 in outboard of the skin,
    // its dishes looking aft.
    func testHighGainAntenna() throws {
        func hga(_ p: VesselPart) -> [VisualShape] { p.shapes.filter { $0.material == .apolloHighGainAntenna } }
        XCTAssertTrue(hga(try part(VesselLibrary.apolloCSM(.apollo7), "SM")).isEmpty)
        XCTAssertEqual(hga(try part(stack(.apollo8), "SM")).count, 6)

        for v in [VesselLibrary.apolloCSM(.apollo11), stack(.apollo11)] {
            let sm = try part(v, "SM"), shapes = hga(sm), stowed = sm.centeredUntilEvent != nil
            XCTAssertEqual(shapes.count, 6)
            let dishes = shapes.filter { $0.twoSided }
            XCTAssertEqual(dishes.count, 4)
            for dish in dishes { XCTAssertEqual(2 * profile(dish).last!.r * inch, 0.79, accuracy: 0.005) }
            let horn = try XCTUnwrap(shapes.first { if case .box = $0.kind { true } else { false } })
            guard case let .box(width, height) = horn.kind else { return XCTFail() }
            XCTAssertEqual(width / inch, 11, accuracy: 1e-9)
            XCTAssertEqual(height / inch, 11, accuracy: 1e-9)
            let centre = origin(horn, on: sm, of: v) + horn.axis * (horn.length / 2)
            XCTAssertLessThan(apart(theta(centre), 127.75 + 90), 1e-6)
            if stowed {
                // Inside the SLA and clear of the nozzle.
                let sps = sm.shapes.last { $0.thruster == "SPS" }!
                let bell = profile(sps), exit = xa(origin(sps, on: sm, of: v).x)
                func bellRadius(_ station: Double) -> Double {
                    let x = station - exit
                    for (a, b) in zip(bell, bell.dropFirst()) where x >= a.x && x <= b.x {
                        return a.r + (b.r - a.r) * (x - a.x) / (b.x - a.x)
                    }
                    return 0
                }
                for p in points(shapes, on: sm, of: v) {
                    XCTAssertLessThan(radius(p), slaRadius(xa(p.x)))
                    XCTAssertGreaterThan(radius(p) - bellRadius(xa(p.x)), 10)
                    XCTAssertLessThan(xa(p.x), 838)
                }
                XCTAssertEqual(horn.axis.x, 0, accuracy: 1e-12)   // the dishes look in at the nozzle
            } else {
                XCTAssertEqual(radius(centre), 77 + 38, accuracy: 1e-9)
                XCTAssertEqual((horn.axis + Vec3.unitX).length, 0, accuracy: 1e-12)   // aft
            }
        }

        // The stack's CSM, once separated and dressed again, deploys it.
        let v = stack(.apollo11)
        _ = v.jettisonAll(event: 6)
        VesselLibrary.dressApollo(v)
        let sm = try part(v, "SM"), horn = hga(sm).first { if case .box = $0.kind { true } else { false } }!
        XCTAssertEqual(radius(origin(horn, on: sm, of: v) + horn.axis * (horn.length / 2)), 115, accuracy: 1e-9)
    }

    // MARK: Command module

    // The CM's heat-shield face at Xa 998 and its 154 in maximum diameter
    // near Xa 1020; no apex beyond the docking interface, Xa 1110.25, but
    // CSM-107's probe; the forward heat shield (the apex cover) from Xa
    // 1081.13 up to it.
    func testCMFaceAndDiameter() throws {
        for (v, covered) in [(stack(.apollo11), true), (VesselLibrary.apolloCSM(.apollo7), true)] {
            let cm = try part(v, "CM")
            let heatShield = try XCTUnwrap(cm.shapes.first { $0.emissive == .heatShield })
            XCTAssertEqual(heatShield.material, .apolloCMFoil)   // the Kapton covers the ablator
            let face = xa(origin(heatShield, on: cm, of: v).x)
            XCTAssertEqual(face, 998, accuracy: 1e-9)
            let widest = profile(heatShield).max { $0.r < $1.r }!
            XCTAssertEqual(2 * widest.r, 154, accuracy: 1e-9)
            XCTAssertEqual(face + widest.x, 1019.9, accuracy: 0.1)
            let probe = cm.shapes.filter { $0.material == .apolloDockingProbe }
            let top = points(cm.shapes.filter { $0.material != .apolloDockingProbe }, on: cm, of: v).map(\.x).max()!
            XCTAssertEqual(xa(top), 1110.25 + 0.05, accuracy: 1e-9)   // the docking ring's lip
            let afterbody = cm.shapes[1]
            XCTAssertEqual(face + profile(afterbody).map(\.x).max()!, 1110.25, accuracy: 1e-9)
            XCTAssertEqual(probe.count, v.parts[0].appearance?.csm == .csm107 ? 1 : 0)
            if covered {
                let cover = try part(v, "Apex cover"), shield = cover.shapes[0]
                let c = profile(shield), base = xa(origin(shield, on: cover, of: v).x)
                XCTAssertEqual(base, 1081.13, accuracy: 1e-9)
                XCTAssertEqual(base + c.last!.x, 1110.25, accuracy: 1e-9)
                XCTAssertEqual(c.last!.r, 16.5, accuracy: 1e-9)
            }
        }
        let s = stack(.apollo11), cm = try part(s, "CM")
        let probe = try XCTUnwrap(cm.shapes.first { $0.material == .apolloDockingProbe })
        XCTAssertEqual(xa(points([probe], on: cm, of: s).map(\.x).max()!), 1130.25, accuracy: 1e-9)

        // Alone without its cover (after event 30), the CM ends at the
        // interface with the forward heat shield's top and the tunnel.
        let alone = VesselLibrary.commandModule(.apollo7)
        _ = alone.jettisonAll(event: 30)
        VesselLibrary.dressApollo(alone)
        let bare = try part(alone, "CM")
        let ab = profile(bare.shapes[1]), at = xa(origin(bare.shapes[1], on: bare, of: alone).x)
        XCTAssertEqual(at + ab.map(\.x).max()!, 1110.25, accuracy: 1e-9)
        XCTAssertEqual(ab.filter { abs(at + $0.x - 1110.25) < 1e-9 }.map(\.r).max()!, 19.8, accuracy: 0.05)
        XCTAssertTrue(ab.contains { abs($0.r - 14) < 1e-9 })   // the 28 in clear tunnel
    }

    // Five windows at θ 304°, 326°, 0°, 34° and 56° (1 to 5): the hatch's
    // and the rendezvous windows between Xa 1043.4 and 1081.13; the side
    // windows 13 in square, the rendezvous windows 13 by 8 in triangles, the
    // hatch's 9 in round. The hatch 34 by 29 in on θ 0°. Twelve RCS ports in
    // pairs, the -pitch pair on the forward heat shield.
    func testCMWindowsHatchAndPorts() throws {
        let v = stack(.apollo11), cm = try part(v, "CM")
        let panes = cm.shapes.filter { $0.material == .apolloCMWindow }
        XCTAssertEqual(panes.count, 5)
        let expected: [(theta: Double, across: Double, up: Double)] = [(304, 13, 13), (326, 13, 8), (0, 9, 9),
                                                                        (34, 13, 8), (56, 13, 13)]
        for (pane, e) in zip(panes, expected) {
            let at = origin(pane, on: cm, of: v) + pane.axis * (0.9 * inch)   // the pane's foot on the cone
            XCTAssertLessThan(apart(theta(at), e.theta), 1e-6)
            guard case let .prism(section, _) = pane.kind else { return XCTFail() }
            let a = section.map(\.a), b = section.map(\.b)
            XCTAssertEqual((a.max()! - a.min()!) / inch, e.across, accuracy: 0.1)
            XCTAssertEqual((b.max()! - b.min()!) / inch, e.up, accuracy: 0.1)
            if e.theta == 0 || e.up == 8 {
                for p in points([pane], on: cm, of: v) { XCTAssertTrue((1043.4...1081.13).contains(xa(p.x))) }
            }
        }

        let hatch = try XCTUnwrap(cm.shapes.first { s in
            if case let .revolution(_, _, sweep) = s.kind { sweep.upperBound - sweep.lowerBound < 1 } else { false }
        })
        let c = points([hatch], on: cm, of: v)
        // 34 in round the cone at the hatch's middle, Xa 1062.3, where it is 50.96 in from the axis.
        XCTAssertEqual(2 * c.map(theta).map { apart($0, 0) }.max()! * Double.pi / 180 * 50.96, 34, accuracy: 0.5)
        let slant = (xa(c.map(\.x).max()!) - xa(c.map(\.x).min()!)) / cos(33 * Double.pi / 180)
        XCTAssertEqual(slant, 29, accuracy: 0.5)

        func ports(_ p: VesselPart) -> Int { p.shapes.filter { $0.material == .apolloCMRCSPort }.count }
        let cover = try part(v, "Apex cover")
        XCTAssertEqual(ports(cm), 10)
        XCTAssertEqual(ports(cover), 2)
        for p in points(cover.shapes.filter { $0.material == .apolloCMRCSPort }, on: cover, of: v) {
            XCTAssertGreaterThan(xa(p.x), 1081.13)
        }
        let alone = VesselLibrary.commandModule(.apollo7)
        _ = alone.jettisonAll(event: 30)
        VesselLibrary.dressApollo(alone)
        XCTAssertEqual(ports(try part(alone, "CM")), 12)
    }

    // MARK: Launch escape system

    // The LES at the AOH's stations (Xa = XL + 1083.476): the skirt XL
    // 118.3-138, 54 to 28.89 in; the LES motor's case to XL 283, 26 in, its
    // four nozzles' 15 in exits at XL 97.43, canted 35°, 53.66 in across
    // them; the TJM to XL 338.6, its two nozzles at 30° in the pitch plane
    // reaching its 28 in envelope; the canard section's 26 in cylinder to XL
    // 363.7, then one 15° cone through the 13.3 in Q-ball base at XL 387.5
    // to the tip at XL 400.762, rounded on a 4 in radius: 33 ft from the
    // separation plane. The pitch motor's 8.8 in case, 22 in to its exit on
    // -Z_A.
    func testLESStations() throws {
        let v = stack(.apollo11), les = try part(v, "LES")
        func xl(_ x: Double) -> Double { xa(x) - 1_083.476 }
        let tip = points(les.shapes, on: les, of: v).map(\.x).max()!
        XCTAssertEqual(xl(tip), 400.762, accuracy: 1e-9)
        XCTAssertEqual(xl(tip) / 12, 33.4, accuracy: 0.05)   // "33 feet"

        let skirt = try XCTUnwrap(les.shapes.first { $0.material == .apolloLESSkirt })
        let s = profile(skirt), skirtBase = xl(origin(skirt, on: les, of: v).x)
        XCTAssertEqual(skirtBase, 118.3, accuracy: 1e-9)
        XCTAssertEqual(skirtBase + s.last!.x, 138, accuracy: 1e-9)
        XCTAssertEqual(2 * s[0].r, 54, accuracy: 1e-9)
        XCTAssertEqual(2 * s[1].r, 28.89, accuracy: 1e-9)

        // The bodies of revolution on the axis, bottom up: the LES motor, the
        // TJM, the canard section, the Q-ball.
        let bodies = les.shapes.filter { s in
            let o = origin(s, on: les, of: v)
            return !s.twoSided && s.capTop && profile(s).count > 2 && abs(o.y) + abs(o.z) < 1e-9
                && abs(s.axis.x - 1) < 1e-12 && s.material != .apolloLESCanard
        }
        XCTAssertEqual(bodies.count, 4)
        let spans = bodies.map { b -> (Double, Double) in
            let c = points([b], on: les, of: v).map(\.x)
            return (xl(c.min()!), xl(c.max()!))
        }
        XCTAssertEqual(spans[0].1, 283, accuracy: 1e-9)
        XCTAssertEqual(spans[1].0, 283, accuracy: 1e-9)
        XCTAssertEqual(spans[1].1, 338.6, accuracy: 1e-9)
        XCTAssertEqual(spans[2].1, 387.5, accuracy: 1e-9)
        XCTAssertEqual(spans[3].0, 387.5, accuracy: 1e-9)
        XCTAssertEqual(spans[3].1 - spans[3].0, 13.3, accuracy: 0.1)   // CNR15: 13.37 (text), 13.275 (figure)
        for body in bodies[0...2] { XCTAssertEqual(profile(body).map(\.r).max()!, 13, accuracy: 1e-9) }
        // The motor case from the skirt's top; the nose cone from XL 363.7.
        let motor = profile(bodies[0]), motorBase = xl(origin(bodies[0], on: les, of: v).x)
        XCTAssertEqual(motorBase + motor.first { abs($0.r - 13) < 1e-9 }!.x, 138, accuracy: 1e-9)
        let section = profile(bodies[2]), sectionBase = xl(origin(bodies[2], on: les, of: v).x)
        XCTAssertEqual(sectionBase + section.filter { abs($0.r - 13) < 1e-9 }.map(\.x).max()!, 363.7, accuracy: 1e-9)
        let q = profile(bodies[3])
        XCTAssertEqual(2 * q[1].r, 13.3, accuracy: 0.1)
        XCTAssertEqual(atan2(q[1].r - q[2].r, q[2].x - q[1].x) * 180 / Double.pi, 15, accuracy: 1e-9)
        // The tip on a 4 in sphere (TRN §2.3): its last points equidistant
        // from a centre 4 in below the tip.
        for p in q.suffix(5) {
            XCTAssertEqual(((q.last!.x - 4 - p.x) * (q.last!.x - 4 - p.x) + p.r * p.r).squareRoot(), 4, accuracy: 0.01)
        }

        // The nozzles: dark open bells; the LES motor's four, the TJM's two.
        let nozzles = les.shapes.filter { $0.material == .apolloEngineBell }
        XCTAssertEqual(nozzles.count, 4 + 2 + 1)
        var escape = 0, jettison = 0
        for n in nozzles {
            let exit = origin(n, on: les, of: v), r0 = profile(n)[0].r, out = (-n.axis).x   // the exhaust's x
            if abs(r0 - 7.5) < 1e-9 {
                escape += 1
                XCTAssertEqual(xl(exit.x), 97.43, accuracy: 1e-9)
                XCTAssertEqual(acos(-out) * 180 / Double.pi, 35, accuracy: 1e-9)
                XCTAssertEqual(radius(exit) + 7.5 * cos(35 * Double.pi / 180), 53.66 / 2, accuracy: 1e-9)
            } else if abs(r0 - 3) < 1e-9 {
                jettison += 1
                XCTAssertEqual(acos(-out) * 180 / Double.pi, 30, accuracy: 1e-9)
                XCTAssertEqual(radius(exit) + 3 * cos(30 * Double.pi / 180), 14, accuracy: 1e-9)
                XCTAssertTrue(apart(theta(exit), 180) < 1e-6 || apart(theta(exit), 0) < 1e-6)   // ±Z_A
            }
        }
        XCTAssertEqual(escape, 4)
        XCTAssertEqual(jettison, 2)

        // The pitch motor: its 8.8 in case across the axis along Z_A, and its
        // nozzle to the skin on -Z_A (Position I), 22 in in all.
        let pitch = try XCTUnwrap(les.shapes.first { s in
            profile(s).count == 2 && !s.twoSided && abs(xa(origin(s, on: les, of: v).x) - 1428.97) < 1e-6
        })
        XCTAssertEqual(abs(pitch.axis.z), 1, accuracy: 1e-12)
        XCTAssertEqual(profile(pitch)[0].r, 4.4, accuracy: 1e-9)
        let ends = [origin(pitch, on: les, of: v), origin(pitch, on: les, of: v) + pitch.axis * pitch.length]
        XCTAssertEqual(xa(ends[0].x), 1428.97, accuracy: 1e-9)
        let far = ends.map(\.z).min()! / inch   // -z is +Z_A
        XCTAssertEqual(13 - far, 22, accuracy: 1e-9)
    }

    // The truss: four 3.5 in legs from a 50.67 by 46.84 in rectangle at XL 0
    // ("about 4 feet square") to a 36.06 in square at XL 118.3; on each face
    // the hour-glass (four 2.5 in tubes converging on the short horizontal J
    // at XL 88.6 and spreading to the full horizontal M at XL 59.7), a long
    // and a half diagonal, the 3.5 in horizontal P at XL 35.87 and the
    // inverted V to the legs at XL 12.85. The hour-glass leaves the motor's
    // nozzles clear.
    func testLESTruss() throws {
        let v = stack(.apollo11), les = try part(v, "LES")
        func xl(_ x: Double) -> Double { xa(x) - 1_083.476 }
        let tubes = les.shapes.filter { $0.material == .apolloLESTower }
        XCTAssertEqual(tubes.count, 4 + 4 * 11)
        let ends = tubes.map { t -> (a: Vec3, b: Vec3, r: Double) in
            let a = origin(t, on: les, of: v)
            return (a, a + t.axis * t.length, profile(t)[0].r)
        }
        XCTAssertEqual(ends.filter { abs($0.r - 1.75) < 1e-9 }.count, 4 + 4)
        XCTAssertEqual(ends.filter { abs($0.r - 1.25) < 1e-9 }.count, 4 * 10)

        // The legs: Apollo (Y, Z) of their feet and tops.
        for leg in ends.prefix(4) {
            XCTAssertEqual(xl(leg.a.x), 0, accuracy: 1e-9)
            XCTAssertEqual(xl(leg.b.x), 118.3, accuracy: 1e-9)
            XCTAssertEqual(abs(leg.a.y) / inch, 50.67 / 2, accuracy: 1e-9)
            XCTAssertEqual(abs(leg.a.z) / inch, 46.84 / 2, accuracy: 1e-9)
            XCTAssertEqual(radius(leg.a), 34.5, accuracy: 0.05)
            XCTAssertEqual(atan2(abs(leg.a.z), abs(leg.a.y)) * 180 / Double.pi, 42.75, accuracy: 0.05)
            XCTAssertEqual(abs(leg.b.y) / inch, 36.06 / 2, accuracy: 1e-9)
            XCTAssertEqual(abs(leg.b.z) / inch, 36.06 / 2, accuracy: 1e-9)
        }
        XCTAssertEqual((50.67 + 46.84) / 2 / 12, 4, accuracy: 0.1)

        // The horizontals: J short, M and P across the face.
        func horizontals(at station: Double) -> [Double] {
            ends.filter { abs(xl($0.a.x) - station) < 1e-6 && abs(xl($0.b.x) - station) < 1e-6 }
                .map { ($0.b - $0.a).length / inch }
        }
        func width(at station: Double) -> (Double, Double) {
            (25.335 + (18.03 - 25.335) * station / 118.3, 23.42 + (18.03 - 23.42) * station / 118.3)
        }
        for (station, share) in [(88.6, 1.0 / 3), (59.7, 1.0), (35.87, 1.0)] {
            let w = width(at: station), found = horizontals(at: station).sorted()
            XCTAssertEqual(found.count, 4, "XL \(station)")
            let faces = [2 * w.1, 2 * w.1, 2 * w.0, 2 * w.0].map { $0 * share }.sorted()
            for (a, b) in zip(found, faces) { XCTAssertEqual(a, b, accuracy: 1e-6, "XL \(station)") }
        }
        XCTAssertTrue(ends.filter { abs(xl($0.a.x) - 35.87) < 1e-6 && abs(xl($0.b.x) - 35.87) < 1e-6 }
            .allSatisfy { abs($0.r - 1.75) < 1e-9 })
        // The V: eight tubes from XL 35.87 down to the legs at XL 12.85.
        let vee = ends.filter { abs(xl($0.a.x) - 35.87) < 1e-6 && abs(xl($0.b.x) - 12.85) < 1e-6 }
        XCTAssertEqual(vee.count, 8)
        // The hour-glass's eight tubes from the top to J.
        XCTAssertEqual(ends.filter { abs(xl($0.a.x) - 118.3) < 1e-6 && abs(xl($0.b.x) - 88.6) < 1e-6 }.count, 8)

        // Each LES motor nozzle's exit rim clears every tube.
        for nozzle in les.shapes.filter({ $0.material == .apolloEngineBell && abs(profile($0)[0].r - 7.5) < 1e-9 }) {
            let centre = origin(nozzle, on: les, of: v), r = 7.5 * inch
            let u = nozzle.axis.cross(.unitX).normalized, w = nozzle.axis.cross(u)
            for k in 0..<36 {
                let a = Double(k) * Double.pi / 18, p = centre + u * (r * cos(a)) + w * (r * sin(a))
                for tube in ends {
                    let d = tube.b - tube.a, t = max(0, min(1, (p - tube.a).dot(d) / d.lengthSquared))
                    XCTAssertGreaterThan(((p - (tube.a + d * t)).length / inch) - tube.r, 0.5)
                }
            }
        }
    }

    // The canards: two 100° arc segments of the canard section's skin side
    // by side on one half, XL 339.6 to 386.5, stowed flush.
    func testCanards() throws {
        let v = stack(.apollo11), les = try part(v, "LES")
        let canards = les.shapes.filter { $0.material == .apolloLESCanard }
        XCTAssertEqual(canards.count, 2)
        var middles: [Double] = []
        for canard in canards {
            guard case let .revolution(_, _, sweep) = canard.kind else { return XCTFail() }
            XCTAssertEqual((sweep.upperBound - sweep.lowerBound) * 180 / Double.pi, 100, accuracy: 1e-9)
            middles.append((sweep.lowerBound + sweep.upperBound) / 2 * 180 / Double.pi)
            let c = points([canard], on: les, of: v)
            XCTAssertEqual(xa(c.map(\.x).min()!) - 1_083.476, 339.6, accuracy: 1e-9)
            XCTAssertEqual(xa(c.map(\.x).max()!) - 1_083.476, 386.5, accuracy: 1e-9)
            for p in c where xa(p.x) - 1_083.476 < 363.7 { XCTAssertLessThan(radius(p), 13.2) }
        }
        XCTAssertEqual(apart(middles[0], middles[1]), 110, accuracy: 1e-9)
    }

    // The BPC: its aft edge at Xa 1014 on the SM's fairing, the joint at Xa
    // 1081, its apex at Xa 1135.13 on the axis; the CM, its probe and the
    // forward heat shield inside it; an 8 in window over window 2, a hatch
    // over the CM's, a blow-out port over each RCS port.
    func testBPC() throws {
        let v = stack(.apollo11), les = try part(v, "LES")
        let shells = les.shapes.filter { $0.material == .apolloBPCSoft || $0.material == .apolloBPC }
            .filter { if case let .revolution(_, _, sweep) = $0.kind { sweep.upperBound > 6 } else { false } }
        XCTAssertEqual(shells.count, 2)
        let face = xa(origin(shells[0], on: les, of: v).x)
        let profile = shells.flatMap { self.profile($0).map { (x: face + $0.x, r: $0.r) } }
        XCTAssertEqual(profile.first!.x, 1014, accuracy: 1e-9)
        XCTAssertEqual(profile.first!.r, 77, accuracy: 0.2)
        XCTAssertEqual(profile.last!.x, 1135.13, accuracy: 1e-9)
        XCTAssertEqual(profile.last!.r, 0, accuracy: 1e-9)
        XCTAssertTrue(profile.contains { abs($0.x - 1081) < 1e-9 })
        /// The BPC's radius at `station`: the widest of its segments there.
        func bpc(_ station: Double) -> Double {
            zip(profile, profile.dropFirst()).compactMap { a, b -> Double? in
                guard station >= min(a.x, b.x) && station <= max(a.x, b.x), b.x != a.x else { return nil }
                return a.r + (b.r - a.r) * (station - a.x) / (b.x - a.x)
            }.max() ?? 0
        }
        for name in ["CM", "Apex cover"] {
            let p = try part(v, name)
            for c in points(p.shapes, on: p, of: v) where xa(c.x) > 1014.72 {
                XCTAssertLessThan(radius(c), bpc(xa(c.x)), name)
            }
        }

        let window = les.shapes.filter { $0.material == .apolloCMWindow }
        XCTAssertEqual(window.count, 1)
        guard case let .prism(section, _) = window[0].kind else { return XCTFail() }
        XCTAssertEqual((section.map(\.a).max()! - section.map(\.a).min()!) / inch, 8, accuracy: 0.05)
        XCTAssertLessThan(apart(theta(origin(window[0], on: les, of: v)), 326), 1e-6)
        XCTAssertEqual(les.shapes.filter { $0.material == .apolloBPCSoft }.count, 2)   // the shell and the hatch
        // The twelve blow-out ports, and the TJM's two ports and the pitch motor's exit.
        XCTAssertEqual(les.shapes.filter { $0.material == .apolloCMRCSPort }.count, 12 + 2 + 1)
    }

    // MARK: Variants

    // What each vehicle shows: Apollo 7's CSM-101 neither HGA nor probe;
    // Apollo 8's CSM-103 the HGA and LTA-B; Apollo 11's CSM-107 the HGA, the
    // probe and the LM.
    func testVariantSwitches() throws {
        func count(_ v: Vessel, _ material: MaterialKey) -> Int {
            v.parts.reduce(0) { $0 + $1.shapes.filter { $0.material == material }.count }
        }
        let cases: [(Vessel, hga: Bool, probe: Bool, ltaB: Bool, lm: Bool)] = [
            (VesselLibrary.apolloCSM(.apollo7), false, false, false, false),
            (stack(.apollo8), true, false, true, false),
            (stack(.apollo11), true, true, false, true),
            (VesselLibrary.apolloCSM(.apollo11), true, true, false, false),
        ]
        for (v, hga, probe, ltaB, lm) in cases {
            XCTAssertEqual(count(v, .apolloHighGainAntenna) > 0, hga, v.name)
            XCTAssertEqual(count(v, .apolloDockingProbe) > 0, probe, v.name)
            XCTAssertEqual(count(v, .apolloLTAB) > 0, ltaB, v.name)
            XCTAssertEqual(count(v, .apolloLMFoil) > 0, lm, v.name)
        }
    }
}
