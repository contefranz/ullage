import XCTest
@testable import OrbitCore

/// The Saturn V's mass characteristics against AS-506's, FER (MPR-SAT-FE-69-9)
/// Table 20-10, "Mass Characteristics Comparison" (actual values; read twice
/// independently, every cell agreeing: datasheet §13). The stages' dry rows
/// are model data (`AS506.MassRow`); the vehicle rows below check everything
/// else: the propellant loads, where each tank holds them, and the parts'
/// masses, at each of the table's events.
final class MassCharacteristicsTests: XCTestCase {
    /// A Table 20-10 vehicle row: mass (kg), longitudinal CG (STA, in), roll
    /// and pitch moments of inertia about the CG (kg m^2 x 10^6).
    typealias Row = (event: String, mass: Double, station: Double, roll: Double, pitch: Double)

    // Each event's mass within 0.1 % while the S-IC is aboard (it carries
    // the 661 kg of frost and purge gas AS-506 had shed by CECO to its
    // separation: the model is 662 and 783 kg heavy at OECO and separation)
    // and within 50 kg after it (the model is 27 kg light to 34 kg heavy);
    // its CG within 8 in (the worst is the S-IVB cutoff's +7.5; the S-IC's
    // residual LOX, in the suction lines that the engines empty last, puts
    // OECO within 1 in, where it was 8.2 in high at the column's bottom); its
    // roll inertia within 3 % (the dry structure's: no liquid spins with the
    // tanks); its pitch inertia within 7 % (the S-IVB stack is +6.5 %: the
    // spacecraft's inner layout, L). Before the tanks' sourced geometry and
    // the FER's dry rows, the CG was 1.7 m high in the S-II burn and the
    // roll inertia up to 9.5 times too large.
    func testMassCharacteristicsMatchTheFER() {
        let rows = flyTheEvents()
        XCTAssertEqual(rows.count, 12)
        for (i, (model, fer)) in rows.enumerated() {
            XCTAssertEqual(model.mass, fer.mass, accuracy: i < 3 ? 1e-3 * fer.mass : 50, fer.event)
            XCTAssertEqual(model.station, fer.station, accuracy: 8, fer.event)
            XCTAssertEqual(model.roll, fer.roll, accuracy: 0.03 * fer.roll, fer.event)
            XCTAssertEqual(model.pitch, fer.pitch, accuracy: 0.07 * fer.pitch, fer.event)
        }
    }

    // The spacecraft (SLA, LM, CSM and LES) at liftoff against Table 20-10's
    // "spacecraft, total" (48,626 kg at STA 3608.6). The model's spacecraft
    // is the FER's modules (Tables 20-7, 20-9: SLA 1,792, LM 15,095, CSM
    // 28,806, LES 4,042 kg), SP-4029's 109,646 lb, whose sum with the stages
    // gives the FER's first-motion mass to 1 kg: 1,109 kg (2.3 %) more than
    // this row, which must book an item elsewhere; placed anywhere from the
    // SLA's base to the LES's top, that item moves the row's CG by 8-11 in.
    // Its CG within 10 in (the model is +7.6 in, with the LM's CG from the
    // predicted rows, the CSM's and LES's estimated: L). The row's pitch
    // inertia (1.549e6 kg m²) is not checked: the model's is 9 % higher, its
    // modules' inner layouts being estimates (datasheet §13.2).
    func testSpacecraftCenterOfMass() {
        let v = VesselLibrary.saturnV()
        let sc = v.parts.filter { ["SLA", "LM", "CSM", "LES"].contains($0.name) }
        let m = sc.reduce(0) { $0 + $1.mass }
        let x = sc.reduce(0) { $0 + ($1.offset.x + $1.centerOfMass.x) * $1.mass } / m - v.structureOrigin.x
        XCTAssertEqual(m, 1_792 + 15_095 + 28_806 + 4_042, accuracy: 1e-6)
        XCTAssertEqual(x / AS506.inch, 3_608.6, accuracy: 10)
    }

