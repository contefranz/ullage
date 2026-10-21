import XCTest
@testable import OrbitCore

/// `VisualShape` and `VesselLibrary.dressApollo`: every part dressed, the
/// nozzle links, the sourced dimensions and the tessellation.
final class VisualShapeTests: XCTestCase {
    let inch = 0.0254

    /// Construction x (m) of Apollo station `xa` (in).
    func xa(_ xa: Double) -> Double { AS506.apolloStation(xa) }

    /// A part spanning construction x `bottom...top` (m), on the axis.
    func part(_ name: String, _ bottom: Double, _ top: Double, radius: Double = 1) -> VesselPart {
        VesselPart(name: name, dryMass: 100, offset: Vec3((bottom + top) / 2, 0, 0), length: top - bottom,
                   radius: radius)
    }

    /// Stand-ins for the M1.5 parts above the S-IVB, by the ROADMAP's naming
    /// contract and at their stations, until tracks C and E2 build them. The
    /// SM carries an "SPS" and two "SM RCS" jets.
    func splitStack() -> Vessel {
        let sm = part("SM", xa(838), xa(1010), radius: 1.96)
        let ox = PropellantTank(name: "SPS oxidizer", capacity: 1000)
        sm.thrusters = [Thruster(name: "SPS", position: Vec3(xa(833) - sm.offset.x, 0, 0), direction: .unitX,
                                 maxThrustVacuum: 93_768, ispVacuum: 312.34, tank: ox, groups: [.main]),
                        Thruster(name: "SM RCS A1", position: Vec3(xa(959) - sm.offset.x, 0.3, 1.96),
                                 direction: -Vec3.unitX, maxThrustVacuum: 444, ispVacuum: 276, tank: ox, groups: []),
                        Thruster(name: "SM RCS C1", position: Vec3(xa(959) - sm.offset.x, -0.3, -1.96),
                                 direction: .unitX, maxThrustVacuum: 444, ispVacuum: 276, tank: ox, groups: [])]
        let parts = [part("S-IVB", AS506.station(AS506.sIVBAftSkirt), AS506.station(AS506.sIVBTop), radius: 3.3),
                     part("IU", AS506.station(AS506.sIVBTop), AS506.station(AS506.iuTop), radius: 3.3),
                     part("SLA ring", xa(502), xa(586), radius: 3.3)]
            + (1...4).map { part("SLA panel \($0)", xa(586), xa(838), radius: 3) }
            + [part("LM", AS506.height(AS506.lmBottomHeight), AS506.height(AS506.lmTopHeight), radius: 2.1), sm,
               part("CM", xa(1000), xa(1127), radius: 1.96), part("Apex cover", xa(1088), xa(1127), radius: 0.9),
               part("Drogue parachutes", xa(1088), xa(1100), radius: 0.5),
               part("Main parachutes", xa(1088), xa(1100), radius: 0.6)]
        let v = Vessel(name: "Split", parts: parts, reference: VesselLibrary.placeholderBody)
        VesselLibrary.dressApollo(v)
        return v
    }

    /// Every vehicle the library builds, and the split stack before and
    /// after the CM leaves the SM.
    func vehicles() -> [Vessel] {
        let split = splitStack()
        let cm = split.separate(parts: split.parts.filter { ["CM", "Apex cover", "Drogue parachutes",
                                                              "Main parachutes"].contains($0.name) }, name: "CM")!
        return [VesselLibrary.saturnV(), VesselLibrary.testRocket(), VesselLibrary.capsule(), splitStack(), split, cm]
    }

    /// Construction coordinates of the triangles of `shape` on `part`.
    func triangles(_ shape: VisualShape, on part: VesselPart, of v: Vessel) -> [VisualShape.Vertex] {
        shape.triangles(offset: part.offset - v.structureOrigin)
    }

