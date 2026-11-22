import XCTest
import OrbitCore
@testable import OrbitScene

/// The procedural weather's statistics and structure (docs/look/clouds.md,
/// the procedural weather): its zonal means against the climatology it
/// replaces, its variance along the parallels, its determinism per seed, its
/// change over time, and the circulation's features where they belong.
final class ProceduralWeatherTests: XCTestCase {
    /// The parking orbit's day: 16 July 1969.
    static let july = VesselLibrary.apollo11Insertion
    static let january = Epoch(utcYear: 1969, month: 1, day: 15, hour: 12)

    /// A calibrated map at every `columnStride`-th column of every row, as
    /// the GPU makes it (each row's offsets from its own nodes, smoothed over
    /// ±2°): covers and nodes.
    struct Map {
        var columns: [Int]
        var nodes: [[ProceduralWeather.Node]]
        var offsets: [(low: Double, mid: Double, high: Double)]
        var state: ProceduralWeather.State

        func cover(row j: Int, column k: Int) -> (low: Double, mid: Double, high: Double) {
            ProceduralWeather.covers(nodes[j][k], offsets[j])
        }
    }

    static func map(_ w: ProceduralWeather, at epoch: Epoch, columnStride: Int = 4) -> Map {
        let state = w.state(at: epoch)
        let g = WeatherGeography.earth
        let columns = Array(stride(from: 0, to: ProceduralWeather.columns, by: columnStride))
        var nodes: [[ProceduralWeather.Node]] = []
        var raw: [(Double, Double, Double)] = []
        for j in 0..<ProceduralWeather.rows {
            let lat = ProceduralWeather.latitude(row: j)
            let band = ProceduralWeather.band(latitude: lat, sky: state.sky)
            let row = columns.map { c in
                ProceduralWeather.node(latitude: lat, longitude: ProceduralWeather.longitude(column: c),
                                       geography: g.texel(row: j, column: c), band: band, state: state)
            }
            nodes.append(row)
            let clim = CloudClimatology.cover(latitude: lat, yearFraction: state.sky.yearFraction)
            let g = ProceduralWeather.gains
            raw.append((ProceduralWeather.offset(row.map(\.low), target: clim.low, gain: g.low),
                        ProceduralWeather.offset(row.map(\.mid), target: clim.mid, gain: g.mid),
                        ProceduralWeather.offset(row.map(\.high), target: clim.high, gain: g.high)))
        }
        let offsets = (0..<raw.count).map { j in
            (ProceduralWeather.smoothed(raw.map(\.0), row: j), ProceduralWeather.smoothed(raw.map(\.1), row: j),
             ProceduralWeather.smoothed(raw.map(\.2), row: j))
        }
        return Map(columns: columns, nodes: nodes, offsets: offsets, state: state)
    }

    /// Maps made once for the tests that share them.
    nonisolated(unsafe) static var maps: [String: Map] = [:]
    static func cached(seed: Int, _ epoch: Epoch, columnStride: Int = 4) -> Map {
        let key = "\(seed) \(epoch.tdb) \(columnStride)"
        if let m = maps[key] { return m }
        let m = map(ProceduralWeather(seed: seed), at: epoch, columnStride: columnStride)
        maps[key] = m
        return m
    }

    /// The latitude band of rows within ±2.5° of `degrees`: the climatology's
    /// own (cos-latitude weighted means of the rows within 2.5°).
    static func bandMean(_ m: Map, degrees: Double, _ value: ((low: Double, mid: Double, high: Double)) -> Double) -> Double {
        var sum = 0.0, weight = 0.0
        for j in 0..<ProceduralWeather.rows {
            let lat = 90 - 0.5 * Double(j)
            guard abs(lat - degrees) <= 2.5 else { continue }
            let w = max(cos(lat * .pi / 180), 1e-3)
            for k in 0..<m.columns.count {
                sum += w * value(m.cover(row: j, column: k))
                weight += w
            }
        }
        return sum / weight
    }

