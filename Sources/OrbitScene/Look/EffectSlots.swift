import Foundation

/// The effect slots' maths (track R6), shared by every effect that draws
/// through them (C2's clouds, P2's plumes, P3's smoke):
/// - the half-resolution scene depth they test against;
/// - the front depth each layer reports;
/// - the weighted-blended OIT weight and its resolve;
/// - the depth-aware upsample;
/// - the order the layers are composited in, pixel by pixel.
///
/// The shader header EffectSlotsCommon and the R6 modules mirror these
/// functions line for line, and OrbitRenderTests checks the GPU's results
/// against them. Depths are reversed-Z (`near / z`: larger is nearer, 0
/// is the sky) unless a name says linear (metres along the view axis).
public enum EffectSlots {
    // MARK: Targets

    /// The effect targets' size for a frame of `width` × `height` at
    /// `scale` (2 at half resolution, 1 at full), rounded up, so that every
    /// full-resolution pixel has a texel.
    public static func targetSize(width: Int, height: Int, scale: Int) -> (width: Int, height: Int) {
        let s = max(scale, 1)
        return ((max(width, 1) + s - 1) / s, (max(height, 1) + s - 1) / s)
    }

    // MARK: Half-resolution depth

    /// A half-resolution texel's scene depth from the full-resolution
    /// pixels it covers (its 2×2 quad, fewer at the image's edge).
    /// - `test` is the depth effects test against and clamp their marches
    ///   at: the quad's nearest on the checkerboard's even texels
    ///   ((x + y) even), its farthest on odd ones. Every 2×2 neighbourhood
    ///   of texels therefore holds both, and the upsample finds a texel
    ///   that matches on either side of an edge.
    /// - `other` is the quad's other extreme.
    public static func halfResDepth(_ quad: [Double], x: Int, y: Int) -> (test: Double, other: Double) {
        guard let nearest = quad.max(), let farthest = quad.min() else { return (0, 0) }
        return (x + y) % 2 == 0 ? (nearest, farthest) : (farthest, nearest)
    }

    // MARK: Upsample

    /// Reversed-Z depths below this are the sky: log2 is taken of this instead.
    public static let skyDepth = 1e-30

    /// The depth-aware upsample's weights for a full-resolution pixel over
    /// its four nearest half-resolution texels (Bavoil's nearest-depth
    /// upsampling, NVIDIA 2008):
    /// - the bilinear weights where every texel's test depth is within
    ///   `tolerance` of the pixel's (relative, in linear depth);
    /// - otherwise all the weight on the texel nearest in depth, ties going
    ///   to the larger bilinear weight, then to the lower index.
    ///
    /// `bilinear` sums to 1 (texels in the order (0,0), (1,0), (0,1), (1,1));
    /// `depths` are the texels' test depths and `depth` the pixel's.
    public static func upsampleWeights(bilinear: [Double], depths: [Double], depth: Double,
                                       tolerance: Double) -> [Double] {
        // In log2 of the depth, a relative distance: z = near / d, so
        // |log2 z_i - log2 z| = |log2 d_i - log2 d|, whatever the near plane.
        let here = log2(max(depth, skyDepth))
        let apart = depths.map { abs(log2(max($0, skyDepth)) - here) }
        if apart.allSatisfy({ $0 <= log2(1 + tolerance) }) { return bilinear }
        var best = 0
        for i in 1..<apart.count where apart[i] < apart[best] || apart[i] == apart[best] && bilinear[i] > bilinear[best] {
            best = i
        }
        return apart.indices.map { $0 == best ? 1 : 0 }
    }

    /// The four texels around a full-resolution pixel's centre and their
    /// bilinear weights, at `scale` (texel centres at (i + 0.5) · scale).
    /// Texels outside the target are clamped to its edge.
    public static func upsampleFootprint(pixelX: Int, pixelY: Int, scale: Int, width: Int, height: Int)
        -> (texels: [(x: Int, y: Int)], bilinear: [Double]) {
        let s = Double(max(scale, 1))
        let u = (Double(pixelX) + 0.5) / s - 0.5, v = (Double(pixelY) + 0.5) / s - 0.5
        let x0 = Int(u.rounded(.down)), y0 = Int(v.rounded(.down))
        let fx = u - Double(x0), fy = v - Double(y0)
        func clamp(_ x: Int, _ n: Int) -> Int { min(max(x, 0), n - 1) }
        let texels = [(x0, y0), (x0 + 1, y0), (x0, y0 + 1), (x0 + 1, y0 + 1)].map { (clamp($0.0, width), clamp($0.1, height)) }
        let bilinear = [(1 - fx) * (1 - fy), fx * (1 - fy), (1 - fx) * fy, fx * fy]
        return (texels, bilinear)
    }

