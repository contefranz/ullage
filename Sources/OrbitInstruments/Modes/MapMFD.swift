import Foundation
import OrbitCore

/// MAP, after Orbiter's Map MFD: the reference body in an equirectangular
/// projection, with
/// - the coastlines (the Earth) and a latitude-longitude grid;
/// - the night side, bounded by the geometric terminator, and the subsolar
///   point (the Sun overhead);
/// - the ground track flown (dim) and the one predicted (dashed) over the
///   next orbits, with secular J2 (`GroundTrack.predict`, vacuum);
/// - the vessel, its horizon (the circle it sees the ground to), the
///   predicted entry interface and landing point, the launch sites and the
///   recovery target (a crosshair in the target colour).
///
/// Zoom 1 shows the whole body; zoomed in, TRK keeps the vessel in the
/// centre, and without it the arrow buttons scroll the map.
public final class MapMFD: MFDMode {
    public static let zooms: [Double] = [1, 2, 4, 8, 16, 32, 64, 128]

    public var zoom = 1.0
    public var track = true
    /// The map's centre while not tracking, degrees.
    public var centerLatitude = 0.0, centerLongitude = 0.0
    /// Orbits of predicted track drawn, 0-3.
    public var predictedOrbits = 2

    public init() {}

    public var id: MFDModeID { .map }

    public func buttons(_ c: MFDContext?) -> [MFDButton?] {
        let scroll = !track
        return [
            MFDButton("ZM-", .x, "Zoom out", active: zoom > Self.zooms.first!),
            MFDButton("ZM+", .z, "Zoom in", active: zoom < Self.zooms.last!),
            MFDButton("TRK", .k, "Track the vessel on/off"),
            MFDButton("PRD", .p, "Orbits predicted: 0-3"),
            nil, nil,
            MFDButton("UP", .minus, "Scroll north", active: scroll),
            MFDButton("DN", .equal, "Scroll south", active: scroll),
            MFDButton("<", .leftBracket, "Scroll west", active: scroll),
            MFDButton(">", .rightBracket, "Scroll east", active: scroll),
        ]
    }

    public func press(_ b: MFDButton, _ c: MFDContext?) -> Bool {
        let i = Self.zooms.firstIndex(of: zoom) ?? 0
        let step = 90 / zoom
        switch b.key {
        case .x: zoom = Self.zooms[max(0, i - 1)]
        case .z: zoom = Self.zooms[min(Self.zooms.count - 1, i + 1)]
        case .k:
            if track, let c {
                // Leave the map where it is.
                let v = view(c)
                centerLatitude = v.latitude
                centerLongitude = v.longitude
            }
            track.toggle()
        case .p: predictedOrbits = (predictedOrbits + 1) % 4
        case .minus: centerLatitude = min(90, centerLatitude + step)
        case .equal: centerLatitude = max(-90, centerLatitude - step)
        case .leftBracket: centerLongitude = remainder(centerLongitude - step, 360)
        case .rightBracket: centerLongitude = remainder(centerLongitude + step, 360)
        default: return false
        }
        return true
    }

    // MARK: Projection

    /// The map's area on the screen.
    public static let area = MFDRect(MFDPoint(0, 2.0 / 24), MFDPoint(1, 21.0 / 24))

    /// A view of the map: its centre (degrees) and scale (screen units per
    /// degree), over `area`.
    public struct View {
        public var latitude: Double
        public var longitude: Double
        public var scale: Double
        public var area: MFDRect

        /// Half the visible span, degrees of longitude and latitude.
        public var halfWidth: Double { area.width / 2 / scale }
        public var halfHeight: Double { area.height / 2 / scale }

        /// The screen point of `latitude`, `longitude` (degrees), with the
        /// longitude taken within 180° of the centre's; and that offset.
        public func project(latitude lat: Double, longitude lon: Double) -> (point: MFDPoint, offset: Double) {
            var d = remainder(lon - longitude, 360)
            if d <= -180 { d += 360 }
            return (MFDPoint(area.center.x + d * scale, area.center.y - (lat - latitude) * scale), d)
        }

        /// Polylines through `points` (degrees), split where they cross the
        /// meridian opposite the centre.
        public func polylines(_ points: [(lat: Double, lon: Double)]) -> [[MFDPoint]] {
            var lines: [[MFDPoint]] = [], line: [MFDPoint] = [], last: Double?
            for p in points {
                let q = project(latitude: p.lat, longitude: p.lon)
                if let l = last, abs(q.offset - l) > 180 {
                    if line.count > 1 { lines.append(line) }
                    line = []
                }
                line.append(q.point)
                last = q.offset
            }
            if line.count > 1 { lines.append(line) }
            return lines
        }
    }

    public func view(_ c: MFDContext) -> View {
        let scale = zoom / 360
        var lat = centerLatitude, lon = centerLongitude
        if track {
            if zoom > 1 {
                let ll = c.vessel.latitudeLongitude(snapshot: c.snapshot)
                lat = ll.lat * 180 / .pi
                lon = ll.lon * 180 / .pi
            } else {
                lat = 0
                lon = 0
            }
        }
        let hh = Self.area.height / 2 / scale
        lat = hh >= 90 ? 0 : min(max(lat, -90 + hh), 90 - hh)
        return View(latitude: lat, longitude: lon, scale: scale, area: Self.area)
    }

    // MARK: Page

