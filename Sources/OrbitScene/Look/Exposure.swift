import Foundation

/// The camera's exposure in photographic terms (track R1). The renderer's
/// pre-exposure takes scene luminance (cd/m²) to a pixel value where 1 is
/// the sensor's saturation, following Lagarde and de Rousiers (2014,
/// "Moving Frostbite to PBR", §5.1): EV100 = log₂(N²/t · 100/S), the
/// reflected-light meter reads an average luminance L = 2^EV100 · K/100
/// with K = 12.5 (ISO 2720), and the saturation-based sensitivity puts the
/// maximum luminance at 1.2 · 2^EV100.
public enum Exposure {
    /// The reflected-light meter's calibration constant K, cd s/(m² ISO).
    public static let meterConstant = 12.5
    /// Saturation-based speed: the luminance that saturates is this times 2^EV100 (78 / (S q), q = 0.65, at S = 100).
    public static let saturationFactor = 1.2

    /// The EV100 a reflected-light meter gives for an average luminance `l` (cd/m²).
    public static func ev100(averageLuminance l: Double) -> Double {
        log2(max(l, 1e-12) * 100 / meterConstant)
    }

    /// The average luminance (cd/m²) a meter reads as `ev100`.
    public static func averageLuminance(ev100: Double) -> Double {
        pow(2, ev100) * meterConstant / 100
    }

    /// The luminance that saturates the sensor at `ev100`, cd/m².
    public static func maxLuminance(ev100: Double) -> Double {
        saturationFactor * pow(2, ev100)
    }

    /// The pre-exposure at `ev100`: scene luminance to pixel value, 1 at saturation.
    public static func exposure(ev100: Double) -> Double {
        1 / maxLuminance(ev100: ev100)
    }

    /// The EV100 of a camera at f-number `aperture`, `shutter` s and film speed `iso`.
    public static func ev100(aperture: Double, shutter: Double, iso: Double) -> Double {
        log2(aperture * aperture / shutter * 100 / iso)
    }
}

/// A histogram of the image's luminance, in EV100 units (the EV100 a meter
/// would give if the whole image had that pixel's luminance), with the
/// weight of pixels too dark to count (empty space) kept apart. The GPU
/// fills it (PostPass) with centre-weighted integer weights; the auto
/// exposure reads it on the CPU.
public struct LuminanceHistogram: Equatable {
    public static let binCount = 256
    /// The range of the bins, EV100: about 0.002 to 8e6 cd/m² (a glowing
    /// heat shield is about 2e5); brighter pixels fall in the last bin.
    public static let minEV100 = -6.0
    public static let maxEV100 = 26.0
    public static var binWidth: Double { (maxEV100 - minEV100) / Double(binCount) }

    /// Weights per bin, darkest first.
    public var bins: [Double]
    /// The weight of pixels darker than the first bin (the black of space).
    public var dark: Double

    public init(bins: [Double] = [Double](repeating: 0, count: LuminanceHistogram.binCount), dark: Double = 0) {
        precondition(bins.count == Self.binCount)
        self.bins = bins
        self.dark = dark
    }

    /// The bin of a pixel of luminance `l` (cd/m²), nil when it is too dark to count.
    public static func bin(luminance l: Double) -> Int? {
        let ev = Exposure.ev100(averageLuminance: l)
        guard ev >= minEV100 else { return nil }
        return min(Int((ev - minEV100) / binWidth), binCount - 1)
    }

    /// The centre of bin `i`, EV100.
    public static func centre(_ i: Int) -> Double { minEV100 + (Double(i) + 0.5) * binWidth }

    public mutating func add(luminance l: Double, weight: Double = 1) {
        if let b = Self.bin(luminance: l) { bins[b] += weight } else { dark += weight }
    }

    public var signal: Double { bins.reduce(0, +) }
    /// The share of the weight bright enough to count.
    public var coverage: Double {
        let s = signal
        return s + dark > 0 ? s / (s + dark) : 0
    }