    // MARK: Front depth

    /// Where an item reports its front: the nearest depth at which its own
    /// contribution, accumulated front to back, becomes visible. That is
    /// where its coverage 1 − T reaches `frontOpacity`, or its premultiplied,
    /// pre-exposed radiance (the largest channel) reaches `frontRadiance`,
    /// whichever comes first. So a bright, optically thin glow reports a
    /// front as surely as a dense deck does. An OIT fragment counts on its
    /// own: fragments are summed in any order, so none can see the others.
    public static let frontOpacity = 0.02
    /// About one 8-bit step of a display-relative (pre-exposed) image.
    public static let frontRadiance = 1.0 / 256

    /// Whether an item's accumulated coverage and radiance (largest channel)
    /// have become visible: its front is here.
    public static func frontReached(coverage: Double, radiance: Double) -> Bool {
        coverage >= frontOpacity || radiance >= frontRadiance
    }

    /// A front depth as stored: log2 of the linear depth in metres, in one
    /// rgba16Float channel per layer, blended with min. 1.1 % relative at
    /// 1e9 m, 0.3 % at 30 m.
    public static func frontCode(linearDepth z: Double) -> Double {
        min(log2(max(z, 1.0 / 16_384)), noFront)
    }

    /// Where a layer has no front: the channel's clear value, half's largest.
    public static let noFront = 65_504.0

    /// The linear depth (m) a front code stands for; infinity for none.
    public static func linearDepth(frontCode c: Double) -> Double {
        c >= noFront ? .infinity : exp2(c)
    }

    /// The front of a homogeneous medium entered at `entry` (any unit along
    /// the ray) with `extinction` per that unit, whose premultiplied radiance
    /// is `source` × (1 − T) (its source radiance, largest channel,
    /// pre-exposed): where `frontReached` first holds; nil when it does not
    /// before `exit`.
    public static func homogeneousFront(entry: Double, exit: Double, extinction: Double,
                                        source: Double = 0) -> Double? {
        guard extinction > 0 else { return nil }
        let coverage = source > 0 ? min(frontOpacity, frontRadiance / source) : frontOpacity
        let t = entry - log(1 - coverage) / extinction
        return t <= exit ? t : nil
    }

    // MARK: Premultiplied colour

    /// Premultiplied linear colour: radiance times coverage in rgb, coverage
    /// (1 − transmittance) in a.
    public struct Premultiplied: Equatable {
        public var r: Double, g: Double, b: Double, a: Double

        public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double) {
            self.r = r
            self.g = g
            self.b = b
            self.a = a
        }

        public static let clear = Premultiplied(0, 0, 0, 0)

        /// This in front of `below` (Porter and Duff's over).
        public func over(_ below: Premultiplied) -> Premultiplied {
            Premultiplied(r + (1 - a) * below.r, g + (1 - a) * below.g, b + (1 - a) * below.b, a + (1 - a) * below.a)
        }

        /// Weighted sum.
        public static func * (w: Double, c: Premultiplied) -> Premultiplied {
            Premultiplied(w * c.r, w * c.g, w * c.b, w * c.a)
        }