    /// The weather noise is about unit variance over the sphere (its scale
    /// `noiseScale`), so the latent terms' weights mean what they say.
    func testNoiseIsAboutUnitVariance() {
        let w = ProceduralWeather(seed: 3)
        let state = w.state(at: Self.july)
        var sums = [0.0, 0.0, 0.0], squares = [0.0, 0.0, 0.0]
        let n = 4_000
        for k in 0..<n {
            // Area-uniform points (a Fibonacci lattice).
            let z = 1 - 2 * (Double(k) + 0.5) / Double(n)
            let lat = asin(z), lon = Double(k) * 2.399963
            let v = ProceduralWeather.weatherNoise(latitude: lat, longitude: lon, steer: 0, phases: state.phases)
            for (i, x) in [v.0, v.1, v.2].enumerated() {
                sums[i] += x
                squares[i] += x * x
            }
        }
        for i in 0..<3 {
            let mean = sums[i] / Double(n), sd = (squares[i] / Double(n) - mean * mean).squareRoot()
            print("noise channel \(i): mean \(mean), sd \(sd)")
            XCTAssertEqual(sd, 1, accuracy: 0.2, "channel \(i)")
            XCTAssertEqual(mean, 0, accuracy: 0.15, "channel \(i)")
        }
    }

    /// Its zonal means are the climatology's, in every 5° band, in July and
    /// January (the calibration's rows smoothed over ±2°).
    func testZonalMeansMatchTheClimatology() {
        for epoch in [Self.july, Self.january] {
            let m = Self.cached(seed: 1, epoch)
            for deg in stride(from: -85.0, through: 85, by: 5) {
                let c = CloudClimatology.cover(latitude: deg * .pi / 180, yearFraction: m.state.sky.yearFraction)
                XCTAssertEqual(Self.bandMean(m, degrees: deg) { $0.low }, c.low, accuracy: 0.03, "low at \(deg)°")
                XCTAssertEqual(Self.bandMean(m, degrees: deg) { $0.mid }, c.mid, accuracy: 0.03, "mid at \(deg)°")
                XCTAssertEqual(Self.bandMean(m, degrees: deg) { $0.high }, c.high, accuracy: 0.03, "high at \(deg)°")
            }
        }
    }

    /// The cover varies along the parallels: not the same weather at every
    /// longitude (the climatology's standard deviation along a row is 0).
    func testCoverVariesAlongTheParallels() {
        let m = Self.cached(seed: 1, Self.july)
        var all: [Double] = []
        for j in stride(from: 60, through: 300, by: 10) {
            var sds: [Double] = []
            for layer in 0..<3 {
                let v = (0..<m.columns.count).map { k -> Double in
                    let c = m.cover(row: j, column: k)
                    return [c.low, c.mid, c.high][layer]
                }
                let mean = v.reduce(0, +) / Double(v.count)
                sds.append((v.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(v.count)).squareRoot())
            }
            XCTAssertGreaterThan(sds.max()!, 0.12, "row \(j): \(sds)")
            all += sds
        }
        XCTAssertGreaterThan(all.reduce(0, +) / Double(all.count), 0.2, "the mean standard deviation along a parallel")
    }

    /// One seed, one sky; another seed, another.
    func testDeterministicPerSeed() {
        let a = Self.map(ProceduralWeather(seed: 42), at: Self.july, columnStride: 24)
        let b = Self.map(ProceduralWeather(seed: 42), at: Self.july, columnStride: 24)
        let c = Self.map(ProceduralWeather(seed: 43), at: Self.july, columnStride: 24)
        XCTAssertEqual(a.nodes, b.nodes)
        XCTAssertEqual(a.state, b.state)
        XCTAssertGreaterThan(Self.difference(a, c), 0.12)
    }

    /// Mean absolute difference of the low, mid and high covers.
    static func difference(_ a: Map, _ b: Map) -> Double {
        var sum = 0.0, n = 0.0
        for j in 0..<a.nodes.count {
            for k in 0..<a.columns.count {
                let x = a.cover(row: j, column: k), y = b.cover(row: j, column: k)
                sum += abs(x.low - y.low) + abs(x.mid - y.mid) + abs(x.high - y.high)
                n += 3
            }
        }
        return sum / n
    }

