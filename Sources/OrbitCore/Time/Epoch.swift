import Foundation

/// A point in time, stored as TDB seconds past J2000 (2000-01-01 12:00 TDB).
///
/// TDB is the time argument of the JPL ephemerides. UTC is converted via
/// TAI-UTC (leap seconds, and before 1972 the official rubber-second
/// expressions) and TT = TAI + 32.184 s; TDB is taken equal to TT (the
/// periodic difference is below 2 ms). UT1 is approximated by UTC.
public struct Epoch: Comparable, Hashable, Codable, CustomStringConvertible {
    public var tdb: Double

    public init(tdbSecondsPastJ2000 s: Double) { tdb = s }

    public static let j2000JD = 2451545.0
    public static let secondsPerDay = 86400.0

    public static func < (a: Epoch, b: Epoch) -> Bool { a.tdb < b.tdb }

    public static func + (e: Epoch, dt: Double) -> Epoch { Epoch(tdbSecondsPastJ2000: e.tdb + dt) }
    public static func - (a: Epoch, b: Epoch) -> Double { a.tdb - b.tdb }

    /// TDB Julian date.
    public var julianDateTDB: Double { Epoch.j2000JD + tdb / Epoch.secondsPerDay }

    /// Julian centuries of TDB past J2000.
    public var centuriesTDB: Double { tdb / (Epoch.secondsPerDay * 36525) }

    // MARK: UTC conversions

    /// Create from a UTC calendar date (Gregorian).
    public init(utcYear y: Int, month m: Int, day d: Int, hour h: Int = 0, minute mi: Int = 0, second s: Double = 0) {
        let jdUTC = Epoch.julianDay(year: y, month: m, day: d) + (Double(h) * 3600 + Double(mi) * 60 + s) / 86400
        self.init(julianDateUTC: jdUTC)
    }

    public init(julianDateUTC jd: Double) {
        let tt = Epoch.taiMinusUTC(julianDateUTC: jd) + 32.184
        tdb = (jd - Epoch.j2000JD) * Epoch.secondsPerDay + tt
    }

    /// UTC Julian date. The expression in force is the last one switched to,
    /// in TAI, at or before this instant (within 1e-9 day, so that rounding
    /// does not land a step's own label in the gap before it). A label the
    /// clock showed twice (it was set back by a step or a leap second) reads
    /// as shown the second time; `init(julianDateUTC:)` takes it as the first.
    public var julianDateUTC: Double {
        let tai = julianDateTDB - 32.184 / Epoch.secondsPerDay
        guard let s = Epoch.offsets.last(where: { tai >= $0.switchTAI - 1e-9 }) else {
            return tai - Epoch.offsets[0].seconds(Epoch.offsets[0].start) / Epoch.secondsPerDay
        }
        var jd = tai
        for _ in 0..<2 { jd = tai - s.seconds(jd) / Epoch.secondsPerDay }
        return jd
    }

    /// UT1 Julian date, approximated as UTC.
    public var julianDateUT1: Double { julianDateUTC }

    public struct Calendar: Equatable {
        public var year: Int, month: Int, day: Int, hour: Int, minute: Int
        public var second: Double
    }

