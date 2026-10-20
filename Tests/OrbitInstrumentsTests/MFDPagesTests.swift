import XCTest
import OrbitCore
@testable import OrbitInstruments

/// No air: the vacuum ground track's reference.
final class NoAir: Atmosphere {
    func state(altitude h: Double) -> AtmosphereState { .vacuum }
    var ceiling: Double { 0 }
    var seaLevelPressure: Double { 101_325 }
}

/// A flight program with a ΔV counter, as track C's Apollo SCS has.
final class TestCounter: FlightProgram, DeltaVCounting {
    var deltaVRemaining: Double?
    func loadDeltaV(_ deltaV: Double?) { deltaVRemaining = deltaV }
    func update(_ vessel: Vessel, in sim: Simulation) {}
    func timeToNextEvent(at now: Epoch) -> Double? { nil }
    var status: String { "SCS" }
}

/// A flight program that predicts a landing point, as E1's entry program does.
final class TestPredictor: FlightProgram, LandingPointPredicting {
    var predictedLandingPoint: (latitude: Double, longitude: Double, time: Epoch)?
    func update(_ vessel: Vessel, in sim: Simulation) {}
    func timeToNextEvent(at now: Epoch) -> Double? { nil }
    var status: String { "entry" }
}

/// What the pages show, for the capsule in the 185 km, 32.5° parking orbit
/// of the "Capsule in low Earth orbit" scenario and a command module in the
/// air.
final class MFDPagesTests: XCTestCase {
    let deg = Double.pi / 180
    let epoch = Epoch(utcYear: 1969, month: 7, day: 16, hour: 13, minute: 44)

    func parkingOrbit(air: Bool = true) throws -> (Simulation, Vessel) {
        let system = try SolarSystem.bundled()
        let sim = Simulation(system: system, time: epoch)
        if !air { sim.atmospheres[399] = NoAir() }
        let v = VesselLibrary.capsule()
        sim.add(v)
        sim.placeInCircularOrbit(v, around: system.earth, altitude: 185_000, inclination: 32.5, ascendingNode: 0,
                                 argumentOfLatitude: 0)
        return (sim, v)
    }

    func page(_ id: MFDModeID, _ sim: Simulation, _ mfd: MFDController = MFDController()) -> MFDPage {
        mfd.handle(.f1, side: .left, sim: sim)
        mfd.handle(id.selectKey, side: .left, sim: sim)
        mfd.update(sim: sim, realTime: 0)
        return mfd.page(.left, sim: sim)
    }

    func dump(_ p: MFDPage) -> String { p.lines.joined(separator: "\n") }

    // ORBIT: Orbiter's element list. The apsis altitudes are radii less the
    // equatorial radius (the HUD's), the period two-body; LAN is from the
    // mean equinox of date.
    func testOrbitPage() throws {
        let (sim, v) = try parkingOrbit()
        let p = page(.orbit, sim)
        XCTAssertEqual(p.title, "ORBIT  Earth")
        XCTAssertTrue(p.shows("PeA 185.0k"), dump(p))
        XCTAssertTrue(p.shows("ApA 185.0k"), dump(p))
        XCTAssertTrue(p.shows("Inc 32.50°"), dump(p))
        XCTAssertTrue(p.shows("Ecc 0.0000"), dump(p))
        let a = sim.system.earth.radius + 185_000
        let period = 2 * Double.pi * (a * a * a / sim.system.earth.gm).squareRoot()
        XCTAssertEqual(period, 5_291.5, accuracy: 0.5)
        XCTAssertTrue(p.shows("T " + MFDFormat.duration(period)), dump(p))
        XCTAssertTrue(p.shows("SMa " + MFDFormat.si(a)), dump(p))
        XCTAssertTrue(p.shows("Vel " + MFDFormat.si(v.velocity.length)), dump(p))
        XCTAssertTrue(p.shows("Vel 7.793k"), dump(p))
        // Alt is geodetic: on the equator, the radius less a.
        XCTAssertTrue(p.shows("Alt 185.0k"), dump(p))

        // The node's right ascension from the mean equinox of date, worked
        // out here from the angular momentum.
        let pole = sim.snapshot.orientation(sim.system.earth).pole
        let x = EarthOrientation.biasPrecessionMatrix(tt: sim.time.tt).r0
        let ex = (x - pole * x.dot(pole)).normalized, ey = pole.cross(ex)
        let node = pole.cross(v.position.cross(v.velocity)).normalized
        var raan = atan2(node.dot(ey), node.dot(ex))
        if raan < 0 { raan += 2 * .pi }
        XCTAssertTrue(p.shows("LAN " + MFDFormat.degrees(raan)), dump(p))
        // placeInCircularOrbit's node 0 is +z × pole, at RA 269° in 1969.
        XCTAssertEqual(raan / deg, 269.1, accuracy: 0.2)
        // On a circular orbit at its node, the true longitude is the node's.
        XCTAssertTrue(p.shows("TrL " + MFDFormat.degrees(raan)), dump(p))

        // The graph: the Earth, the orbit just outside it, the vessel.
        XCTAssertTrue(p.shapes.contains { if case .marker(_, .vessel, .own) = $0 { true } else { false } })
        let circles = p.shapes.compactMap { s -> Double? in if case let .circle(_, r, _, _) = s { r } else { nil } }
        XCTAssertEqual(circles.count, 1)

        // DST: radii.
        let mfd = MFDController(left: .orbit)
        mfd.handle(.d, side: .left, sim: sim)
        let radii = mfd.page(.left, sim: sim)
        XCTAssertTrue(radii.shows("PeR " + MFDFormat.si(a)), dump(radii))
        XCTAssertTrue(radii.shows("Rad 6.563M"), dump(radii))
        // MOD: the list alone has no graph.
        mfd.handle(.m, side: .left, sim: sim)
        XCTAssertTrue(mfd.page(.left, sim: sim).layers.isEmpty)
    }

