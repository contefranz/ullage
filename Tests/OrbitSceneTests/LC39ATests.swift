import Foundation
import XCTest
import OrbitCore
@testable import OrbitScene

/// The LC-39A set against the core's pad and vehicle and against
/// docs/LC39A-datasheet.md: where the site stands, which way it faces, when
/// its arms move, and its key heights and anchors.
final class LC39ATests: XCTestCase {
    static let system = try! SolarSystem.bundled()
    let foot = 0.3048, inch = 0.0254

    /// Apollo 11 at first motion, standing where the core stands it.
    func onPad() throws -> (Simulation, Vessel, LandedState) {
        let sim = Simulation(system: Self.system, time: VesselLibrary.apollo11FirstMotion)
        let v = VesselLibrary.apollo11OnPad(in: sim)
        return (sim, v, try XCTUnwrap(v.landed))
    }

    /// The site's axes at its placement, body-fixed: forward, left, up.
    func axes(_ p: SitePlacement) -> (Vec3, Vec3, Vec3) {
        let up = Self.system.earth.figure.normal(latitude: p.latitude, longitude: p.longitude)
        let east = Vec3(-sin(p.longitude), cos(p.longitude), 0)
        let north = up.cross(east)
        let forward = north * cos(p.azimuth) + east * sin(p.azimuth)
        return (forward, up.cross(forward), up)
    }

    /// All vertices of `e` placed in the site frame at range time `t`.
    func vertices(_ e: LC39A.Element, at t: Double = -3600, _ c: LC39A.Countdown = .apollo11) -> [Vec3] {
        let (r, o) = e.transform(at: t, c)
        return e.shapes.flatMap { $0.mesh().vertices.map { r * $0.position + o } }
    }

    func element(_ name: String) throws -> LC39A.Element { try XCTUnwrap(LC39A.element(name)) }

    /// A shape of the set placed in the site frame: its vertices and its
    /// triangles. The set's boxes and prisms are convex.
    struct Piece {
        var points: [Vec3]
        var triangles: [(Vec3, Vec3, Vec3)]
    }

    /// The shapes of `e` placed in the site frame at range time `t`.
    func pieces(_ e: LC39A.Element, at t: Double, _ c: LC39A.Countdown = .apollo11) -> [Piece] {
        let (r, o) = e.transform(at: t, c)
        return e.shapes.map { s in
            let m = s.mesh()
            let p = m.vertices.map { r * $0.position + o }
            let corners = stride(from: 0, to: m.indices.count, by: 3).map { (i: Int) -> (Vec3, Vec3, Vec3) in
                (p[Int(m.indices[i])], p[Int(m.indices[i + 1])], p[Int(m.indices[i + 2])])
            }
            return Piece(points: p, triangles: corners)
        }
    }

    /// Directions of `v`, one of each parallel set (unit).
    func distinctDirections(_ v: [Vec3]) -> [Vec3] {
        var out: [Vec3] = []
        for d in v where d.length > 1e-9 {
            let u = d.normalized
            if !out.contains(where: { $0.cross(u).length < 1e-9 }) { out.append(u) }
        }
        return out
    }

    /// How deep two convex pieces overlap (m): the least overlap of their
    /// projections on the separating-axis candidates, the faces' normals
    /// and the cross products of their edges. Zero or less when a plane
    /// separates them or they only touch; `exact`, it is then less the
    /// largest gap between their projections, a lower bound on how far
    /// apart they are.
    func overlap(_ a: Piece, _ b: Piece, exact: Bool = false) -> Double {
        let normals = { (p: Piece) in p.triangles.map { ($0.1 - $0.0).cross($0.2 - $0.0) } }
        let edges = { (p: Piece) in p.triangles.flatMap { [$0.1 - $0.0, $0.2 - $0.1, $0.0 - $0.2] } }
        let ea = distinctDirections(edges(a)), eb = distinctDirections(edges(b))
        var axes = distinctDirections(normals(a) + normals(b))
        for u in ea { axes += eb.map { u.cross($0) }.filter { $0.length > 1e-9 }.map(\.normalized) }
        var least = Double.infinity
        for n in axes {
            let pa = a.points.map { $0.dot(n) }, pb = b.points.map { $0.dot(n) }
            guard let a0 = pa.min(), let a1 = pa.max(), let b0 = pb.min(), let b1 = pb.max() else { return 0 }
            least = min(least, a1 - b0, b1 - a0)
            if least <= 0 && !exact { return least }
        }
        return least
    }

