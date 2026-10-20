import XCTest
@testable import OrbitCore

/// The CSM's mass, CG and inertia against the Mission Reports' mass
/// properties (Apollo 7, MSC-PA-R-68-15 Table A.5-I; Apollo 11, MSC-00171
/// Table A-I), at the rows the scenarios use. Each row's weight is the
/// model's by construction (its loads are set from the row's weight and
/// the consumption the reports give); its CG and inertia test where the
/// model keeps its propellant. Rows in Apollo axes: weight lb, CG in, the
/// moments and the products (+∫xy dm about the CG) in slug ft².
final class CSMMassPropertiesTests: XCTestCase {
    let lb = 0.45359237, inch = 0.0254, slugFt2 = 1.3558179483

    struct Measured { let weight: Double, xa: Double, ya: Double, za: Double, inertia: Mat3 }

    /// `parts` of `v` (all by default) in Apollo axes: weight, CG and the
    /// inertia tensor about the CG (slug ft², the tensor's own signs).
    func measure(_ v: Vessel, _ names: [String]? = nil) -> Measured {
        let ps = v.parts.filter { names?.contains($0.name) ?? true }
        let m = ps.reduce(0) { $0 + $1.mass }
        let c = ps.reduce(Vec3.zero) { $0 + ($1.offset + $1.centerOfMass) * $1.mass } / m
        var i = Mat3.zero
        for p in ps { i = i + p.localInertia + .parallelAxis(mass: p.mass, offset: p.offset + p.centerOfMass - c) }
        let s = c - v.structureOrigin
        // Construction to Apollo axes: y = -Y_A, z = -Z_A.
        let flip = Mat3.diagonal(Vec3(1, -1, -1))
        return Measured(weight: m / lb, xa: s.x / inch - AS506.apolloStationOffset, ya: -s.y / inch, za: -s.z / inch,
                        inertia: flip * i * flip * (1 / slugFt2))
    }

    /// A row's tensor in Apollo axes from its moments and +∫xy dm products.
    func tensor(_ r: ApolloCM.MassRow) -> Mat3 {
        Mat3(rows: Vec3(r.ixx, -r.ixy, -r.ixz), Vec3(-r.ixy, r.iyy, -r.iyz), Vec3(-r.ixz, -r.iyz, r.izz))
    }

    /// Eigenvalues of a symmetric tensor, ascending (Jacobi rotations).
    func principal(_ t: Mat3) -> [Double] {
        var a = [[t[0, 0], t[0, 1], t[0, 2]], [t[1, 0], t[1, 1], t[1, 2]], [t[2, 0], t[2, 1], t[2, 2]]]
        for _ in 0..<50 {
            var (p, q) = (0, 1)
            for (i, j) in [(0, 1), (0, 2), (1, 2)] where abs(a[i][j]) > abs(a[p][q]) { (p, q) = (i, j) }
            if abs(a[p][q]) < 1e-12 * (abs(a[0][0]) + abs(a[1][1]) + abs(a[2][2])) { break }
            let theta = 0.5 * atan2(2 * a[p][q], a[q][q] - a[p][p])
            let c = cos(theta), s = sin(theta)
            var b = a
            for k in 0..<3 {
                b[k][p] = c * a[k][p] - s * a[k][q]
                b[k][q] = s * a[k][p] + c * a[k][q]
            }
            a = b
            for k in 0..<3 {
                b[p][k] = c * a[p][k] - s * a[q][k]
                b[q][k] = s * a[p][k] + c * a[q][k]
            }
            a = b
        }
        return [a[0][0], a[1][1], a[2][2]].sorted()
    }

    func check(_ m: Measured, _ row: ApolloCM.MassRow, cg: Double, moments: Double, _ label: String) {
        XCTAssertEqual(m.weight, row.weight, accuracy: 1e-6 * row.weight, label)
        XCTAssertEqual(m.xa, row.xa, accuracy: cg, "\(label) X_A")
        XCTAssertEqual(m.ya, row.ya, accuracy: cg, "\(label) Y_A")
        XCTAssertEqual(m.za, row.za, accuracy: cg, "\(label) Z_A")
        for (a, b) in zip(principal(m.inertia), principal(tensor(row))) {
            XCTAssertEqual(a, b, accuracy: moments * b, "\(label) principal moment")
        }
        // Products, qualitatively: the larger ones keep their sign.
        let model = [-m.inertia[0, 1], -m.inertia[0, 2], -m.inertia[1, 2]]
        for (name, (a, b)) in zip(["xy", "xz", "yz"], zip(model, [row.ixy, row.ixz, row.iyz])) where abs(b) > 250 {
            XCTAssertEqual(a.sign, b.sign, "\(label) I_\(name): \(a) against \(b)")
        }
    }