    /// The (x, r) profile of a revolution, or nil.
    func profile(_ s: VisualShape) -> [VisualShape.ProfilePoint]? {
        if case let .revolution(profile, _, _) = s.kind { return profile }
        return nil
    }

    // Every part of every vehicle has shapes, each of which tessellates.
    func testEveryPartIsDressed() {
        for v in vehicles() {
            for p in v.parts {
                XCTAssertFalse(p.shapes.isEmpty, "\(v.name): \(p.name)")
                for s in p.shapes { XCTAssertFalse(s.triangles().isEmpty, "\(v.name): \(p.name)") }
            }
        }
        // The Saturn V's SLA (track C's ring and panels) dresses as the
        // stand-in's.
        let stack = VesselLibrary.saturnV(), split = splitStack()
        func count(_ v: Vessel, _ names: [String]) -> Int {
            v.parts.filter { names.contains($0.name) }.reduce(0) { $0 + $1.shapes.count }
        }
        let sla = ["SLA ring", "SLA panel 1", "SLA panel 2", "SLA panel 3", "SLA panel 4"]
        XCTAssertEqual(count(stack, sla), count(split, sla))
    }

    // Dressing again replaces the shapes with the same ones; a part the dress
    // does not know keeps its own.
    func testDressingIsRepeatable() {
        let stack = VesselLibrary.saturnV()
        let origins = stack.parts.map { $0.shapes.map(\.origin) }
        VesselLibrary.dressSaturnV(stack)
        XCTAssertEqual(stack.parts.map { $0.shapes.map(\.origin) }, origins)

        let rocket = VesselLibrary.testRocket(), before = rocket.parts.map { $0.shapes.map(\.origin) }
        VesselLibrary.dressApollo(rocket)
        XCTAssertEqual(rocket.parts.map { $0.shapes.map(\.origin) }, before)
    }

    // A separation keeps the construction frame: the CM leaving the SM with
    // its apex cover and parachutes draws where it was drawn on the stack,
    // dressed again or not. Without the cover the CM's afterbody runs on up
    // to the docking interface, 112.25 in above the face (datasheet §9.1).
    func testShapesSurviveSeparation() {
        let split = splitStack()
        let leaving = split.parts.filter { ["CM", "Apex cover", "Drogue parachutes", "Main parachutes"].contains($0.name) }
        func positions(_ v: Vessel) -> [Vec3] {
            leaving.flatMap { p in p.shapes.flatMap { triangles($0, on: p, of: v) } }.map(\.position)
        }
        let before = positions(split)
        let cm = split.separate(parts: leaving, name: "CM")!
        for redress in [false, true] {
            if redress { VesselLibrary.dressApollo(cm) }
            let after = positions(cm)
            XCTAssertEqual(before.count, after.count)
            for (a, b) in zip(before, after) { XCTAssertEqual((a - b).length, 0, accuracy: 1e-9) }
        }
        let cover = cm.separate(parts: cm.parts.filter { $0.name == "Apex cover" }, name: "Apex cover")!
        VesselLibrary.dressApollo(cm)
        let shapes = cm.parts.first { $0.name == "CM" }!.shapes
        let afterbody = shapes.first { $0.origin == shapes[0].origin && $0.emissive == .none }!
        XCTAssertEqual(profile(afterbody)!.map(\.x).max()! / inch, 1_110.25 - 998, accuracy: 1e-9)
        // The forward heat shield and its -pitch RCS ports.
        XCTAssertEqual(cover.parts[0].shapes.count, 1 + 2)
    }