    public var utc: Calendar {
        let jd = julianDateUTC + 0.5
        let z = floor(jd)
        let f = jd - z
        var a = z
        if z >= 2299161 {
            let alpha = floor((z - 1867216.25) / 36524.25)
            a = z + 1 + alpha - floor(alpha / 4)
        }
        let b = a + 1524
        let c = floor((b - 122.1) / 365.25)
        let d = floor(365.25 * c)
        let e = floor((b - d) / 30.6001)
        let day = Int(b - d - floor(30.6001 * e))
        let month = Int(e < 14 ? e - 1 : e - 13)
        let year = Int(month > 2 ? c - 4716 : c - 4715)
        var secs = f * 86400
        secs = (secs * 1000).rounded() / 1000
        let hour = Int(secs / 3600)
        let minute = Int((secs - Double(hour) * 3600) / 60)
        let second = secs - Double(hour) * 3600 - Double(minute) * 60
        return Calendar(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }

    public var description: String {
        let c = utc
        return String(format: "%04d-%02d-%02d %02d:%02d:%06.3f UTC", c.year, c.month, c.day, c.hour, c.minute, c.second)
    }

    /// Julian day number at 0h of a Gregorian calendar date (Meeus ch. 7).
    public static func julianDay(year: Int, month: Int, day: Int) -> Double {
        var y = year, m = month
        if m <= 2 { y -= 1; m += 12 }
        let a = y / 100
        let b = 2 - a + a / 4
        return floor(365.25 * Double(y + 4716)) + floor(30.6001 * Double(m + 1)) + Double(day) + Double(b) - 1524.5
    }

    // MARK: Leap seconds

    /// (UTC Julian date from which the value applies, TAI-UTC in seconds).
    private static let leapSeconds: [(Double, Double)] = [
        (2441317.5, 10), (2441499.5, 11), (2441683.5, 12), (2442048.5, 13), (2442413.5, 14),
        (2442778.5, 15), (2443144.5, 16), (2443509.5, 17), (2443874.5, 18), (2444239.5, 19),
        (2444786.5, 20), (2445151.5, 21), (2445516.5, 22), (2446247.5, 23), (2447161.5, 24),
        (2447892.5, 25), (2448257.5, 26), (2448804.5, 27), (2449169.5, 28), (2449534.5, 29),
        (2450083.5, 30), (2450630.5, 31), (2451179.5, 32), (2453736.5, 33), (2454832.5, 34),
        (2456109.5, 35), (2457204.5, 36), (2457754.5, 37),
    ]

    /// One expression of TAI-UTC: from the UTC Julian date `start`, offset +
    /// (MJD - mjd0) × rate seconds, with MJD the UTC modified Julian date.
    private struct Offset {
        let start: Double, offset: Double, mjd0: Double, rate: Double
        /// The TAI Julian date from which the expression gives the clock's
        /// reading. Set forward, the clock jumps to `start` when it is reached
        /// by this expression; set back, it returns to the labels before
        /// `start` when the previous expression reaches `start`.
        var switchTAI = 0.0

        init(start: Double, offset: Double, mjd0: Double = 0, rate: Double = 0) {
            self.start = start; self.offset = offset; self.mjd0 = mjd0; self.rate = rate
        }

        func seconds(_ jdUTC: Double) -> Double { offset + (jdUTC - 2400000.5 - mjd0) * rate }
    }

    /// TAI-UTC from 1960 (USNO tai-utc.dat, the table of SOFA/ERFA `dat`).
    /// Before 1972 UTC ran at a rate offset from the SI second ("rubber
    /// seconds") with steps of 0.05-0.1 s; since then the rate is 0 and the
    /// steps are leap seconds.
    private static let offsets: [Offset] = {
        let rubber: [(year: Int, month: Int, offset: Double, mjd0: Double, rate: Double)] = [
            (1960, 1, 1.4178180, 37300, 0.0012960), (1961, 1, 1.4228180, 37300, 0.0012960),
            (1961, 8, 1.3728180, 37300, 0.0012960), (1962, 1, 1.8458580, 37665, 0.0011232),
            (1963, 11, 1.9458580, 37665, 0.0011232), (1964, 1, 3.2401300, 38761, 0.0012960),
            (1964, 4, 3.3401300, 38761, 0.0012960), (1964, 9, 3.4401300, 38761, 0.0012960),
            (1965, 1, 3.5401300, 38761, 0.0012960), (1965, 3, 3.6401300, 38761, 0.0012960),
            (1965, 7, 3.7401300, 38761, 0.0012960), (1965, 9, 3.8401300, 38761, 0.0012960),
            (1966, 1, 4.3131700, 39126, 0.0025920), (1968, 2, 4.2131700, 39126, 0.0025920),
        ]
        var all = rubber.map {
            Offset(start: julianDay(year: $0.year, month: $0.month, day: 1), offset: $0.offset, mjd0: $0.mjd0, rate: $0.rate)
        } + leapSeconds.map { Offset(start: $0.0, offset: $0.1) }
        for i in all.indices {
            let s = all[i], own = s.seconds(s.start)
            let previous = i > 0 ? all[i - 1].seconds(s.start) : own
            all[i].switchTAI = s.start + min(own, previous) / Epoch.secondsPerDay
        }
        return all
    }()

    /// TAI-UTC (s) at a UTC Julian date. Before 1960, when there was no UTC,
    /// the value at 1960-01-01 is held.
    public static func taiMinusUTC(julianDateUTC jd: Double) -> Double {
        guard let s = offsets.last(where: { jd >= $0.start }) else { return offsets[0].seconds(offsets[0].start) }
        return s.seconds(jd)
    }
}
