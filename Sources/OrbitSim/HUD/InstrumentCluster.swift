import SwiftUI
import OrbitCore
import OrbitRender
import OrbitInstruments

/// The flight instruments at the bottom centre: throttle (the g meter in an
/// entry), speed tape, the navball with heading, pitch and roll and the
/// body-rate needles, the altitude tape with the apsides, the vertical-speed
/// bar and the autopilot modes; below them a strip with the next event and
/// the target's range and range rate, or in an entry the 0.05 g light, the
/// bank, the heating and the landing system. The moving parts are drawn
/// every frame from `InstrumentModel`, in step with the ball; the scales and
/// labels once, the mode column when the mode changes and the strip five
/// times a second (text is what costs in a canvas).
struct InstrumentCluster: View {
    let instruments: InstrumentModel
    let layout: Layout

    init(instruments: InstrumentModel, ball: CGFloat) {
        self.instruments = instruments
        layout = Layout(ball: ball)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            StaticLayer(layout: layout).equatable()
            TimelineView(.animation) { timeline in
                // Read the instruments at each tick, so the canvas redraws with them.
                let painter = Painter(layout: layout, r: instruments.readouts, ball: instruments.navball,
                                      date: timeline.date)
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, _ in painter.draw(&ctx) }
                    ModeColumn(layout: layout, autopilot: painter.r.autopilot,
                               holdProgram: painter.r.holdProgram).equatable()
                }
            }
            NavballView(instruments: instruments)
                .frame(width: layout.ball.width, height: layout.ball.height)
                .offset(x: layout.ball.minX, y: layout.ball.minY)
            TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                AnnunciatorStrip(r: instruments.readouts)
                    .frame(width: layout.strip.width, height: layout.strip.height)
                    .offset(x: layout.strip.minX, y: layout.strip.minY)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
    }

    /// Where everything sits, from the ball's diameter.
    struct Layout: Equatable {
        let size: CGSize
        let ball: CGRect
        let throttle, speedTape, altitudeTape, vsi, modes: CGRect
        /// Rows above and below the tapes, for their labels.
        let labelRow: CGFloat, belowRows: (CGFloat, CGFloat)
        /// The annunciator strip along the bottom.
        let strip: CGRect
        /// The visible ball's radius in the navball view (its bezel's).
        var ballRadius: CGFloat { ball.width / 2 * CGFloat(NavballRenderer.bezelRadius) }

        init(ball d: CGFloat) {
            let pad: CGFloat = 8, top: CGFloat = 6
            let tapeTop = top + 18 + 12, tapeHeight = d + 24
            var x = pad
            func column(_ w: CGFloat, gap: CGFloat) -> CGRect {
                defer { x += w + gap }
                return CGRect(x: x, y: tapeTop, width: w, height: tapeHeight)
            }
            throttle = column(22, gap: 10)
            speedTape = column(84, gap: 12)
            ball = CGRect(x: x, y: tapeTop + 12, width: d, height: d)
            x += d + 22
            altitudeTape = column(84, gap: 4)
            vsi = column(36, gap: 10)
            modes = column(74, gap: pad)
            labelRow = top + 9
            let below = tapeTop + tapeHeight + 10
            belowRows = (below, below + 15)
            strip = CGRect(x: pad, y: below + 24, width: x - 2 * pad, height: 16)
            size = CGSize(width: x, height: strip.maxY + 6)
        }

        static func == (a: Layout, b: Layout) -> Bool { a.ball == b.ball }
    }
}

/// The scales, frames and fixed labels, drawn once per layout.
private struct StaticLayer: View, Equatable {
    let layout: InstrumentCluster.Layout

    var body: some View {
        Canvas { ctx, _ in Painter.drawStatic(&ctx, layout) }
    }
}

/// The autopilot modes, drawn when the mode changes.
private struct ModeColumn: View, Equatable {
    let layout: InstrumentCluster.Layout
    let autopilot: AttitudeAutopilot?
    let holdProgram: String?

    var body: some View {
        Canvas { ctx, _ in Painter.drawModes(&ctx, layout, autopilot: autopilot, holdProgram: holdProgram) }
    }
}

// MARK: - Painting

private struct Painter {
    let layout: InstrumentCluster.Layout
    let r: InstrumentModel.Readouts
    let ball: Navball?
    let date: Date

    static let green = Color(red: 0.6, green: 1.0, blue: 0.7)
    static let dim = Color(red: 0.6, green: 1.0, blue: 0.7).opacity(0.55)
    static let panel = Color.black.opacity(0.5)
    static let deg = Double.pi / 180