    // Every nozzle link names a thruster of its part; every main engine of
    // the Saturn V has one bell, a linked revolution (the SPS among them,
    // whose stiffener and columbium band turn with it too), and each SM or
    // CM RCS jet its nozzle, as the stand-in SM's SPS and RCS jets.
    func testThrusterLinksResolve() {
        for v in vehicles() {
            for p in v.parts {
                for s in p.shapes {
                    guard let name = s.thruster else { continue }
                    XCTAssertTrue(p.thrusters.contains { $0.name == name }, "\(p.name): \(name)")
                }
            }
        }
        let stack = VesselLibrary.saturnV()
        var linked = 0
        for p in stack.parts {
            for t in p.thrusters {
                let linkedShapes = p.shapes.filter { $0.thruster == t.name }
                // The bell: an open, two-sided revolution from its exit.
                let bells = linkedShapes.filter { profile($0) != nil && !$0.capBase && $0.twoSided }
                let rcs = t.name.hasPrefix("SM RCS") || t.name.hasPrefix("CM RCS")
                let expected = t.groups.contains(.main) || rcs ? 1 : 0
                XCTAssertEqual(bells.count, expected, t.name)
                XCTAssertEqual(linkedShapes.count, t.name == "SPS" ? 3 : expected, t.name)
                linked += bells.count
            }
        }
        XCTAssertEqual(linked, 11 + 1 + 16 + 12)   // 5 F-1, 5 + 1 J-2, the SPS, the SM and CM RCS
        // The SM's sixteen R-4D nozzles stand where DB3 Fig. 2-5 puts them
        // whether or not the part has the thrusters (CSMExteriorTests); the
        // stand-in SM's two jets take two of them.
        let real = stack.parts.first { $0.name == "SM" }!
        let sm = splitStack().parts.first { $0.name == "SM" }!
        XCTAssertEqual(Set(sm.shapes.compactMap(\.thruster)), ["SPS", "SM RCS A1", "SM RCS C1"])
        XCTAssertEqual(sm.shapes.count, real.shapes.count)
    }

    // Each bell's exit radius is √(A_e/π) of its engine's exit area, its
    // exit and top at the engine's exit and gimbal stations.
    func testBellExits() {
        let stack = VesselLibrary.saturnV()
        let expected: [String: (exit: Double, gimbal: Double, radius: Double)] = [
            "S-IC": (AS506.baseStation, AS506.f1GimbalStation, (10.10 / Double.pi).squareRoot()),   // FER Fig. 5-3
            "S-II": (AS506.sIIJ2ExitStation, AS506.sIIJ2GimbalStation, (AS506.j2ExitArea / Double.pi).squareRoot()),
            "S-IVB": (AS506.sIVBJ2ExitStation, AS506.sIVBJ2GimbalStation, (AS506.j2ExitArea / Double.pi).squareRoot()),
        ]
        XCTAssertEqual(expected["S-IC"]!.radius, 1.7930, accuracy: 1e-4)
        XCTAssertEqual(expected["S-II"]!.radius, 14.7 / 2 * 27.5.squareRoot() * inch, accuracy: 1e-9)   // SP-8120
        for p in stack.parts {
            guard let e = expected[p.name] else { continue }
            for t in p.thrusters where t.groups.contains(.main) {
                let bell = p.shapes.first { $0.thruster == t.name }!
                XCTAssertEqual(profile(bell)!.first!.r, e.radius, accuracy: 1e-12, t.name)
                // The rating's own nozzle: F(p) = F_vac - p A_e.
                XCTAssertEqual(profile(bell)!.first!.r, (t.rating.impliedExitArea / Double.pi).squareRoot(),
                               accuracy: 1e-9, t.name)
                let x = (p.offset - stack.structureOrigin).x + bell.origin.x
                XCTAssertEqual(x / inch, e.exit, accuracy: 1e-6, t.name)
                XCTAssertEqual((x + bell.length) / inch, e.gimbal, accuracy: 1e-6, t.name)
                XCTAssertEqual(bell.origin.y, t.position.y, accuracy: 1e-12)
                XCTAssertEqual(bell.origin.z, t.position.z, accuracy: 1e-12)
                XCTAssertFalse(bell.capBase)
                XCTAssertTrue(bell.twoSided)
            }
        }
        // SPS: 98.4 in inside diameter at the nozzle extension's exit (AOH
        // 2.4-43), Xa 721.3 to the gimbal at Xa 833.2 (DB3 Fig. 2-10). The
        // bell is the last of the SPS's linked shapes, whose exit the scene
        // takes for the plume's.
        let sm = stack.parts.first { $0.name == "SM" }!
        let sps = sm.shapes.last { $0.thruster == "SPS" }!
        XCTAssertEqual(profile(sps)!.first!.r / inch, 49.2, accuracy: 1e-9)
        let x = (sm.offset - stack.structureOrigin).x + sps.origin.x
        XCTAssertEqual(x, xa(721.3), accuracy: 1e-9)
        XCTAssertEqual(x + sps.length, xa(833.2), accuracy: 1e-9)
    }