    // Apollo 7 (CSM-101) through its last four SPS burns, rows 11-18 of
    // Table A.5-I: the SM's structure is row 18 (CM/SM separation) less the
    // CM (row 19), the SPS's 1,214.3 + 711.9 lb and the SM RCS's 397.9 lb
    // left then (§5.21), so row 18 is the model's exactly; the rows before it
    // add each burn's weight drop to the SPS at the flight's mixture ratio
    // and the rest to the SM RCS. Their CG comes within 0.5 in, and their
    // principal moments within 1.5 % (3 % allowed), as the SPS tanks drain
    // in their sumps from an aft end fitted at Xa 834 over these rows
    // (`ApolloCSM.tankBottom`): the 4,530 lb of SPS-5 moves the CG 15 in
    // forward, the model's within 0.3 in of the flight's. Rows 3-10 also
    // hold up to 350 lb of cryogenics the model does not count apart; their
    // CG is up to 0.9 in out (Z_A), and they are not checked.
    func testApollo7RowsThroughTheLastBurns() {
        let v = VesselLibrary.apolloCSM(.apollo7)
        for k in 11...18 {
            let loads = ApolloCSM.apollo7Loads(row: k)
            ApolloCSM.setLoads(v, spsOxidizer: loads.spsOxidizer, spsFuel: loads.spsFuel, rcs: loads.rcs)
            XCTAssertGreaterThanOrEqual(loads.rcs, 397.9 - 1e-9, "row \(k)")
            check(measure(v), ApolloCSM.apollo7Rows[k]!, cg: 0.5, moments: 0.03, "row \(k)")
        }
        // The SPS-8 deorbit scenario's row: 2,735.2 lb of SPS propellant at
        // ignition, 809 lb more than at separation.
        let ign = ApolloCSM.apollo7Loads(row: 17)
        XCTAssertEqual(ign.spsOxidizer + ign.spsFuel, 1_926.2 + 809, accuracy: 1e-9)
        XCTAssertEqual(ign.rcs, 397.9, accuracy: 1e-9)
        // The structure: the SM at separation less its propellant, 8,764.9
        // lb; 68-FM-184 Table I(c)'s SM less its RCS, 10,604 - 1,341.7 lb,
        // is that plus the 498.9 lb of cryogenics the flight used (§5.21),
        // within 2 lb.
        let structure = v.parts.first { $0.name == "SM" }!.dryMass / lb
        XCTAssertEqual(structure, 23_453 - 12_364 - 1_926.2 - 397.9, accuracy: 1e-6)
        XCTAssertEqual(structure + 498.9, 10_604 - 1_341.7, accuracy: 2)
    }

    // Apollo 11's CSM: the FER's 28,806 kg at launch (Table 20-7); Table
    // A-I's CSM at transposition and docking, 63,473.0 lb at (934.0, 4.0,
    // 6.5), with its SPS loaded and the 33.3 lb the FER's CSM has more taken
    // from the SM RCS, by construction; and the spacecraft at Earth orbit
    // insertion (CSM, LM and SLA), 100,756.4 lb at (807.2, 2.6, 4.1),
    // against the model's FER modules (LM 15,095 and SLA 1,792 kg): 19.9 lb
    // (0.02 %) light, its CG within 1 in, the LM's CG from the FER's rows
    // (the stack itself carries the CSM centred on its axis until the CSM
    // separates: `VesselPart.centeredUntilEvent`). The CM after separation
    // (1040.4, -0.2, 6.0) is track E2's.
    func testApollo11Rows() {
        let csm = VesselLibrary.apolloCSM(.apollo11)
        XCTAssertEqual(csm.mass, AS506.csm, accuracy: 1e-6)
        XCTAssertEqual(csm.mass, 28_806, accuracy: 1e-6)
        let rcs = csm.tanks.filter { $0.name.hasPrefix("SM RCS") }
        let loaded = rcs.reduce(0) { $0 + $1.mass }
        for t in rcs { t.mass *= 1 - ApolloCSM.apollo11RCSUsedByDocking * lb / loaded }
        csm.recenter()
        XCTAssertEqual(ApolloCSM.apollo11RCSUsedByDocking, 33.4, accuracy: 0.05)
        check(measure(csm), ApolloCSM.apollo11Docking, cg: 1e-6, moments: 1e-6, "transposition and docking")
        let cm = measure(csm, ["CM", "Apex cover", "Drogue parachutes", "Main parachutes"])
        XCTAssertEqual(cm.weight, 12_107.4, accuracy: 1e-6)
        XCTAssertEqual(cm.xa, 1_040.4, accuracy: 1e-6)

        let stack = VesselLibrary.saturnV()
        for n in 1...5 { stack.jettison(event: n) }
        // The CSM's own mass distribution, which the stack centres on its
        // axis until the CSM separates.
        for p in stack.parts { p.centeredUntilEvent = nil }
        let sc = measure(stack, stack.parts.filter { !["S-IVB", "IU"].contains($0.name) }.map(\.name))
        let row = ApolloCSM.apollo11Insertion
        XCTAssertEqual(sc.weight, (28_806 + 15_095 + 1_792) / lb, accuracy: 1e-6)
        XCTAssertEqual(sc.weight, row.weight, accuracy: 0.0005 * row.weight)
        XCTAssertEqual(sc.xa, row.xa, accuracy: 1)
        XCTAssertEqual(sc.ya, row.ya, accuracy: 0.2)
        XCTAssertEqual(sc.za, row.za, accuracy: 0.2)
    }

    // The FER totals stand: the CSM is the FER's 28,806 kg on the stack,
    // and the vehicle at first motion 2,899,008.6 kg.
    func testFERTotalsAreUnchanged() {
        let v = VesselLibrary.saturnV()
        let csm = v.parts.filter { ["SM", "CM", "Apex cover", "Drogue parachutes", "Main parachutes"].contains($0.name) }
        XCTAssertEqual(csm.reduce(0) { $0 + $1.mass }, 28_806, accuracy: 1e-6)
        XCTAssertEqual(v.mass, 2_899_008.6, accuracy: 0.05)
    }
}
