import XCTest
@testable import OrbitCore

/// `ExhaustSpec` and the `ExhaustLibrary`, which `ApolloExhaust` fills: a
/// spec for every Apollo thruster, its nozzle the dresser's, its gas the CEA
/// table's.
final class ExhaustSpecTests: XCTestCase {
    /// The Apollo vehicles: the Saturn V stack (S-IC to LES, the CSM and
    /// CM within it), the CSM alone and the command module alone.
    func apolloVessels() -> [Vessel] {
        [VesselLibrary.saturnV(), VesselLibrary.apolloCSM(.apollo7), VesselLibrary.commandModule(.apollo7)]
    }

    // Every thruster of the Apollo vehicles has a spec; the M0 test
    // vehicles' have none. A spec keeps what it is given.
    func testEveryApolloThrusterHasASpec() {
        var families = Set<ExhaustSpec.Family>(), count = 0
        for v in apolloVessels() {
            for p in v.parts {
                for t in p.thrusters {
                    let spec = ExhaustLibrary.spec(for: t, in: p)
                    XCTAssertNotNil(spec, "\(p.name): \(t.name)")
                    if let s = spec { families.insert(s.family); count += 1 }
                    if t.isSolid { XCTAssertEqual(spec?.family, .solidOther, t.name) }
                }
            }
        }
        XCTAssertEqual(families, [.keroseneLOX, .hydrogenLOX, .hypergolic, .solidOther])
        XCTAssertGreaterThan(count, 80)
        for v in [VesselLibrary.testRocket(), VesselLibrary.capsule()] {
            for p in v.parts {
                for t in p.thrusters { XCTAssertNil(ExhaustLibrary.spec(for: t, in: p), t.name) }
            }
        }
        let spec = ExhaustSpec(family: .hydrogenLOX, chamberPressure: 5.26e6, areaRatio: 27.5, exitRadius: 0.979,
                               lipHalfAngle: 0.2, exitGamma: 1.23, molarMass: 0.0135, chamberTemperature: 3_200,
                               exitTemperature: 1_100, source: "test", grade: "L")
        XCTAssertEqual(spec.family, .hydrogenLOX)
        XCTAssertNil(spec.film)
        XCTAssertEqual(spec.aluminaFraction, 0)
    }

    // The exit radius of every thruster whose nozzle the dresser draws and
    // links to it (the F-1s, J-2s, the SPS, the SM and CM RCS jets, the S-II
    // retros and the TX-280s) is its spec's: drawing and plume share one
    // exit per family. Other shapes may be linked to the thruster too, to
    // turn with its gimbal (an engine's cocoon and extension, a nozzle's
    // band and stiffener ring); the scene (OrbitScene's VesselGeometry)
    // starts the plume at the last linked revolution or frustum, the
    // nozzle, open at its exit. A frustum's exit is its base, the wide end
    // of a cone narrowing up the thrust. A revolution's is its profile's
    // first point, the gas side's exit, wherever along the axis that lies:
    // on the plane that bounds the profile, and the innermost point there,
    // so that the plume fills the mouth. It need not be the widest point:
    // the J-2's profile runs on out over its exit ring to the 80.75 in
    // envelope, wider than the 77 in gas side.
    func testExitRadiiMatchTheDressedNozzles() throws {
        var checked = Set<String>()
        for v in apolloVessels() {
            for p in v.parts {
                for t in p.thrusters {
                    guard let nozzle = p.shapes.last(where: { $0.thruster == t.name && Self.hasExit($0) }) else {
                        continue
                    }
                    let spec = try XCTUnwrap(ExhaustLibrary.spec(for: t, in: p), t.name)
                    XCTAssertFalse(nozzle.capBase, "\(t.name): the nozzle is open at its exit")
                    switch nozzle.kind {
                    case let .revolution(profile, _, _):
                        let exit = try XCTUnwrap(profile.first, t.name)
                        XCTAssertEqual(exit.r, spec.exitRadius, accuracy: 1e-9, t.name)
                        let along = profile.map { $0.x - exit.x }
                        XCTAssertTrue(along.allSatisfy { $0 >= -1e-12 } || along.allSatisfy { $0 <= 1e-12 },
                                      "\(t.name): the exit plane bounds the nozzle")
                        let mouth = profile.filter { abs($0.x - exit.x) < 1e-12 }.map(\.r)
                        XCTAssertEqual(mouth.min(), exit.r, "\(t.name): the gas side is the mouth's edge")
                    case let .frustum(base, top):
                        XCTAssertEqual(base, spec.exitRadius, accuracy: 1e-9, t.name)
                        XCTAssertGreaterThan(base, top, "\(t.name): the cone narrows from its exit")
                    default:
                        XCTFail("\(p.name): \(t.name)'s nozzle has no exit")
                    }
                    checked.insert(try XCTUnwrap(Self.row(of: spec), t.name))
                }
            }
        }
        XCTAssertEqual(checked, ["F-1", "J-2", "SPS", "SM RCS", "CM RCS", "S-II retro", "S-IVB ullage"])
    }