    // The CM's outer mould line (TM X-1243 Fig. 1; CSM News Reference): a
    // 184.8 in spherical heat shield, a 7.8 in toroidal shoulder at 77 in,
    // a 33° afterbody up to the docking interface, Xa 1110.25 (DB3 Figs.
    // 2-2, 2-10), on the face at Xa 998 (datasheet §9.1, from TN D-5399).
    func testCommandModuleOuterMouldLine() throws {
        // The stack without its apex cover (staging event 30): the CM has
        // its forward heat shield.
        let stack = VesselLibrary.saturnV()
        stack.jettison(event: 30)
        VesselLibrary.dressApollo(stack)
        let csm = stack.parts.first { $0.name == "CM" }!
        let heatShield = try XCTUnwrap(csm.shapes.first { $0.emissive == .heatShield })
        let afterbody = try XCTUnwrap(csm.shapes.first { $0.origin == heatShield.origin && $0.emissive == .none })
        let face = ((csm.offset - stack.structureOrigin).x + heatShield.origin.x) / inch - AS506.apolloStationOffset
        XCTAssertEqual(face, 998, accuracy: 1e-9)
        let hs = profile(heatShield)!.map { (x: $0.x / inch, r: $0.r / inch) }
        let ab = profile(afterbody)!.map { (x: $0.x / inch, r: $0.r / inch) }

        // The cap (the first nine points) on the 184.8 in sphere.
        for p in hs.prefix(9) {
            XCTAssertEqual(((184.8 - p.x) * (184.8 - p.x) + p.r * p.r).squareRoot(), 184.8, accuracy: 1e-9)
        }
        // The shoulder on a 7.8 in circle, reaching 77 in.
        let maximum = hs.max { $0.r < $1.r }!
        XCTAssertEqual(maximum.r, 77, accuracy: 1e-9)
        for p in hs.dropFirst(9) {
            XCTAssertEqual(((p.x - maximum.x) * (p.x - maximum.x) + (p.r - 77 + 7.8) * (p.r - 77 + 7.8)).squareRoot(),
                           7.8, accuracy: 1e-9)
        }
        // The cone at 33° from the shoulder to the docking interface, 112.25
        // in from the face; then the tunnel down to the forward hatch.
        XCTAssertEqual(atan2(ab[0].r - ab[1].r, ab[1].x - ab[0].x) * 180 / Double.pi, 33, accuracy: 1e-9)
        XCTAssertEqual(ab[1].x, 112.25, accuracy: 1e-9)
        XCTAssertEqual(ab.map(\.x).max()!, 112.25, accuracy: 1e-9)
        XCTAssertEqual(ab.last!.r, 0, accuracy: 1e-9)
        // The face from the CG: Apollo 7's CM CG, Xa 1040.8 (Mission Report
        // Table A.5-I), sits at x_cg/d ≈ 0.27 from it (TN D-5276 Table I:
        // 0.269-0.277 in the free-flight models).
        XCTAssertEqual((1040.8 - face) / 154, 0.27, accuracy: 0.01)
        XCTAssertFalse(heatShield.twoSided)
        XCTAssertFalse(afterbody.capBase)
        XCTAssertFalse(heatShield.capTop)
    }