    static func text(_ s: String, size: CGFloat = 11, weight: Font.Weight = .regular, color: Color = green) -> Text {
        Text(s).font(.system(size: size, weight: weight, design: .monospaced)).foregroundColor(color)
    }

    func text(_ s: String, size: CGFloat = 11, weight: Font.Weight = .regular, color: Color = green) -> Text {
        Self.text(s, size: size, weight: weight, color: color)
    }

    /// The moving parts.
    func draw(_ ctx: inout GraphicsContext) {
        throttle(&ctx)
        speedTape(&ctx)
        altitudeTape(&ctx)
        verticalSpeed(&ctx)
        ballReadouts(&ctx)
    }

    /// The panel, the instruments' frames and scales, and their fixed labels.
    static func drawStatic(_ ctx: inout GraphicsContext, _ layout: InstrumentCluster.Layout) {
        let all = CGRect(origin: .zero, size: layout.size)
        ctx.fill(Path(roundedRect: all, cornerRadius: 8), with: .color(panel))
        for f in [layout.throttle, layout.speedTape, layout.altitudeTape, layout.vsi] {
            ctx.fill(Path(f), with: .color(.black.opacity(0.5)))
            ctx.stroke(Path(f), with: .color(dim), lineWidth: 1)
        }
        func label(_ s: String, _ f: CGRect, _ y: CGFloat, weight: Font.Weight = .regular) {
            ctx.draw(text(s, size: 10, weight: weight), at: CGPoint(x: f.midX, y: y))
        }
        label("ALT", layout.altitudeTape, layout.labelRow, weight: .semibold)
        label("VS", layout.vsi, layout.labelRow, weight: .semibold)
        label("m/s", layout.vsi, layout.belowRows.1)
        label("AUTO", layout.modes, layout.labelRow, weight: .semibold)

        // The vertical-speed scale.
        let f = layout.vsi
        for (v, name) in [(0.0, "0"), (10, ""), (100, "100"), (500, ""), (1000, "1k"), (2000, "2k")] {
            for s in v == 0 ? [1.0] : [1.0, -1.0] {
                let y = vsiY(v * s, f)
                var p = Path()
                p.move(to: CGPoint(x: f.minX, y: y))
                p.addLine(to: CGPoint(x: f.minX + (name.isEmpty ? 4 : 7), y: y))
                ctx.stroke(p, with: .color(dim), lineWidth: 1)
                if !name.isEmpty {
                    ctx.draw(text(name, size: 8, color: dim), at: CGPoint(x: f.maxX - 2, y: y), anchor: .trailing)
                }
            }
        }

        // The body-rate scales, ±5°/s: roll above the ball, pitch at its
        // right, yaw below (as an FDAI's).
        let n = needleGeometry(layout)
        func scale(from p0: CGPoint, to p1: CGPoint) {
            var p = Path()
            p.move(to: p0)
            p.addLine(to: p1)
            ctx.stroke(p, with: .color(dim), lineWidth: 1)
        }
        func tick(_ p: CGPoint, horizontal: Bool) {
            var t = Path()
            t.move(to: CGPoint(x: p.x - (horizontal ? 0 : 3), y: p.y - (horizontal ? 3 : 0)))
            t.addLine(to: CGPoint(x: p.x + (horizontal ? 0 : 3), y: p.y + (horizontal ? 3 : 0)))
            ctx.stroke(t, with: .color(dim), lineWidth: 1)
        }
        let c = n.centre, length = n.length
        scale(from: CGPoint(x: c.x - length, y: n.top), to: CGPoint(x: c.x + length, y: n.top))
        scale(from: CGPoint(x: c.x - length, y: n.bottom), to: CGPoint(x: c.x + length, y: n.bottom))
        scale(from: CGPoint(x: n.right, y: c.y - length), to: CGPoint(x: n.right, y: c.y + length))
        for k in [-1.0, -0.5, 0, 0.5, 1] {
            tick(CGPoint(x: c.x + CGFloat(k) * length, y: n.top), horizontal: true)
            tick(CGPoint(x: c.x + CGFloat(k) * length, y: n.bottom), horizontal: true)
            tick(CGPoint(x: n.right, y: c.y + CGFloat(k) * length), horizontal: false)
        }
    }

