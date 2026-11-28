import Foundation
import Metal
import XCTest
import OrbitCore
import OrbitScene
@testable import OrbitRender

/// LR5's trail as drawn (TrailPass), measured on its renders.
@MainActor
final class TrailLookTests: XCTestCase {
    /// The frame's light as luminance, rows top first.
    struct Light {
        let width: Int, height: Int
        let luminance: [Double]

        init(_ out: SnapshotRenderer.Output) throws {
            let light = try XCTUnwrap(out.light, "no HDR light")
            width = out.shot.width
            height = out.shot.height
            luminance = (0..<(width * height)).map { i in
                0.2126 * Double(light[4 * i]) + 0.7152 * Double(light[4 * i + 1]) + 0.0722 * Double(light[4 * i + 2])
            }
        }

        func at(_ x: Double, _ y: Double) -> Double {
            let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down)), fx = x - Double(x0), fy = y - Double(y0)
            guard x0 >= 0, y0 >= 0, x0 + 1 < width, y0 + 1 < height else { return 0 }
            func p(_ i: Int, _ j: Int) -> Double { luminance[j * width + i] }
            return p(x0, y0) * (1 - fx) * (1 - fy) + p(x0 + 1, y0) * fx * (1 - fy) + p(x0, y0 + 1) * (1 - fx) * fy
                + p(x0 + 1, y0 + 1) * fx * fy
        }
    }

    /// The line's width at half its height across it, every `step` px from
    /// the brightest pixel along the line's principal axis (of the pixels
    /// over `floor` times the frame's median), while its centre is over
    /// `floor` times the median: (distance from the tip, width, centre's
    /// luminance), the stations 20 px within the frame.
    static func widths(_ l: Light, step: Double = 4, floor: Double = 5) -> [(s: Double, width: Double, centre: Double)] {
        let sorted = l.luminance.sorted(), median = max(sorted[sorted.count / 2], 1e-9)
        var tip = (x: 0.0, y: 0.0), best = -1.0
        var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0, n = 0.0
        for y in 0..<l.height {
            for x in 0..<l.width {
                let v = l.luminance[y * l.width + x]
                if v > best { (best, tip) = (v, (Double(x), Double(y))) }
                guard v > floor * median else { continue }
                sx += Double(x)
                sy += Double(y)
                sxx += Double(x * x)
                syy += Double(y * y)
                sxy += Double(x * y)
                n += 1
            }
        }
        let mx = sx / n, my = sy / n
        let cxx = sxx / n - mx * mx, cyy = syy / n - my * my, cxy = sxy / n - mx * my
        let angle = 0.5 * atan2(2 * cxy, cxx - cyy)
        var d = (x: cos(angle), y: sin(angle))
        // Pointing from the tip into the line.
        if (mx - tip.x) * d.x + (my - tip.y) * d.y < 0 { d = (-d.x, -d.y) }
        let across = (x: -d.y, y: d.x)
        var out: [(Double, Double, Double)] = []
        var s = step
        while true {
            let c = (x: tip.x + d.x * s, y: tip.y + d.y * s)
            // Within the frame, its edges 20 px off.
            guard c.x > 20, c.y > 20, c.x < Double(l.width) - 20, c.y < Double(l.height) - 20 else { break }
            var profile: [(t: Double, v: Double)] = []
            for k in -160...160 {
                let t = Double(k) * 0.5
                profile.append((t, l.at(c.x + across.x * t, c.y + across.y * t) - median))
            }
            guard let peak = profile.max(by: { $0.v < $1.v }), peak.v > floor * median else { break }
            let half = profile.filter { $0.v >= 0.5 * peak.v }
            out.append((s, (half.last!.t - half.first!.t) + 0.5, peak.v))
            s += step
        }
        return out
    }

    /// `p4-trail-chase` (T+75 s from 2.5 km, the trail seen from behind
    /// and beside): past the flame's brightest stretch, where the plume's
    /// far field hands its exhaust over to the trail, the line nowhere
    /// narrows below 0.85 of its widest before (the puffs it replaces
    /// narrowed to 0.43 of the plume), and grows on as the trail spreads.
    func testTrailChaseKeepsThePlumesWidth() throws {
        let device = try XCTUnwrap(RenderDevice.shared, "no Metal device")
        let spec = try SnapshotSpec.load(GoldenImageTests.shots.appendingPathComponent("p4.json"))
        var shot = try XCTUnwrap(spec.shots.first { $0.name == "p4-trail-chase" })
        shot.aovs = []
        let out = try SnapshotRenderer(device: device).render(shot)
        let w = Self.widths(try Light(out))
        XCTAssertGreaterThan(w.count, 30, "the line followed")
        let tip = w.map(\.centre).max() ?? 0
        // Past the flame: the centre under 1 % of the brightest station.
        let start = try XCTUnwrap(w.firstIndex { $0.centre < 0.01 * tip })
        var widest = 0.0, lowest = Double.infinity
        for x in w[start...] {
            if widest > 0 { lowest = min(lowest, x.width / widest) }
            widest = max(widest, x.width)
        }
        print(String(format: "TrailLookTests: p4-trail-chase: %d stations, the flame's to %.0f px, widths %@; the narrowest after the widest before %.3f",
                     w.count, w[start].s, w.map { String(format: "%.1f", $0.width) }.joined(separator: " "), lowest))
        XCTAssertGreaterThanOrEqual(lowest, 0.85)
        XCTAssertGreaterThan(w.last!.width, w[start].width, "it spreads")
    }

    /// A shot of `p4.json`, rendered.
    func render(_ name: String) throws -> Light {
        let device = try XCTUnwrap(RenderDevice.shared, "no Metal device")
        let spec = try SnapshotSpec.load(GoldenImageTests.shots.appendingPathComponent("p4.json"))
        var shot = try XCTUnwrap(spec.shots.first { $0.name == name })
        shot.aovs = []
        return try Light(try SnapshotRenderer(device: device).render(shot))
    }

    /// `p4-trail-tube`: a stretch of trail, a straight line of nodes 25 m
    /// apart (σ 15 m along, 21 m across, depth 1.35), side-on from 900 m.
    /// Along its axis, over the middle 60 % of the frame, its light less
    /// its smooth trend (a quadratic: the Sun's phase changes across the
    /// frame) stays within 2 % of its mean: no beads.
    func testTrailTubeHasNoBeads() throws {
        let l = try render("p4-trail-tube")
        // The axis: the brightest row at the frame's middle column.
        let mid = l.width / 2
        let row = (0..<l.height).max { l.luminance[$0 * l.width + mid] < l.luminance[$1 * l.width + mid] }!
        let xs = Array(Int(0.2 * Double(l.width))..<Int(0.8 * Double(l.width)))
        let v = xs.map { x in (-1...1).reduce(0.0) { $0 + l.luminance[(row + $1) * l.width + x] } / 3 }
        // Least squares quadratic in u = x scaled to [-1, 1].
        let u = xs.map { 2 * Double($0 - xs[0]) / Double(xs.count - 1) - 1 }
        var a = [[Double]](repeating: [0, 0, 0], count: 3), b = [0.0, 0, 0]
        for (x, y) in zip(u, v) {
            let p = [1, x, x * x]
            for r in 0..<3 {
                b[r] += p[r] * y
                for c in 0..<3 { a[r][c] += p[r] * p[c] }
            }
        }
        // Gaussian elimination.
        for k in 0..<3 {
            for r in (k + 1)..<3 {
                let f = a[r][k] / a[k][k]
                for c in k..<3 { a[r][c] -= f * a[k][c] }
                b[r] -= f * b[k]
            }
        }
        var q = [0.0, 0, 0]
        for k in stride(from: 2, through: 0, by: -1) {
            q[k] = (b[k] - ((k + 1)..<3).reduce(0.0) { $0 + a[k][$1] * q[$1] }) / a[k][k]
        }
        let mean = v.reduce(0, +) / Double(v.count)
        let ripple = zip(u, v).map { abs($1 - (q[0] + q[1] * $0 + q[2] * $0 * $0)) }.max()! / mean
        let trend = (v.max()! - v.min()!) / mean
        print(String(format: "TrailLookTests: p4-trail-tube: its axis at row %d; ripple %.4f of its mean (the trend %.3f)",
                     row, ripple, trend))
        XCTAssertGreaterThan(mean, 10 * (l.luminance.sorted()[l.luminance.count / 2] + 1e-9), "the tube is seen")
        XCTAssertLessThan(ripple, 0.02)
    }

    /// `p4-trail-joint-studio`: P2's F-1 cluster at 6 km in a 265 m/s
    /// stream (T+60 s or so) and the trail it hands its exhaust over to,
    /// laid as the launch lays it (`TrailStudio`), side-on from 700 m. Past
    /// the flame, from one station to the next (4 px) the line's width,
    /// averaged over three stations (P2's eddies shake its edge a station
    /// at a time), changes by under 10 % through the joint and on.
    func testTrailJointHasNoWidthJump() throws {
        let w = Self.widths(try render("p4-trail-joint-studio"))
        XCTAssertGreaterThan(w.count, 40, "the line followed")
        let tip = w.map(\.centre).max() ?? 0
        let start = try XCTUnwrap(w.firstIndex { $0.centre < 0.3 * tip })
        let smooth = (start + 1..<(w.count - 1)).map { i in (s: w[i].s, width: (w[i - 1].width + w[i].width + w[i + 1].width) / 3) }
        var jump = 0.0, at = 0.0
        for (a, b) in zip(smooth, smooth.dropFirst()) where abs(b.width / a.width - 1) > jump {
            (jump, at) = (abs(b.width / a.width - 1), b.s)
        }
        print(String(format: "TrailLookTests: p4-trail-joint-studio: %d stations, from %.0f px, widths %@; the largest step %.3f at %.0f px",
                     w.count, w[start].s, w.map { String(format: "%.1f", $0.width) }.joined(separator: " "), jump, at))
        XCTAssertLessThan(jump, 0.1)
    }

}