    /// The weather moves on: six hours later the sky differs, a minute later
    /// it has barely moved.
    func testWeatherChangesOverTime() {
        let w = ProceduralWeather(seed: 7)
        let now = Self.map(w, at: Self.july, columnStride: 8)
        let minute = Self.map(w, at: Self.july + 60, columnStride: 8)
        let later = Self.map(w, at: Self.july + 6 * 3600, columnStride: 8)
        XCTAssertGreaterThan(Self.difference(now, later), 0.06)
        XCTAssertLessThan(Self.difference(now, minute), 0.004)
    }

    /// No pops: at points around the globe, the latent cover changes
    /// smoothly through half a day in minutes, through systems' births and
    /// deaths and the noise's phases. (A front's cloud edge, about 100 km,
    /// passing at 15 m/s changes it by up to 0.1 a minute.)
    func testNoPopsThroughHalfADay() {
        let w = ProceduralWeather(seed: 11)
        let g = WeatherGeography.earth
        let points = (0..<60).map { k -> (Double, Double) in
            (asin(1 - 2 * (Double(k) + 0.5) / 60) * 0.9, Double(k) * 2.399963)
        }
        var last: [ProceduralWeather.Node]?
        var worst = 0.0
        for q in 0...720 {
            let state = w.state(at: Self.july + Double(q) * 60)
            let nodes = points.map { w.node(latitude: $0.0, longitude: $0.1, state: state, geography: g) }
            if let last {
                for (a, b) in zip(last, nodes) {
                    worst = max(worst, abs(a.low - b.low), abs(a.mid - b.mid), abs(a.high - b.high))
                }
            }
            last = nodes
        }
        XCTAssertLessThan(worst, 0.25)
    }

    /// The systems travel with the circulation: the cyclones east and
    /// poleward, the ITCZ's clusters west, the tropical cyclones west and
    /// poleward until they recurve.
    func testSystemsTravelWithTheCirculation() {
        let w = ProceduralWeather(seed: 5)
        let a = w.state(at: Self.july), b = w.state(at: Self.july + 6 * 3600)
        var cyclones = 0, clusters = 0
        for s in a.systems {
            guard let t = b.systems.first(where: { $0.kind == s.kind && abs($0.age - s.age - 6 * 3600) < 1 }) else { continue }
            var dlon = t.longitude - s.longitude
            dlon -= (dlon / (2 * .pi)).rounded() * 2 * .pi
            switch s.kind {
            case .cyclone:
                XCTAssertGreaterThan(dlon, 0, "a cyclone goes east")
                XCTAssertGreaterThan(abs(t.latitude), abs(s.latitude), "and poleward")
                cyclones += 1
            case .cluster:
                XCTAssertLessThan(dlon, 0, "a cluster goes west")
                clusters += 1
            case .tropical:
                break
            }
        }
        XCTAssertGreaterThan(cyclones, 8)
        XCTAssertGreaterThan(clusters, 15)
        // Both hemispheres' storm tracks.
        XCTAssertTrue(a.systems.contains { $0.kind == .cyclone && $0.latitude > 0.5 })
        XCTAssertTrue(a.systems.contains { $0.kind == .cyclone && $0.latitude < -0.5 })
    }

    /// The geography's boundary currents belong to the continents: land to
    /// the east of the sea off Peru, Namibia and California, none west of
    /// Hawaii, New Caledonia or Jamaica (islands); the ice sheets on
    /// Antarctica and Greenland, not on the tundra beside them.
    func testGeographyKnowsContinentsAndIceSheets() {
        let g = WeatherGeography.earth
        func at(_ lat: Double, _ lon: Double) -> WeatherGeography.Texel {
            g.texel(latitude: lat * .pi / 180, longitude: lon * .pi / 180)
        }
        for (name, lat, lon) in [("Peru", -15.0, -80.0), ("Namibia", -20.0, 10.0), ("California", 30.0, -122.0)] {
            XCTAssertGreaterThan(at(lat, lon).seaEastLand, 0.5, name)
        }
        for (name, lat, lon) in [("Hawaii", 20.5, -158.5), ("Hawaii", 19.5, -170.0), ("New Caledonia", -21.0, 162.0),
                                 ("Jamaica", 18.0, -79.0)] {
            XCTAssertLessThan(at(lat, lon).seaEastLand, 0.2, "west of \(name)")
        }
        for (name, lat, lon) in [("Greenland", 72.5, -38.5), ("Greenland", 65.0, -45.0), ("Antarctica", -80.0, 30.0),
                                 ("the South Pole", -90.0, 0.0)] {
            XCTAssertEqual(at(lat, lon).iceSheet, 1, accuracy: 0.01, name)
        }
        for (name, lat, lon) in [("Siberia", 68.0, 100.0), ("Canada", 62.0, -100.0), ("Baffin Island", 70.0, -72.0),
                                 ("Alaska", 66.0, -152.0), ("Iceland", 64.8, -18.5)] {
            XCTAssertEqual(at(lat, lon).iceSheet, 0, accuracy: 0.01, name)
        }
    }