    /// The CEA table's row for `spec`, its family's name.
    static func row(of spec: ExhaustSpec) -> String? {
        ApolloExhaust.byTableRow.first { $0.value.spec.source == spec.source }?.key
    }

    /// Whether the scene can take a nozzle exit from `shape`, as
    /// `VesselGeometry.exit(of:)` does: a revolution's first profile point,
    /// a frustum's base.
    static func hasExit(_ shape: VisualShape) -> Bool {
        switch shape.kind {
        case let .revolution(profile, _, _): return !profile.isEmpty
        case .frustum: return true
        default: return false
        }
    }

    // The specs' gas, chamber pressure and area ratio are the CEA table's
    // rows (tools/data/cea_apollo_exhaust.csv), to the digits transcribed;
    // so is every exit the table gives or derives, the F-1's drawn gas side
    // among them.
    func testSpecsAreTheCEATable() throws {
        let rows = try toolsData("cea_apollo_exhaust.csv")
        XCTAssertEqual(Set(ApolloExhaust.byTableRow.keys).subtracting(rows.compactMap { $0["row"] }), [])
        let psi = 6_894.757293168
        for (name, engine) in ApolloExhaust.byTableRow {
            let row = try XCTUnwrap(rows.first { $0["row"] == name }, name)
            let s = engine.spec
            XCTAssertEqual(s.chamberPressure / psi, row.number("pc_psia")!, accuracy: 0.05, name)
            XCTAssertEqual(s.areaRatio, row.number("area_ratio")!, accuracy: 1e-9, name)
            XCTAssertEqual(s.exitGamma, row.number("gamma_nozzle")!, accuracy: 5e-5, name)
            XCTAssertEqual(s.molarMass, row.number("molar_mass_exit")!, accuracy: 5e-7, name)
            XCTAssertEqual(s.chamberTemperature, row.number("tc_k")!, accuracy: 0.005, name)
            XCTAssertEqual(s.exitTemperature, row.number("te_k")!, accuracy: 0.005, name)
            XCTAssertEqual(s.fuelRichFraction, row.number("fuel_rich")!, accuracy: 5e-6, name)
            XCTAssertEqual(s.aluminaFraction, row.number("y_al2o3")!, accuracy: 5e-6, name)
            let exit = try XCTUnwrap(row.number("exit_diameter_in"), name)
            XCTAssertEqual(2 * s.exitRadius / AS506.inch, exit, accuracy: 5e-4, name)
        }
    }

    // Each engine's rated flow is the vehicle's: full output at the rated
    // flow gives the spec's chamber pressure. AS-506's F-1s started about
    // 1 % above the rated 5,737 lb/s; the J-2s ran below the rated flow at
    // the S-II's low EMR and on the S-IVB.
    func testRatedFlowsAreTheVehicles() throws {
        let stack = VesselLibrary.saturnV()
        func thruster(_ name: String) throws -> (Thruster, VesselPart) {
            let p = try XCTUnwrap(stack.parts.first { $0.thrusters.contains { $0.name == name } }, name)
            return (p.thrusters.first { $0.name == name }!, p)
        }
        func fraction(_ name: String) throws -> Double {
            let (t, p) = try thruster(name)
            return t.rating.massFlow / ApolloExhaust.engine(for: t, in: p)!.ratedFlow
        }
        XCTAssertEqual(try fraction("S-IC engine 5"), 1.012, accuracy: 0.005)
        XCTAssertEqual(try fraction("S-IVB engine"), 0.877, accuracy: 0.005)
        XCTAssertEqual(AS506.sIIJ2LowEMR.massFlow / ApolloExhaust.j2.ratedFlow, 0.75, accuracy: 0.01)
        for name in ["SPS", "SM RCS A1", "APS I pitch", "APS III ullage", "Tower jettison motor",
                     "S-IC retro motor 1", "S-II ullage motor 1", "S-II retro motor 4", "S-IVB ullage motor 2"] {
            XCTAssertEqual(try fraction(name), 1, accuracy: 1e-9, name)
        }
        let cm = VesselLibrary.commandModule(.apollo7)
        let cmPart = try XCTUnwrap(cm.parts.first { $0.name == "CM" })
        let jet = try XCTUnwrap(cmPart.thrusters.first)
        XCTAssertEqual(jet.rating.massFlow / ApolloExhaust.engine(for: jet, in: cmPart)!.ratedFlow, 1, accuracy: 1e-9)
    }
}