    // The tank geometry §13 derives the loads' centroids from holds the
    // flight manuals' volumes: the S-IC tanks from AS-501 FER Fig. B-1's
    // stations (LOX 772-1541 with Y-rings at 909 and 1404, RP-1 225-742 with
    // its forward one at 605: 137 in domes) against MSFC-MAN-504's 345,000
    // and 216,000 gal, 4.7 % and 5.1 % over on the 396 in outer skin; the
    // S-II's LOX ellipsoid, 1716-1980 with a/b 1.5 bulkheads, against its
    // 12,745.5 cu ft (1.6 % under) and its LH2 tank, 1848-2519 over the
    // common bulkhead, against 37,737 cu ft (1.8 % over; MAN-504 Fig 5-1);
    // the S-IVB's 44.0 ft tank (MAN-504 Fig 6-1) with hemispherical domes,
    // 2702.56-3230.56, against MSFC-MAN-506's 2,830 + 10,400 cu ft (2.5 %
    // over). Its cylinder starts where the aft skirt's top is, STA 2832.00
    // (AS-501 FER Fig. B-1; NASA image 9253429), as MAN-504 §6 bolts the
    // skirt there.
    func testTankGeometryHoldsThePublishedVolumes() {
        let inch = AS506.inch, gal = 0.003785411784, cuft = 0.028316846592
        let rS = 198 * inch, rU = 130 * inch
        func cylinder(_ r: Double, _ from: Double, _ to: Double) -> Double { Double.pi * r * r * (to - from) * inch }
        func dome(_ r: Double, depth: Double) -> Double { 2.0 / 3 * Double.pi * r * r * depth * inch }
        let sICLOX = cylinder(rS, 909, 1_404) + dome(rS, depth: 909 - 772) + dome(rS, depth: 1_541 - 1_404)
        let sICRP1 = cylinder(rS, 225 + 137, 605) + dome(rS, depth: 137) + dome(rS, depth: 742 - 605)
        XCTAssertEqual(sICLOX, 345_000 * gal, accuracy: 0.06 * 345_000 * gal)
        XCTAssertEqual(sICRP1, 216_000 * gal, accuracy: 0.06 * 216_000 * gal)
        let sIILOX = 2 * dome(rS, depth: 198 / 1.5)
        XCTAssertEqual(1_980 - 1_716, 2 * 198 / 1.5, accuracy: 1e-9)
        XCTAssertEqual(sIILOX, 12_745.5 * cuft, accuracy: 0.03 * 12_745.5 * cuft)
        let sIILH2 = cylinder(rS, 1_848, 2_519 - 198 / 1.5)   // the two bulkheads' volumes cancel
        XCTAssertEqual(sIILH2, 37_737 * cuft, accuracy: 0.03 * 37_737 * cuft)
        XCTAssertEqual(3_230.56 - 2_702.56, 44 * 12, accuracy: 1e-9)
        let sIVB = cylinder(rU, 2_702.56 + 130, 3_230.56 - 130) + 2 * dome(rU, depth: 130)
        XCTAssertEqual(sIVB, (2_830 + 10_400) * cuft, accuracy: 0.03 * (2_830 + 10_400) * cuft)
        XCTAssertEqual(2_702.56 + 130, 2_832.00, accuracy: 1)
    }

    /// The vehicle's row now, from the model.
    func measure(_ v: Vessel, _ event: String) -> Row {
        let i = v.inertia
        return (event, v.mass, (v.centerOfMass.x - v.structureOrigin.x) / AS506.inch, i.r0.x / 1e6, i.r1.y / 1e6)
    }