    /// The land's heating follows the Sun's elevation: one value at the pole
    /// (its 720 nodes are one place), and none of the day's cycle over the
    /// ice sheets (Greenland in July), while the Siberian tundra beside it
    /// has its afternoon cumulus.
    func testHeatingFollowsTheSun() {
        let w = ProceduralWeather(seed: 3), g = WeatherGeography.earth
        for epoch in [Self.january, Self.july] {
            let state = w.state(at: epoch)
            let j = ProceduralWeather.rows - 1, lat = ProceduralWeather.latitude(row: j)
            let band = ProceduralWeather.band(latitude: lat, sky: state.sky)
            let pole = (0..<ProceduralWeather.columns).map { c in
                ProceduralWeather.node(latitude: lat, longitude: ProceduralWeather.longitude(column: c),
                                       geography: g.texel(row: j, column: c), band: band, state: state)
            }
            for (k, name) in [(\ProceduralWeather.Node.low, "low"), (\.base, "base"), (\.top, "top"),
                              (\.cumuliform, "cumuliform")] {
                let v = pole.map { $0[keyPath: k] }
                XCTAssertLessThan(v.max()! - v.min()!, 1e-6 * max(1, abs(v[0])), "the pole's \(name)")
            }
        }
        var night = w.state(at: Self.july)
        var day = night
        day.sky.subsolarLongitude = -40 * .pi / 180 - 0.785
        night.sky.subsolarLongitude = day.sky.subsolarLongitude + .pi
        func node(_ s: ProceduralWeather.State, _ lat: Double, _ lon: Double) -> ProceduralWeather.Node {
            let φ = lat * .pi / 180
            return ProceduralWeather.node(latitude: φ, longitude: lon * .pi / 180,
                                          geography: g.texel(latitude: φ, longitude: lon * .pi / 180),
                                          band: ProceduralWeather.band(latitude: φ, sky: s.sky), state: s)
        }
        let a = node(day, 72.5, -40), b = node(night, 72.5, -40)
        XCTAssertEqual(a.base, b.base, accuracy: 1e-9, "Greenland's ice")
        XCTAssertEqual(a.top, b.top, accuracy: 1e-9)
        XCTAssertEqual(a.cumuliform, b.cumuliform, accuracy: 1e-9)
        day.sky.subsolarLongitude = 100 * .pi / 180 - 0.785
        night.sky.subsolarLongitude = day.sky.subsolarLongitude + .pi
        let c = node(day, 66, 100), d = node(night, 66, 100)
        XCTAssertGreaterThan(c.top - d.top, 700, "Siberia's afternoon")
    }