    /// Points spread over a triangle, its corners and edges among them.
    func surfacePoints(_ t: (Vec3, Vec3, Vec3), steps n: Int = 16) -> [Vec3] {
        var out: [Vec3] = []
        for i in 0...n {
            for j in 0...(n - i) {
                let u: Vec3 = (t.1 - t.0) * (Double(i) / Double(n))
                let v: Vec3 = (t.2 - t.0) * (Double(j) / Double(n))
                out.append(t.0 + u + v)
            }
        }
        return out
    }

    /// The shapes of the vehicle the core stands on the pad that the
    /// outline leaves out, placed in the site frame through the core's
    /// placement (its landed position and attitude, the site's deck and
    /// axes): all but the frustums and surfaces of revolution whose axis,
    /// placed, is the site's z axis (to 1 mm and 1e-9 rad).
    func vehicleItems() throws -> [Piece] {
        let (_, v, landed) = try onPad()
        let p = LC39A.placement()
        let (forward, left, up) = axes(p)
        let deck = Self.system.earth.figure.bodyFixed(latitude: p.latitude, longitude: p.longitude, height: p.height)
        let att = landed.bodyFixedAttitude, fromDeck = landed.bodyFixedPosition - deck
        /// A body-fixed direction or offset from the deck in site axes.
        func inSite(_ b: Vec3) -> Vec3 { Vec3(b.dot(forward), b.dot(left), b.dot(up)) }
        func direction(_ d: Vec3) -> Vec3 { inSite(att.rotate(d)) }
        func site(_ q: Vec3) -> Vec3 { inSite(fromDeck + att.rotate(q)) }
        var out: [Piece] = []
        for part in v.parts {
            for s in part.shapes {
                switch s.kind {
                case .frustum, .revolution:
                    let o = site(part.offset + s.origin), a = direction(s.axis).normalized
                    if (o.x * o.x + o.y * o.y).squareRoot() < 1e-3, (a.x * a.x + a.y * a.y).squareRoot() < 1e-9 { continue }
                default:
                    break
                }
                let m = s.mesh(offset: part.offset)
                let q = m.vertices.map { site($0.position) }
                let triangles = stride(from: 0, to: m.indices.count, by: 3).map { (i: Int) -> (Vec3, Vec3, Vec3) in
                    (q[Int(m.indices[i])], q[Int(m.indices[i + 1])], q[Int(m.indices[i + 2])])
                }
                out.append(Piece(points: q, triangles: triangles))
            }
        }
        return out
    }

    /// The box round `p`: its least and largest x, y and z.
    func box(_ p: Piece) -> (low: Vec3, high: Vec3) {
        var low = Vec3(.infinity, .infinity, .infinity), high = -low
        for q in p.points {
            low = Vec3(min(low.x, q.x), min(low.y, q.y), min(low.z, q.z))
            high = Vec3(max(high.x, q.x), max(high.y, q.y), max(high.z, q.z))
        }
        return (low, high)
    }

    /// Whether boxes `a` and `b` come within `margin` of each other.
    func near(_ a: (low: Vec3, high: Vec3), _ b: (low: Vec3, high: Vec3), within margin: Double) -> Bool {
        b.low.x <= a.high.x + margin && a.low.x <= b.high.x + margin && b.low.y <= a.high.y + margin
            && a.low.y <= b.high.y + margin && b.low.z <= a.high.z + margin && a.low.z <= b.high.z + margin
    }

    /// The least of `p`'s horizontal distance from the vehicle's axis less
    /// the drawn vehicle's radius at its height, over its surface (m):
    /// negative inside the vehicle.
    func clearance(_ p: Piece, _ outline: LC39A.VehicleOutline) -> Double {
        p.triangles.flatMap { surfacePoints($0) }.map { (q: Vec3) -> Double in
            let horizontal = (q.x * q.x + q.y * q.y).squareRoot()
            return horizontal - outline.radius(at: q.z)
        }.min() ?? .infinity
    }

    // MARK: Placement