    /// Where the rate needles run: the ball's centre, the half-length of
    /// their scales, the roll scale's y above the ball, the yaw scale's
    /// below and the pitch scale's x at its right.
    static func needleGeometry(_ layout: InstrumentCluster.Layout)
        -> (centre: CGPoint, length: CGFloat, top: CGFloat, bottom: CGFloat, right: CGFloat) {
        let b = layout.ball, c = CGPoint(x: b.midX, y: b.midY), radius = layout.ballRadius
        return (c, radius * 0.9, c.y - radius - 6, c.y + radius + 6, c.x + radius + 8)
    }

    /// The vertical-speed scale: signed square root to ±2 km/s.
    static func vsiY(_ vs: Double, _ f: CGRect) -> CGFloat {
        let half = f.height / 2 - 4, full = 2_000.0
        let s = (min(abs(vs), full) / full).squareRoot()
        return f.midY - CGFloat(vs < 0 ? -s : s) * half
    }

    // MARK: Throttle

    /// The throttle, or in an entry the g meter in its place.
    func throttle(_ ctx: inout GraphicsContext) {
        let f = layout.throttle
        if let entry = r.entry {
            gMeter(&ctx, entry)
            return
        }
        let level = max(0, min(1, r.throttle))
        let bar = CGRect(x: f.minX + 3, y: f.maxY - 3 - (f.height - 6) * level, width: f.width - 6,
                         height: (f.height - 6) * level)
        ctx.fill(Path(bar), with: .color(Color(red: 0.95, green: 0.7, blue: 0.2)))
        ctx.draw(text("THR", size: 10), at: CGPoint(x: f.midX, y: layout.labelRow))
        ctx.draw(text(String(format: "%.0f", level * 100), size: 10), at: CGPoint(x: f.midX, y: layout.belowRows.0))
        ctx.draw(text("%", size: 10), at: CGPoint(x: f.midX, y: layout.belowRows.1))
    }

    /// Full scale of the g meter, g.
    static let gMeterScale = 10.0

    /// The sensed load factor on a 0-10 g scale (the EMS's), ticked every g,
    /// amber from 5 g and red from 8 g, with the entry's peak.
    func gMeter(_ ctx: inout GraphicsContext, _ entry: EntryReadouts) {
        let f = layout.throttle, inner = f.height - 6
        func y(_ g: Double) -> CGFloat { f.maxY - 3 - inner * CGFloat(max(0, min(1, g / Self.gMeterScale))) }
        let g = entry.loadFactor
        let color = g >= 8 ? Color(red: 1, green: 0.3, blue: 0.25) : g >= 5 ? Color(red: 1, green: 0.7, blue: 0.2)
            : Self.green
        ctx.fill(Path(CGRect(x: f.minX + 7, y: y(g), width: f.width - 10, height: f.maxY - 3 - y(g))),
                 with: .color(color))
        for k in 0...Int(Self.gMeterScale) {
            var p = Path()
            p.move(to: CGPoint(x: f.minX, y: y(Double(k))))
            p.addLine(to: CGPoint(x: f.minX + (k % 5 == 0 ? 6 : 3), y: y(Double(k))))
            ctx.stroke(p, with: .color(Self.dim), lineWidth: 1)
        }
        if let peak = entry.peakLoadFactor, peak > 0 {
            var p = Path()
            p.move(to: CGPoint(x: f.minX + 4, y: y(peak)))
            p.addLine(to: CGPoint(x: f.maxX - 1, y: y(peak)))
            ctx.stroke(p, with: .color(Color(red: 1, green: 0.85, blue: 0.3)), lineWidth: 1.5)
        }
        ctx.draw(text("G", size: 10, weight: .semibold), at: CGPoint(x: f.midX, y: layout.labelRow))
        ctx.draw(text(String(format: "%.1f", g), size: 10), at: CGPoint(x: f.midX, y: layout.belowRows.0))
        ctx.draw(text("g", size: 10), at: CGPoint(x: f.midX, y: layout.belowRows.1))
    }

    // MARK: Tapes