    /// The circulation's features where they belong, over two seeds and two
    /// days: stratocumulus off Peru, Namibia and California (low cover above
    /// its row's mean), none in Hawaii's lee, clear skies over the Sahara and
    /// Arabia.
    func testDecksAndDesertsWhereTheyBelong() {
        func boxMean(_ m: Map, lat: ClosedRange<Double>, lon: ClosedRange<Double>,
                     _ f: ((low: Double, mid: Double, high: Double)) -> Double) -> (box: Double, row: Double) {
            var box = 0.0, nb = 0.0, row = 0.0, nr = 0.0
            for j in 0..<ProceduralWeather.rows {
                let la = 90 - 0.5 * Double(j)
                guard lat.contains(la) else { continue }
                for (k, c) in m.columns.enumerated() {
                    var lo = 0.5 * Double(c)
                    if lo > 180 { lo -= 360 }
                    let v = f(m.cover(row: j, column: k))
                    row += v
                    nr += 1
                    if lon.contains(lo) { box += v; nb += 1 }
                }
            }
            return (box / nb, row / nr)
        }
        for seed in [1, 2] {
            for epoch in [Self.july, Self.july + 2 * 86_400] {
                let m = Self.cached(seed: seed, epoch)
                let peru = boxMean(m, lat: -25 ... -12, lon: -85 ... -75) { $0.low }
                let namibia = boxMean(m, lat: -25 ... -12, lon: 0 ... 10) { $0.low }
                let california = boxMean(m, lat: 22...32, lon: -130 ... -120) { $0.low }
                let hawaii = boxMean(m, lat: 19...22, lon: -175 ... -160) { $0.low }
                let sahara = boxMean(m, lat: 18...28, lon: 0...25) { $0.low }
                let saharaHigh = boxMean(m, lat: 18...28, lon: 0...25) { $0.high }
                XCTAssertGreaterThan(peru.box - peru.row, 0.15, "Peru's deck, seed \(seed)")
                XCTAssertGreaterThan(namibia.box - namibia.row, 0.15, "Namibia's deck, seed \(seed)")
                XCTAssertGreaterThan(california.box - california.row, 0.1, "California's deck, seed \(seed)")
                XCTAssertLessThanOrEqual(hawaii.box - hawaii.row, 0.0, "Hawaii's lee, seed \(seed)")
                XCTAssertLessThan(sahara.box - sahara.row, -0.1, "the Sahara, seed \(seed)")
                XCTAssertLessThan(saharaHigh.box - saharaHigh.row, -0.05, "the Sahara's high cloud, seed \(seed)")
            }
        }
    }

    /// The ITCZ follows the Sun over Africa: its high cloud (the clusters'
    /// anvils and the band) lies further north in July than in January.
    func testITCZFollowsTheSeasonOverAfrica() {
        func peak(_ epoch: Epoch) -> Double {
            var best = (lat: 0.0, value: -1.0)
            for seed in [1, 2] {
                let m = Self.cached(seed: seed, epoch)
                for j in stride(from: 120, through: 240, by: 2) {
                    var sum = 0.0, n = 0.0
                    for (k, c) in m.columns.enumerated() where c >= 20 && c <= 60 {
                        sum += m.cover(row: j, column: k).high
                        n += 1
                    }
                    if sum / n > best.value { best = (90 - 0.5 * Double(j), sum / n) }
                }
            }
            return best.lat
        }
        let july = peak(Self.july), january = peak(Self.january)
        XCTAssertGreaterThan(july - january, 8, "July \(july)°, January \(january)°")
    }

    /// The winds turn cyclonically about a cyclone: anticlockwise in the
    /// north (northward east of the low), clockwise in the south.
    func testWindsAreCyclonic() {
        let w = ProceduralWeather(seed: 5)
        let state = w.state(at: Self.july)
        var checked = 0
        for s in state.systems where s.kind == .cyclone && s.intensity > 0.5 {
            let east = s.longitude + 0.5 * s.size / (6_371_000 * cos(s.latitude))
            // Its own circulation: the winds with it less those without it.
            let winds = ProceduralWeather.winds(latitude: s.latitude, longitude: east, state: state)
            let others = ProceduralWeather.winds(latitude: s.latitude, longitude: east,
                                                 state: ProceduralWeather.State(epoch: state.epoch, sky: state.sky,
                                                                                phases: state.phases,
                                                                                systems: state.systems.filter { $0 != s }))
            let north = winds[0].north - others[0].north
            if s.latitude > 0 { XCTAssertGreaterThan(north, 2) } else { XCTAssertLessThan(north, -2) }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 3)
    }