    /// The site's origin is the ML deck on the vehicle's axis: the core's
    /// geodetic pad, 3.240 m above the vehicle base the core places, so the
    /// hold-down posts (STA 113.31) rest on the arms' heads, 100.75 in up.
    func testSiteStandsOnTheCorePad() throws {
        let (_, v, landed) = try onPad()
        let p = LC39A.placement()
        let pad = VesselLibrary.lc39A, deg = Double.pi / 180
        XCTAssertEqual(p.bodyID, Self.system.earth.id)
        XCTAssertEqual(p.latitude, pad.latitude * deg, accuracy: 1e-15)
        XCTAssertEqual(p.longitude, pad.longitude * deg, accuracy: 1e-15)
        XCTAssertEqual(LC39A.deckAboveVehicleBase, (113.31 + 115 - 100.75) * inch, accuracy: 1e-12)
        XCTAssertEqual(p.height, pad.elevation + LC39A.deckAboveVehicleBase, accuracy: 1e-12)

        // The core's base is the F-1 exit plane, STA -115 (datasheet §1).
        XCTAssertEqual(-v.baseHeight - v.structureOrigin.x, -115 * inch, accuracy: 1e-3)
        let figure = Self.system.earth.figure
        let deck = figure.bodyFixed(latitude: p.latitude, longitude: p.longitude, height: p.height)
        let (_, _, up) = axes(p)
        let att = landed.bodyFixedAttitude
        let base = landed.bodyFixedPosition + att.rotate(Vec3(-v.baseHeight, 0, 0))
        XCTAssertLessThan((base + up * LC39A.deckAboveVehicleBase - deck).length, 1e-3,
                          "the deck stands 3.240 m above the base, on the vehicle's axis")
        let post = landed.bodyFixedPosition + att.rotate(Vec3(113.31 * inch, 0, 0) + v.structureOrigin)
        XCTAssertEqual((post - deck).dot(up), 100.75 * inch, accuracy: 1e-3)
        // The hold-down arms' heads are there in the set.
        for i in 1...4 {
            let top = try vertices(element("Hold-down arm \(i)")).map(\.z).max()
            XCTAssertEqual(try XCTUnwrap(top), 100.75 * inch, accuracy: 1e-9)
        }
        // The deck is then 29.24 m above the drawn surface, 0.28 m above
        // the published 95 ft (48 ft of pad, 22 ft of pedestal, 25 ft of base).
        XCTAssertEqual(-LC39A.ellipsoidHeight, 29.24, accuracy: 0.005)
        XCTAssertEqual(-LC39A.ellipsoidHeight - 95 * foot, 0.28, accuracy: 0.005)
    }

    /// Position II faces the tower: the site's x axis is the direction the
    /// core's vehicle turns Position II (construction -y) to, north, with
    /// Position I east; through the scene extractor too.
    func testPositionIIFacesTheTower() throws {
        let (sim, v, landed) = try onPad()
        let p = LC39A.placement()
        let (forward, left, up) = axes(p)
        let att = landed.bodyFixedAttitude
        let positionII = att.rotate(-Vec3.unitY), positionI = att.rotate(.unitZ)
        XCTAssertLessThan(angleBetween(positionII, forward), 1e-9)
        XCTAssertLessThan(angleBetween(positionI, -left), 1e-9, "Position I faces east")
        XCTAssertLessThan(angleBetween(att.rotate(.unitX), up), 1e-9)
        let east = Vec3(-sin(p.longitude), cos(p.longitude), 0), north = up.cross(east)
        XCTAssertEqual(atan2(positionII.dot(east), positionII.dot(north)), LC39A.towerAzimuth, accuracy: 1e-9)
        // The tower stands on that side of the vehicle.
        let lut = try vertices(element("LUT"))
        XCTAssertGreaterThan(try XCTUnwrap(lut.map(\.x).min()), 14, "the whole tower is on the +x side")

        let extractor = SceneExtractor()
        extractor.sites = [p]
        var camera = OrbitCamera()
        camera.target = .vessel(v.id)
        camera.distance = 200
        camera.update(sim: sim)
        let scene = extractor.extract(sim: sim, camera: camera, viewport: RenderScene.Viewport(width: 64, height: 40),
                                      realTime: 0)
        let site = try XCTUnwrap(scene.sites.first)
        let vessel = try XCTUnwrap(scene.vessels.first)
        XCTAssertEqual(site.name, "LC-39A")
        XCTAssertLessThan(angleBetween(site.orientation.c0, vessel.attitude.rotate(-Vec3.unitY)), 1e-9)
        XCTAssertLessThan(angleBetween(site.orientation.c2, vessel.attitude.rotate(.unitX)), 1e-9)
        let base = vessel.position + vessel.attitude.rotate(Vec3(-v.baseHeight, 0, 0))
        let deck = base + vessel.attitude.rotate(.unitX) * LC39A.deckAboveVehicleBase
        XCTAssertLessThan((site.origin - deck).length, 1e-3)
    }

    // MARK: Timeline

    func angle(_ arm: Int, _ t: Double, _ c: LC39A.Countdown) throws -> Double {
        try element("Swing arm \(arm)").angle(at: t, c)
    }