    // The SLA: the ring under four panels hinged at Xa 583.2 (datasheet
    // §12), each a quarter turn about its axis, whose projected area, 243
    // ft² on that hinge line, is 1.7 % over 68-FM-160's 239 ft² (the drag
    // the physics keeps).
    func testSLAPanels() {
        let v = splitStack()
        let ring = v.parts.first { $0.name == "SLA ring" }!.shapes[0]
        XCTAssertEqual(ring.length / inch, 583.2 - 502, accuracy: 1e-9)
        XCTAssertFalse(ring.capBase || ring.capTop)
        var centres: [Vec3] = []
        for n in 1...4 {
            let p = v.parts.first { $0.name == "SLA panel \(n)" }!, panel = p.shapes[0]
            XCTAssertEqual(panel.length / inch, 838 - 583.2, accuracy: 1e-9)
            guard case let .revolution(_, _, sweep) = panel.kind else { return XCTFail() }
            XCTAssertEqual(sweep.upperBound - sweep.lowerBound, Double.pi / 2, accuracy: 1e-12)
            let centre = panel.radial((sweep.lowerBound + sweep.upperBound) / 2)
            centres.append(centre)
            var area = 0.0
            let t = panel.triangles()
            for i in stride(from: 0, to: t.count, by: 3) {
                area += 0.5 * (t[i + 1].position - t[i].position).cross(t[i + 2].position - t[i].position).dot(centre)
            }
            XCTAssertEqual(area / (0.3048 * 0.3048), 239, accuracy: 0.02 * 239, "panel \(n)")
            XCTAssertTrue(panel.twoSided)
        }
        // Panel 1 at +Z_A, 2 at -Z_A, 3 at +Y_A, 4 at -Y_A (68-FM-160).
        let expected = [Vec3(0, 0, -1), Vec3(0, 0, 1), Vec3(0, -1, 0), Vec3(0, 1, 0)]
        for (c, e) in zip(centres, expected) { XCTAssertEqual((c - e).length, 0, accuracy: 1e-12) }
    }

    // Triangles wind counter-clockwise seen from where their normals point,
    // closed shapes enclose a positive volume equal to the solid of
    // revolution's, and the whole Saturn V stays inside its envelope.
    func testTessellation() {
        for v in vehicles() {
            for p in v.parts {
                for s in p.shapes {
                    let t = s.triangles()
                    XCTAssertEqual(t.count % 3, 0)
                    for i in stride(from: 0, to: t.count, by: 3) {
                        let face = (t[i + 1].position - t[i].position).cross(t[i + 2].position - t[i].position)
                        guard face.length > 1e-12 else { continue }
                        for k in i..<i + 3 {
                            XCTAssertGreaterThan(face.dot(t[k].normal), 0, "\(p.name)")
                            XCTAssertEqual(t[k].normal.length, 1, accuracy: 1e-9)
                        }
                    }
                }
            }
        }

        /// Signed volume enclosed by triangles (divergence theorem).
        func volume(_ t: [VisualShape.Vertex]) -> Double {
            stride(from: 0, to: t.count, by: 3).reduce(0) {
                $0 + t[$1].position.dot(t[$1 + 1].position.cross(t[$1 + 2].position)) / 6
            }
        }
        // A closed frustum: the 32-gon's frustum volume.
        let f = VisualShape.frustum(from: Vec3(1, 2, 3), length: 2, baseRadius: 1, topRadius: 0.5, axis: Vec3(0, 1, 1),
                                    color: (1, 1, 1))
        let polygon = 32 / (2 * Double.pi) * sin(2 * Double.pi / 32)
        XCTAssertEqual(volume(f.triangles()), polygon * Double.pi * 2 * (1 + 0.5 + 0.25) / 3, accuracy: 1e-12)

        // The CM, heat shield and afterbody together, against π ∫ r² dx on
        // the same profile (trapezoids in r², exact for the cone).
        let csm = VesselLibrary.saturnV().parts.first { $0.name == "CM" }!
        let cm = csm.shapes.filter { $0.origin == csm.shapes.first { $0.emissive == .heatShield }!.origin }
        XCTAssertEqual(cm.count, 2)
        let points = profile(cm[0])! + profile(cm[1])!.dropFirst()
        var solid = 0.0
        for (a, b) in zip(points, points.dropFirst()) {
            solid += Double.pi * (b.x - a.x) * (a.r * a.r + a.r * b.r + b.r * b.r) / 3
        }
        let mesh = volume(cm[0].triangles() + cm[1].triangles())
        XCTAssertEqual(mesh / solid, 48 / (2 * Double.pi) * sin(2 * Double.pi / 48), accuracy: 1e-9)

        // The Saturn V within the base, the LES tip and the 33 ft body, but
        // for the outboard F-1 bells, which stand out under their fairings.
        let stack = VesselLibrary.saturnV()
        let tip = AS506.station(AS506.baseStation) + AS506.overallHeight * 0.3048
        let f1Reach = AS506.f1OutboardRadius * inch + (AS506.f1ExitArea / Double.pi).squareRoot()
        for p in stack.parts {
            for s in p.shapes {
                let limit = p.name == "S-IC" && s.thruster != nil ? f1Reach : 396.0 / 2 * inch
                for vertex in triangles(s, on: p, of: stack) {
                    let c = vertex.position
                    XCTAssertGreaterThanOrEqual(c.x, AS506.station(AS506.baseStation) - 1e-9, p.name)
                    XCTAssertLessThanOrEqual(c.x, tip + 1e-9, p.name)
                    XCTAssertLessThanOrEqual((c.y * c.y + c.z * c.z).squareRoot(), limit + 1e-9, p.name)
                }
            }
        }
    }

