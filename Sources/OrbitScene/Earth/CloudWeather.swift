import Foundation
import OrbitCore

/// The sky the renderer draws (track C1): the mission's ERA5 field where
/// it has data, the zonal climatology elsewhere and fading into it over
/// `fade` beyond the field's span, then each override (the observed sky at
/// the pad at launch) on top.
public struct CloudWeather {
    public var field: CloudField?
    public var overrides: [CloudOverride]
    /// Beyond the field's first or last snapshot, its edge fades into the
    /// climatology over this time, s.
    public var fade = 3 * 3600.0

    public init(field: CloudField? = nil, overrides: [CloudOverride] = []) {
        self.field = field
        self.overrides = overrides
    }

    /// A mission's weather: `<mission>.oscloud` from OrbitSceneResources
    /// when the owner has fetched it (tools/make_clouds_era5.py), with the
    /// launch's observed sky; the climatology and the observed sky
    /// otherwise. Missions: apollo7, apollo8, apollo11.
    public static func mission(_ name: String) -> CloudWeather {
        let field = OrbitSceneResources.url(name + ".oscloud").flatMap { try? CloudField(contentsOf: $0) }
        return CloudWeather(field: field, overrides: CloudOverride.launches[name].map { [$0] } ?? [])
    }

    public func sample(latitude: Double, longitude: Double, at epoch: Epoch) -> CloudSample {
        var s = base(latitude: latitude, longitude: longitude, at: epoch)
        for o in overrides { s = o.apply(to: s, latitude: latitude, longitude: longitude, at: epoch) }
        return s
    }

    private func base(latitude: Double, longitude: Double, at epoch: Epoch) -> CloudSample {
        let climate = CloudClimatology.sample(latitude: latitude, at: epoch)
        guard let field, let first = field.times.first, let last = field.times.last else { return climate }
        let edge = epoch < first ? first : (epoch > last ? last : epoch)
        guard let s = field.sample(latitude: latitude, longitude: longitude, at: edge) else { return climate }
        let away = abs(epoch - edge)
        if away == 0 { return s }
        return away >= fade ? climate : CloudSample.mix(s, climate, away / fade)
    }
}

/// A sky as TM X-64796 Table 1 reports it: tenths of sky by cloud genus,
/// "1/10 cumulus, 2/10 altocumulus, 9/10 cirrostratus", or "clear".
public struct CloudObservation: Equatable {
    public var low: Double
    public var mid: Double
    public var high: Double
    /// Cumulonimbus reported.
    public var convective: Bool

    public init(low: Double, mid: Double, high: Double, convective: Bool = false) {
        self.low = low
        self.mid = mid
        self.high = high
        self.convective = convective
    }

    /// The ERA5 layer of a cloud genus (WMO's étages: low cumulus,
    /// stratocumulus, stratus, nimbostratus and cumulonimbus by their base;
    /// mid alto-; high cirro-), nil for a word that is none.
    public static func layer(of genus: String) -> CloudLayer.Kind? {
        let g = genus.lowercased()
        if g.hasPrefix("cirr") { return .high }
        if g.hasPrefix("alto") { return .mid }
        for low in ["cumulus", "stratocumulus", "stratus", "fractocumulus", "fractostratus", "nimbostratus",
                    "cumulonimbus"] where g.hasPrefix(low) {
            return .low
        }
        return nil
    }

    /// The observation in Table 1's words. Genera of one layer combine at
    /// random overlap, 1 - (1 - a)(1 - b). Nil when a part is not
    /// "n/10 genus" and the text is not "clear".
    public init?(table text: String) {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        self.init(low: 0, mid: 0, high: 0)
        if t == "clear" { return }
        for part in t.split(separator: ",") {
            let words = part.split(separator: " ")
            guard words.count >= 2 else { return nil }
            let fraction = words[0].split(separator: "/")
            guard fraction.count == 2, let n = Double(fraction[0]), let d = Double(fraction[1]), d > 0,
                  let kind = Self.layer(of: String(words[1])) else { return nil }
            let f = min(max(n / d, 0), 1)
            switch kind {
            case .low: low += f - low * f
            case .mid: mid += f - mid * f
            case .high: high += f - high * f
            }
            if words[1].hasPrefix("cumulonimbus") { convective = true }
        }
    }
}