    // TGT: another vessel about the Earth, in yellow, with range and range rate.
    func testOrbitTarget() throws {
        let (sim, _) = try parkingOrbit()
        let other = VesselLibrary.capsule(name: "S-IVB")
        sim.add(other)
        sim.placeInCircularOrbit(other, around: sim.system.earth, altitude: 300_000, inclination: 28, ascendingNode: 0,
                                 argumentOfLatitude: 0)
        let mfd = MFDController(left: .orbit)
        XCTAssertTrue(mfd.handle(.t, side: .left, sim: sim))
        let p = mfd.page(.left, sim: sim)
        XCTAssertTrue(p.shows("PeA 185.0k 300.0k"), dump(p))
        XCTAssertTrue(p.shows("Inc 32.50° 28.00°"), dump(p))
        XCTAssertTrue(p.shows("Tgt S-IVB"), dump(p))
        XCTAssertTrue(p.shows("Dst 115.0k"), dump(p))
        XCTAssertTrue(p.text.contains { $0.string == "300.0k" && $0.style == .target })
        XCTAssertTrue(mfd.handle(.n, side: .left, sim: sim))
        XCTAssertFalse(mfd.page(.left, sim: sim).shows("Tgt"))
    }

    // SURFACE on orbit and on the pad.
    func testSurfacePage() throws {
        let (sim, v) = try parkingOrbit()
        let p = page(.surface, sim)
        XCTAssertTrue(p.shows("ALT 185.0k"), dump(p))
        XCTAssertTrue(p.shows("OS 7.793k"), dump(p))
        XCTAssertTrue(p.shows("FPAi +0.000°"), dump(p))
        let ground = v.surfaceVelocity(snapshot: sim.snapshot).length
        XCTAssertTrue(p.shows("GS " + MFDFormat.si(ground)), dump(p))
        // Eastward over the node at 32.5°: the course is 90° - 32.5° plus a
        // little for the Earth's rotation.
        let crs = p.compactLines.first { $0.hasPrefix("CRS") }!
        let course = Double(crs.split(separator: " ")[1].dropLast())!
        XCTAssertEqual(course, 57.5, accuracy: 2.5)
        XCTAssertTrue(p.shows("LAT 0.00°N"), dump(p))

        let pad = Simulation(system: sim.system, time: epoch)
        let rocket = VesselLibrary.testRocket()
        pad.add(rocket)
        pad.placeLanded(rocket, on: pad.system.earth, latitude: 28.608, longitude: -80.604, azimuth: 90)
        let q = page(.surface, pad)
        XCTAssertTrue(q.shows("GS 0.000"), dump(q))
        XCTAssertTrue(q.shows("CRS ---"), dump(q))
        XCTAssertTrue(q.shows("LAT 28.61°N"), dump(q))
        XCTAssertTrue(q.shows("LON 80.60°W"), dump(q))
        XCTAssertTrue(q.shows("ACC 1.00g"), dump(q))
    }

