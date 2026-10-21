import SwiftUI
import AppKit
import OrbitInstruments

/// One multi-function display, Orbiter-style: a square screen drawing an
/// `MFDPage` (a display list: text on a 40 x 24 character grid and vector
/// graphics) in a frame with six buttons down each side, their labels on
/// the screen's edge beside them, and PWR, SEL and MNU beneath.
struct MFDPanelView: View, Equatable {
    let page: MFDPage
    let side: MFDSide
    let size: CGSize
    let press: (MFDControl) -> Void

    nonisolated static func == (a: MFDPanelView, b: MFDPanelView) -> Bool {
        a.page == b.page && a.side == b.side && a.size == b.size
    }

    /// The frame around the screen: the side button columns and the bottom row.
    static let bezel: CGFloat = 14, bottom: CGFloat = 20, gap: CGFloat = 3

    struct Geometry {
        let screen: CGRect
        init(_ size: CGSize) {
            let s = max(40, min(size.width - 2 * MFDPanelView.bezel, size.height - MFDPanelView.bottom - MFDPanelView.gap))
            screen = CGRect(x: (size.width - s) / 2, y: max(0, size.height - MFDPanelView.bottom - MFDPanelView.gap - s),
                            width: s, height: s)
        }

        /// The centre's y of side button `i` (0-5 on either side).
        func buttonY(_ i: Int) -> CGFloat {
            screen.minY + screen.height * (CGFloat(MFDPage.buttonRow(i)) + 0.5) / CGFloat(MFDPage.rows)
        }
    }

    var body: some View {
        let g = Geometry(size)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(white: 0.13).opacity(0.85))
                .frame(width: g.screen.width + 2 * Self.bezel, height: g.screen.height + Self.bottom + Self.gap + 4)
                .offset(x: g.screen.minX - Self.bezel, y: g.screen.minY - 4)
            Canvas { ctx, _ in MFDRenderer(page: page, screen: g.screen).draw(&ctx) }
                .frame(width: size.width, height: size.height)
            ForEach(0..<12, id: \.self) { i in
                let left = i < 6
                MFDKey(width: Self.bezel - 5, height: 9) { click(.button(i)) }
                    .offset(x: left ? g.screen.minX - Self.bezel + 2 : g.screen.maxX + 3, y: g.buttonY(i) - 4.5)
            }
            HStack(spacing: 6) {
                MFDKey(label: "PWR", width: 34, height: 14) { click(.power) }
                MFDKey(label: "SEL", width: 34, height: 14) { click(.select) }
                MFDKey(label: "MNU", width: 34, height: 14) { click(.menu) }
            }
            .frame(width: g.screen.width)
            .offset(x: g.screen.minX, y: g.screen.maxY + Self.gap + 2)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// Act on a click, then give the keyboard back to the flight view.
    func click(_ control: MFDControl) {
        press(control)
        guard let window = NSApp.keyWindow, let view = window.contentView.flatMap(Self.gameView) else { return }
        window.makeFirstResponder(view)
    }

    static func gameView(in view: NSView) -> GameView? {
        if let g = view as? GameView { return g }
        for sub in view.subviews { if let g = gameView(in: sub) { return g } }
        return nil
    }
}

/// A button of the display's frame.
private struct MFDKey: View {
    var label: String? = nil
    let width: CGFloat
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.32))
                RoundedRectangle(cornerRadius: 2).stroke(Color(white: 0.5), lineWidth: 0.5)
                if let label {
                    Text(label).font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color(white: 0.85))
                }
            }
            .frame(width: width, height: height)
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

/// Draws an `MFDPage` into a canvas.
struct MFDRenderer {
    let page: MFDPage
    let screen: CGRect

    var cell: CGSize {
        CGSize(width: screen.width / CGFloat(MFDPage.columns), height: screen.height / CGFloat(MFDPage.rows))
    }

    /// The monospaced font's advance per point of size.
    static let advance: CGFloat = {
        let f = NSFont.monospacedSystemFont(ofSize: 100, weight: .regular)
        return ("0" as NSString).size(withAttributes: [.font: f]).width / 100
    }()

    var fontSize: CGFloat { min(cell.width / Self.advance, cell.height * 0.95) }

    static func color(_ s: MFDStyle) -> Color {
        let c = s.rgba
        return Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }

    func point(_ p: MFDPoint) -> CGPoint {
        CGPoint(x: screen.minX + CGFloat(p.x) * screen.width, y: screen.minY + CGFloat(p.y) * screen.height)
    }