    /// Arm 1 at T-30 s, arm 2 at T-16.2 s (FER-503, FER-506 §3.6); the
    /// in-flight arms 4-8 and the tail service masts from about an inch of
    /// rise, within M503 Fig. 8-8's maximum times and the masts' measured
    /// ones; arm 9 parked at 12° from T-42 or T-43 min and retracted at T-5
    /// min (A8PK, A11PK); the hold-down arms' links at release.
    func testArmsRetractOnTheCountdown() throws {
        let deg = Double.pi / 180, out = 90 * deg
        // (countdown, arm 1's withdrawal and safe angle, its margin before arm 2, arm 9's park)
        let launches: [(LC39A.Countdown, Double, Double, Double, Double)] = [
            (.apollo8, 6.14, 11.1, 2.69, -42 * 60), (.apollo11, 5.06, 9.9, 3.9, -43 * 60)]
        for (c, withdrawal, safe, margin, park) in launches {
            XCTAssertEqual(try angle(1, -30, c), 0)
            XCTAssertEqual(try angle(1, -30 + withdrawal, c), 0, "the carrier withdraws before the arm swings")
            XCTAssertEqual(try angle(1, -30 + safe, c), out, accuracy: 1e-12)
            let arm1 = LC39A.armSwings(1, c)[0]
            XCTAssertEqual(c.sICForwardCommand - arm1.end, margin, accuracy: 0.011, c.name)   // FER-503: 29.99 s in all
            XCTAssertEqual(c.sICForwardCommand, -16.2)
            XCTAssertEqual(try angle(2, -16.2, c), 0)
            XCTAssertEqual(try angle(2, -16.2 + 8, c), out, accuracy: 1e-12)
            XCTAssertEqual(try angle(3, c.sIIAftArmRetracted, c), out, accuracy: 1e-12)

            XCTAssertEqual(try angle(9, park, c), 0)
            XCTAssertEqual(try angle(9, park + 12, c), 12 * deg, accuracy: 1e-12)
            XCTAssertEqual(try angle(9, -400, c), 12 * deg, accuracy: 1e-12, "parked until the final retraction")
            XCTAssertEqual(try angle(9, -5 * 60, c), out, accuracy: 1e-12)

            // At first motion arms 1, 2, 3 and 9 are back; 4-8 still connected.
            for n in [1, 2, 3, 9] { XCTAssertEqual(try angle(n, c.firstMotion, c), out, accuracy: 1e-12) }
            for n in 4...8 { XCTAssertEqual(try angle(n, c.firstMotion, c), 0) }
            let start = c.firstMotion + 0.16
            XCTAssertEqual(c.liftoffSwitch, start, accuracy: 1e-12)
            for (n, max) in zip(4...8, [6.4, 7.4, 7.7, 8.4, 9.0]) {
                XCTAssertEqual(try angle(n, start, c), 0)
                let mid = try angle(n, start + max / 2, c)
                XCTAssertGreaterThan(mid, 0)
                XCTAssertLessThan(mid, out)
                XCTAssertEqual(try angle(n, start + max, c), out, accuracy: 1e-12)
            }
            for n in 1...9 { XCTAssertEqual(try angle(n, c.firstMotion + 9.2, c), out, accuracy: 1e-12) }

            for (i, time) in [2.62, 2.77, 2.54].enumerated() {
                let mast = try element("Tail service mast \(["1-2", "3-2", "3-4"][i]) boom")
                XCTAssertEqual(mast.angle(at: start, c), 0)
                XCTAssertEqual(mast.angle(at: start + time, c), LC39A.tailMastRetractAngle, accuracy: 1e-12)
            }
            for i in 1...4 {
                let link = try element("Hold-down arm \(i) link")
                XCTAssertEqual(link.angle(at: c.holdDownRelease, c), 0)
                XCTAssertEqual(link.angle(at: c.holdDownRelease + 0.2, c), 90 * deg, accuracy: 1e-12)
            }
        }
        XCTAssertEqual(LC39A.Countdown.apollo8.rangeZero, Epoch(utcYear: 1968, month: 12, day: 21, hour: 12, minute: 51))
        XCTAssertEqual(LC39A.Countdown.apollo8.firstMotion, 0.33)
        XCTAssertEqual(LC39A.Countdown.apollo11.rangeZero, VesselLibrary.apollo11RangeZero)
        XCTAssertEqual(LC39A.Countdown.apollo11.firstMotion, 0.30, accuracy: 1e-6)
    }