    // Each builder sets its vehicle on every part (`appearance`), and the
    // parts keep it through their separations: Apollo 7's CSM-101 stays
    // CSM-101 once its CM flies alone.
    func testVariantsRideOnTheParts() {
        XCTAssertTrue(VesselLibrary.saturnV().parts.allSatisfy { $0.appearance == .apollo11 })
        XCTAssertTrue(VesselLibrary.commandModule(.apollo7).parts.allSatisfy { $0.appearance == .apollo7 })
        let csm = VesselLibrary.apolloCSM(.apollo7)
        XCTAssertTrue(csm.parts.allSatisfy { $0.appearance == .apollo7 })
        let sm = csm.jettison(event: 7)!
        VesselLibrary.dressApollo(csm)
        XCTAssertTrue((csm.parts + sm.parts).allSatisfy { $0.appearance == .apollo7 })
        XCTAssertEqual(ApolloVariant(.apollo7), .apollo7)
        XCTAssertEqual(ApolloVariant(.apollo11), .apollo11)
        XCTAssertNil(ApolloVariant.apollo7.launchVehicle)
        XCTAssertEqual(ApolloVariant.apollo8, ApolloVariant(launchVehicle: .as503, csm: .csm103, payload: .ltaB))
        XCTAssertEqual(ApolloVariant.apollo11.payload, .lm(5))
        XCTAssertEqual(ApolloVariant.LaunchVehicle.allCases.map(\.rawValue), ["AS-501", "AS-502", "AS-503", "AS-506"])
        XCTAssertEqual(ApolloVariant.CSM.allCases.map(\.rawValue), ["CSM-101", "CSM-103", "CSM-107"])
    }