    func draw(_ ctx: inout GraphicsContext) {
        let r = Path(roundedRect: screen, cornerRadius: 3)
        ctx.fill(r, with: .color(.black.opacity(page.powered ? 0.82 : 0.9)))
        guard page.powered else { return }
        var screenCtx = ctx
        screenCtx.clip(to: r)
        for layer in page.layers {
            var c = screenCtx
            if let clip = layer.clip {
                let a = point(clip.min), b = point(clip.max)
                c.clip(to: Path(CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)))
            }
            for s in layer.shapes { draw(s, &c) }
        }
        text(MFDText(0, 0, page.title, .reference), &screenCtx)
        for t in page.text { text(t, &screenCtx) }
        labels(&screenCtx)
    }

    func draw(_ shape: MFDShape, _ ctx: inout GraphicsContext) {
        let line = StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
        let dashed = StrokeStyle(lineWidth: 1, lineCap: .butt, dash: [3, 3])
        switch shape {
        case let .polyline(pts, style, isDashed):
            guard pts.count > 1 else { return }
            var path = Path()
            path.addLines(pts.map(point))
            ctx.stroke(path, with: .color(Self.color(style)), style: isDashed ? dashed : line)
        case let .polygon(pts, style):
            guard pts.count > 2 else { return }
            var path = Path()
            path.addLines(pts.map(point))
            path.closeSubpath()
            ctx.fill(path, with: .color(Self.color(style)))
        case let .circle(center, radius, style, filled):
            let c = point(center), rr = CGFloat(radius) * screen.width
            let path = Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr))
            if filled { ctx.fill(path, with: .color(Self.color(style))) } else {
                ctx.stroke(path, with: .color(Self.color(style)), style: line)
            }
        case let .marker(p, kind, style):
            marker(point(p), kind, Self.color(style), &ctx)
        case let .rect(a, b, style, filled):
            let p = point(a), q = point(b)
            let path = Path(CGRect(x: p.x, y: p.y, width: q.x - p.x, height: q.y - p.y))
            if filled { ctx.fill(path, with: .color(Self.color(style))) } else {
                ctx.stroke(path, with: .color(Self.color(style)), style: line)
            }
        }
    }

    func marker(_ c: CGPoint, _ kind: MFDMarkerKind, _ color: Color, _ ctx: inout GraphicsContext) {
        let r = max(2.5, screen.width / 80)
        var path = Path()
        switch kind {
        case .vessel:
            path.addRect(CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            path.move(to: CGPoint(x: c.x - 2 * r, y: c.y)); path.addLine(to: CGPoint(x: c.x + 2 * r, y: c.y))
            path.move(to: CGPoint(x: c.x, y: c.y - 2 * r)); path.addLine(to: CGPoint(x: c.x, y: c.y + 2 * r))
        case .cross:
            path.move(to: CGPoint(x: c.x - r, y: c.y - r)); path.addLine(to: CGPoint(x: c.x + r, y: c.y + r))
            path.move(to: CGPoint(x: c.x - r, y: c.y + r)); path.addLine(to: CGPoint(x: c.x + r, y: c.y - r))
        case .diamond:
            path.addLines([CGPoint(x: c.x, y: c.y - r), CGPoint(x: c.x + r, y: c.y), CGPoint(x: c.x, y: c.y + r),
                           CGPoint(x: c.x - r, y: c.y)])
            path.closeSubpath()
        case .circle:
            path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        case .crosshair:
            let rr = 1.4 * r
            path.addEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr))
            for (dx, dy) in [(1.0, 0.0), (-1, 0), (0, 1), (0, -1)] {
                path.move(to: CGPoint(x: c.x + dx * 0.5 * r, y: c.y + dy * 0.5 * r))
                path.addLine(to: CGPoint(x: c.x + dx * 2.2 * r, y: c.y + dy * 2.2 * r))
            }
        }
        ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.2))
    }

    /// `t` on the character grid, each character in its cell.
    func text(_ t: MFDText, _ ctx: inout GraphicsContext) {
        guard !t.string.isEmpty else { return }
        let size = fontSize, tracking = max(0, cell.width - Self.advance * size)
        let resolved = ctx.resolve(Text(t.string).font(.system(size: size, design: .monospaced)).tracking(tracking)
            .foregroundColor(Self.color(t.style)))
        let at = CGPoint(x: screen.minX + CGFloat(t.startColumn) * cell.width,
                         y: screen.minY + (CGFloat(t.row) + 0.5) * cell.height)
        ctx.draw(resolved, at: at, anchor: .leading)
    }

    /// The side buttons' labels on the screen's edges, on a dark ground so
    /// they read over a map.
    func labels(_ ctx: inout GraphicsContext) {
        for (i, label) in page.buttons.prefix(12).enumerated() {
            guard let label else { continue }
            let row = MFDPage.buttonRow(i)
            let left = i < 6
            let t = MFDText(left ? 0 : MFDPage.columns - 1, row, label.label,
                            label.inactive ? .referenceDim : .reference, alignment: left ? .leading : .trailing)
            let x0 = screen.minX + CGFloat(t.startColumn) * cell.width
            let y = screen.minY + (CGFloat(row) + 0.5) * cell.height
            let box = CGRect(x: x0 - 1, y: y - cell.height / 2, width: CGFloat(label.label.count) * cell.width + 2,
                             height: cell.height)
            ctx.fill(Path(box), with: .color(.black.opacity(0.75)))
            let size = fontSize, tracking = max(0, cell.width - Self.advance * size)
            let resolved = ctx.resolve(Text(t.string).font(.system(size: size, design: .monospaced)).tracking(tracking)
                .foregroundColor(Self.color(t.style)))
            ctx.draw(resolved, at: CGPoint(x: x0, y: y), anchor: .leading)
        }
    }
}