    /// A vertical tape centred on `value`, its scale auto-ranging with the
    /// value's size: `span` across the whole tape, a labelled tick every
    /// quarter and a small one every twentieth.
    func tape(_ ctx: inout GraphicsContext, _ f: CGRect, value: Double, span: Double,
              label: (Double) -> String, readout: String, ticksOnRight: Bool) {
        let perUnit = Double(f.height) / span
        func y(_ v: Double) -> CGFloat { f.midY - CGFloat((v - value) * perUnit) }
        let minor = span / 20, major = span / 4
        var inner = ctx
        inner.clip(to: Path(f))
        var v = ((value - span / 2) / minor).rounded(.down) * minor
        while v <= value + span / 2 {
            let isMajor = abs((v / major).rounded() * major - v) < minor * 1e-3
            let len: CGFloat = isMajor ? 12 : 6
            let x0 = ticksOnRight ? f.maxX - len : f.minX, x1 = ticksOnRight ? f.maxX : f.minX + len
            var p = Path()
            p.move(to: CGPoint(x: x0, y: y(v)))
            p.addLine(to: CGPoint(x: x1, y: y(v)))
            inner.stroke(p, with: .color(Self.dim), lineWidth: 1)
            if isMajor {
                inner.draw(text(label(v), size: 10, color: Self.dim),
                           at: CGPoint(x: ticksOnRight ? f.maxX - 16 : f.minX + 16, y: y(v)),
                           anchor: ticksOnRight ? .trailing : .leading)
            }
            v += minor
        }
        // The value's box, pointing at the scale.
        let box = CGRect(x: f.minX + 2, y: f.midY - 10, width: f.width - 4, height: 20)
        ctx.fill(Path(roundedRect: box, cornerRadius: 3), with: .color(.black.opacity(0.9)))
        ctx.stroke(Path(roundedRect: box, cornerRadius: 3), with: .color(Self.green), lineWidth: 1)
        ctx.draw(text(readout, size: 12, weight: .semibold), at: CGPoint(x: box.midX, y: box.midY))
    }

    /// Two units of the value's order of magnitude (at least `floor`).
    static func span(_ value: Double, floor: Double, factor: Double) -> Double {
        factor * pow(10, Foundation.floor(log10(max(abs(value), floor))))
    }

    static func compact(_ v: Double) -> String {
        abs(v) >= 10_000 ? String(format: "%.0fk", v / 1000)
            : abs(v) >= 1000 ? String(format: "%.1fk", v / 1000) : String(format: "%.0f", v)
    }

    func speedTape(_ ctx: inout GraphicsContext) {
        let f = layout.speedTape
        tape(&ctx, f, value: r.speed, span: Self.span(r.speed, floor: 10, factor: 2), label: Self.compact,
             readout: String(format: "%.1f", r.speed), ticksOnRight: true)
        ctx.draw(text("\(r.frame.label) \(r.automatic ? "auto" : "N")", size: 10, weight: .semibold),
                 at: CGPoint(x: f.midX, y: layout.labelRow))
        ctx.draw(text(String(format: "M %.2f", r.mach), size: 10), at: CGPoint(x: f.midX, y: layout.belowRows.0))
        ctx.draw(text(String(format: "q %.1f kPa", r.dynamicPressure / 1000), size: 10),
                 at: CGPoint(x: f.midX, y: layout.belowRows.1))
    }

    func altitudeTape(_ ctx: inout GraphicsContext) {
        let f = layout.altitudeTape
        let span = Self.span(r.altitude, floor: 1000, factor: 1)
        let readout = abs(r.altitude) >= 10_000 ? String(format: "%.2f km", r.altitude / 1000)
            : String(format: "%.0f m", r.altitude)
        // Labels in km from a 10 km span, in m below it.
        tape(&ctx, f, value: r.altitude, span: span,
             label: { span >= 100_000 ? String(format: "%.0f", $0 / 1000)
                 : span >= 10_000 ? String(format: "%.1f", $0 / 1000) : String(format: "%.0f", $0) },
             readout: readout, ticksOnRight: false)
        // Apoapsis and periapsis bugs on the scale's side, held at the tape's
        // ends when out of its range.
        func bug(_ alt: Double?, _ name: String, _ color: Color) {
            guard let alt else { return }
            let perUnit = Double(f.height) / span
            let y = min(max(f.midY - CGFloat((alt - r.altitude) * perUnit), f.minY + 6), f.maxY - 6)
            var p = Path()
            p.move(to: CGPoint(x: f.maxX, y: y))
            p.addLine(to: CGPoint(x: f.maxX - 8, y: y - 5))
            p.addLine(to: CGPoint(x: f.maxX - 8, y: y + 5))
            p.closeSubpath()
            ctx.fill(p, with: .color(color))
            ctx.draw(text(name, size: 9, weight: .bold, color: color), at: CGPoint(x: f.maxX - 10, y: y),
                     anchor: .trailing)
        }
        bug(r.periapsisAltitude, "Pe", Color(red: 1, green: 0.6, blue: 0.3))
        bug(r.apoapsisAltitude, "Ap", Color(red: 0.4, green: 0.85, blue: 1))
        ctx.draw(text("Ap " + (r.apoapsisAltitude.map { String(format: "%.1fk", $0 / 1000) } ?? "–"), size: 10),
                 at: CGPoint(x: f.midX, y: layout.belowRows.0))
        ctx.draw(text("Pe " + (r.periapsisAltitude.map { String(format: "%.1fk", $0 / 1000) } ?? "–"), size: 10),
                 at: CGPoint(x: f.midX, y: layout.belowRows.1))
    }

