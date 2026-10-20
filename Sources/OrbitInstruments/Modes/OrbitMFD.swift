import Foundation
import OrbitCore

/// ORBIT, after Orbiter's Orbit MFD: the osculating elements of the vessel
/// (green) and of a target (yellow) about the reference body, and a graph of
/// both orbits seen from above the reference equator (EQU) or the vessel's
/// orbit plane (SHP), with the radius vectors, apsides and nodes.
///
/// Apsis altitudes are radii less the body's equatorial radius, as the HUD
/// gives them; DST shows the radii instead. Alt is the geodetic altitude.
/// LAN is measured from the mean equinox of date on the Earth.
public final class OrbitMFD: MFDMode {
    public enum Projection: String, CaseIterable, Sendable {
        case equator = "EQU", ship = "SHP"
    }
    public enum Display: CaseIterable, Sendable {
        case listAndGraph, list, graph
    }

    public var projection = Projection.equator
    public var display = Display.listAndGraph
    /// Radii (PeR, ApR, Rad) instead of altitudes.
    public var showRadii = false
    /// The target vessel, by id.
    public var targetID: UUID?

    public init() {}

    public var id: MFDModeID { .orbit }

    public func buttons(_ c: MFDContext?) -> [MFDButton?] {
        let hasTarget = c.map { !targets($0).isEmpty } ?? false
        return [
            MFDButton("TGT", .t, "Next target vessel", active: hasTarget),
            MFDButton("NT", .n, "No target", active: targetID != nil),
            MFDButton("MOD", .m, "List, graph or both"),
            nil, nil, nil,
            MFDButton("PRJ", .p, "Graph plane: EQU/SHP"),
            MFDButton("DST", .d, "Altitudes or radii"),
        ]
    }

    public func press(_ b: MFDButton, _ c: MFDContext?) -> Bool {
        switch b.key {
        case .t:
            guard let c else { return false }
            let ts = targets(c)
            guard !ts.isEmpty else { return false }
            let i = ts.firstIndex { $0.id == targetID } ?? -1
            targetID = ts[(i + 1) % ts.count].id
        case .n: targetID = nil
        case .m:
            let all = Display.allCases
            display = all[(all.firstIndex(of: display)! + 1) % all.count]
        case .p:
            projection = projection == .equator ? .ship : .equator
        case .d: showRadii.toggle()
        default: return false
        }
        return true
    }

    /// Vessels that can be targets: the others flying about the same body.
    func targets(_ c: MFDContext) -> [Vessel] {
        c.sim.vessels.filter { $0 !== c.vessel && $0.status == .flying && $0.reference === c.body }
    }

    func target(_ c: MFDContext) -> Vessel? {
        guard let id = targetID else { return nil }
        return targets(c).first { $0.id == id }
    }

    // MARK: Page

    /// Where the own and target values end, and the list's first row.
    static let ownEnd = 14, targetEnd = 22, firstRow = 2

    public func page(_ c: MFDContext) -> MFDPage {
        var page = MFDPage(title: "ORBIT  " + c.body.name)
        page.add(35, 0, projection.rawValue, .referenceDim, alignment: .trailing)
        guard let el = c.elements else {
            page.add(4, 2, "On the ground", .referenceDim)
            return page
        }
        let tgt = target(c)
        let tel = tgt.map { $0.elements(snapshot: c.snapshot) }

        if display != .graph {
            list(&page, c, el, vessel: c.vessel, end: Self.ownEnd, style: .own, labels: true)
            if let tgt, let tel { list(&page, c, tel, vessel: tgt, end: Self.targetEnd, style: .target, labels: false) }
        }
        if display != .list {
            let area = display == .graph ? MFDRect.cells(columns: 4...35, rows: 2...21)
                : MFDRect.cells(columns: 15...35, rows: 2...21)
            page.layers.append(graph(c, el, target: tel.map { ($0, tgt!) }, area: area))
        }
        if let tgt {
            let d = tgt.position - c.vessel.position, rv = tgt.velocity - c.vessel.velocity
            page.add(4, 22, "Tgt " + tgt.name, .target)
            page.add(4, 23, "Dst " + MFDFormat.si(d.length), .target)
            page.add(16, 23, "RVel " + MFDFormat.si(d.length > 0 ? rv.dot(d.normalized) : 0), .target)
        }
        return page
    }

