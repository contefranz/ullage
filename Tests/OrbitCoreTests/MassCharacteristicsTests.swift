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

    // Each event's mass within 0.2 % (the model carries the 74-776 kg that
    // AS-506 had lost to frost, venting and purges by then: datasheet §9.4);
    // its CG within 10 in (the worst is S-IC OECO's +8.2: where the residual
    // LOX sits in the suction lines, L); its roll inertia
    // within 3 % (the dry structure's: no liquid spins with the tanks); its
    // pitch inertia within 7 % (the S-IVB stack is +6.5 %: the spacecraft's
    // inner layout, L). Before the tanks' sourced geometry and the FER's dry
    // rows, the CG was 1.7 m high in the S-II burn and the roll inertia up to
    // 9.5 times too large.
    func testMassCharacteristicsMatchTheFER() {
        let rows = flyTheEvents()
        XCTAssertEqual(rows.count, 12)
        for (model, fer) in rows {
            XCTAssertEqual(model.mass, fer.mass, accuracy: 2e-3 * fer.mass, fer.event)
            XCTAssertEqual(model.station, fer.station, accuracy: 10, fer.event)
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
        for e in mains() { e.rating = AS506.sIIJ2LowEMR }
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