    // MAP: the tracks split where they cross the map's edge; the predicted
    // track is drawn; the caveat shows under thrust.
    func testMapPage() throws {
        let (sim, v) = try parkingOrbit()
        let mfd = MFDController(left: .map)
        mfd.update(sim: sim, realTime: 0)
        let p = mfd.page(.left, sim: sim)
        XCTAssertTrue(p.shows("LAT 0.00°N"), dump(p))
        XCTAssertTrue(p.shows("ALT 185.0k"), dump(p))
        XCTAssertFalse(p.shows("PRED"), dump(p))
        var predicted = 0
        for s in p.shapes {
            guard case let .polyline(pts, style, dashed) = s, style == .own || style == .ownDim else { continue }
            if style == .own && dashed { predicted += pts.count }
            for (a, b) in zip(pts, pts.dropFirst()) {
                XCTAssertLessThan(abs(a.x - b.x), 0.5, "a line across the map")
            }
        }
        // Two orbits of 30 s points, cut at the map's edge.
        XCTAssertGreaterThan(predicted, 300)
        XCTAssertTrue(p.shapes.contains { if case .polygon(_, .night) = $0 { true } else { false } })
        // The subsolar point at 13:44 UTC on 16 July: about 21.3° N, 26° W.
        let sun = GroundTrack.subsolarPoint(on: sim.system.earth, sun: sim.system.sun, snapshot: sim.snapshot)
        XCTAssertEqual(sun.latitude / deg, 21.3, accuracy: 0.3)
        XCTAssertEqual(sun.longitude / deg, -24.5, accuracy: 1)

        // Zoomed and tracking, the vessel is in the middle.
        mfd.handle(.z, side: .left, sim: sim)
        let z = mfd.page(.left, sim: sim)
        let marker = z.shapes.compactMap { s -> MFDPoint? in if case let .marker(q, .vessel, _) = s { q } else { nil } }
        XCTAssertEqual(marker.first!.x, 0.5, accuracy: 1e-9)

        v.mainThrottle = 1
        sim.advance(by: 1)
        mfd.update(sim: sim, realTime: 2)
        XCTAssertTrue(mfd.page(.left, sim: sim).shows("PRED: THRUSTING"))
    }

    // The ground track recorded at long intervals (time warp) is filled from
    // the coasting state; an orbit later it lies on the track predicted at
    // the start, as the pilot checks on the MAP.
    func testPredictedTrackOverlaysTheRecordedOne() throws {
        let (sim, _) = try parkingOrbit(air: false)
        let mfd = MFDController(left: .map)
        mfd.update(sim: sim, realTime: 0)
        let d = mfd.data(for: sim.focus!)
        let predicted = d.predicted
        let period = sim.focus!.elements(snapshot: sim.snapshot).period
        sim.warp = 600
        var real = 0.0
        while sim.time - epoch < 1.6 * period {
            sim.advance(by: 1)   // 600 s between samples
            real += 0.25         // refresh the prediction no more than every 4th sample
            mfd.update(sim: sim, realTime: real)
        }
        let recorded = d.track.points.filter { $0.time - epoch > period && $0.time - epoch < 1.5 * period }
        XCTAssertGreaterThan(recorded.count, 40)
        var worst = 0.0
        for r in recorded {
            guard let i = predicted.firstIndex(where: { $0.time > r.time }), i > 0 else { continue }
            let a = predicted[i - 1], b = predicted[i]
            let f = (r.time - a.time) / (b.time - a.time)
            let lat = a.latitude + (b.latitude - a.latitude) * f
            let lon = a.longitude + remainder(b.longitude - a.longitude, 2 * .pi) * f
            let e = GreatCircle.angle(fromLatitude: lat, longitude: lon, toLatitude: r.latitude, longitude: r.longitude)
            worst = max(worst, e)
        }
        print(String(format: "MAP: recorded vs predicted track one orbit on: %.4f°", worst / deg))
        XCTAssertLessThan(worst / deg, 0.05)
    }