    // The attachments: the S-IC's eight retro ports and the S-IC/S-II
    // plane at STA 1564; the interstage's four S-II ullage exits and its
    // ring's plane at STA 1760; the S-II retros on the aft interstage with
    // the S-II/S-IVB plane at STA 2746.5; the S-IVB's two ullage exits. Each
    // port names its motor and points along its exhaust; they stay where
    // they were on the stack once their part has left.
    func testAttachments() throws {
        let stack = VesselLibrary.saturnV()
        func attachments(_ name: String) -> [VisualAttachment] { stack.parts.first { $0.name == name }!.attachments }
        let expected: [(String, VisualAttachment.Kind, Int, Double?)] = [
            ("S-IC", .retroPort, 8, nil), ("S-IC", .separationPlane, 1, 1_564),
            ("S-IC/S-II interstage", .ullageExit, 4, nil), ("S-IC/S-II interstage", .separationPlane, 1, 1_760),
            ("S-II/S-IVB interstage", .retroPort, 4, nil), ("S-II/S-IVB interstage", .separationPlane, 1, 2_746.5),
            ("S-IVB ullage rockets", .ullageExit, 2, nil),
        ]
        for (name, kind, count, station) in expected {
            let part = try XCTUnwrap(stack.parts.first { $0.name == name })
            let found = part.attachments.filter { $0.kind == kind }
            XCTAssertEqual(found.count, count, "\(name) \(kind)")
            for a in found {
                if let station {
                    XCTAssertEqual((a.position.x + part.offset.x - stack.structureOrigin.x) / inch, station,
                                   accuracy: 1e-9, a.name)
                    XCTAssertEqual(a.direction, .unitX)
                } else {
                    let motor = try XCTUnwrap(part.thrusters.first { $0.name == a.thruster }, a.name)
                    XCTAssertTrue(motor.isSolid)
                    XCTAssertEqual(a.position, motor.position)
                    XCTAssertEqual((a.direction + motor.direction).length, 0, accuracy: 1e-12)
                }
            }
        }
        let carrying = Set(expected.map(\.0))
        for p in stack.parts where !carrying.contains(p.name) { XCTAssertTrue(p.attachments.isEmpty, p.name) }
        XCTAssertEqual(attachments("S-IC").filter { $0.kind == .retroPort }.compactMap(\.thruster),
                       (1...8).map { "S-IC retro motor \($0)" })

        // The S-IC leaves with its attachments where they were.
        let sIC = stack.parts.first { $0.name == "S-IC" }!
        let before = sIC.attachments.map { $0.position + sIC.offset - stack.structureOrigin }
        let spent = try XCTUnwrap(stack.jettison(event: 1))
        VesselLibrary.dressApollo(spent)
        let after = sIC.attachments.map { $0.position + sIC.offset - spent.structureOrigin }
        for (a, b) in zip(before, after) { XCTAssertEqual((a - b).length, 0, accuracy: 1e-9) }
    }

    // A revolution's sweep, facets and caps: a quarter turn spans 90° from
    // its reference, eight faceted segments make an octagon with flat sides,
    // and open ends leave no cap.
    func testRevolution() {
        var s = VisualShape.revolution([.init(0, 1), .init(2, 1)], from: .zero, reference: .unitZ, segments: 8,
                                       sweep: 0...(Double.pi / 2), color: (1, 1, 1))
        s.capBase = false
        s.capTop = false
        let t = s.triangles()
        XCTAssertEqual(t.count, 2 * 2 * 3)
        let azimuths = t.map { atan2(-$0.position.y, $0.position.z) }   // from +z towards x × z = -y
        XCTAssertEqual(azimuths.min()!, 0, accuracy: 1e-12)
        XCTAssertEqual(azimuths.max()!, Double.pi / 2, accuracy: 1e-12)

        var octagon = VisualShape.revolution([.init(0, 1), .init(1, 1)], from: .zero, segments: 8, color: (1, 1, 1))
        octagon.faceted = true
        let o = octagon.triangles()
        XCTAssertEqual(o.count, 8 * 2 * 3 + 2 * 8 * 3)
        let sideNormals = Set(o.prefix(8 * 2 * 3).map { n -> [Double] in
            [(n.normal.y * 1e9).rounded(), (n.normal.z * 1e9).rounded()]
        })
        XCTAssertEqual(sideNormals.count, 8)
    }
}