    /// Swings turn the right way: a retracting arm folds east against the
    /// tower's face, out of the vehicle's path; a link and a boom lift what
    /// faced the vehicle.
    func testMovingPartsClearTheVehicle() throws {
        let c = LC39A.Countdown.apollo11
        for n in 1...9 {
            let arm = try element("Swing arm \(n)")
            let retracted = vertices(arm, at: 30, c)
            XCTAssertGreaterThan(try XCTUnwrap(retracted.map(\.x).min()), LC39A.towerFaceX - LC39A.armWidth - 1e-9)
            XCTAssertLessThan(try XCTUnwrap(retracted.map(\.y).max()), 1e-9, "folded east")
        }
        // FER-503 Table 11-1: 8.63 m from fin tip A, 376.2 in out at 45°,
        // to the retracted arms.
        let finTipNorth = 376.2 * inch * sin(Double.pi / 4)
        let nearFace = try (1...9).map { try XCTUnwrap(vertices(element("Swing arm \($0)"), at: 30).map(\.x).min()) }.min()
        XCTAssertEqual(try XCTUnwrap(nearFace) - finTipNorth, 8.628, accuracy: 0.01)

        for i in 1...4 {
            let link = try element("Hold-down arm \(i) link")
            let r = LC39A.radialAndTangent(LC39A.holdDownAzimuths[i - 1]).0
            let latched = vertices(link, at: 0, c).map { $0.dot(r) }.min() ?? 0
            let open = vertices(link, at: 1, c).map { $0.dot(r) }.min() ?? 0
            XCTAssertLessThan(latched, LC39A.holdDownHeadRadius, "the jaw over the post")
            XCTAssertGreaterThan(open, LC39A.holdDownHeadRadius + 0.3, "swung back off it")
        }
        for name in ["1-2", "3-2", "3-4"] {
            let boom = try element("Tail service mast \(name) boom")
            let low = vertices(boom, at: 0, c).map(\.z).min() ?? 0
            let high = vertices(boom, at: 10, c).map(\.z).min() ?? 0
            XCTAssertEqual(low, 4.76, accuracy: 0.6, "the carrier at the tail plate")
            XCTAssertGreaterThan(high, 7, "up in the hood")
        }
    }

    /// The drawn vehicle the arms reach, against the exterior datasheet: the
    /// S-IC's and S-II's 198 in, the S-II/S-IVB interstage's cone (198 to
    /// 130 in over STA 2519-2746.5), the S-IVB's 130 in, the SLA's cone (130
    /// to 77 in over Xa 502-838), the SM's 77 in, and the CM's 77 in under
    /// the boost protective cover's 1.5 in. The deck is STA 12.56; Xa is
    /// STA less 2756.56. The core's vessel on the pad has the same outline.
    func testVehicleOutline() throws {
        let o = LC39A.vehicleOutline, unit = inch
        let deck = 113.31 - 100.75
        let sta = { (s: Double) -> Double in (s - deck) * unit }
        let xa = { (x: Double) -> Double in sta(x + 2756.56) }
        let rows: [(z: Double, radius: Double)] = [(sta(1000), 198), (sta(2519 + 227.5 / 2), 164), (sta(3000), 130),
                                                   (xa(670), 103.5), (xa(900), 77)]
        for row in rows { XCTAssertEqual(o.radius(at: row.z), row.radius * inch, accuracy: 1e-6) }
        XCTAssertEqual(o.largestRadius(from: xa(1000), to: xa(1100)), 78.5 * inch, accuracy: 1e-6,
                       "the CM's 77 in under the BPC's 1.5 in")
        XCTAssertEqual(o.radius(at: xa(1500)), 0, "above the LES")

        let (_, v, _) = try onPad()
        let placed = LC39A.VehicleOutline(v, deckAboveBase: LC39A.deckAboveVehicleBase)
        // The largest radius in each 0.25 m band from below the base to
        // above the LES, so that no step or ring is missed.
        func bands(_ outline: LC39A.VehicleOutline) -> [Double] {
            stride(from: -4.0, to: 120, by: 0.25).map { outline.largestRadius(from: $0, to: $0 + 0.25) }
        }
        for (a, b) in zip(bands(placed), bands(o)) { XCTAssertEqual(a, b, accuracy: 1e-9) }

        // Only the shapes about the vehicle's axis are in it, the others in
        // the items: a widened copy of its widest shape, moved off the axis
        // or tilted, leaves the outline as it was; on the axis it shows.
        func largest(_ s: VisualShape) -> Double {
            switch s.kind {
            case let .frustum(r0, r1): return max(r0, r1)
            case let .revolution(profile, _, _): return profile.map(\.r).max() ?? 0
            default: return 0
            }
        }
        func with(_ change: (inout VisualShape) -> Void) throws -> (LC39A.VehicleOutline, LC39A.VehicleItems) {
            let w = VesselLibrary.saturnV()
            let round = w.parts.flatMap { part in part.shapes.filter { LC39A.turnsAboutAxis($0, of: part, in: w) }
                .map { (part, $0) } }
            let (part, widest) = try XCTUnwrap(round.max { largest($0.1) < largest($1.1) })
            var copy = widest
            switch copy.kind {
            case let .frustum(r0, r1):
                copy.kind = .frustum(baseRadius: 1.5 * r0, topRadius: 1.5 * r1)
            case let .revolution(profile, segments, sweep):
                copy.kind = .revolution(profile: profile.map { VisualShape.ProfilePoint($0.x, 1.5 * $0.r) },
                                        segments: segments, sweep: sweep)
            default:
                XCTFail("not round")
            }
            change(&copy)
            part.shapes.append(copy)
            return (LC39A.VehicleOutline(w, deckAboveBase: LC39A.deckAboveVehicleBase),
                    LC39A.VehicleItems(w, deckAboveBase: LC39A.deckAboveVehicleBase))
        }
        let items = LC39A.vehicleItems.items.count
        let tilt = 10 * Double.pi / 180
        for (name, change) in [("moved", { (s: inout VisualShape) in s.origin = s.origin + Vec3(0, 0.5, 0) }),
                               ("tilted", { (s: inout VisualShape) in
                                   s.axis = s.axis * cos(tilt) + s.reference.cross(s.axis) * sin(tilt) })] {
            let (outline, more) = try with(change)
            XCTAssertEqual(more.items.count, items + 1, name)
            XCTAssertEqual(bands(outline), bands(o), name)
        }
        let (wider, same) = try with { _ in }
        XCTAssertEqual(same.items.count, items)
        XCTAssertGreaterThan(zip(bands(wider), bands(o)).map { $0 - $1 }.max() ?? 0, 0.1,
                             "a widened shape on the axis widens it")
    }

