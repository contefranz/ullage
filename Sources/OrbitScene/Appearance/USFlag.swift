import Foundation

/// The 50-star flag of 4 July 1960, the one Apollo flew, from Executive
/// Order 10834 (21 August 1959), §2 and its chart of proportions, every
/// length a fraction of the hoist:
///
/// - hoist A 1.0, fly B 1.9;
/// - union: hoist C 0.5385 (7/13), fly D 0.76;
/// - stars: E = F = 0.054 vertically and G = H = 0.063 horizontally (the
///   first row and column from the union's top and hoist edges, then the
///   spacing between rows and between columns), diameter K 0.0616;
/// - stripes L 0.0769 (1/13), thirteen, red at the top and the foot.
///
/// The fifty stars stand in nine rows, alternately six and five, the six
/// rows on columns 1, 3, ... 11 and the five rows on columns 2, 4, ... 10.
/// Coordinates here are in hoists: x along the fly from the hoist edge,
/// y down from the top edge. A US government work; no copyright.
public enum USFlag {
    public static let hoist = 1.0
    public static let fly = 1.9
    public static let unionHoist = 0.5385
    public static let unionFly = 0.76
    public static let starRowSpacing = 0.054     // E and F
    public static let starColumnSpacing = 0.063  // G and H
    public static let starDiameter = 0.0616      // K
    public static let stripe = 0.0769            // L

    public static let stripeCount = 13
    public static let starRows = 9

    /// The stars' centres, row by row from the top: (x, y) in hoists.
    public static let starCentres: [(x: Double, y: Double)] = {
        var centres: [(x: Double, y: Double)] = []
        for row in 0..<starRows {
            let y = starRowSpacing * Double(row + 1)
            let firstColumn = row % 2 == 0 ? 1 : 2
            for column in stride(from: firstColumn, through: 11, by: 2) {
                centres.append((starColumnSpacing * Double(column), y))
            }
        }
        return centres
    }()

    /// The colour at (x, y) (hoists, from the upper hoist corner; nil off
    /// the flag).
    public static func colour(x: Double, y: Double) -> PaintColour? {
        guard x >= 0, x <= fly, y >= 0, y <= hoist else { return nil }
        if x <= unionFly && y <= unionHoist { return starDistance(x: x, y: y) <= 0 ? .flagWhite : .flagBlue }
        let index = min(Int(y * Double(stripeCount) / hoist), stripeCount - 1)
        return index % 2 == 0 ? .flagRed : .flagWhite
    }

    /// The stripe of row y: 0 at the top, 12 at the foot; red when even.
    public static func stripeIndex(y: Double) -> Int { min(max(Int(y * Double(stripeCount)), 0), stripeCount - 1) }

    /// Signed distance (hoists) from (x, y) to the nearest star's edge,
    /// negative inside a star.
    public static func starDistance(x: Double, y: Double) -> Double {
        // Only the nearest few centres can be nearest: rows and columns are
        // at least one spacing apart.
        let row = Int((y / starRowSpacing).rounded()) - 1, column = Int((x / starColumnSpacing).rounded())
        var d = Double.infinity
        for r in max(row - 1, 0)...min(max(row + 1, 0), starRows - 1) {
            let first = r % 2 == 0 ? 1 : 2
            for c in max(column - 2, first)...min(max(column + 2, first), 11) where (c - first) % 2 == 0 {
                let cx = starColumnSpacing * Double(c), cy = starRowSpacing * Double(r + 1)
                d = min(d, star(x: x - cx, y: y - cy, radius: starDiameter / 2))
            }
        }
        return d
    }

    /// Signed distance to a five-pointed star of circumradius `radius`, one
    /// point up (towards -y, the top), centred at the origin: the regular
    /// pentagram's outline, inner radius radius × sin 18° / sin 126°.
    public static func star(x: Double, y: Double, radius: Double) -> Double {
        let inner = radius * sin(18 * Double.pi / 180) / sin(126 * Double.pi / 180)
        var vertices: [(x: Double, y: Double)] = []
        for k in 0..<10 {
            let a = Double(k) * Double.pi / 5
            let r = k % 2 == 0 ? radius : inner
            vertices.append((r * sin(a), -r * cos(a)))
        }
        return polygonDistance(x: x, y: y, vertices)
    }

    /// Signed distance to a simple polygon, negative inside.
    static func polygonDistance(x: Double, y: Double, _ v: [(x: Double, y: Double)]) -> Double {
        var d2 = Double.infinity
        var inside = false
        var j = v.count - 1
        for i in 0..<v.count {
            let ex = v[j].x - v[i].x, ey = v[j].y - v[i].y
            let wx = x - v[i].x, wy = y - v[i].y
            let t = max(0, min(1, (wx * ex + wy * ey) / (ex * ex + ey * ey)))
            let bx = wx - ex * t, by = wy - ey * t
            d2 = min(d2, bx * bx + by * by)
            if (v[i].y > y) != (v[j].y > y) && x < ex * (y - v[i].y) / ey + v[i].x { inside.toggle() }
            j = i
        }
        return inside ? -d2.squareRoot() : d2.squareRoot()
    }
}