        public static func + (x: Premultiplied, y: Premultiplied) -> Premultiplied {
            Premultiplied(x.r + y.r, x.g + y.g, x.b + y.b, x.a + y.a)
        }
    }

    // MARK: Weighted-blended OIT

    /// The OIT weight's bounds and slope: nearer fragments win over a factor
    /// of 16 in depth around the reference, and the rgba16Float sums stay
    /// finite.
    public static let oitWeightRange = (min: 1.0 / 64, max: 64.0)
    public static let oitWeightExponent = 3.0
    /// The most a fragment adds to each colour channel of the accumulation,
    /// so a few bright, near fragments together stay below half's 65504.
    public static let oitMaxAccumulation = 16_384.0

    /// McGuire and Bavoil's weight (JCGT 2(2), 2013, after their eq. 9), on
    /// depth relative to `reference`, the distance the frame is about (the
    /// camera's target): the fragment's opacity times (z / reference)^−3,
    /// with the depth factor held within `oitWeightRange`.
    public static func oitWeight(alpha: Double, linearDepth z: Double, reference: Double) -> Double {
        let f = pow(max(z, 1e-6) / max(reference, 1e-6), -oitWeightExponent)
        return alpha * min(max(f, oitWeightRange.min), oitWeightRange.max)
    }

    /// What a fragment of premultiplied `color` adds to the accumulation
    /// target, as in the paper: rgb is the colour times the weight (held
    /// below `oitMaxAccumulation`), a the opacity times the weight. The
    /// revealage target is multiplied by 1 − a.
    public static func oitAccumulation(_ color: Premultiplied, linearDepth z: Double, reference: Double) -> Premultiplied {
        let w = oitWeight(alpha: color.a, linearDepth: z, reference: reference)
        func held(_ x: Double) -> Double { min(x * w, oitMaxAccumulation) }
        return Premultiplied(held(color.r), held(color.g), held(color.b), color.a * w)
    }

    /// The OIT pair resolved to premultiplied colour: the weighted mean
    /// colour times the coverage 1 − revealage, where revealage is
    /// Π(1 − a_i).
    public static func oitResolve(accumulation: Premultiplied, revealage: Double) -> Premultiplied {
        let coverage = 1 - min(max(revealage, 0), 1)
        let k = coverage / min(max(accumulation.a, 1e-5), 5e4)
        return Premultiplied(accumulation.r * k, accumulation.g * k, accumulation.b * k, coverage)
    }

    /// The accumulation and revealage of `fragments` (premultiplied colours
    /// at linear depths), in any order.
    public static func oitAccumulate(_ fragments: [(color: Premultiplied, linearDepth: Double)], reference: Double)
        -> (accumulation: Premultiplied, revealage: Double) {
        var acc = Premultiplied.clear, revealage = 1.0
        for f in fragments {
            acc = acc + oitAccumulation(f.color, linearDepth: f.linearDepth, reference: reference)
            revealage *= 1 - f.color.a
        }
        return (acc, revealage)
    }

    // MARK: Layers

    /// The composite's layers, in their tie order: clouds (C2), volumes
    /// (P2's plumes), OIT (P3's smoke).
    public enum Layer: Int, CaseIterable {
        case clouds, volumes, oit
    }

    /// One layer at one pixel: its premultiplied colour and its front's
    /// linear depth (infinity where it has none).
    public struct LayerSample: Equatable {
        public var color: Premultiplied
        public var front: Double

        public init(_ color: Premultiplied, front: Double) {
            self.color = color
            self.front = front
        }
    }

    /// The order a pixel's layers are composited in, farthest front first.
    /// Equal fronts keep the tie order, the later layer over the earlier
    /// (smoke over plumes over clouds).
    public static func compositeOrder(_ fronts: [Double]) -> [Int] {
        fronts.indices.sorted { fronts[$0] > fronts[$1] || fronts[$0] == fronts[$1] && $0 < $1 }
    }

    /// A pixel's layers as one premultiplied colour to blend over the scene:
    /// each over the ones behind it, in `compositeOrder`.
    public static func composite(_ layers: [LayerSample]) -> Premultiplied {
        compositeOrder(layers.map(\.front)).reduce(.clear) { below, i in layers[i].color.over(below) }
    }

    /// One texel of the targets, as the composite reads it.
    public struct Texel {
        public var clouds: Premultiplied
        public var volumes: Premultiplied
        public var accumulation: Premultiplied
        public var revealage: Double
        /// Front codes: clouds, volumes, OIT.
        public var fronts: [Double]

        public init(clouds: Premultiplied, volumes: Premultiplied, accumulation: Premultiplied, revealage: Double,
                    fronts: [Double]) {
            self.clouds = clouds
            self.volumes = volumes
            self.accumulation = accumulation
            self.revealage = revealage
            self.fronts = fronts
        }
    }

    /// The composite at one pixel, step by step as the GPU does it:
    /// - the drawn layers' texels mixed with the upsample weights;
    /// - each front the least code among the texels that weigh;
    /// - the OIT pair resolved after mixing;
    /// - the layers composited in front order.
    public static func compositePixel(_ texels: [Texel], weights: [Double], drawn: Set<Layer>) -> Premultiplied {
        var colors = [Premultiplied](repeating: .clear, count: 3)
        var fronts = [Double](repeating: noFront, count: 3)
        var accumulation = Premultiplied.clear, revealage = 0.0
        for (t, w) in zip(texels, weights) where w > 0 {
            if drawn.contains(.clouds) {
                colors[0] = colors[0] + w * t.clouds
                fronts[0] = min(fronts[0], t.fronts[0])
            }
            if drawn.contains(.volumes) {
                colors[1] = colors[1] + w * t.volumes
                fronts[1] = min(fronts[1], t.fronts[1])
            }
            if drawn.contains(.oit) {
                accumulation = accumulation + w * t.accumulation
                revealage += w * t.revealage
                fronts[2] = min(fronts[2], t.fronts[2])
            }
        }
        if drawn.contains(.oit) { colors[2] = oitResolve(accumulation: accumulation, revealage: revealage) }
        return composite((0..<3).map { LayerSample(colors[$0], front: linearDepth(frontCode: fronts[$0])) })
    }
}