    /// The vertical-speed bar on its scale.
    func verticalSpeed(_ ctx: inout GraphicsContext) {
        let f = layout.vsi, y = Self.vsiY(r.verticalSpeed, f)
        let bar = CGRect(x: f.minX + 8, y: min(f.midY, y), width: 5, height: abs(y - f.midY))
        ctx.fill(Path(bar), with: .color(r.verticalSpeed >= 0 ? Self.green : Color(red: 1, green: 0.55, blue: 0.3)))
        ctx.draw(text(String(format: "%+.0f", r.verticalSpeed), size: 10), at: CGPoint(x: f.midX, y: layout.belowRows.0))
    }

    // MARK: The ball's readouts

    func ballReadouts(_ ctx: inout GraphicsContext) {
        let b = layout.ball, c = CGPoint(x: b.midX, y: b.midY)
        guard let ball else {
            ctx.draw(text("NO ATTITUDE"), at: c)
            return
        }
        let a = ball.angles
        ctx.draw(text(String(format: "HDG %05.1f°", a.heading / Self.deg), size: 13, weight: .bold),
                 at: CGPoint(x: c.x, y: layout.labelRow))
        ctx.draw(text(String(format: "PIT %+05.1f°", a.pitch / Self.deg), size: 11, weight: .semibold),
                 at: CGPoint(x: b.minX, y: layout.belowRows.0), anchor: .leading)
        ctx.draw(text(String(format: "RLL %+06.1f°", a.roll / Self.deg), size: 11, weight: .semibold),
                 at: CGPoint(x: b.maxX, y: layout.belowRows.0), anchor: .trailing)
        if let aero = ball.aero, r.dynamicPressure >= 10 {
            ctx.draw(text(String(format: "α %+.1f°  β %+.1f°", aero.alpha / Self.deg, aero.beta / Self.deg), size: 10),
                     at: CGPoint(x: c.x, y: layout.belowRows.1))
        }

        // Body-rate needles, ±5°/s full scale.
        let n = Self.needleGeometry(layout), full = 5 * Self.deg
        func needle(_ rate: Double) -> CGFloat { CGFloat(max(-1, min(1, rate / full))) * n.length }
        func triangle(_ tip: CGPoint, pointing dx: CGFloat, _ dy: CGFloat) {
            var p = Path()
            p.move(to: tip)
            p.addLine(to: CGPoint(x: tip.x - dx * 7 - dy * 4, y: tip.y - dy * 7 - dx * 4))
            p.addLine(to: CGPoint(x: tip.x - dx * 7 + dy * 4, y: tip.y - dy * 7 + dx * 4))
            p.closeSubpath()
            ctx.fill(p, with: .color(Color(red: 1, green: 0.85, blue: 0.3)))
        }
        triangle(CGPoint(x: c.x + needle(ball.rates.x), y: n.top + 1), pointing: 0, 1)
        triangle(CGPoint(x: n.right - 1, y: c.y - needle(ball.rates.y)), pointing: -1, 0)
        triangle(CGPoint(x: c.x + needle(ball.rates.z), y: n.bottom - 1), pointing: 0, -1)
    }

    // MARK: Autopilot modes

    static let modeRows: [(name: String, key: String, mode: AttitudeAutopilot)] = [
        ("KILL", "T", .killRotation), ("PRO", "1", .prograde), ("RETRO", "2", .retrograde),
        ("NML", "3", .normal), ("ANML", "4", .antinormal), ("RAD+", "5", .radialOut), ("RAD-", "6", .radialIn),
        ("LVL", "7", .horizonLevel), ("HOLD", "8", .attitudeHold),
    ]