    /// No swing arm goes into the drawn vehicle: extended (T-2 h), every
    /// point of every arm's surface, its corners and edges among them, is at
    /// least the vehicle's radius at its own height from the vehicle's axis,
    /// and no arm overlaps the vehicle's shapes off its axis (fins,
    /// fairings, tunnels, plates and doors; separating axes). Each umbilical
    /// carrier, and arm 9's white room, touches the vehicle: where it is
    /// widest over its height, or an item in front of it. The trusses stand
    /// off.
    func testSwingArmsStayOutsideTheVehicle() throws {
        let items = try vehicleItems().map { ($0, box($0)) }
        XCTAssertGreaterThan(items.count, 0)
        for n in 1...9 {
            let arm = try element("Swing arm \(n)")
            let parts = pieces(arm, at: -7200)
            XCTAssertEqual(parts.count, 2)
            var gaps: [Double] = []
            for (i, piece) in parts.enumerated() {
                let what = "arm \(n)'s \(i == 0 ? "truss" : n == 9 ? "room" : "carrier")"
                let gap = clearance(piece, LC39A.vehicleOutline), around = box(piece)
                // Items further than 0.2 m are further than the checks below need.
                let apart = items.filter { near(around, $0.1, within: 0.2) }
                    .map { -overlap(piece, $0.0, exact: true) }.min() ?? .infinity
                XCTAssertGreaterThan(gap, -1e-6, "\(what) is \(-gap) m inside the vehicle")
                XCTAssertGreaterThan(apart, -1e-6, "\(what) is \(-apart) m into an item off the vehicle's axis")
                gaps.append(min(gap, apart))
            }
            XCTAssertEqual(gaps[1], 0, accuracy: 1e-3, "arm \(n)'s carrier or room meets the vehicle")
            XCTAssertGreaterThan(gaps[0], 0.1, "arm \(n)'s truss stands off it")
        }
        // Arm 9's room stands outside the real CM at its floor: the 33°
        // structural cone, its theoretical apex at Xa 1133.5, under the
        // leeward ablator's 0.70 in (exterior datasheet §9.1; about 1.46 m).
        let floorXa = (LC39A.accessArmLevel * foot + LC39A.chamber.floor) / inch + (113.31 - 100.75) - 2756.56
        let cone = 33 * Double.pi / 180
        let realCM = ((1133.5 - floorXa) * tan(cone) + 0.70 / cos(cone)) * inch
        XCTAssertEqual(realCM, 1.46, accuracy: 0.015)
        XCTAssertGreaterThan(LC39A.accessArmRoomRadius, realCM)
    }