    public func page(_ c: MFDContext) -> MFDPage {
        let v = c.vessel, body = c.body, deg = 180 / Double.pi
        var page = MFDPage(title: "MAP  " + body.name)
        page.add(35, 0, String(format: "x%g", zoom) + (track ? " TRK" : ""), .referenceDim, alignment: .trailing)
        let view = view(c)
        var back: [MFDShape] = [], front: [MFDShape] = []
        func lines(_ pts: [(lat: Double, lon: Double)], _ style: MFDStyle, dashed: Bool = false,
                   into list: inout [MFDShape]) {
            for l in view.polylines(pts) { list.append(.polyline(l, style, dashed: dashed)) }
        }
        func degrees(_ g: [GeoPoint]) -> [(lat: Double, lon: Double)] { g.map { ($0.latitude * deg, $0.longitude * deg) } }

        // The body's edge at zoom 1, and the grid.
        let top = min(90, view.latitude + view.halfHeight), bottom = max(-90, view.latitude - view.halfHeight)
        let west = view.longitude - view.halfWidth, east = view.longitude + view.halfWidth
        let spacing: Double = zoom <= 2 ? 30 : zoom <= 8 ? 10 : zoom <= 32 ? 5 : 1
        func x(_ lon: Double) -> Double { view.area.center.x + (lon - view.longitude) * view.scale }
        func y(_ lat: Double) -> Double { view.area.center.y - (lat - view.latitude) * view.scale }
        var k = (west / spacing).rounded(.up)
        while k * spacing <= east {
            let lon = k * spacing
            back.append(.polyline([MFDPoint(x(lon), y(top)), MFDPoint(x(lon), y(bottom))], .referenceDim,
                                  dashed: lon != 0))
            k += 1
        }
        k = (bottom / spacing).rounded(.up)
        while k * spacing <= top {
            let lat = k * spacing
            back.append(.polyline([MFDPoint(x(west), y(lat)), MFDPoint(x(east), y(lat))], .referenceDim,
                                  dashed: lat != 0))
            k += 1
        }

        // Night, and the Sun overhead.
        let sun = GroundTrack.subsolarPoint(on: body, sun: c.sim.system.sun, snapshot: c.snapshot)
        let n = 96
        var night: [MFDPoint] = (0...n).map { i in
            let lon = west + (east - west) * Double(i) / Double(n)
            return MFDPoint(x(lon), y(sun.terminatorLatitude(atLongitude: lon / deg) * deg))
        }
        let dark = sun.latitude >= 0 ? -90.0 : 90.0
        night += [MFDPoint(x(east), y(dark)), MFDPoint(x(west), y(dark))]
        back.insert(.polygon(night, .night), at: 0)
        front.append(.marker(view.project(latitude: sun.latitude * deg, longitude: sun.longitude * deg).point,
                             .circle, .target))

        if body.id == 399 {
            for coast in c.environment.coastlines { lines(degrees(coast), .aux, into: &back) }
            for site in c.environment.sites {
                front.append(.marker(view.project(latitude: site.location.latitude * deg,
                                                  longitude: site.location.longitude * deg).point, .circle, .reference))
            }
        }
        if let target = c.recoveryTarget {
            front.append(.marker(view.project(latitude: target.location.latitude * deg,
                                              longitude: target.location.longitude * deg).point, .crosshair, .target))
        }

        // Tracks: flown, then predicted.
        lines(c.data.track.points.map { ($0.latitude * deg, $0.longitude * deg) }, .ownDim, into: &front)
        let caveat = c.predictionCaveat
        if predictedOrbits > 0, let el = c.elements, v.landed == nil {
            let period = el.isBound ? el.period : 7200
            let end = c.time + Double(predictedOrbits) * period
            let ahead = c.data.predicted.filter { $0.time >= c.time && $0.time <= end }
            lines(ahead.map { ($0.latitude * deg, $0.longitude * deg) }, caveat == nil ? .own : .ownDim, dashed: true,
                  into: &front)
        }

        // The vessel and what it sees.
        let ll = v.latitudeLongitude(snapshot: c.snapshot)
        if v.landed == nil {
            let horizon = GroundTrack.horizonCircle(latitude: ll.lat, longitude: ll.lon, height: v.altitude,
                                                    figure: body.figure, points: 72)
            lines(horizon.map { ($0.latitude * deg, $0.longitude * deg) }, .ownDim, into: &front)
        }
        if let ei = c.data.entryInterface {
            front.append(.marker(view.project(latitude: ei.latitude * deg, longitude: ei.longitude * deg).point,
                                 .cross, .aux))
            page.add(4, 21, "EI " + MFDFormat.clock(ei.time, zero: c.missionClockZero), .aux)
            page.add(35, 21, MFDFormat.latitude(ei.latitude) + " " + MFDFormat.longitude(ei.longitude), .aux,
                     alignment: .trailing)
        }
        if let land = c.landingPoint {
            front.append(.marker(view.project(latitude: land.latitude * deg, longitude: land.longitude * deg).point,
                                 .cross, .warn))
        }
        front.append(.marker(view.project(latitude: ll.lat * deg, longitude: ll.lon * deg).point, .vessel, .own))

        page.layers = [MFDLayer(clip: view.area, shapes: back + front)]
        if let caveat, predictedOrbits > 0, v.landed == nil { page.add(35, 1, "PRED: " + caveat, .warn, alignment: .trailing) }

        let ground = v.surfaceVelocity(snapshot: c.snapshot)
        page.field(4, 22, "LAT", MFDFormat.latitude(ll.lat), valueEnd: 16, labelStyle: .reference)
        page.field(20, 22, "LON", MFDFormat.longitude(ll.lon), valueEnd: 35, labelStyle: .reference)
        page.field(4, 23, "ALT", MFDFormat.si(v.altitude), valueEnd: 16, labelStyle: .reference)
        page.field(20, 23, "CRS", ground.length > 0.5
                   ? MFDFormat.heading(EntryInterface.azimuth(position: v.position, velocity: ground,
                                                              pole: c.orientation.pole)) : "---",
                   valueEnd: 35, labelStyle: .reference)
        return page
    }
}
