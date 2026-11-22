import Foundation
import OrbitCore

// Track C2 follow-up: the weather where no ERA5 field is (the whole Earth
// in the random setting, beyond a mission's days in the historic one). A
// seeded generator with the general circulation's structure, evaluated on
// the GPU at 720 × 361 nodes (CloudShaders' `cloud_procedural`, which
// mirrors `node` line for line in Float) and calibrated row by row so that
// its zonal means are the climatology's (`cloud_calibrate`, `offset`):
//
// - the ITCZ and its convective clusters, following the Sun over the
//   continents (the monsoons), afternoon storms over land;
// - the subtropical highs: subsidence, the deserts on the continents' west
//   sides and interiors, the stratocumulus decks over the cold eastern
//   boundary currents, thinning by day and giving way westward to trade
//   cumulus;
// - the storm tracks' extratropical cyclones, born in the climatological
//   genesis regions, carried east and poleward by the steering flow,
//   growing and occluding: the warm front's cloud shield, the cold front's
//   band and its convective line, the comma head wrapping round the low,
//   the dry slot, open cells in the cold air behind;
// - tropical cyclones in their basins' seasons, with an eye, a central dense
//   overcast and spiral bands, recurving poleward;
// - polar stratus over the sea, little low cloud over the ice sheets;
// - between the systems, weather noise carried by the steering wind, made
//   afresh every 18 h and cross-faded so features grow and decay;
// - low, mid and high cover, and the low layer's base and top (stratocumulus
//   under the inversion, deeper trade and continental cumulus, nimbostratus
//   in the fronts, cumulonimbus to 9-15 km in the cores).
//
// Everything is a pure function of the seed and the time (systems are born
// at times hashed from the seed and integrated from their birth), so a
// warp, a jump or a snapshot gives the same sky. The latitude-and-season
// terms are a row's (`Band`); only what varies along a parallel survives the
// calibration, which sets each row's level (a row-wide offset of the
// latent cover) from the climatology.

/// The procedural weather (see the file's header).
public struct ProceduralWeather: Equatable {
    /// The run's seed (CloudSettings.seed).
    public var seed: Int

    public init(seed: Int) {
        self.seed = seed
    }

    // MARK: Grid and cover

    /// The GPU's nodes: row j at latitude 90° − 0.5° j, column c at 0.5° c east.
    public static let columns = 720
    public static let rows = 361

    public static func latitude(row j: Int) -> Double { (90 - 0.5 * Double(j)) * .pi / 180 }
    public static func longitude(column c: Int) -> Double { 0.5 * Double(c) * .pi / 180 }

    /// Cover from the latent value z (with the row's offset in): a logistic of
    /// each layer's gain, so a node is mostly clear or cloudy and partly
    /// cloudy where its latent value is near the row's threshold. The gains
    /// give ERA5's shares of clear, broken and overcast sky per layer
    /// (`ProceduralWeatherTests.testCoverStatisticsLikeERA5`): high cloud is
    /// the most often all or nothing.
    public static let gains = (low: 2.5, mid: 3.0, high: 5.0)
    public static func cover(_ z: Double, gain: Double) -> Double { 1 / (1 + exp(-gain * z)) }
    public static func covers(_ n: Node, _ o: (low: Double, mid: Double, high: Double)) -> (low: Double, mid: Double, high: Double) {
        (cover(n.low + o.low, gain: gains.low), cover(n.mid + o.mid, gain: gains.mid), cover(n.high + o.high, gain: gains.high))
    }

    static let earthRadius = 6_371_000.0

    // MARK: Random numbers

