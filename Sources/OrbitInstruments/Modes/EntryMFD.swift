import Foundation
import OrbitCore

/// ENTRY, after the Apollo Entry Monitor System (EMS): the entry telemetry
/// (track E1) and the earth landing system (track E2):
/// - load factor and its peak, with the 0.05 G light (lit when the sensed
///   deceleration first reaches 0.05 g coasting down, as the EMS starts);
/// - inertial and air-relative speed, altitude and its rate, flight-path
///   angle;
/// - the bank angle of the lift vector from the local up (positive right),
///   and a dial of it;
/// - the stagnation-point heat flux and heat load (Sutton-Graves);
/// - dynamic pressure and Mach;
/// - the time to the vacuum entry interface while above it;
/// - the landing point and range to go, when the vessel's program predicts
///   one (`LandingPointPredicting`, E1's predictor);
/// - the parachutes' state;
/// - the EMS scroll: load factor against inertial speed since 0.05 g.
public final class EntryMFD: MFDMode {
    public init() {}

    public var id: MFDModeID { .entry }

    public func buttons(_ c: MFDContext?) -> [MFDButton?] { [] }

    static let left = 4, leftEnd = 18, right = 21, rightEnd = 35

    public func page(_ c: MFDContext) -> MFDPage {
        let v = c.vessel, s = c.snapshot, o = c.orientation, d = c.data
        var page = MFDPage(title: "ENTRY  " + c.body.name)
        page.add(35, 0, "0.05G", d.pointZeroFiveG != nil ? .target : .referenceDim, alignment: .trailing)
        var row = 2
        func pair(_ l1: String, _ v1: String, _ l2: String?, _ v2: String?, _ style: MFDStyle = .own) {
            page.field(Self.left, row, l1, v1, valueEnd: Self.leftEnd, style, labelStyle: .reference)
            if let l2, let v2 { page.field(Self.right, row, l2, v2, valueEnd: Self.rightEnd, style, labelStyle: .reference) }
            row += 1
        }
        let air = v.surfaceVelocity(snapshot: s)
        let up = c.body.vertical(at: v.position, orientation: o)

        pair("G", MFDFormat.fixed(v.loadFactor, 2), "PEAK", MFDFormat.fixed(d.peakLoadFactor, 2))
        pair("VI", MFDFormat.si(v.velocity.length), "VR", MFDFormat.si(air.length))
        pair("ALT", MFDFormat.si(v.altitude), "HDOT", MFDFormat.fixed(v.velocity.dot(up), 0, signed: true))
        pair("GAM", MFDFormat.degrees(EntryInterface.flightPathAngle(position: v.position, velocity: air), signed: true),
             "GAMi", MFDFormat.degrees(EntryInterface.flightPathAngle(position: v.position, velocity: v.velocity),
                                      signed: true))
        if let bank = v.bankAngle {
            pair("BANK", (bank >= 0 ? "R " : "L ") + MFDFormat.degrees(abs(bank)), "LIFT",
                 abs(bank) <= .pi / 2 ? "UP" : "DOWN")
        } else {
            pair("BANK", "---", nil, nil)
        }
        pair("QDOT", MFDFormat.si(v.heatFlux), "QLOAD", MFDFormat.si(v.heatLoad))
        pair("q", MFDFormat.si(v.dynamicPressure), "M", MFDFormat.fixed(v.mach, 1))
        if let ei = d.entryInterface {
            pair("EI", MFDFormat.duration(ei.time - c.time), "AT", MFDFormat.clock(ei.time, zero: c.missionClockZero),
                 .aux)
        } else {
            pair("EI", v.altitude < EntryInterface.standardHeight && v.landed == nil ? "below" : "none", nil, nil,
                 .referenceDim)
        }
        if let land = c.landingPoint {
            let ll = v.latitudeLongitude(snapshot: s)
            let range = GreatCircle.distance(fromLatitude: ll.lat, longitude: ll.lon, toLatitude: land.latitude,
                                             longitude: land.longitude, radius: GreatCircle.meanRadius(of: c.body.figure))
            pair("LAND", MFDFormat.latitude(land.latitude), "", MFDFormat.longitude(land.longitude), .warn)
            pair("RTG", MFDFormat.si(range), "TTG", MFDFormat.duration(land.time - c.time), .warn)
        } else {
            page.add(Self.left, row, "LAND no predictor", .referenceDim)
            row += 1
        }
        page.add(Self.left, row, "ELS " + els(v), .reference)

        page.layers = [scroll(d, speed: v.velocity.length, g: v.loadFactor,
                              area: MFDRect.cells(columns: 4...23, rows: 14...21)),
                       dial(v.bankAngle, area: MFDRect.cells(columns: 26...35, rows: 14...21))]
        page.add(4, 22, "g", .referenceDim)
        page.add(23, 22, "VI", .referenceDim, alignment: .trailing)
        return page
    }