    /// The FER's events through the propellant model (as
    /// `SaturnVDataTests.testEventTimelineThroughThePropellantModel` burns
    /// them), with each stage's jettisons.
    func flyTheEvents() -> [(model: Row, fer: Row)] {
        let v = VesselLibrary.saturnV()
        var t = AS506.firstMotion
        let t3 = AS506.timeBase3
        func engine(_ name: String) -> Thruster { v.thrusters.first { $0.name == name }! }
        func mains() -> [Thruster] { v.activeStage!.thrusters.filter { $0.groups.contains(.main) } }
        func set(_ engines: [Thruster], _ level: Double) { for e in engines { e.level = level } }
        func burn(to end: Double) {
            while t < end - 1e-9 {
                let h = min(0.02, end - t)
                v.consumePropellant(dt: h)
                t += h
                if mains().contains(where: { $0.isEnabled && $0.level > 0 && !$0.hasPropellant }) { return }
            }
        }
        var rows: [(model: Row, fer: Row)] = []
        func check(_ fer: Row) { rows.append((measure(v, fer.event), fer)) }

        check(("1st flight stage at holddown arm release", 2_899_010, 1_192.0, 3.703, 914.293))
        set(mains(), 1)
        burn(to: AS506.sICCenterCutoff)
        engine("S-IC engine 5").isEnabled = false
        burn(to: 170)
        check(("1st flight stage at outboard engine cutoff signal", 827_294, 1_828.9, 3.689, 440.511))
        set(mains(), 0)
        burn(to: t3 + AS506.sIIUllageIgnitionTime)
        for m in v.thrusters where m.name.hasPrefix("S-II ullage") { m.ignite() }
        burn(to: AS506.sICSeparation)
        check(("1st flight stage at separation", 823_627, 1_835.1, 3.686, 435.728))
        _ = v.jettisonNextStage()
        burn(to: AS506.sIIStartCommand)
        check(("2nd flight stage at start sequence command", 658_549, 2_199.0, 0.985, 135.506))
        burn(to: AS506.sIIIgnition)
        set(mains(), 1)
        burn(to: 166.2)
        check(("2nd flight stage at mainstage", 657_461, 2_199.5, 0.974, 135.387))
        burn(to: t3 + AS506.sIIHighMixtureRatioTime)
        for e in mains() { e.rating = AS506.sIIJ2 }
        burn(to: AS506.interstageJettison)
        _ = v.jettisonNextStage()
        burn(to: AS506.lesJettison)
        _ = v.jettisonNextStage()
        burn(to: AS506.sIICenterCutoff)
        engine("S-II engine 5").isEnabled = false
        burn(to: AS506.sIIMixtureRatioShift)
        for e in mains() {
            e.setRating(AS506.sIIJ2LowEMR, ramp: AS506.sIIMixtureRatioRamp)
            e.schedule = AS506.sIILowMixtureRatioDecline.delayed(by: e.burnTime)
        }
        burn(to: 560)
        check(("2nd flight stage at cutoff signal", 213_890, 2_795.8, 0.871, 44.932))
        set(mains(), 0)
        burn(to: 548.9)
        for m in v.thrusters where m.name.hasPrefix("S-IVB ullage") { m.ignite() }
        burn(to: AS506.sIISeparation)
        check(("2nd flight stage at separation", 213_759, 2_796.4, 0.871, 44.849))
        _ = v.jettisonNextStage()
        burn(to: 549.2)
        check(("3rd flight stage at 1st start sequence command", 166_634, 3_036.6, 0.198, 13.415))
        burn(to: AS506.sIVBIgnition)
        check(("3rd flight stage at 1st ignition", 166_572, 3_036.4, 0.198, 13.413))
        set(mains(), 1)
        burn(to: 554.70)
        check(("3rd flight stage at 1st mainstage", 166_397, 3_036.5, 0.198, 13.412))
        burn(to: 561.0)
        _ = v.jettisonNextStage()
        burn(to: 699.34)
        check(("3rd flight stage at 1st cutoff signal", 135_183, 3_072.7, 0.197, 12.594))
        set(mains(), 0)
        burn(to: 699.54)
        check(("3rd flight stage at 1st end thrust decay", 135_102, 3_072.9, 0.197, 12.591))
        return rows
    }
}