    /// The element list, values ending at column `end`; with the labels.
    func list(_ page: inout MFDPage, _ c: MFDContext, _ el: OrbitalElements, vessel v: Vessel, end: Int,
              style: MFDStyle, labels: Bool) {
        let r = c.body.radius
        var row = Self.firstRow
        func put(_ label: String, _ value: String) {
            if labels { page.add(4, row, label, .reference) }
            page.add(end, row, value, style, alignment: .trailing)
            row += 1
        }
        let bound = el.isBound
        let node = c.equinox.flatMap { el.longitudeOfAscendingNode(from: $0) } ?? el.longitudeOfAscendingNode
        let lpe = MFDFormat.wrapped(node + el.argumentOfPeriapsis)
        put("SMa", MFDFormat.si(el.semiMajorAxis))
        put("SMi", MFDFormat.si(el.semiMinorAxis))
        if showRadii {
            put("PeR", MFDFormat.si(el.periapsisRadius))
            put("ApR", bound ? MFDFormat.si(el.apoapsisRadius) : "---")
            put("Rad", MFDFormat.si(v.position.length))
        } else {
            put("PeA", MFDFormat.si(el.periapsisRadius - r))
            put("ApA", bound ? MFDFormat.si(el.apoapsisRadius - r) : "---")
            put("Alt", MFDFormat.si(v.altitude))
        }
        put("Ecc", String(format: "%.4f", el.eccentricity))
        put("T", bound ? MFDFormat.duration(el.period) : "---")
        put("PeT", MFDFormat.duration(el.timeToPeriapsis))
        put("ApT", bound ? MFDFormat.duration(el.timeToApoapsis) : "---")
        put("Vel", MFDFormat.si(v.velocity.length))
        put("Inc", MFDFormat.degrees(el.inclination))
        put("LAN", MFDFormat.degrees(node))
        put("LPe", MFDFormat.degrees(lpe))
        put("AgP", MFDFormat.degrees(el.argumentOfPeriapsis))
        put("TrA", MFDFormat.degrees(el.trueAnomaly))
        put("TrL", MFDFormat.degrees(MFDFormat.wrapped(lpe + el.trueAnomaly)))
        put("MnA", MFDFormat.degrees(MFDFormat.wrapped(el.meanAnomaly)))
        put("MnL", MFDFormat.degrees(MFDFormat.wrapped(lpe + el.meanAnomaly)))
    }

    // MARK: Graph

    /// The projection's axes in ICRF: x and y of the plane, seen from its
    /// north side.
    func axes(_ c: MFDContext, _ el: OrbitalElements) -> (x: Vec3, y: Vec3) {
        let pole = el.referenceFrame.r2
        switch projection {
        case .equator:
            var x = c.equinox ?? el.referenceFrame.r0
            x = (x - pole * x.dot(pole)).normalized
            return (x, pole.cross(x))
        case .ship:
            let w = el.angularMomentum.normalized
            let x = el.ascendingNodeDirection ?? el.perifocalBasis.p
            return (x, w.cross(x))
        }
    }

    func graph(_ c: MFDContext, _ el: OrbitalElements, target: (OrbitalElements, Vessel)?, area: MFDRect) -> MFDLayer {
        let (ex, ey) = axes(c, el)
        let r = c.vessel.position.length
        // The scale fits the largest apoapsis shown (escape orbits: three
        // times the radius).
        func reach(_ e: OrbitalElements, _ radius: Double) -> Double {
            e.isBound ? max(e.apoapsisRadius, radius) : 3 * max(e.periapsisRadius, radius)
        }
        var extent = max(reach(el, r), c.body.radius)
        if let (tel, tv) = target { extent = max(extent, reach(tel, tv.position.length)) }
        extent *= 1.05
        let centre = area.center, half = min(area.width, area.height) / 2
        let k = half / extent
        func p(_ v: Vec3) -> MFDPoint { MFDPoint(centre.x + v.dot(ex) * k, centre.y - v.dot(ey) * k) }

        var shapes: [MFDShape] = [.circle(center: centre, radius: c.body.radius * k, .referenceDim, filled: false)]
        // The line of nodes on the vessel's orbit.
        if let an = el.ascendingNodeDirection {
            shapes.append(.polyline([p(an * extent), p(an * -extent)], .referenceDim, dashed: true))
        }
        func orbit(_ e: OrbitalElements, _ v: Vessel, _ style: MFDStyle) {
            let pts = e.conicPoints(180, maxRadius: extent / 1.05 * 1.2)
            if pts.count > 1 { shapes.append(.polyline(pts.map(p), style, dashed: false)) }
            shapes.append(.polyline([centre, p(v.position)], style.dim, dashed: false))
            shapes.append(.marker(p(v.position), .vessel, style))
            if e.eccentricity > 1e-4 {
                shapes.append(.marker(p(e.position(atTrueAnomaly: 0)), .diamond, style))
                if e.isBound { shapes.append(.marker(p(e.position(atTrueAnomaly: .pi)), .diamond, style.dim)) }
            }
            if let an = e.ascendingNode { shapes.append(.marker(p(an), .circle, style)) }
            if let dn = e.descendingNode { shapes.append(.marker(p(dn), .circle, style.dim)) }
        }
        if let (tel, tv) = target { orbit(tel, tv, .target) }
        orbit(el, c.vessel, .own)
        return MFDLayer(clip: area, shapes: shapes)
    }
}