    /// The arms swing clear of the LUT: at every angle of every swing, no
    /// arm's truss, carrier or room overlaps the tower's body, its flare's
    /// legs or their ties. Folded flat against the face, the arms take the
    /// 2.90 m in front of it, which the LUT leaves clear.
    func testSwingArmsClearTheTower() throws {
        let c = LC39A.Countdown.apollo11
        let lut = try pieces(element("LUT"), at: 0, c)
        XCTAssertEqual(lut.count, 1 + 4 + 4, "the body, four legs and two tie frames of two")
        XCTAssertEqual(try XCTUnwrap(lut.flatMap(\.points).map(\.x).min()), LC39A.towerFaceX, accuracy: 1e-9,
                       "the whole LUT stands behind its face")
        for n in 1...9 {
            let arm = try element("Swing arm \(n)")
            let swings = LC39A.armSwings(n, c)
            var times = [swings[0].start - 1]
            for s in swings {
                times += (0...30).map { (i: Int) -> Double in s.start + (s.end - s.start) * Double(i) / 30 }
            }
            var worst = (depth: -Double.infinity, what: "")
            for t in times {
                for (i, a) in pieces(arm, at: t, c).enumerated() {
                    for (j, b) in lut.enumerated() {
                        let depth = overlap(a, b)
                        if depth > worst.depth { worst = (depth, "shape \(i) at T\(t) s, LUT shape \(j)") }
                    }
                }
            }
            XCTAssertLessThanOrEqual(worst.depth, 1e-6, "arm \(n) overlaps the LUT: \(worst.what)")
        }
    }