    // DEORBIT: the planner's burn to -1.75° at EI, with TIG 10 minutes ahead on
    // a whole minute; SET loads the counter when the vessel has one.
    func testDeorbitPage() throws {
        let (sim, v) = try parkingOrbit()
        let mfd = MFDController(left: .deorbit)
        mfd.missionClockZero = Epoch(utcYear: 1969, month: 7, day: 16, hour: 13, minute: 32)
        let p = mfd.page(.left, sim: sim)
        let mode = mfd.mode(.deorbit, on: .left) as! DeorbitMFD
        let tig = mode.ignition!
        XCTAssertGreaterThanOrEqual(tig - sim.time, 600)
        XCTAssertLessThan(tig - sim.time, 660)
        XCTAssertEqual((tig - mfd.missionClockZero!).truncatingRemainder(dividingBy: 60), 0, accuracy: 1e-6)
        let plan = DeorbitPlanner.plan(v, snapshot: sim.snapshot, ignition: .at(tig),
                                       target: .entryFlightPathAngle(-1.75 * deg),
                                       engine: DeorbitPlanner.Engine(thrust: 20_000, specificImpulse: 310))!
        XCTAssertTrue(p.shows("TGT EI -1.750°"), dump(p))
        XCTAssertTrue(p.shows(String(format: "DV %.1f m/s", plan.deltaVMagnitude)), dump(p))
        XCTAssertTrue(p.shows(String(format: "BT %.1f s", plan.burnTime!)), dump(p))
        XCTAssertTrue(p.shows("HP " + MFDFormat.si(plan.postBurnElements.periapsisRadius - sim.system.earth.radius)),
                      dump(p))
        XCTAssertTrue(p.shows("GAM -1.750°"), dump(p))
        XCTAssertTrue(p.shows("TIG " + MFDFormat.clock(plan.centredIgnition!, zero: mfd.missionClockZero)), dump(p))
        XCTAssertLessThan(plan.deltaVLocal.x, 0)
        // The burn's direction for the navball's manoeuvre marker.
        XCTAssertEqual(mfd.deorbitBurnDirection!.dot(plan.burnDirection), 1, accuracy: 1e-12)
        // Retrograde: the burn's X is nearly all of it.
        XCTAssertEqual(abs(plan.deltaVLocal.x), plan.deltaVMagnitude, accuracy: 0.01 * plan.deltaVMagnitude)
        // No counter: SET and CLR do nothing.
        XCTAssertTrue(p.shows("DVC n/a"), dump(p))
        XCTAssertEqual(p.buttons[10]?.label, "SET")
        XCTAssertEqual(p.buttons[10]?.inactive, true)
        XCTAssertFalse(mfd.handle(.s, side: .left, sim: sim))

        let counter = TestCounter()
        v.flightProgram = counter
        let q = mfd.page(.left, sim: sim)
        XCTAssertTrue(q.shows("DVC not set"), dump(q))
        XCTAssertTrue(mfd.handle(.s, side: .left, sim: sim))
        XCTAssertEqual(counter.deltaVRemaining!, plan.deltaVMagnitude, accuracy: 1e-6)
        XCTAssertTrue(mfd.page(.left, sim: sim).shows(String(format: "DVC %.1f m/s", plan.deltaVMagnitude)))
        XCTAssertTrue(mfd.handle(.c, side: .left, sim: sim))
        XCTAssertNil(counter.deltaVRemaining)

        // TIG steps, and the perigee target.
        mfd.handle(.equal, side: .left, sim: sim)
        XCTAssertEqual(mode.ignition! - tig, 60, accuracy: 1e-9)
        mfd.handle(.i, side: .left, sim: sim)
        mfd.handle(.i, side: .left, sim: sim)
        mfd.handle(.minus, side: .left, sim: sim)
        XCTAssertEqual(mode.ignition! - tig, 60 - 10, accuracy: 1e-9)
        mfd.handle(.g, side: .left, sim: sim)
        let hp = mfd.page(.left, sim: sim)
        XCTAssertTrue(hp.shows("TGT HP 40.00k"), dump(hp))
        XCTAssertTrue(hp.shows("HP 40.00k"), dump(hp))

        // Past TIG with the entry already steeper than the target (an
        // overburn): no Δv to go, and the EI the vessel now heads for.
        mfd.handle(.g, side: .left, sim: sim)
        mode.ignition = sim.time + -1
        v.velocity = v.velocity * (1 - 300 / v.velocity.length)
        mfd.update(sim: sim, realTime: 100)
        let over = mfd.page(.left, sim: sim)
        XCTAssertTrue(over.shows("TTG PASSED"), dump(over))
        XCTAssertTrue(over.shows("DV TO GO 0.0 m/s"), dump(over))
        XCTAssertTrue(over.shows("OVERBURN"), dump(over))
        let ei = mfd.data(for: v).entryInterface!
        XCTAssertLessThan(ei.inertialFlightPathAngle, -1.75 * deg)
        XCTAssertTrue(over.shows("GAM " + MFDFormat.degrees(ei.inertialFlightPathAngle, signed: true)), dump(over))
    }