    /// The fractions of the area (cos-latitude weighted) clear (cover 0.1 or
    /// less), partly cloudy and overcast (0.9 or more) of each layer, and the
    /// layers' correlations within 70° of the equator.
    static func statistics(_ m: Map, gains: (Double, Double, Double)? = nil)
        -> (fractions: [[Double]], correlations: [Double]) {
        var f = [[Double]](repeating: [0, 0, 0], count: 3), total = 0.0
        var xs: [[Double]] = [[], [], []]
        // With other gains: each row calibrated again.
        var offsets = m.offsets
        if let g = gains {
            for j in 0..<m.nodes.count {
                let lat = ProceduralWeather.latitude(row: j)
                let clim = CloudClimatology.cover(latitude: lat, yearFraction: m.state.sky.yearFraction)
                func off(_ zs: [Double], _ k: Double, _ t: Double) -> Double {
                    ProceduralWeather.offset(zs, target: t, gain: k)
                }
                offsets[j] = (off(m.nodes[j].map(\.low), g.0, clim.low), off(m.nodes[j].map(\.mid), g.1, clim.mid),
                              off(m.nodes[j].map(\.high), g.2, clim.high))
            }
        }
        let k = gains ?? ProceduralWeather.gains
        for j in 0..<m.nodes.count {
            let lat = 90 - 0.5 * Double(j), w = cos(lat * .pi / 180)
            for (c, n) in m.nodes[j].enumerated() {
                _ = c
                let o = offsets[j]
                func cover(_ z: Double, _ g: Double) -> Double { 1 / (1 + exp(-g * z)) }
                let v = [cover(n.low + o.low, k.0), cover(n.mid + o.mid, k.1), cover(n.high + o.high, k.2)]
                for l in 0..<3 { f[l][v[l] <= 0.1 ? 0 : (v[l] >= 0.9 ? 2 : 1)] += w }
                total += w
                if abs(lat) < 70 { for l in 0..<3 { xs[l].append(v[l]) } }
            }
        }
        func corr(_ a: [Double], _ b: [Double]) -> Double {
            let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
            var sab = 0.0, saa = 0.0, sbb = 0.0
            for (x, y) in zip(a, b) { sab += (x - ma) * (y - mb); saa += (x - ma) * (x - ma); sbb += (y - mb) * (y - mb) }
            return sab / (saa * sbb).squareRoot()
        }
        return (f.map { $0.map { $0 / total } }, [corr(xs[0], xs[1]), corr(xs[0], xs[2]), corr(xs[1], xs[2])])
    }

    /// ERA5's cover is mostly clear or overcast: measured over six snapshots
    /// of the Apollo 11 field (16-24 July 1969, `apollo11.oscloud`), the low
    /// layer's area is 0.30-0.32 clear (0.1 or less), 0.52-0.54 partly cloudy
    /// and 0.16-0.17 overcast (0.9 or more); the mid layer's 0.48-0.52,
    /// 0.39-0.42, 0.09-0.10; the high layer's 0.54-0.56, 0.23-0.25,
    /// 0.20-0.22; the layers' correlations (within 70°) 0.24-0.31 low-mid,
    /// 0.07-0.17 low-high, 0.32-0.39 mid-high. The generator's are within
    /// 0.1 of these and its layers no more correlated than 0.5.
    func testCoverStatisticsLikeERA5() {
        let m = Self.cached(seed: 1, Self.july)
        if ProcessInfo.processInfo.environment["ORBITSIM_WEATHER_SWEEP"] != nil {
            for g in [(2.5, 2.5, 2.5), (3.0, 3.0, 3.0), (3.0, 3.0, 4.0), (3.0, 3.5, 5.0), (4.0, 4.0, 6.0), (2.5, 3.0, 5.0)] {
                let st = Self.statistics(m, gains: g)
                print("gains \(g): " + st.fractions.map { $0.map { String(format: "%.2f", $0) }.joined(separator: "/") }
                    .joined(separator: "  ") + "  corr " + st.correlations.map { String(format: "%.2f", $0) }.joined(separator: " "))
            }
        }
        let st = Self.statistics(m)
        let era5: [[Double]] = [[0.31, 0.53, 0.16], [0.50, 0.40, 0.10], [0.55, 0.24, 0.21]]
        for l in 0..<3 {
            for b in 0..<3 {
                XCTAssertEqual(st.fractions[l][b], era5[l][b], accuracy: 0.1, "layer \(l), bin \(b): \(st.fractions)")
            }
        }
        for (c, e) in zip(st.correlations, [0.27, 0.11, 0.35]) {
            XCTAssertEqual(c, e, accuracy: 0.3, "\(st.correlations)")
        }
    }