    /// The mean EV100 of the weight between the quantiles `low` and `high`
    /// of the pixels that count (the darkest `low` and the brightest 1 -
    /// `high` left out), nil with none.
    public func meanEV100(low: Double, high: Double) -> Double? {
        let total = signal
        guard total > 0 else { return nil }
        let a = low * total, b = high * total
        var below = 0.0, sum = 0.0, weight = 0.0
        for (i, w) in bins.enumerated() where w > 0 {
            let lo = max(below, a), hi = min(below + w, b)
            if hi > lo {
                sum += (hi - lo) * Self.centre(i)
                weight += hi - lo
            }
            below += w
            if below >= b { break }
        }
        return weight > 0 ? sum / weight : nil
    }

    /// The EV100 below which the share `q` of the pixels that count lies,
    /// interpolated within its bin; nil with none.
    public func quantileEV100(_ q: Double) -> Double? {
        let total = signal
        guard total > 0 else { return nil }
        let goal = min(max(q, 0), 1) * total
        var below = 0.0
        for (i, w) in bins.enumerated() where w > 0 {
            if below + w >= goal {
                return Self.minEV100 + (Double(i) + (goal - below) / w) * Self.binWidth
            }
            below += w
        }
        return Self.maxEV100
    }
}

/// The automatic exposure, run on the CPU from the latest histogram: the
/// mean of the 50th to 95th percentile of what counts sets the target,
/// unless the brightest 1 % would then go far over saturation (a glowing
/// heat shield or a sunlit vehicle over the night side: the subject, as a
/// photographer would meter it); the camera follows the target in
/// wall-clock time, brightening scenes faster than darkening ones (2 and 1
/// EV/s).
public struct AutoExposure: Equatable {
    /// The camera's EV100, nil before the first histogram.
    public private(set) var ev100: Double?
    public var lowQuantile = 0.5
    public var highQuantile = 0.95
    /// Fastest adaptation, EV/s, towards brighter and darker scenes.
    public var upRate = 2.0
    public var downRate = 1.0
    /// How quickly the last fraction of a stop closes, 1/s.
    public var settleRate = 3.0
    /// The camera's EV100 range.
    public var range = -4.0...17.0
    /// When less than this share of the image counts (stars on black), the
    /// target slides towards `darkEV100`, so that empty space is exposed for
    /// the stars rather than for the few pixels that are lit.
    public var minimumCoverage = 0.02
    public var darkEV100 = -2.0
    /// The brightest pixels (above `highlightQuantile`) may reach at most
    /// this many times the sensor's saturation (AgX still shows colour there).
    public var highlightQuantile = 0.99
    public var highlightValue = 2.0

    public init(ev100: Double? = nil) {
        self.ev100 = ev100
    }

    /// The EV100 the histogram asks for, with `compensation` (EV; positive
    /// brightens) applied to the mean but not to the highlights' limit; nil
    /// without any weight.
    public func target(_ h: LuminanceHistogram, compensation: Double = 0) -> Double? {
        guard h.signal + h.dark > 0 else { return nil }
        guard let lit = h.meanEV100(low: lowQuantile, high: highQuantile),
              let top = h.quantileEV100(highlightQuantile) else { return darkEV100 }
        // At EV the top luminance L = 2^top / 8 reads L / (1.2 · 2^EV).
        let limit = top - log2(8 * Exposure.saturationFactor * highlightValue)
        let share = min(1, h.coverage / minimumCoverage)
        return darkEV100 + (max(lit - compensation, limit) - darkEV100) * share
    }

    /// Moves the camera towards `target` (an EV100, compensation applied)
    /// over `dt` wall-clock seconds; `snap` jumps to it.
    public mutating func update(target: Double, dt: Double, snap: Bool = false) {
        let goal = min(max(target, range.lowerBound), range.upperBound)
        guard let current = ev100, !snap else {
            ev100 = goal
            return
        }
        let delta = goal - current
        let rate = min(max(settleRate * delta, -downRate), upRate)
        let step = rate * max(dt, 0)
        ev100 = abs(step) >= abs(delta) ? goal : current + step
    }

    /// Forgets the camera (a scenario load): the next update snaps.
    public mutating func reset() { ev100 = nil }
}