    /// docs/LC39A-datasheet.md §4.1 gives each arm's radius reached and
    /// length as the model builds them (to 5 mm).
    func testDatasheetArmTable() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/LC39A-datasheet.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("docs/LC39A-datasheet.md not found")
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let start = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("### 4.1") })
        /// The first number in `cell` given in metres ("13.31 m").
        func metres(_ cell: String) -> Double? {
            let words = cell.split(separator: " ")
            for (word, unit) in zip(words, words.dropFirst()) where unit == "m" {
                if let value = Double(word) { return value }
            }
            return nil
        }
        var rows: [Int] = []
        for line in lines[start...] {
            if line.hasPrefix("### 4.2") { break }
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 9, let n = Int(cells[1]), (1...9).contains(n) else { continue }
            let arm = LC39A.swingArms[n - 1]
            XCTAssertEqual(try XCTUnwrap(metres(cells[6]), "arm \(n)'s radius"), arm.vehicleRadius, accuracy: 0.005,
                           "arm \(n)'s radius reached")
            XCTAssertEqual(try XCTUnwrap(metres(cells[8]), "arm \(n)'s length"), LC39A.armLength(arm), accuracy: 0.005,
                           "arm \(n)'s length")
            rows.append(n)
        }
        XCTAssertEqual(rows, Array(1...9))
    }

    // MARK: Heights

    /// The ML deck, the LUT's top, the crane's and the arms' levels against
    /// the datasheet.
    func testKeyHeights() throws {
        let base = try vertices(element("ML base"))
        XCTAssertEqual(try XCTUnwrap(base.map(\.z).max()), 0, accuracy: 1e-9, "the deck is level 0")
        XCTAssertEqual(LC39A.hardstandHeight, -47 * foot, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(base.map(\.z).min()), -47 * foot, accuracy: 1e-9, "the pedestals stand on it")
        XCTAssertEqual(LC39A.gradeHeight, -89 * foot, accuracy: 1e-9)
        let mlFootprint = base.filter { $0.z > -1e-6 }
        XCTAssertEqual(try XCTUnwrap(mlFootprint.map(\.x).max()) - (mlFootprint.map(\.x).min() ?? 0), 48.87,
                       accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(mlFootprint.map(\.y).max()) * 2, 41.15, accuracy: 1e-6)

        let lut = try vertices(element("LUT"))
        XCTAssertEqual(try XCTUnwrap(lut.map(\.z).max()), 380 * foot, accuracy: 1e-9)
        XCTAssertEqual(LC39A.towerFaceX, 60 * foot, accuracy: 1e-9)
        let crane = try vertices(element("Hammerhead crane"))
        XCTAssertEqual(try XCTUnwrap(crane.map(\.z).max()), 398 * foot, accuracy: 1e-9)
        let reach = crane.map { (($0.x - 80 * foot) * ($0.x - 80 * foot) + $0.y * $0.y).squareRoot() }.max()
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(reach), 85 * foot)

        let levels: [Double] = [60, 120, 140, 160, 200, 220, 260, 300, 320]
        XCTAssertEqual(LC39A.swingArms.map(\.number), Array(1...9))
        for (a, level) in zip(LC39A.swingArms, levels) {
            XCTAssertEqual(a.level, level)
            let top = try vertices(element("Swing arm \(a.number)")).map(\.z).max()
            if a.number < 9 { XCTAssertEqual(try XCTUnwrap(top), level * foot, accuracy: 1e-9) }
            XCTAssertEqual(LC39A.hinge(a).z, level * foot, accuracy: 1e-9)
        }
        // Every arm lies on its own part of the vehicle: the deck is STA
        // 12.56, so level 60 is STA 732.6 (S-IC intertank, 628.8-885.2) and
        // level 300 is Xa 856 (SM, 838-993).
        let station = { (level: Double) in 12.56 + level * 12 }
        XCTAssertTrue((628.8...885.2).contains(station(60)))
        XCTAssertTrue((1420.3...1541).contains(station(120)))
        XCTAssertTrue((1541...1760).contains(station(140)))
        XCTAssertTrue((838...993).contains(station(300) - 2756.56))
        // Arm 9's white room on the CM's hatch, Position I (east), at the sill.
        let arm9 = try element("Swing arm 9")
        let (turn, hinge) = arm9.transform(at: -7200, .apollo11)
        let room = try XCTUnwrap(arm9.shapes.last).mesh().vertices.map { turn * $0.position + hinge }
        XCTAssertEqual(try XCTUnwrap(room.map(\.y).max()), -LC39A.accessArmRoomRadius, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(room.map(\.z).min()), 320 * foot - 1.28, accuracy: 0.05)
        // The arms' lengths fall in Moonport's 13.7-18.3 m, but for the
        // S-IC and S-II arms', 0.4 m short (datasheet §4).
        for a in LC39A.swingArms { XCTAssertTrue((13.3...18.3).contains(LC39A.armLength(a)), "arm \(a.number)") }
    }

    // MARK: Anchors

    /// The trench's exits at its ends, north and south of the vehicle, at
    /// mid-height between the floor at grade and the hardstand; the ML's
    /// opening at the deck; the deflector's ridge 12 m above the floor.
    func testTrenchAttachments() throws {
        let a = Dictionary(uniqueKeysWithValues: LC39A.attachments.map { ($0.name, $0) })
        let north = try XCTUnwrap(a["Flame trench north exit"]), south = try XCTUnwrap(a["Flame trench south exit"])
        let mid = -(47 + 21) * foot
        XCTAssertLessThan((north.position - Vec3(225 * foot, 0, mid)).length, 1e-9)
        XCTAssertLessThan((south.position - Vec3(-225 * foot, 0, mid)).length, 1e-9)
        XCTAssertEqual(north.direction, .unitX)
        XCTAssertEqual(south.direction, -.unitX)
        XCTAssertEqual(north.radius, 29 * foot, accuracy: 1e-9)
        XCTAssertEqual(south.radius, 29 * foot, accuracy: 1e-9)
        XCTAssertGreaterThan(north.position.x, 0, "north is the tower's side")

        let opening = try XCTUnwrap(a["ML exhaust opening"])
        XCTAssertEqual(opening.position, .zero)
        XCTAssertEqual(opening.direction, -.unitZ)
        XCTAssertEqual(opening.radius, 22.5 * foot, accuracy: 1e-9)
        let ridge = try XCTUnwrap(a["Flame deflector ridge"])
        XCTAssertEqual(ridge.position.z, -89 * foot + 12, accuracy: 1e-9)

        // The exits are at the trench floor's ends, inside its walls.
        let pad = try vertices(element("Pad"))
        let floorEnds = pad.filter { abs($0.z - LC39A.gradeHeight) < 1e-6 && abs($0.y) <= LC39A.trenchHalfWidth + 1e-6 }
        XCTAssertEqual(try XCTUnwrap(floorEnds.map(\.x).max()), north.position.x, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(floorEnds.map(\.x).min()), south.position.x, accuracy: 1e-6)
        // And the exhaust opening sits over the trench.
        XCTAssertLessThan(22.5 * foot, LC39A.trenchHalfLength)
    }

    /// Every element tessellates into finite triangles with unit normals.
    func testGeometryIsWellFormed() throws {
        XCTAssertEqual(LC39A.elements.count, 4 + 9 + 2 * 4 + 2 * 3)
        XCTAssertEqual(Set(LC39A.elements.map(\.name)).count, LC39A.elements.count, "names are unique")
        var triangles = 0
        for e in LC39A.elements {
            XCTAssertFalse(e.shapes.isEmpty, e.name)
            XCTAssertEqual(e.axis.length, 1, accuracy: 1e-12)
            for s in e.shapes {
                let m = s.mesh()
                triangles += m.triangleCount
                XCTAssertGreaterThan(m.triangleCount, 0, e.name)
                for v in m.vertices {
                    XCTAssertTrue(v.position.x.isFinite && v.position.y.isFinite && v.position.z.isFinite, e.name)
                    XCTAssertEqual(v.normal.length, 1, accuracy: 1e-9, e.name)
                }
            }
        }
        XCTAssertLessThan(triangles, 20_000, "a mid-fidelity set")
    }
}
