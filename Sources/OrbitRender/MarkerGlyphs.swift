import CoreGraphics
import OrbitCore

/// The navball's marker symbols, KSP-like in shape and colour but drawn here
/// with CoreGraphics (no KSP art: it is proprietary). The navball draws them
/// into its atlas; the scene renderer can reuse them for markers in the 3-D
/// view.
public enum MarkerGlyph: Int, CaseIterable {
    case prograde, retrograde, normal, antinormal, radialOut, radialIn
    case command, thrust, target, antitarget, maneuver
    /// The nose: an orange "W", fixed at the ball's centre.
    case waterline
    /// A white arrowhead pointing right, tinted and turned for a marker
    /// behind the ball.
    case pointer

    public init(_ kind: NavballMarker.Kind) {
        switch kind {
        case .prograde: self = .prograde
        case .retrograde: self = .retrograde
        case .normal: self = .normal
        case .antinormal: self = .antinormal
        case .radialOut: self = .radialOut
        case .radialIn: self = .radialIn
        case .command: self = .command
        case .thrust: self = .thrust
        case .target: self = .target
        case .antitarget: self = .antitarget
        case .maneuver: self = .maneuver
        }
    }

    /// sRGB colour components (r, g, b).
    public var color: (r: CGFloat, g: CGFloat, b: CGFloat) {
        switch self {
        case .prograde, .retrograde: (1.00, 0.84, 0.10)
        case .normal, .antinormal: (0.86, 0.32, 0.96)
        case .radialOut, .radialIn: (0.25, 0.86, 1.00)
        case .command: (0.25, 1.00, 0.40)
        case .thrust: (1.00, 0.50, 0.12)
        case .target, .antitarget: (1.00, 0.42, 0.72)
        case .maneuver: (0.30, 0.55, 1.00)
        case .waterline: (1.00, 0.62, 0.10)
        case .pointer: (1, 1, 1)
        }
    }

    public var cgColor: CGColor { CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1) }

    /// Draw the glyph centred in `rect` (y up), sized to it.
    public func draw(in ctx: CGContext, rect: CGRect) {
        let s = min(rect.width, rect.height)
        let c = CGPoint(x: rect.midX, y: rect.midY)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: c.x + x * s, y: c.y + y * s) }
        let path = CGMutablePath()
        var dots: [CGPoint] = []
        func circle(_ r: CGFloat) { path.addEllipse(in: CGRect(x: c.x - r * s, y: c.y - r * s, width: 2 * r * s, height: 2 * r * s)) }
        func line(_ a: CGPoint, _ b: CGPoint) { path.move(to: a); path.addLine(to: b) }
        func spoke(_ angle: CGFloat, _ r0: CGFloat, _ r1: CGFloat) {
            line(p(cos(angle) * r0, sin(angle) * r0), p(cos(angle) * r1, sin(angle) * r1))
        }
        let d = CGFloat.pi / 180
        switch self {
        case .prograde:
            circle(0.24)
            for a in [90.0, 180, 0] { spoke(a * d, 0.24, 0.42) }
            dots.append(c)
        case .retrograde:
            circle(0.24)
            for a in [45.0, 135] { spoke(a * d, -0.17, 0.17) }
            for a in [270.0, 210, 330] { spoke(a * d, 0.24, 0.42) }
        case .normal:
            path.addLines(between: [p(0, 0.30), p(-0.27, -0.17), p(0.27, -0.17), p(0, 0.30)])
            dots.append(p(0, -0.01))
        case .antinormal:
            path.addLines(between: [p(0, -0.30), p(-0.27, 0.17), p(0.27, 0.17), p(0, -0.30)])
            line(p(0, -0.30), p(0, -0.44))
            line(p(-0.27, 0.17), p(-0.39, 0.24))
            line(p(0.27, 0.17), p(0.39, 0.24))
        case .radialOut:
            circle(0.22)
            for a in [45.0, 135, 225, 315] { spoke(a * d, 0.22, 0.42) }
            dots.append(c)
        case .radialIn:
            circle(0.30)
            for a in [45.0, 135, 225, 315] { spoke(a * d, 0.08, 0.30) }
        case .command:
            path.addLines(between: [p(0, 0.34), p(0.34, 0), p(0, -0.34), p(-0.34, 0), p(0, 0.34)])
            dots.append(c)
        case .thrust:
            circle(0.20)
            for a in [0.0, 90, 180, 270] { spoke(a * d, 0.08, 0.38) }
        case .target:
            circle(0.26)
            for a in [0.0, 90, 180, 270] { spoke(a * d, 0.26, 0.42) }
            dots.append(c)
        case .antitarget:
            circle(0.26)
            for a in [45.0, 135, 225, 315] { spoke(a * d, 0.10, 0.42) }
        case .maneuver:
            circle(0.22)
            for a in [90.0, 210, 330] { spoke(a * d, 0.22, 0.42) }
            dots.append(c)
        case .waterline:
            path.addLines(between: [p(-0.48, 0), p(-0.20, 0), p(-0.10, -0.13), p(0, 0), p(0.10, -0.13),
                                    p(0.20, 0), p(0.48, 0)])
        case .pointer:
            path.addLines(between: [p(0.30, 0), p(-0.20, 0.26), p(-0.08, 0), p(-0.20, -0.26), p(0.30, 0)])
        }

        let width = s * (self == .waterline ? 0.075 : 0.065)
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        // A dark outline keeps the symbol readable on sky, ground and the white horizon.
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.75))
        ctx.setLineWidth(width * 2.2)
        ctx.strokePath()
        for dot in dots {
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.75))
            ctx.fillEllipse(in: CGRect(x: dot.x - 0.085 * s, y: dot.y - 0.085 * s, width: 0.17 * s, height: 0.17 * s))
        }
        if self == .pointer {
            ctx.addPath(path)
            ctx.setFillColor(cgColor)
            ctx.fillPath()
        }
        ctx.addPath(path)
        ctx.setStrokeColor(cgColor)
        ctx.setLineWidth(width)
        ctx.strokePath()
        for dot in dots {
            ctx.setFillColor(cgColor)
            ctx.fillEllipse(in: CGRect(x: dot.x - 0.05 * s, y: dot.y - 0.05 * s, width: 0.1 * s, height: 0.1 * s))
        }
        ctx.restoreGState()
    }
}