    /// SplitMix64's finaliser (Steele, Lea and Flood 2014).
    static func mix(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A uniform number in [0, 1) for this seed, a stream, a slot, a cycle and a draw.
    func uniform(_ stream: UInt64, _ slot: Int, _ cycle: Int64, _ draw: UInt64) -> Double {
        var h = Self.mix(UInt64(bitPattern: Int64(seed)) &+ stream &* 0x1000_0000_01B3)
        h = Self.mix(h ^ UInt64(slot))
        h = Self.mix(h ^ UInt64(bitPattern: cycle))
        h = Self.mix(h ^ draw)
        return Double(h >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// A standard normal number (Box-Muller) from two of the draws.
    func normal(_ stream: UInt64, _ slot: Int, _ cycle: Int64, _ draw: UInt64) -> Double {
        let a = max(uniform(stream, slot, cycle, draw), 1e-12), b = uniform(stream, slot, cycle, draw + 1)
        return (-2 * log(a)).squareRoot() * cos(2 * .pi * b)
    }

    // MARK: The Sun and the season

    /// What the time of year and day set.
    public struct Sky: Equatable {
        /// Fraction of the year since 1 January.
        public var yearFraction: Double
        /// The Sun's declination (rad).
        public var declination: Double
        /// The declination over its greatest, −1 to 1: 1 at the June solstice.
        public var season: Double
        /// The same a month later, for what lags the Sun (the oceans' ITCZ, the monsoons).
        public var laggedSeason: Double
        /// The subsolar longitude (rad east): local noon there.
        public var subsolarLongitude: Double
        /// The ITCZ's latitude over the sea and over the continents (rad).
        public var itczSea: Double
        public var itczLand: Double
    }

    public static func sky(_ epoch: Epoch) -> Sky {
        let jd = epoch.julianDateUTC
        let year = CloudClimatology.yearFraction(epoch)
        // The March equinox about 20 March, day 79 of 365.25.
        let phase = 2 * Double.pi * (year - 0.2163)
        let season = sin(phase), lagged = sin(phase - 2 * .pi * 0.07)
        let dayFraction = (jd + 0.5) - (jd + 0.5).rounded(.down)
        let deg = Double.pi / 180
        return Sky(yearFraction: year, declination: 23.44 * deg * season, season: season, laggedSeason: lagged,
                   subsolarLongitude: .pi - 2 * .pi * dayFraction,
                   itczSea: (6 + 4 * lagged) * deg, itczLand: (2 + 10 * lagged) * deg)
    }

    // MARK: Winds

    /// The zonal-mean wind, m/s east, at latitude φ (rad) and a level (0:
    /// 850 hPa, 1: 500 hPa, 2: 250 hPa), for the season (−1...1): the jets
    /// (about 31° N and 42 m/s at 250 hPa in the northern winter, 45° N and
    /// 18 m/s in its summer; 37-47° S, 26-38 m/s), the trades either side of
    /// the ITCZ, the polar easterlies at 850 hPa; zero at the poles.
    public static func zonalWind(latitude φ: Double, level: Int, season s: Double) -> Double {
        let deg = φ * 180 / .pi
        func g(_ x: Double, _ w: Double) -> Double { exp(-0.5 * x * x / (w * w)) }
        let jetN = 38 + 7 * s, jetS = -(42 - 5 * s)
        let speedN = 30 - 12 * s, speedS = 32 + 6 * s
        let share = [0.32, 0.62, 1.0][level], shift = [4.0, 2.0, 0.0][level]
        var u = share * (speedN * g(deg - jetN - shift, 13) + speedS * g(deg - jetS + shift, 13))
        let itcz = 5 + 4 * s
        let east = [7.0, 3.0, 4.0][level]
        u -= east * (g(deg - itcz - 13, 9) + g(deg - itcz + 15, 9))
        if level == 0 { u -= 3 * g(abs(deg) - 75, 8) }
        return u * (1 - smoothstep(70, 90, abs(deg)))
    }

    /// The steering flow's angular speed about the axis (rad/s): the
    /// weather noise's drift, between 850 and 500 hPa.
    public static func steering(latitude φ: Double, season s: Double) -> Double {
        let u = 0.35 * zonalWind(latitude: φ, level: 0, season: s) + 0.65 * zonalWind(latitude: φ, level: 1, season: s)
        return u / (earthRadius * max(cos(φ), 1e-3))
    }

    // MARK: Latitude bands

    /// The terms of a latitude and season (each 0...1), which the GPU gets row
    /// by row with the row's climatology.
    public struct Band: Equatable {
        /// The steering flow's angular speed (rad/s).
        public var steer = 0.0
        /// The subtropical highs' subsidence.
        public var subtropics = 0.0
        /// The latitudes of the stratocumulus decks.
        public var stratocumulus = 0.0
        /// The subtropical deserts' latitudes, and the mid-latitude interiors'.
        public var desert = 0.0
        public var midDesert = 0.0
        /// The trade cumulus' latitudes.
        public var trades = 0.0
        /// Polar sea, and the ice sheets' latitudes.
        public var polar = 0.0
        public var ice = 0.0

        public init() {}
    }

    public static func band(latitude φ: Double, sky: Sky) -> Band {
        let deg = φ * 180 / .pi, a = abs(deg)
        // Summer in this hemisphere: 1; its winter: −1.
        let local = deg >= 0 ? sky.season : -sky.season
        func g(_ x: Double, _ w: Double) -> Double { exp(-0.5 * x * x / (w * w)) }
        var b = Band()
        b.steer = steering(latitude: φ, season: sky.season)
        b.subtropics = g(a - (27 + 4 * local), 8)
        b.stratocumulus = g(a - 22, 9)
        b.desert = g(a - (24 + 2 * local), 8)
        b.midDesert = g(a - 43, 7)
        b.trades = smoothstep(3, 9, a) * (1 - smoothstep(24, 33, a))
        b.polar = smoothstep(55, 70, a)
        b.ice = smoothstep(60, 72, a)
        return b
    }

    // MARK: Systems

    /// A weather system at one time.
    public struct System: Equatable {
        public enum Kind: Int, Equatable {
            case cyclone = 0, cluster = 1, tropical = 2
        }

        public var kind: Kind
        /// Body-fixed unit vectors: the centre, east there, and poleward there
        /// (north in the northern hemisphere, south in the southern).
        public var centre: Vec3
        public var east: Vec3
        public var poleward: Vec3
        /// Its size (m): a cyclone's radius, a cluster's core, a tropical
        /// cyclone's central dense overcast.
        public var size: Double
        /// Its reach (rad of arc): nothing beyond.
        public var reach: Double
        /// 0...1.
        public var intensity: Double
        /// A cyclone's occlusion (0 an open wave, 1 wrapped up); a cluster's
        /// anvil (its high cloud outlives the core).
        public var stage: Double
        /// The convective cores' tops (m).
        public var top: Double
        /// The template's turn (rad), from the seed.
        public var tilt: Double
        /// Geodetic latitude and east longitude (rad), for the tests.
        public var latitude: Double
        public var longitude: Double
        /// Its age (s) and life (s).
        public var age: Double
        public var life: Double
    }

    /// The weather noise's two phases at one time: each carried by the
    /// steering flow for its age, then faded out as the next fades in.
    public struct Phase: Equatable {
        /// Noise-space offset (from the seed and the phase's number).
        public var offset: Vec3
        /// s since the phase began.
        public var age: Double
        public var weight: Double
    }

    /// Everything the nodes of one time need.
    public struct State: Equatable {
        public var epoch: Epoch
        public var sky: Sky
        public var phases: [Phase]
        public var systems: [System]
    }

    /// A noise phase's life, s: each begins half of it after the last.
    public static let phaseLife = 1.5 * 86_400.0

    static let cycloneSlots = (north: 11, south: 13)
    static let clusterSlots = 52
    static let tropicalSlots = 7

    /// The sky, the noise phases and the systems alive at `epoch`.
    public func state(at epoch: Epoch, geography: WeatherGeography = .earth) -> State {
        let sky = Self.sky(epoch)
        let t = epoch.tdb
        // The noise phases.
        let half = Self.phaseLife / 2
        let m = Int64((t / half).rounded(.down))
        let age0 = t - Double(m) * half
        var phases: [Phase] = []
        for (k, age) in [(m, age0), (m - 1, age0 + half)] {
            let w = 1 - abs(2 * age / Self.phaseLife - 1)
            let o = Vec3(uniform(9, 0, k, 0), uniform(9, 0, k, 1), uniform(9, 0, k, 2)) * 256
            phases.append(Phase(offset: o, age: age, weight: w))
        }
        var systems: [System] = []
        for slot in 0..<(Self.cycloneSlots.north + Self.cycloneSlots.south) {
            if let s = cyclone(slot: slot, north: slot < Self.cycloneSlots.north, t: t, sky: sky) { systems.append(s) }
        }
        for slot in 0..<Self.clusterSlots {
            if let s = cluster(slot: slot, t: t, epoch: epoch, geography: geography) { systems.append(s) }
        }
        for slot in 0..<Self.tropicalSlots {
            if let s = tropical(slot: slot, t: t, epoch: epoch, geography: geography) { systems.append(s) }
        }
        return State(epoch: epoch, sky: sky, phases: phases, systems: systems)
    }

    /// The system of a slot alive at t: slots run cycles of `period`, each
    /// with one system of life `life` born at a hashed time within it.
    private func lifetime(stream: UInt64, slot: Int, t: Double, period: Double,
                          life: (Double) -> Double) -> (cycle: Int64, age: Double, life: Double)? {
        let t0 = uniform(stream, slot, 0, 99) * period
        let cycle = Int64(((t - t0) / period).rounded(.down))
        let l = life(uniform(stream, slot, cycle, 1))
        let birth = t0 + Double(cycle) * period + uniform(stream, slot, cycle, 2) * max(period - l, 0)
        let age = t - birth
        guard age >= 0, age < l else { return nil }
        return (cycle, age, l)
    }

    /// Unit vector, east and poleward at a latitude and longitude.
    static func frame(latitude φ: Double, longitude λ: Double) -> (centre: Vec3, east: Vec3, poleward: Vec3) {
        let c = Vec3(cos(φ) * cos(λ), cos(φ) * sin(λ), sin(φ))
        let e = Vec3(-sin(λ), cos(λ), 0)
        let n = Vec3(-sin(φ) * cos(λ), -sin(φ) * sin(λ), cos(φ))
        return (c, e, φ >= 0 ? n : -n)
    }

    /// Integrates a track from its genesis for `age` s, in a fixed number of
    /// midpoint steps (so the position is smooth in time), with east and
    /// poleward speeds (m/s) of the position and the age's fraction.
    static func track(latitude φ0: Double, longitude λ0: Double, age: Double, life: Double,
                      velocity: (Double, Double) -> (east: Double, poleward: Double)) -> (Double, Double) {
        let n = 24, dt = age / Double(n), hemi: Double = φ0 >= 0 ? 1 : -1
        var φ = φ0, λ = λ0
        for k in 0..<n {
            let v = velocity(φ, (Double(k) + 0.5) * dt / life)
            let φm = φ + 0.5 * hemi * v.poleward * dt / earthRadius
            let vm = velocity(φm, (Double(k) + 0.5) * dt / life)
            φ += hemi * vm.poleward * dt / earthRadius
            λ += vm.east * dt / (earthRadius * max(cos(φm), 0.05))
            φ = min(max(φ, -1.4), 1.4)
        }
        return (φ, λ)
    }

    /// The storm tracks' genesis regions (Hoskins and Hodges 2002, J. Atmos.
    /// Sci. 59, 1041): east longitude (deg), its spread, latitude (deg), its
    /// spread, and weight.
    static let northGenesis: [(Double, Double, Double, Double, Double)] = [
        (135, 15, 37, 5, 1.0),   // off Japan: the Kuroshio
        (285, 12, 37, 5, 1.0),   // off the United States: the Gulf Stream
        (250, 8, 45, 5, 0.6),    // the lee of the Rockies
        (320, 20, 50, 6, 0.6),   // the central North Atlantic
        (195, 25, 42, 6, 0.8),   // the North Pacific, the Gulf of Alaska
        (15, 12, 40, 3, 0.4),    // the Mediterranean
        (60, 30, 55, 6, 0.4),    // Europe and Siberia
    ]
    static let southGenesis: [(Double, Double, Double, Double, Double)] = [
        (0, 180, -46, 6, 2.0),   // the Southern Ocean all round
        (295, 15, -42, 4, 0.5),  // east of the Andes
        (30, 20, -40, 4, 0.4),   // south of Africa
        (150, 20, -40, 4, 0.5),  // east of Australia, the Tasman Sea
    ]

    private static func pick(_ regions: [(Double, Double, Double, Double, Double)], _ u: Double)
        -> (Double, Double, Double, Double, Double) {
        let total = regions.reduce(0) { $0 + $1.4 }
        var x = u * total
        for r in regions {
            if x < r.4 { return r }
            x -= r.4
        }
        return regions[regions.count - 1]
    }

    /// The age's occlusion: from an open wave to wrapped up.
    static func occlusion(_ a: Double) -> Double { smoothstep(0.1, 0.75, a) }

    private func cyclone(slot: Int, north: Bool, t: Double, sky: Sky) -> System? {
        let stream: UInt64 = 1
        guard let l = lifetime(stream: stream, slot: slot, t: t, period: 7 * 86_400,
                               life: { (4 + 2.5 * $0) * 86_400 }) else { return nil }
        let (cycle, age, life) = (l.cycle, l.age, l.life)
        let deg = Double.pi / 180
        let local = north ? sky.season : -sky.season
        let r = Self.pick(north ? Self.northGenesis : Self.southGenesis, uniform(stream, slot, cycle, 3))
        let lon0 = (r.0 + r.1 * normal(stream, slot, cycle, 4)) * deg
        let lat0 = ((r.2 + r.3 * normal(stream, slot, cycle, 6)) + (north ? 5 * local : -3 * local)) * deg
        let speed = 9 + 6 * uniform(stream, slot, cycle, 8) - 2 * local
        let drift = 1.5 + 2 * uniform(stream, slot, cycle, 9)
        let a = age / life
        let (φ, λ) = Self.track(latitude: lat0, longitude: lon0, age: age, life: life) { _, f in
            let w = Self.occlusion(f)
            return (speed * (1 - 0.5 * w), drift * (1 - 0.6 * w))
        }
        let f = Self.frame(latitude: φ, longitude: λ)
        let size = (900_000 + 500_000 * uniform(stream, slot, cycle, 10)) * (0.55 + 0.45 * smoothstep(0, 0.4, a))
        let strength = (0.75 + 0.25 * uniform(stream, slot, cycle, 11)) * (1 - 0.3 * max(local, 0))
        return System(kind: .cyclone, centre: f.centre, east: f.east, poleward: f.poleward, size: size,
                      reach: 3.6 * size / Self.earthRadius,
                      intensity: strength * smoothstep(0, 0.2, a) * (1 - smoothstep(0.65, 1, a)),
                      stage: Self.occlusion(a), top: 8_000, tilt: 0.25 * normal(stream, slot, cycle, 12),
                      latitude: φ, longitude: λ, age: age, life: life)
    }

    /// The ITCZ's convective regions: east longitude (deg), spread, weight.
    static let tropicalConvection: [(Double, Double, Double)] = [
        (20, 15, 1.0),    // Africa
        (297, 12, 0.9),   // the Amazon
        (120, 22, 1.3),   // the Maritime Continent
        (80, 18, 0.7),    // the Indian Ocean
        (160, 20, 0.9),   // the western Pacific
        (220, 25, 0.6),   // the central Pacific
        (262, 12, 0.6),   // the eastern Pacific
        (330, 15, 0.5),   // the Atlantic
        (275, 8, 0.4),    // Central America
    ]

    /// The ITCZ's latitude (rad) where the continents' share is `continental`.
    static func itcz(_ sky: Sky, continental: Double) -> Double {
        sky.itczSea + continental * (sky.itczLand - sky.itczSea)
    }

    private func cluster(slot: Int, t: Double, epoch: Epoch, geography: WeatherGeography) -> System? {
        let stream: UInt64 = 2
        guard let l = lifetime(stream: stream, slot: slot, t: t, period: 2.6 * 86_400,
                               life: { (0.6 + 1.6 * $0) * 86_400 }) else { return nil }
        let (cycle, age, life) = (l.cycle, l.age, l.life)
        let deg = Double.pi / 180
        let r = Self.tropicalConvection[Self.pickIndex(Self.tropicalConvection.map { $0.2 }, uniform(stream, slot, cycle, 3))]
        let lon0 = (r.0 + r.1 * normal(stream, slot, cycle, 4)) * deg
        // The ITCZ where and when it was born.
        let born = Self.sky(Epoch(tdbSecondsPastJ2000: t - age))
        let cont = geography.texel(latitude: born.itczSea, longitude: lon0).continental
        let lat0 = Self.itcz(born, continental: cont) + 3.5 * deg * normal(stream, slot, cycle, 6)
        let speed = -(3 + 5 * uniform(stream, slot, cycle, 8))
        let λ = lon0 + speed * age / (Self.earthRadius * cos(lat0))
        let f = Self.frame(latitude: lat0, longitude: λ)
        let a = age / life
        let size = 180_000 + 220_000 * uniform(stream, slot, cycle, 9)
        return System(kind: .cluster, centre: f.centre, east: f.east, poleward: f.poleward, size: size,
                      reach: 5.0 * size / Self.earthRadius,
                      intensity: smoothstep(0, 0.15, a) * (1 - smoothstep(0.5, 1, a)),
                      stage: smoothstep(0.05, 0.3, a) * (1 - smoothstep(0.75, 1, a)),
                      top: 11_000 + 4_000 * uniform(stream, slot, cycle, 10), tilt: 0,
                      latitude: lat0, longitude: λ, age: age, life: life)
    }

    private static func pickIndex(_ weights: [Double], _ u: Double) -> Int {
        var x = u * weights.reduce(0, +)
        for (i, w) in weights.enumerated() {
            if x < w { return i }
            x -= w
        }
        return weights.count - 1
    }

    /// The tropical cyclone basins: genesis east longitude and latitude
    /// (deg), their spreads, the season's peak (fraction of the year) and
    /// half-width, and weight (Gray 1968's genesis regions).
    static let basins: [(lon: Double, dlon: Double, lat: Double, dlat: Double, peak: Double, width: Double, weight: Double)] = [
        (320, 15, 14, 3, 0.69, 0.10, 1.0),    // the North Atlantic
        (258, 6, 13, 2, 0.62, 0.12, 0.8),     // the eastern North Pacific
        (145, 12, 13, 4, 0.66, 0.18, 1.4),    // the western North Pacific
        (88, 4, 13, 2, 0.85, 0.08, 0.3),      // the Bay of Bengal
        (75, 15, -13, 3, 0.13, 0.12, 0.7),    // the South Indian Ocean
        (140, 15, -14, 3, 0.15, 0.10, 0.6),   // off Australia
    ]

    private func tropical(slot: Int, t: Double, epoch: Epoch, geography: WeatherGeography) -> System? {
        let stream: UInt64 = 3
        guard let l = lifetime(stream: stream, slot: slot, t: t, period: 14 * 86_400,
                               life: { (6 + 5 * $0) * 86_400 }) else { return nil }
        let (cycle, age, life) = (l.cycle, l.age, l.life)
        let b = Self.basins[Self.pickIndex(Self.basins.map { $0.weight }, uniform(stream, slot, cycle, 3))]
        // Born only in its basin's season.
        let born = Self.sky(Epoch(tdbSecondsPastJ2000: t - age)).yearFraction
        var dy = abs(born - b.peak)
        dy = min(dy, 1 - dy)
        guard uniform(stream, slot, cycle, 4) < exp(-0.5 * dy * dy / (b.width * b.width)) else { return nil }
        let deg = Double.pi / 180
        let lon0 = (b.lon + b.dlon * normal(stream, slot, cycle, 5)) * deg
        let lat0 = (b.lat + b.dlat * normal(stream, slot, cycle, 7)) * deg
        let (φ, λ) = Self.track(latitude: lat0, longitude: lon0, age: age, life: life) { φ, _ in
            let turn = smoothstep(20, 30, abs(φ) / deg)
            return (-5 + 13 * turn, 2 + 2.5 * turn)
        }
        let f = Self.frame(latitude: φ, longitude: λ)
        let a = age / life
        let land = geography.texel(latitude: φ, longitude: λ).land
        let intensity = smoothstep(0, 0.25, a) * (1 - smoothstep(0.7, 1, a)) * (1 - 0.75 * land)
        let size = (150_000 + 100_000 * uniform(stream, slot, cycle, 9)) * (0.6 + 0.4 * intensity)
        return System(kind: .tropical, centre: f.centre, east: f.east, poleward: f.poleward, size: size,
                      reach: 6.0 * size / Self.earthRadius, intensity: intensity, stage: 0, top: 14_000,
                      tilt: 2 * .pi * uniform(stream, slot, cycle, 10), latitude: φ, longitude: λ, age: age, life: life)
    }

    // MARK: Noise

    /// Perlin's edge gradients (CloudNoise's), in Double.
    static func gradientDot(_ h: UInt32, _ x: Double, _ y: Double, _ z: Double) -> Double {
        switch h % 12 {
        case 0: return x + y
        case 1: return -x + y
        case 2: return x - y
        case 3: return -x - y
        case 4: return x + z
        case 5: return -x + z
        case 6: return x - z
        case 7: return -x - z
        case 8: return y + z
        case 9: return -y + z
        case 10: return y - z
        default: return -y - z
        }
    }

    /// Three gradient noises at once (one per PCG3D lane), unbounded space.
    static func noise3(_ x: Double, _ y: Double, _ z: Double) -> (Double, Double, Double) {
        let fx = x.rounded(.down), fy = y.rounded(.down), fz = z.rounded(.down)
        let ix = Int32(fx), iy = Int32(fy), iz = Int32(fz)
        let wx = x - fx, wy = y - fy, wz = z - fz
        var c = [(Double, Double, Double)](repeating: (0, 0, 0), count: 8)
        for k in 0..<8 {
            let ox = Int32(k & 1), oy = Int32((k >> 1) & 1), oz = Int32((k >> 2) & 1)
            let h = CloudNoise.pcg3d(UInt32(bitPattern: ix &+ ox), UInt32(bitPattern: iy &+ oy), UInt32(bitPattern: iz &+ oz))
            let dx = wx - Double(ox), dy = wy - Double(oy), dz = wz - Double(oz)
            c[k] = (gradientDot(h.0, dx, dy, dz), gradientDot(h.1, dx, dy, dz), gradientDot(h.2, dx, dy, dz))
        }
        func fade(_ t: Double) -> Double { t * t * t * (t * (t * 6 - 15) + 10) }
        let sx = fade(wx), sy = fade(wy), sz = fade(wz)
        func lane(_ v: (Int) -> Double) -> Double {
            let x00 = v(0) + sx * (v(1) - v(0)), x10 = v(2) + sx * (v(3) - v(2))
            let x01 = v(4) + sx * (v(5) - v(4)), x11 = v(6) + sx * (v(7) - v(6))
            let y0 = x00 + sy * (x10 - x00), y1 = x01 + sy * (x11 - x01)
            return y0 + sz * (y1 - y0)
        }
        return (lane { c[$0].0 }, lane { c[$0].1 }, lane { c[$0].2 })
    }

    /// The noise's octaves: the first's cells about 3,200 km on the Earth,
    /// the last's about 100 km (the nodes are 55 km apart).
    static let octaves = 6
    static let baseFrequency = 2.0, lacunarity = 2.03, persistence = 0.6
    /// Scales the octaves' sum to about unit standard deviation (measured
    /// over the sphere: `ProceduralWeatherTests.testNoiseIsAboutUnitVariance`).
    static let noiseScale = 3.1

    /// Three fBm channels at unit vector p with a phase's offset.
    static func fbm(_ p: Vec3, offset: Vec3) -> (Double, Double, Double) {
        var s = (0.0, 0.0, 0.0), amplitude = 1.0, f = baseFrequency
        for o in 0..<octaves {
            let shift = Double(o) * 17.31
            let n = noise3(p.x * f + offset.x + shift, p.y * f + offset.y + shift, p.z * f + offset.z + shift)
            s.0 += amplitude * n.0
            s.1 += amplitude * n.1
            s.2 += amplitude * n.2
            amplitude *= persistence
            f *= lacunarity
        }
        return (s.0 * noiseScale, s.1 * noiseScale, s.2 * noiseScale)
    }

    /// The weather noise at a node: each phase's fBm at the point its flow
    /// has carried there, cross-faded with the variance kept.
    static func weatherNoise(latitude φ: Double, longitude λ: Double, steer: Double, phases: [Phase]) -> (Double, Double, Double) {
        var n = (0.0, 0.0, 0.0), w2 = 0.0
        for ph in phases {
            let l = λ - steer * ph.age
            let p = Vec3(cos(φ) * cos(l), cos(φ) * sin(l), sin(φ))
            let f = fbm(p, offset: ph.offset)
            n.0 += ph.weight * f.0
            n.1 += ph.weight * f.1
            n.2 += ph.weight * f.2
            w2 += ph.weight * ph.weight
        }
        let k = 1 / max(w2, 1e-6).squareRoot()
        return (n.0 * k, n.1 * k, n.2 * k)
    }

    // MARK: Nodes

    /// One node: the latent low, mid and high cover (before the row's
    /// offset), the low layer's base and top (m above the surface), and how
    /// cumuliform the low cloud is (0 stratiform, 1 cumulus).
    public struct Node: Equatable {
        public var low = 0.0
        public var mid = 0.0
        public var high = 0.0
        public var base = 0.0
        public var top = 0.0
        public var cumuliform = 0.0

        public init() {}
    }

    /// The node at a latitude and longitude (rad) with its geography and band.
    public static func node(latitude φ: Double, longitude λ: Double, geography g: WeatherGeography.Texel, band b: Band,
                            state: State) -> Node {
        let sky = state.sky
        let n = weatherNoise(latitude: φ, longitude: λ, steer: b.steer, phases: state.phases)
        let nl = n.0, nm = n.1, nh = n.2
        let land = g.land, sea = 1 - land
        // Local time: the hour angle from noon; the surface's heating peaks
        // about 15 h, as cumulus over land does.
        let hour = λ - sky.subsolarLongitude
        let noon = max(cos(φ - sky.declination), 0)
        let heat = noon * (0.5 + 0.5 * cos(hour - 0.785))
        let itczLat = itcz(sky, continental: g.continental)
        let itczWidth = (4 + 1 * g.continental) * .pi / 180
        let x = (φ - itczLat) / itczWidth
        let itcz = exp(-0.5 * x * x)
        let desert = land * b.desert * (0.35 + 0.65 * max(g.inland, g.landWestSea)) * (1 - g.landEastSea) * (1 - 0.7 * itcz)
            + 0.6 * land * b.midDesert * g.inland
        // The decks lie on the open oceans' eastern sides (not in enclosed
        // seas, with land close to the west as well).
        let sc = sea * g.seaEastLand * (1 - g.seaWestLand) * b.stratocumulus * (1 - itcz)
        let deck = min(1.5 * sc, 1)
        let trades = sea * b.trades * (1 - deck)
        let polar = sea * b.polar
        let ice = land * b.ice * (0.4 + 0.6 * g.inland)
        let tropics = 1 - smoothstep(20, 35, abs(φ) * 180 / .pi)

        var out = Node()
        out.low = 3.0 * sc - 2.8 * desert + 0.8 * polar - 1.4 * ice + land * (1.3 * heat - 0.55) * (1 - desert)
            + 0.4 * sc * cos(hour + 1.83) + 0.5 * itcz + (0.8 - 0.5 * deck - 0.35 * trades - 0.35 * desert) * nl
        out.mid = -1.8 * desert - 1.0 * sc - 0.6 * b.subtropics * sea + 1.1 * itcz + 0.3 * land * heat * (1 - desert)
            + (0.85 - 0.3 * b.subtropics) * nm
        out.high = -1.8 * desert - 0.9 * sc - 0.6 * b.subtropics + 1.7 * itcz + 0.5 * land * heat * tropics * (1 - desert)
            + 0.7 * nh
        // The low layer: stratocumulus under the inversion (base 480 m, top
        // 1,350 m by the coast), trade cumulus (600-750 m, 2,400 m), polar
        // stratus; over land a convective boundary layer, higher where dry
        // and deeper in the afternoon.
        let seaBase = 600 + 150 * trades - 120 * deck - 250 * polar
        let landBase = 900 + 900 * max(desert, 0.5 * g.inland) + 450 * heat - 500 * ice
        let seaTop = 2_100 + 300 * trades - 750 * deck - 600 * polar
        let landTop = landBase + 1_100 + 1_400 * heat
        out.base = sea * seaBase + land * landBase
        out.top = sea * seaTop + land * landTop
        out.cumuliform = sea * (1 - 0.85 * deck - 0.6 * polar) + land * (0.5 + 0.5 * heat)

        // The systems.
        let p = Vec3(cos(φ) * cos(λ), cos(φ) * sin(λ), sin(φ))
        var frontal = 0.0, deep = 0.0, deepTop = 0.0, cells = 0.0
        for s in state.systems {
            let d = p.dot(s.centre)
            let e = p.dot(s.east), q = p.dot(s.poleward)
            let lateral = (e * e + q * q).squareRoot()
            let angle = atan2(lateral, d)
            guard angle < s.reach else { continue }
            let k = lateral > 0 ? angle * earthRadius / (s.size * lateral) : 0
            let u0 = e * k, v0 = q * k
            let ct = cos(s.tilt), st = sin(s.tilt)
            let u = u0 * ct + v0 * st, v = -u0 * st + v0 * ct
            let c: Contribution
            switch s.kind {
            case .cyclone: c = cycloneTemplate(u: u + 0.18 * nm, v: v + 0.18 * nh, s, sea: sea)
            case .cluster: c = clusterTemplate(u: u, v: v, s, land: land, hour: hour, rough: nh)
            case .tropical: c = tropicalTemplate(u: u, v: v, s, rough: nh)
            }
            out.low += c.low
            out.mid += c.mid
            out.high += c.high
            frontal = max(frontal, c.frontal)
            cells = max(cells, c.cells)
            if c.deep > deep {
                deep = c.deep
                deepTop = s.top
            }
        }
        // Fronts: nimbostratus, low based, up into the mid layer; the cold
        // air's open cells; convective cores to their tops.
        out.base += frontal * (450 - out.base)
        out.top += frontal * (max(out.top, 2_900) - out.top)
        out.cumuliform += frontal * (0.15 - out.cumuliform)
        out.top += cells * (max(out.top, 2_800) - out.top)
        out.cumuliform += cells * (1 - out.cumuliform)
        out.base += deep * (900 - out.base)
        out.top += deep * (max(deepTop, out.top) - out.top)
        out.cumuliform += deep * (1 - out.cumuliform)
        out.top = max(out.top, out.base + 300)
        return out
    }

    /// What one system adds at a node: latent cover, and the weights of its
    /// fronts' layer cloud, the cold air's open cells and deep convection.
    struct Contribution {
        var low = 0.0, mid = 0.0, high = 0.0
        var frontal = 0.0, cells = 0.0, deep = 0.0
    }

    /// An extratropical cyclone in its own coordinates (u east, v poleward,
    /// in its size): Bjerknes' and Shapiro and Keyser's fronts as satellite
    /// imagery shows them (Carlson 1980's conveyor belts).
    static func cycloneTemplate(u: Double, v: Double, _ s: System, sea: Double) -> Contribution {
        let w = s.stage, i = s.intensity
        let r = (u * u + v * v).squareRoot(), theta = atan2(v, u)
        // The triple point leaves the low as it occludes.
        let tu = 0.30 * w + 0.05, tv = -0.08 * w
        // The warm front runs east-south-east from it: its shield lies
        // poleward, the cirrus furthest ahead, its poleward edge bowing out
        // where the warm conveyor belt turns anticyclonically.
        let along = u - tu, dw = (v - tv) + 0.27 * along
        let bow = 0.35 * exp(-(along - 0.8) * (along - 0.8))
        func shield(_ reach: Double, _ depth: Double) -> Double {
            smoothstep(-0.5, 0, along) * (1 - smoothstep(reach - 0.6, reach, along))
                * smoothstep(-0.25, 0.02, dw) * (1 - smoothstep(depth - 0.4, depth + bow, dw))
        }
        let shieldHigh = shield(2.2, 1.3), shieldMid = shield(1.7, 1.0), shieldLow = shield(1.1, 0.55)
        // The cold front trails equatorward and west of the triple point; its
        // cloud on the warm side, the narrow convective line at the front.
        let sc = max(tv - v, 0)
        let dc = u - (tu - 0.25 * sc - 0.14 * sc * sc)
        let fade = smoothstep(-0.15, 0.1, tv - v) * (1 - smoothstep(1.3, 2.7, sc))
        func band(_ width: Double) -> Double {
            smoothstep(-0.16, -0.04, dc) * (1 - smoothstep(width - 0.18, width, dc)) * fade
        }
        let frontHigh = band(0.70), frontMid = band(0.48), frontLow = band(0.36)
        let line = (1 - smoothstep(0.03, 0.10, abs(dc))) * fade * (1 - smoothstep(1.0, 2.0, sc))
        let warmSector = smoothstep(0.36, 0.55, dc) * smoothstep(0, 0.2, -dw) * (1 - smoothstep(1.4, 2.2, r))
        // The cold air behind the front and the low.
        let cold = (1 - smoothstep(-0.4, -0.15, dc)) * (1 - smoothstep(2.0, 2.9, r)) * (1 - smoothstep(0.1, 0.7, v - tv))
        // The comma head: an arm from east of the low spiralling in through
        // north, west and south as it occludes, filled on the poleward side.
        let span = (0.7 + 1.3 * w) * Double.pi
        var start = theta - 0.05 * .pi
        start -= (start / (2 * .pi)).rounded(.down) * 2 * .pi
        var arm = 0.0
        for k in 0..<2 {
            let a = start + 2 * .pi * Double(k)
            guard a <= span else { break }
            let x = (r - 0.95 * exp(-0.22 * a)) / (0.34 * exp(-0.1 * a))
            arm = max(arm, exp(-0.5 * x * x) * smoothstep(0, 0.6, a) * (1 - smoothstep(span - 0.8, span, a)))
        }
        // The dry slot: the cold air wrapping in from the south-west behind
        // the front, turned with the occlusion, where the arm is not.
        var off = theta + 0.6 * .pi - 0.35 * .pi * w
        off -= (off / (2 * .pi)).rounded() * 2 * .pi
        let dry = (1 - smoothstep(0.8, 1.3, r)) * smoothstep(0.05, 0.2, r) * (1 - smoothstep(-0.1, 0, dc))
            * (1 - smoothstep(0.35 * .pi, 0.6 * .pi, abs(off))) * (1 - arm)
        let head = (1 - smoothstep(0.6, 1.05, r)) * smoothstep(-0.05, 0.25, v) * (1 - dry)
        arm = max(arm, 0.8 * head)
        let outside = cold * (1 - arm) * (1 - dry)
        var c = Contribution()
        c.high = i * (3.2 * max(shieldHigh, frontHigh) + 3.0 * arm - 3.0 * dry - 1.2 * outside)
        c.mid = i * (3.4 * max(shieldMid, frontMid) + 3.2 * arm - 3.0 * dry - 1.5 * outside)
        c.low = i * (2.8 * max(shieldLow, frontLow) + 2.2 * arm + 1.0 * warmSector - 1.2 * dry
                     + (1.0 * sea - 0.5) * outside)
        c.frontal = i * max(max(shieldLow, frontLow), 0.8 * arm)
        c.cells = i * outside * sea
        c.deep = 0.8 * i * line
        return c
    }

    /// A system's lumpy outline: its radius over this at angle θ (rad), the
    /// lumps turned by `phase`.
    static func lumps(_ theta: Double, phase: Double) -> Double {
        1 + 0.22 * sin(3 * theta + phase) + 0.12 * sin(5 * theta + 2.3 * phase)
    }

    /// A tropical mesoscale convective system: its core of cumulonimbus
    /// (strongest in the late afternoon over land), its anvil spreading wider,
    /// downstream (west, with the upper easterlies), and lasting longer.
    static func clusterTemplate(u: Double, v: Double, _ s: System, land: Double, hour: Double, rough: Double) -> Contribution {
        let phase = s.top * 0.0037
        let theta = atan2(v, u)
        let r = (u * u + 1.56 * v * v).squareRoot() / lumps(theta, phase: phase) + 0.15 * rough
        let ua = u + 0.5
        let ra = (0.6 * ua * ua + 1.69 * v * v).squareRoot() / lumps(atan2(v, ua), phase: phase + 1.7) + 0.15 * rough
        let core = 1 - smoothstep(0.4, 1.0, r)
        let anvil = 1 - smoothstep(1.0, 2.6, ra)
        let diurnal = 1 - land + land * (0.3 + 0.7 * (0.5 + 0.5 * cos(hour - 1.3)))
        let ic = s.intensity * diurnal, ia = s.stage
        var c = Contribution()
        c.low = 2.6 * core * ic
        c.mid = 2.0 * core * ic + 0.8 * anvil * ia
        c.high = 3.6 * anvil * ia
        c.deep = core * ic
        return c
    }

    /// A tropical cyclone: the eye, the central dense overcast, two spiral
    /// bands curling in cyclonically, the outflow's cirrus.
    static func tropicalTemplate(u: Double, v: Double, _ s: System, rough: Double) -> Contribution {
        let r = (u * u + v * v).squareRoot(), theta = atan2(v, u)
        let eye = 1 - smoothstep(0.08, 0.14, r)
        let cdo = 1 - smoothstep(0.85, 1.25, r * (1 + 0.1 * sin(4 * theta + s.tilt)) + 0.1 * rough)
        var bands = 0.0
        if r > 0.3 {
            for k in 0..<2 {
                var d = theta - (Double(k) * .pi - 1.2 * log(r))
                d -= (d / (2 * .pi)).rounded() * 2 * .pi
                bands = max(bands, exp(-0.5 * d * d / (0.38 * 0.38)) * (1 - smoothstep(2.6, 4.0, r)) * smoothstep(0.6, 1.0, r))
            }
        }
        let outflow = 1 - smoothstep(1.4, 3.8, r * lumps(theta, phase: s.tilt))
        let i = s.intensity
        var c = Contribution()
        c.high = i * (4.0 * cdo + 1.8 * bands + 1.2 * outflow - 7 * eye)
        c.mid = i * (3.0 * cdo + 1.6 * bands - 7 * eye)
        c.low = i * (3.0 * cdo + 2.4 * bands - 7 * eye)
        c.deep = i * max(0.9 * cdo, 0.6 * bands) * (1 - eye)
        return c
    }

    // MARK: Calibration

    /// The offset that makes the mean cover of a row's latent values the
    /// target (clamped to 0.003...0.997): bisection, as the GPU does it.
    public static func offset(_ latents: [Double], target: Double, gain: Double, iterations: Int = 16) -> Double {
        let t = min(max(target, 0.003), 0.997)
        var lo = -10.0, hi = 10.0
        for _ in 0..<iterations {
            let m = 0.5 * (lo + hi)
            let mean = latents.reduce(0) { $0 + cover($1 + m, gain: gain) } / Double(max(latents.count, 1))
            if mean < t { lo = m } else { hi = m }
        }
        return 0.5 * (lo + hi)
    }

    /// The rows' offsets smoothed over ±2° (a triangle over ±4 rows), as the
    /// GPU reads them: the climatology is 5° means, and a row-by-row offset
    /// would stripe the map where a system crosses a few rows.
    public static func smoothed(_ offsets: [Double], row j: Int) -> Double {
        var sum = 0.0
        for i in -4...4 {
            let jj = min(max(j + i, 0), offsets.count - 1)
            sum += Double(5 - abs(i)) * offsets[jj]
        }
        return sum / 25
    }

    // MARK: The CPU's sample

    /// The node at any latitude and longitude, computed afresh (the geography
    /// bilinear).
    public func node(latitude: Double, longitude: Double, state: State, geography: WeatherGeography = .earth) -> Node {
        Self.node(latitude: latitude, longitude: longitude, geography: geography.texel(latitude: latitude, longitude: longitude),
                  band: Self.band(latitude: latitude, sky: state.sky), state: state)
    }

    /// The row offsets at a latitude, from `samples` nodes along it (the
    /// GPU's map uses all 720 of its nodes, smoothed over ±2°: this is the CPU's
    /// estimate for a single point).
    public func offsets(latitude: Double, state: State, samples: Int = 180,
                        geography: WeatherGeography = .earth) -> (low: Double, mid: Double, high: Double) {
        let band = Self.band(latitude: latitude, sky: state.sky)
        var low: [Double] = [], mid: [Double] = [], high: [Double] = []
        for k in 0..<samples {
            let lon = 2 * Double.pi * Double(k) / Double(samples)
            let n = Self.node(latitude: latitude, longitude: lon, geography: geography.texel(latitude: latitude, longitude: lon),
                              band: band, state: state)
            low.append(n.low)
            mid.append(n.mid)
            high.append(n.high)
        }
        let c = CloudClimatology.cover(latitude: latitude, yearFraction: state.sky.yearFraction)
        return (Self.offset(low, target: c.low, gain: Self.gains.low), Self.offset(mid, target: c.mid, gain: Self.gains.mid),
                Self.offset(high, target: c.high, gain: Self.gains.high))
    }

    /// The winds at a place (east and north, m/s; 850, 500 and 250 hPa): the
    /// zonal means and the cyclones' and tropical cyclones' circulations.
    public static func winds(latitude φ: Double, longitude λ: Double, state: State) -> [LayerWind] {
        let p = Vec3(cos(φ) * cos(λ), cos(φ) * sin(λ), sin(φ))
        let east = Vec3(-sin(λ), cos(λ), 0)
        let north = Vec3(-sin(φ) * cos(λ), -sin(φ) * sin(λ), cos(φ))
        var vortex = Vec3(0, 0, 0)
        for s in state.systems where s.kind != .cluster {
            let lateral = p - s.centre * p.dot(s.centre)
            let angle = atan2(lateral.length, p.dot(s.centre))
            guard angle < s.reach, lateral.length > 0 else { continue }
            let rm = s.kind == .tropical ? 0.15 : 0.4, peak = s.kind == .tropical ? 40.0 : 15.0
            let x = angle * earthRadius / s.size / rm
            let speed = peak * s.intensity * 2 * x / (1 + x * x)
            // Cyclonic: anticlockwise about the local up in the north,
            // clockwise in the south.
            let hemi: Double = s.centre.z >= 0 ? 1 : -1
            vortex += p.cross(lateral.normalized) * (hemi * speed)
        }
        return (0..<3).map { level in
            let u = zonalWind(latitude: φ, level: level, season: state.sky.season)
            let share = [0.8, 1.0, 0.6][level]
            return LayerWind(east: u + share * vortex.dot(east), north: share * vortex.dot(north))
        }
    }
}

fileprivate func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    let t = min(max((x - e0) / (e1 - e0), 0), 1)
    return t * t * (3 - 2 * t)
}
