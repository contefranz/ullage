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

    /// The upsample's weights for a full-resolution pixel over its four
    /// nearest half-resolution texels: Kopf et al.'s joint bilateral
    /// upsampling (SIGGRAPH 2007) with a binary range kernel. A texel
    /// matches the pixel when
    /// - its test depth is within `tolerance` of the pixel's (relative, in
    ///   linear depth), or
    /// - every effect drawn at it ended nearer than both scene depths, the
    ///   texel's and the pixel's (`ended`, from the writers' back and clip
    ///   codes: `texelEnded`), so neither depth cut it.
    ///
    /// Where all four match the weights are the bilinear ones, exactly;
    /// otherwise the bilinear weights renormalised over the matching texels;
    /// where none matches, all the weight on the texel nearest in depth,
    /// ties going to the larger bilinear weight, then to the lower index.
    ///
    /// `bilinear` sums to 1 (texels in the order (0,0), (1,0), (0,1), (1,1));
    /// `depths` are the texels' test depths and `depth` the pixel's.
    public static func upsampleWeights(bilinear: [Double], depths: [Double], depth: Double, tolerance: Double,
                                       ended: [Bool] = [false, false, false, false]) -> [Double] {
        reconstruction(bilinear: bilinear, depths: depths, depth: depth, tolerance: tolerance, ended: ended).weights
    }

    /// How a pixel was reconstructed (`upsampleWeights`).
    public enum Reconstruction: Int {
        /// All four texels match: plain bilinear.
        case bilinear
        /// Some match: bilinear renormalised over them.
        case renormalised
        /// None does: the texel nearest in depth.
        case nearest
    }

    /// `upsampleWeights` and which of its three cases it took.
    public static func reconstruction(bilinear: [Double], depths: [Double], depth: Double, tolerance: Double,
                                      ended: [Bool]) -> (weights: [Double], kind: Reconstruction) {
        // In log2 of the depth, a relative distance: z = near / d, so
        // |log2 z_i - log2 z| = |log2 d_i - log2 d|, whatever the near plane.
        let here = log2(max(depth, skyDepth))
        let apart = depths.map { abs(log2(max($0, skyDepth)) - here) }
        let matches = apart.indices.map { apart[$0] <= log2(1 + tolerance) || ended[$0] }
        if matches.allSatisfy({ $0 }) { return (bilinear, .bilinear) }
        let total = zip(bilinear, matches).reduce(0.0) { $0 + ($1.1 ? $1.0 : 0) }
        if total > 0 {
            return (zip(bilinear, matches).map { $0.1 ? $0.0 / total : 0 }, .renormalised)
        }
        var best = 0
        for i in 1..<apart.count where apart[i] < apart[best] || apart[i] == apart[best] && bilinear[i] > bilinear[best] {
            best = i
        }
        return (apart.indices.map { $0 == best ? 1 : 0 }, .nearest)
    }

    // MARK: What the writers say about where their effects ended

    /// A texel's effects can be used at a neighbouring pixel whose scene
    /// depth differs from the texel's when neither scene depth cut them:
    /// they ended nearer than both. The writers say where, for the
    /// composite to check pixel by pixel (`texelEnded`):
    /// - a volume (plumes) writes a back code into the fronts' a channel,
    ///   blended with max (`backCode`);
    /// - the clouds and the OIT fragments write a clip code each into the
    ///   clip attachment (rg8Unorm: r clouds, g OIT), blended with min
    ///   (`clipCode`).
    /// A layer is reconstructed so only on frames when every effect that
    /// draws it writes its codes (`HalfResEffect.reconstructedLayers`);
    /// otherwise it matches by depth alone.

    /// The fronts' a channel where no volume drew: nothing to cut.
    public static let noBack = -noFront

    /// Added to a back's log2 (1/32, 2.2 %), so that half's rounding (0.5
    /// steps of 1/64 between 2^16 and 2^32 m) never brings it nearer.
    public static let backMargin = 1.0 / 32

    /// A volume's back code: log2 of the linear depth (m) where its last
    /// visible step ended, plus `backMargin`; `noFront` where the scene cut
    /// it (its proxy went on behind the texel's scene, or lay wholly behind
    /// it). Blended with max: one cut proxy makes the texel cut.
    public static func backCode(lastVisible z: Double?, cut: Bool) -> Double {
        if cut { return noFront }
        guard let z else { return noBack }
        return min(log2(max(z, 1.0 / 16_384)) + backMargin, noFront - 1)
    }

    /// The clip codes' steps: 16 to an octave of depth (4.4 %) for the
    /// first 12 octaves in front of the texel's scene (codes 1...192), where
    /// precision matters; 2 octaves a step beyond (193...254), so that a
    /// texel on the sky (taken at `skyDistance`) can still say its effect
    /// ends a few metres out.
    public static let clipStepsPerOctave = 16.0
    public static let clipFineOctaves = 12.0
    public static let clipCoarseStep = 2.0
    /// The clip code where nothing drew (the attachment's clear): ended
    /// everywhere. Writers write at most `clipEmpty - 1`.
    public static let clipEmpty = 255

    /// A clouds or OIT clip code (one byte): 0 where the effect was cut at
    /// this texel's scene (or hidden behind it); else the octaves that
    /// `endsAt`, the linear depth from which no scene cuts the effect, lies
    /// in front of the texel's scene depth `s` (the sky's: `skyDistance`),
    /// in the codes' steps, rounded down so that the code never claims more
    /// than it knows, at most 254. A pixel whose scene lies at
    /// s · 2^(−clipOctaves(code)) or beyond sees the effect whole.
    public static func clipCode(endsAt x: Double, sceneDepth s: Double) -> Int {
        guard x <= s else { return 0 }
        let octaves = log2(max(s, 1e-30) / max(x, 1e-30))
        let code = octaves < clipFineOctaves ? 1 + Int((octaves * clipStepsPerOctave).rounded(.down))
            : 1 + Int(clipFineOctaves * clipStepsPerOctave) + Int(((octaves - clipFineOctaves) / clipCoarseStep).rounded(.down))
        return min(clipEmpty - 1, code)
    }

    /// The octaves in front of the texel's scene a clip code (1...254) says
    /// its effect ended.
    public static func clipOctaves(code: Int) -> Double {
        let fine = Int(clipFineOctaves * clipStepsPerOctave)
        return code <= fine ? Double(code - 1) / clipStepsPerOctave
            : clipFineOctaves + clipCoarseStep * Double(code - fine - 1)
    }

    /// Whether a pixel of linear depth `pixel` (m; infinity on the sky)
    /// sees whole the effect a texel of linear test depth `texel` (the sky
    /// at `skyDistance`) coded `code`: it lies at the code's depth or beyond.
    public static func clipEnded(code: Int, texel: Double, pixel: Double) -> Bool {
        if code >= clipEmpty { return true }
        guard code > 0 else { return false }
        return log2(min(max(texel, 1e-30), skyDistance)) - log2(min(max(pixel, 1e-30), skyDistance))
            <= clipOctaves(code: code)
    }

    /// Whether every layer drawn at a texel ended nearer than both scene
    /// depths, for a pixel: the volumes' back in front of the pixel's
    /// scene, the clouds' and OIT's clip codes met. Depths are linear (m):
    /// the texel's test depth (`skyDistance` on the sky), the pixel's
    /// (infinity on the sky). A layer drawn but not `reconstructed` this
    /// frame never ends.
    public static func texelEnded(back: Double, clouds: Int, oit: Int, texel: Double, pixel: Double,
                                  drawn: Set<Layer>, reconstructed: Set<Layer>) -> Bool {
        for layer in drawn {
            guard reconstructed.contains(layer) else { return false }
            switch layer {
            case .volumes: if !(back < log2(min(max(pixel, 1e-30), skyDistance))) { return false }
            case .clouds: if !clipEnded(code: clouds, texel: texel, pixel: pixel) { return false }
            case .oit: if !clipEnded(code: oit, texel: texel, pixel: pixel) { return false }
            }
        }
        return true
    }

    /// A reversed-Z depth as the reconstruction's linear one: near / z, the
    /// sky at `skyDistance` for a texel and at infinity for a pixel.
    public static func linearDepth(reversedZ z: Double, near: Double, pixel: Bool) -> Double {
        z > 0 ? near / z : (pixel ? .infinity : skyDistance)
    }

    /// The linear depth (m) the effects take the sky to be at
    /// (ORBIT_EFFECT_SKY_DISTANCE): a cut back (`noFront`) is behind it.
    public static let skyDistance = 1e30

    /// The upsample's footprint of texel (x, y) at `scale` 2: the frame
    /// pixels whose four nearest texels include it, 2x − 1 ... 2x + 2 along
    /// each axis (fewer at the frame's edge); at `scale` 1 its own pixel.
    public static func footprintPixels(x: Int, y: Int, scale: Int, width: Int, height: Int) -> [(x: Int, y: Int)] {
        let r = scale > 1 ? (-1...2) : (0...0)
        var out: [(x: Int, y: Int)] = []
        for dy in r {
            for dx in r {
                let px = scale * x + dx, py = scale * y + dy
                if px >= 0 && py >= 0 && px < width && py < height { out.append((px, py)) }
            }
        }
        return out
    }

    /// The depth sprites test against (the depth attachment): the farthest
    /// of the texel's footprint (`footprintPixels`, reversed-Z: the least).
    /// A sprite behind it is behind every pixel that reads the texel; one in
    /// front of it but behind the texel's own test depth still draws, faded
    /// out there, to write a cut clip code.
    public static func footprintFarthest(_ depths: [Double]) -> Double {
        depths.min() ?? 0
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

    // MARK: Jitter

    /// The fractional part of the golden ratio.
    public static let goldenRatio = 0.618_033_988_749_894_9

    /// The frame's rotation of the blue noise's values (Cranley and
    /// Patterson's rotation, by the golden ratio each frame): over frames a
    /// texel's jitter is the golden-ratio sequence from its noise value,
    /// low-discrepancy in time, while each frame's pattern stays R1's blue
    /// noise in space. In Double from the frame index modulo 2^24, as the
    /// uniforms carry it (`EffectSlotUniforms.reconstruction.y`).
    public static func jitterRotation(frameIndex: Int) -> Double {
        let k = Double(frameIndex % (1 << 24))
        return (k * goldenRatio).truncatingRemainder(dividingBy: 1)
    }

    /// The offset of `salt`'s copy of the tile, so that two uses of the
    /// jitter in one effect are not the same numbers.
    public static func jitterOffset(salt: Int) -> (x: Int, y: Int) { (salt * 37, salt * 61) }

    /// A march's jitter in [0, 1) at texel (x, y) on frame `frameIndex`
    /// (orbit_effectJitter): R1's blue-noise tile there, rotated by the
    /// frame's rotation. The shader takes the rotation from the uniforms in
    /// float, so it agrees to about 1e-7.
    public static func jitter(x: Int, y: Int, salt: Int = 0, frameIndex: Int, noise: BlueNoise = .shared) -> Double {
        let n = noise.size, o = jitterOffset(salt: salt)
        let v = Double(noise.values[((y + o.y) % n) * n + (x + o.x) % n])
        return (v + jitterRotation(frameIndex: frameIndex)).truncatingRemainder(dividingBy: 1)
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

    /// The most any channel of an effect's radiance holds, pre-exposed:
    /// half's largest finite value is 65504 (ORBIT_EFFECT_MAX_RADIANCE).
    public static let maxRadiance = 6.0e4

    /// A layer's channel as the composite takes it: items are held below
    /// `maxRadiance`, but a layer sums them in half floats, which can reach
    /// +inf. Light past half's range saturates at `maxRadiance`, as in R1's
    /// post; NaN and −inf are no light.
    public static func layerChannel(_ x: Double) -> Double {
        if x.isNaN { return 0 }
        return min(max(x, 0), maxRadiance)
    }

    /// Premultiplied colour as the composite takes it, coverage within 0...1.
    public static func layer(_ c: Premultiplied) -> Premultiplied {
        Premultiplied(layerChannel(c.r), layerChannel(c.g), layerChannel(c.b), min(layerChannel(c.a), 1))
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
    /// - each layer's channels taken as `layerChannel` says;
    /// - the layers composited in front order, the result held below
    ///   `maxRadiance`.
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
        colors[0] = layer(colors[0])
        colors[1] = layer(colors[1])
        if drawn.contains(.oit) {
            let a = Premultiplied(layerChannel(accumulation.r), layerChannel(accumulation.g),
                                  layerChannel(accumulation.b), layerChannel(accumulation.a))
            colors[2] = layer(oitResolve(accumulation: a, revealage: revealage.isFinite ? revealage : 1))
        }
        let c = composite((0..<3).map { LayerSample(colors[$0], front: linearDepth(frontCode: fronts[$0])) })
        return Premultiplied(min(c.r, maxRadiance), min(c.g, maxRadiance), min(c.b, maxRadiance), min(max(c.a, 0), 1))
    }
}