    // ENTRY: a command module coasting down through 80 km: the load, the
    // 0.05 G light, the bank, the heating, the landing system and the
    // predicted landing point.
    func testEntryPage() throws {
        let system = try SolarSystem.bundled()
        let sim = Simulation(system: system, time: epoch)
        let v = VesselLibrary.commandModule(.apollo7)
        v.aerodynamics = [.apolloCommandModule()]
        sim.add(v)
        sim.place(v, geodeticLatitude: 30, longitude: -75, height: 80_000, inertialSpeed: 7_600,
                  flightPathAngle: -1.5, azimuth: 90, attitude: Quat(axis: .unitZ, angle: .pi))
        let mfd = MFDController(left: .entry)
        for _ in 0..<10 {
            sim.step(0.02)
            mfd.update(sim: sim, realTime: 0)
        }
        let p = mfd.page(.left, sim: sim)
        XCTAssertGreaterThan(v.loadFactor, 0.05)
        XCTAssertTrue(p.text.contains { $0.string == "0.05G" && $0.style == .target }, dump(p))
        XCTAssertTrue(p.shows("G " + MFDFormat.fixed(v.loadFactor, 2)), dump(p))
        XCTAssertNotNil(v.bankAngle)
        XCTAssertTrue(p.shows("BANK"), dump(p))
        XCTAssertFalse(p.shows("BANK ---"), dump(p))
        XCTAssertGreaterThan(v.heatFlux, 0)
        XCTAssertTrue(p.shows("QDOT " + MFDFormat.si(v.heatFlux)), dump(p))
        XCTAssertTrue(p.shows("EI below"), dump(p))
        XCTAssertTrue(p.shows("LAND no predictor"), dump(p))
        XCTAssertTrue(p.shows("ELS stowed"), dump(p))
        XCTAssertGreaterThan(mfd.data(for: v).entryTrace.count, 0)

        // E1's predictor, through the hook; E2's landing system.
        let predictor = TestPredictor()
        predictor.predictedLandingPoint = (29.8 * deg, -67.0 * deg, sim.time + 900)
        v.flightProgram = predictor
        let q = mfd.page(.left, sim: sim)
        XCTAssertTrue(q.shows("LAND 29.80°N 67.00°W"), dump(q))
        XCTAssertTrue(q.shows("TTG 15:00"), dump(q))
        mfd.handle(.f1, side: .left, sim: sim)
        mfd.handle(.m, side: .left, sim: sim)
        XCTAssertTrue(mfd.page(.left, sim: sim).shapes.contains {
            if case .marker(_, .cross, .warn) = $0 { true } else { false }
        })
        v.flightProgram = EarthLandingSystem(armed: true)
        mfd.handle(.f1, side: .left, sim: sim)
        mfd.handle(.e, side: .left, sim: sim)
        XCTAssertTrue(mfd.page(.left, sim: sim).shows("ELS armed"))
    }

    // In orbit, ENTRY gives the time to a vacuum EI after a deorbit burn.
    func testEntryInterfaceAhead() throws {
        let (sim, v) = try parkingOrbit()
        v.velocity = v.velocity * (1 - 80 / v.velocity.length)
        let mfd = MFDController(left: .entry)
        mfd.update(sim: sim, realTime: 0)
        let ei = mfd.data(for: v).entryInterface!
        let p = mfd.page(.left, sim: sim)
        XCTAssertTrue(p.shows("EI " + MFDFormat.duration(ei.time - sim.time)), dump(p))
        XCTAssertTrue(p.text.contains { $0.string == "0.05G" && $0.style == .referenceDim })

        // Just below the interface on the way down, it is behind: none ahead.
        sim.atmospheres[399] = NoAir()
        let h = EntryInterface.standardHeight
        sim.place(v, geodeticLatitude: 30, longitude: -100, height: h - 300, inertialSpeed: 7_870,
                  flightPathAngle: -1.8, azimuth: 85)
        mfd.update(sim: sim, realTime: 10)
        XCTAssertNil(mfd.data(for: v).entryInterface)
        XCTAssertTrue(mfd.page(.left, sim: sim).shows("EI below"))
    }
}