    /// The landing system's state: the sequencer's line when the vessel
    /// flies it (alone or in the CM's entry program), else what the
    /// parachutes show.
    func els(_ v: Vessel) -> String {
        if let els = ApolloMission.landingSystem(of: v) { return els.status.replacingOccurrences(of: "ELS ", with: "") }
        let chutes = v.parachutes.filter { $0.state != .stowed }
        guard let c = chutes.last else { return v.parachutes.isEmpty ? "---" : "stowed" }
        let name = c.name.lowercased().hasPrefix("drogue") ? "drogues" : c.name.lowercased().hasPrefix("main") ? "mains"
            : c.name
        switch c.state {
        case .stowed: return "stowed"
        case .deploying: return name + " deploying"
        case .reefed(let n): return name + " reefed \(n)"
        case .open: return name + " open"
        case .released: return name + " released"
        }
    }

    /// The EMS scroll: g up, inertial speed to the right.
    func scroll(_ d: MFDVesselData, speed: Double, g: Double, area: MFDRect) -> MFDLayer {
        let vMax = max(8_000, d.entryTrace.map(\.speed).max() ?? 0, speed)
        let gMax = max(5, ((max(d.peakLoadFactor, g)) / 5).rounded(.up) * 5)
        func p(_ v: Double, _ g: Double) -> MFDPoint {
            MFDPoint(area.min.x + area.width * min(v, vMax) / vMax, area.max.y - area.height * min(g, gMax) / gMax)
        }
        var shapes: [MFDShape] = [.rect(area.min, area.max, .referenceDim, filled: false)]
        var k = 1.0
        while k * 1000 < vMax {
            shapes.append(.polyline([p(k * 1000, 0), p(k * 1000, gMax)], .referenceDim, dashed: true))
            k += 1
        }
        k = 1
        while k < gMax {
            shapes.append(.polyline([p(0, k), p(vMax, k)], .referenceDim, dashed: k.truncatingRemainder(dividingBy: 5) != 0))
            k += 1
        }
        if d.entryTrace.count > 1 { shapes.append(.polyline(d.entryTrace.map { p($0.speed, $0.g) }, .own, dashed: false)) }
        if d.pointZeroFiveG != nil { shapes.append(.marker(p(speed, g), .vessel, .own)) }
        return MFDLayer(clip: MFDRect(MFDPoint(area.min.x - 0.02, area.min.y - 0.02),
                                      MFDPoint(area.max.x + 0.02, area.max.y + 0.02)), shapes: shapes)
    }

    /// The lift vector about the velocity: up is lift up, right is a bank
    /// to the right.
    func dial(_ bank: Double?, area: MFDRect) -> MFDLayer {
        let c = area.center, r = min(area.width, area.height) / 2 * 0.85
        var shapes: [MFDShape] = [
            .circle(center: c, radius: r, .referenceDim, filled: false),
            .polyline([MFDPoint(c.x, c.y - r * 1.15), MFDPoint(c.x, c.y - r)], .reference, dashed: false),
            .polyline([MFDPoint(c.x - r, c.y), MFDPoint(c.x + r, c.y)], .referenceDim, dashed: true),
        ]
        if let b = bank {
            shapes.append(.polyline([c, MFDPoint(c.x + r * sin(b), c.y - r * cos(b))], .own, dashed: false))
            shapes.append(.marker(MFDPoint(c.x + r * sin(b), c.y - r * cos(b)), .diamond, .own))
        }
        return MFDLayer(shapes: shapes)
    }
}