    /// CloudWeather's sample beyond a field is the procedural weather's: the
    /// node's heights and how cumuliform, its winds, and covers near the
    /// map's (its row's offsets from 180 nodes, not the GPU's 720 smoothed).
    func testCloudWeatherSamplesTheProceduralWeather() {
        let w = ProceduralWeather(seed: 1)
        let weather = CloudWeather(procedural: w)
        let m = Self.cached(seed: 1, Self.july)
        var worst = 0.0
        for (j, k) in [(100, 10), (150, 40), (180, 90), (220, 150), (260, 170)] {
            let lat = ProceduralWeather.latitude(row: j), lon = ProceduralWeather.longitude(column: m.columns[k])
            let s = weather.sample(latitude: lat, longitude: lon, at: Self.july)
            let n = m.nodes[j][k], c = m.cover(row: j, column: k)
            XCTAssertEqual(s.baseHeight ?? 0, n.base, accuracy: 1e-6)
            XCTAssertEqual(s.topHeight ?? 0, n.top, accuracy: 1e-6)
            XCTAssertEqual(s.cumuliform ?? 0, n.cumuliform, accuracy: 1e-6)
            XCTAssertEqual(s.lowWind, ProceduralWeather.winds(latitude: lat, longitude: lon, state: m.state)[0])
            worst = max(worst, abs(s.low - c.low), abs(s.mid - c.mid), abs(s.high - c.high))
        }
        XCTAssertLessThan(worst, 0.1)
        // Without the procedural weather, the climatology as before.
        let clim = CloudWeather().sample(latitude: 0.5, longitude: 1, at: Self.july)
        XCTAssertEqual(clim, CloudClimatology.sample(latitude: 0.5, at: Self.july))
        let layers = CloudLayerModel.layers(weather.sample(latitude: 0.5, longitude: 1, at: Self.july))
        XCTAssertEqual(layers[0].top, w.node(latitude: 0.5, longitude: 1, state: m.state).top, accuracy: 1e-6)
    }

    /// `ORBITSIM_WEATHER_MAPS=<dir>`: writes the map at a few times as PNGs
    /// (clouds over the land and sea; and low, mid, high apart) for looking at.
    func testWriteMaps() throws {
        guard let dir = ProcessInfo.processInfo.environment["ORBITSIM_WEATHER_MAPS"] else {
            throw XCTSkip("set ORBITSIM_WEATHER_MAPS to a folder to write the maps")
        }
        let seed = Int(ProcessInfo.processInfo.environment["ORBITSIM_WEATHER_SEED"] ?? "") ?? 1
        let w = ProceduralWeather(seed: seed)
        let g = WeatherGeography.earth
        let hours = (ProcessInfo.processInfo.environment["ORBITSIM_WEATHER_HOURS"] ?? "0").split(separator: ",")
            .compactMap { Double($0) }
        for (name, epoch) in [("jul", Self.july), ("jan", Self.january)] {
            for h in hours {
                let m = Self.map(w, at: epoch + h * 3600, columnStride: 1)
                let width = ProceduralWeather.columns, height = ProceduralWeather.rows
                var image = RGBImage(width: width, height: 2 * height)
                for j in 0..<height {
                    for c in 0..<width {
                        let cv = m.cover(row: j, column: c)
                        let t = g.texel(row: j, column: c)
                        let ground = (20 + 70 * t.land, 40 + 60 * t.land, 90 - 50 * t.land)
                        let a = 1 - (1 - cv.low) * (1 - 0.8 * cv.mid) * (1 - 0.5 * cv.high)
                        func px(_ x: Double, _ cloud: Double) -> UInt8 { UInt8(min(max(x + a * (cloud - x), 0), 255)) }
                        image[c, j] = (px(ground.0, 235), px(ground.1, 235), px(ground.2, 240))
                        image[c, height + j] = (UInt8(cv.low * 255), UInt8(cv.mid * 255), UInt8(cv.high * 255))
                    }
                }
                try PNG.write(image, to: URL(fileURLWithPath: dir).appendingPathComponent("weather-\(seed)-\(name)-\(Int(h))h.png"))
            }
        }
    }