/// An observed sky that overrides the field around a place and time: the
/// pad at launch (docs/m16/design-earth-moon.md: about 50 km). Its weight
/// is 1 within half `radius` and `hold` of the observation, and falls
/// smoothly to 0 at `radius` and at `hold + fade`.
public struct CloudOverride: Equatable {
    /// Geodetic latitude and east longitude, rad.
    public var latitude: Double
    public var longitude: Double
    public var time: Epoch
    public var observation: CloudObservation
    /// m.
    public var radius = 50_000.0
    /// s.
    public var hold = 3600.0
    public var fade = 7200.0

    public init(latitude: Double, longitude: Double, time: Epoch, observation: CloudObservation) {
        self.latitude = latitude
        self.longitude = longitude
        self.time = time
        self.observation = observation
    }

    /// The override's weight at a point and time.
    public func weight(latitude: Double, longitude: Double, at epoch: Epoch) -> Double {
        let d = Self.distance(latitude, longitude, self.latitude, self.longitude)
        let space = 1 - Self.smoothstep(radius / 2, radius, d)
        let time = 1 - Self.smoothstep(hold, hold + fade, abs(epoch - self.time))
        return space * time
    }

    public func apply(to s: CloudSample, latitude: Double, longitude: Double, at epoch: Epoch) -> CloudSample {
        let w = weight(latitude: latitude, longitude: longitude, at: epoch)
        guard w > 0 else { return s }
        var out = s
        out.low += w * (observation.low - s.low)
        out.mid += w * (observation.mid - s.mid)
        out.high += w * (observation.high - s.high)
        if w >= 0.5 { out.convective = observation.convective }
        return out
    }

    /// Great-circle distance on a 6,371 km sphere, m.
    static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let a = sin((lat2 - lat1) / 2), b = sin((lon2 - lon1) / 2)
        let h = a * a + cos(lat1) * cos(lat2) * b * b
        return 2 * 6_371_000 * asin(min(sqrt(h), 1))
    }

    static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

extension CloudOverride {
    /// The observed skies at the launches the sim flies, from NASA TM
    /// X-64796 Table 1 (tools/data/tmx64796_table1_saturn.csv; the tests
    /// check these against it): the pad, the launch time to the minute.
    public static let launches: [String: CloudOverride] = [
        // AS-205, LC-34, 1968-10-11 15:03 UTC: "3/10 cumulonimbus".
        "apollo7": CloudOverride(latitude: 28.5218 * .pi / 180, longitude: -80.5611 * .pi / 180,
                                 time: Epoch(utcYear: 1968, month: 10, day: 11, hour: 15, minute: 3),
                                 observation: CloudObservation(low: 0.3, mid: 0, high: 0, convective: true)),
        // AS-503, LC-39A, 1968-12-21 12:51 UTC: "4/10 cirrus".
        "apollo8": CloudOverride(latitude: VesselLibrary.lc39A.latitude * .pi / 180,
                                 longitude: VesselLibrary.lc39A.longitude * .pi / 180,
                                 time: Epoch(utcYear: 1968, month: 12, day: 21, hour: 12, minute: 51),
                                 observation: CloudObservation(low: 0, mid: 0, high: 0.4)),
        // AS-506, LC-39A, 1969-07-16 13:32 UTC: "1/10 cumulus, 2/10
        // altocumulus, 9/10 cirrostratus".
        "apollo11": CloudOverride(latitude: VesselLibrary.lc39A.latitude * .pi / 180,
                                  longitude: VesselLibrary.lc39A.longitude * .pi / 180,
                                  time: Epoch(utcYear: 1969, month: 7, day: 16, hour: 13, minute: 32),
                                  observation: CloudObservation(low: 0.1, mid: 0.2, high: 0.9)),
    ]
}