    static func color(_ mode: AttitudeAutopilot) -> Color {
        let g: MarkerGlyph
        switch mode {
        case .prograde, .retrograde: g = .prograde
        case .normal, .antinormal: g = .normal
        case .radialOut, .radialIn: g = .radialOut
        default: g = .command
        }
        return Color(.sRGB, red: g.color.r, green: g.color.g, blue: g.color.b)
    }

    static func drawModes(_ ctx: inout GraphicsContext, _ layout: InstrumentCluster.Layout,
                          autopilot: AttitudeAutopilot?, holdProgram: String?) {
        let f = layout.modes
        let rowHeight = f.height / CGFloat(modeRows.count)
        for (i, row) in modeRows.enumerated() {
            let cell = CGRect(x: f.minX, y: f.minY + CGFloat(i) * rowHeight + 1.5, width: f.width, height: rowHeight - 3)
            let active = autopilot == row.mode
            if active {
                ctx.fill(Path(roundedRect: cell, cornerRadius: 4), with: .color(color(row.mode).opacity(0.85)))
            } else {
                ctx.stroke(Path(roundedRect: cell, cornerRadius: 4), with: .color(dim.opacity(0.6)), lineWidth: 1)
            }
            var name = row.name
            if row.mode == .attitudeHold, active, let program = holdProgram { name = "HOLD " + program }
            ctx.draw(text(name, size: 10, weight: .bold, color: active ? .black : green),
                     at: CGPoint(x: cell.minX + 6, y: cell.midY), anchor: .leading)
            ctx.draw(text(row.key, size: 10, color: active ? .black : dim),
                     at: CGPoint(x: cell.maxX - 6, y: cell.midY), anchor: .trailing)
        }
        if autopilot == nil {
            ctx.draw(text("off  0", size: 10, color: dim), at: CGPoint(x: f.midX, y: layout.belowRows.0))
        }
    }
}

// MARK: - Annunciator strip

/// The strip under the cluster. In an entry: the 0.05 g light, the peak
/// load factor, the bank, the heat flux and load, the landing system, and
/// the next event when it fits. Otherwise the next event (the flight
/// program's, or the loaded burn's ignition) and the target's range and
/// range rate.
private struct AnnunciatorStrip: View {
    let r: InstrumentModel.Readouts

    static let target = color(.target)
    static let maneuver = color(.maneuver)
    static let lamp = Color(red: 1, green: 0.72, blue: 0.2)

    static func color(_ g: MarkerGlyph) -> Color { Color(.sRGB, red: g.color.r, green: g.color.g, blue: g.color.b) }

    func item(_ label: String, _ value: String, _ color: Color = Painter.green) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundColor(color.opacity(0.75))
            Text(value).foregroundColor(color).fontWeight(.semibold)
        }
    }

    @ViewBuilder var next: some View {
        if let n = r.nextEvent {
            let burn = r.maneuver.map { n.name == $0.name + " TIG" } ?? false
            item("NEXT", HUDFormat.nextEvent(n.name, in: n.timeToGo), burn ? Self.maneuver : Painter.green)
        }
    }

    @ViewBuilder var target: some View {
        if let t = r.target {
            HStack(spacing: 8) {
                item("TGT", t.name, Self.target)
                Text(HUDFormat.range(t.relative.range)).foregroundColor(Self.target)
                Text(HUDFormat.rangeRate(t.relative.rangeRate)).foregroundColor(Self.target)
            }
        }
    }

    func entry(_ e: EntryReadouts) -> some View {
        HStack(spacing: 10) {
            Text("0.05 G")
                .fontWeight(.bold)
                .foregroundColor(e.pointZeroFiveG ? .black : Painter.dim)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 3).fill(e.pointZeroFiveG ? Self.lamp : .clear))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(e.pointZeroFiveG ? Self.lamp : Painter.dim, lineWidth: 1))
            if let peak = e.peakLoadFactor { item("PK", HUDFormat.loadFactor(peak)) }
            item("BANK", HUDFormat.bank(e.bankAngle))
            item("FLUX", HUDFormat.heatFlux(e.heatFlux))
            item("LOAD", HUDFormat.heatLoad(e.heatLoad))
            if let els = e.landingSystem { Text(els).foregroundColor(Painter.green) }
        }
    }

    var body: some View {
        Group {
            if let e = r.entry {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        entry(e)
                        Spacer(minLength: 0)
                        next
                    }
                    HStack {
                        entry(e)
                        Spacer(minLength: 0)
                    }
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        next
                        Spacer(minLength: 0)
                        target
                    }
                    HStack {
                        target
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .lineLimit(1)
    }
}