    /// `ORBITSIM_WEATHER_MAPS=<dir>`: the systems' templates in their own
    /// coordinates (u east, v poleward, ±3 sizes), low, mid and high as RGB.
    func testWriteTemplates() throws {
        guard let dir = ProcessInfo.processInfo.environment["ORBITSIM_WEATHER_MAPS"] else {
            throw XCTSkip("set ORBITSIM_WEATHER_MAPS to a folder to write the templates")
        }
        let n = 241
        var image = RGBImage(width: 5 * n, height: 2 * n)
        let f = ProceduralWeather.frame(latitude: 0.8, longitude: 0)
        for (k, stage) in [0.0, 0.3, 0.6, 1.0].enumerated() {
            let s = ProceduralWeather.System(kind: .cyclone, centre: f.centre, east: f.east, poleward: f.poleward,
                                             size: 1e6, reach: 1, intensity: 1, stage: stage, top: 8_000, tilt: 0,
                                             latitude: 0.8, longitude: 0, age: 0, life: 1)
            for y in 0..<n {
                for x in 0..<n {
                    let u = 6 * Double(x) / Double(n - 1) - 3, v = 3 - 6 * Double(y) / Double(n - 1)
                    let c = ProceduralWeather.cycloneTemplate(u: u, v: v, s, sea: 1)
                    func b(_ z: Double) -> UInt8 { UInt8(ProceduralWeather.cover(z - 1, gain: 3) * 255) }
                    image[k * n + x, y] = (b(c.low), b(c.mid), b(c.high))
                    image[k * n + x, n + y] = (UInt8(min(c.frontal, 1) * 255), UInt8(min(c.cells, 1) * 255),
                                               UInt8(min(c.deep, 1) * 255))
                }
            }
        }
        let t = ProceduralWeather.System(kind: .tropical, centre: f.centre, east: f.east, poleward: f.poleward,
                                         size: 1e6, reach: 1, intensity: 1, stage: 0, top: 14_000, tilt: 0,
                                         latitude: 0.8, longitude: 0, age: 0, life: 1)
        for y in 0..<n {
            for x in 0..<n {
                let u = 6 * Double(x) / Double(n - 1) - 3, v = 3 - 6 * Double(y) / Double(n - 1)
                let c = ProceduralWeather.tropicalTemplate(u: u, v: v, t, rough: 0)
                func b(_ z: Double) -> UInt8 { UInt8(ProceduralWeather.cover(z - 1, gain: 3) * 255) }
                image[4 * n + x, y] = (b(c.low), b(c.mid), b(c.high))
                let d = ProceduralWeather.clusterTemplate(u: u, v: v, t, land: 0, hour: 0, rough: 0)
                image[4 * n + x, n + y] = (b(d.low), b(d.mid), b(d.high))
            }
        }
        try PNG.write(image, to: URL(fileURLWithPath: dir).appendingPathComponent("templates.png"))
    }

    /// One node's cost, for the record (Debug's is the full gate's).
    func testNodeCost() {
        let w = ProceduralWeather(seed: 1)
        let state = w.state(at: Self.july)
        let g = WeatherGeography.earth
        let start = Date()
        var sum = 0.0
        for k in 0..<2_000 {
            let lat = ProceduralWeather.latitude(row: 40 + k % 280), lon = Double(k) * 0.01
            let n = ProceduralWeather.node(latitude: lat, longitude: lon, geography: g.texel(row: 40 + k % 280, column: k % 720),
                                           band: ProceduralWeather.band(latitude: lat, sky: state.sky), state: state)
            sum += n.low
        }
        print("ProceduralWeather.node: \(String(format: "%.1f", Date().timeIntervalSince(start) / 2_000 * 1e6)) µs (\(sum.isFinite))")
    }
}
