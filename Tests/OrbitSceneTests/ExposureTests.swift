import Foundation
import XCTest
@testable import OrbitScene

/// The camera's exposure (track R1): Lagarde and de Rousiers (2014) §5.1,
/// photographers' rules, the histogram and the adaptation.
final class ExposureTests: XCTestCase {
    /// EV100 = log₂(L S/K) with K = 12.5, and the saturating luminance 1.2 · 2^EV100.
    func testEV100AndLuminance() {
        XCTAssertEqual(Exposure.averageLuminance(ev100: 0), 0.125, accuracy: 1e-12)
        XCTAssertEqual(Exposure.ev100(averageLuminance: 0.125), 0, accuracy: 1e-12)
        XCTAssertEqual(Exposure.ev100(averageLuminance: Exposure.averageLuminance(ev100: 13.7)), 13.7, accuracy: 1e-12)
        XCTAssertEqual(Exposure.maxLuminance(ev100: 10), 1.2 * 1_024, accuracy: 1e-9)
        XCTAssertEqual(Exposure.exposure(ev100: 10) * Exposure.maxLuminance(ev100: 10), 1, accuracy: 1e-12)
        // f/1 at 1 s and ISO 100 is EV 0; each stop of aperture or shutter adds one.
        XCTAssertEqual(Exposure.ev100(aperture: 1, shutter: 1, iso: 100), 0, accuracy: 1e-12)
        XCTAssertEqual(Exposure.ev100(aperture: 2, shutter: 1, iso: 100), 2, accuracy: 1e-12)
        XCTAssertEqual(Exposure.ev100(aperture: 1, shutter: 0.5, iso: 200), 0, accuracy: 1e-12)
    }

    /// "Sunny 16": f/16 at 1/100 s on ISO 100 film is EV 14.6, and a meter
    /// on an 18 % grey card facing the Sun gives EV ≈ 15; at EV 15 sunlit
    /// white paint (albedo 0.8) reads 0.86 of saturation, short of clipping.
    func testSunny16() {
        XCTAssertEqual(Exposure.ev100(aperture: 16, shutter: 1.0 / 100, iso: 100), 14.64, accuracy: 0.01)
        let sun = Photometry.solarIlluminanceAt1AU
        let grey = 0.18 * sun / .pi
        XCTAssertEqual(Exposure.ev100(averageLuminance: grey), 15, accuracy: 1)
        let paint = 0.8 * sun / .pi
        XCTAssertEqual(paint * Exposure.exposure(ev100: 15), 0.86, accuracy: 0.01)
    }

    /// The photo mode's default is the Earthrise frame's f/11, 1/250 s,
    /// ISO 64 (AS08-14-2383): EV100 15.5.
    func testHasselbladPhotoMode() {
        var s = ExposureSettings(mode: .photo)
        XCTAssertEqual(try XCTUnwrap(s.fixedEV100), 15.53, accuracy: 0.01)
        s.mode = .manual
        s.ev100 = 9
        XCTAssertEqual(s.fixedEV100, 9)
        s.mode = .auto
        XCTAssertNil(s.fixedEV100)
    }

    /// A uniform image targets its own EV within half a bin.
    func testHistogramOfAUniformImage() throws {
        for l in [0.05, 3.0, 400, 33_000] {
            var h = LuminanceHistogram()
            h.add(luminance: l, weight: 1_000)
            let ev = try XCTUnwrap(h.meanEV100(low: 0.5, high: 0.95))
            XCTAssertEqual(ev, Exposure.ev100(averageLuminance: l), accuracy: LuminanceHistogram.binWidth / 2 + 1e-9)
            XCTAssertEqual(h.coverage, 1)
        }
    }

    /// The 50th-95th percentile band: the darker half and the brightest
    /// 5 % are left out, and pixels too dark to count (black space) do not
    /// drag the exposure down.
    func testHistogramPercentiles() throws {
        var h = LuminanceHistogram()
        h.add(luminance: 1, weight: 50)            // the darker half
        h.add(luminance: 1_000, weight: 45)        // the band
        h.add(luminance: 1e9, weight: 5)           // the Sun, above the range: the last bin
        let ev = try XCTUnwrap(h.meanEV100(low: 0.5, high: 0.95))
        XCTAssertEqual(ev, Exposure.ev100(averageLuminance: 1_000), accuracy: LuminanceHistogram.binWidth)
        XCTAssertEqual(LuminanceHistogram.bin(luminance: 1e9), LuminanceHistogram.binCount - 1)
        XCTAssertNil(LuminanceHistogram.bin(luminance: 1e-4))

        // A lit vessel on 70 % black space is exposed for the vessel.
        var space = LuminanceHistogram()
        space.add(luminance: 0, weight: 70)
        space.add(luminance: 10_000, weight: 30)
        XCTAssertEqual(space.coverage, 0.3, accuracy: 1e-12)
        let auto = AutoExposure()
        XCTAssertEqual(try XCTUnwrap(auto.target(space)), Exposure.ev100(averageLuminance: 10_000),
                       accuracy: LuminanceHistogram.binWidth)

        // A glowing heat shield (3 %) over the dimly lit night side: the
        // highlights set the exposure, the brightest 1 % at 2× saturation.
        var glow = LuminanceHistogram()
        glow.add(luminance: 17.5, weight: 97)
        glow.add(luminance: 2e5, weight: 3)
        let t = try XCTUnwrap(auto.target(glow, compensation: 1.5))
        XCTAssertEqual(2e5 * Exposure.exposure(ev100: t), 2, accuracy: 2 * 0.1, "within a bin")
        XCTAssertEqual(try XCTUnwrap(glow.quantileEV100(0.5)), Exposure.ev100(averageLuminance: 17.5),
                       accuracy: LuminanceHistogram.binWidth)
        // Compensation moves the mean but not the highlights' limit.
        XCTAssertEqual(try XCTUnwrap(auto.target(space, compensation: 1)), try XCTUnwrap(auto.target(space)) - 1,
                       accuracy: 1e-9)

        // Stars alone on black: the target slides to the dark EV.
        var stars = LuminanceHistogram()
        stars.add(luminance: 0, weight: 9_990)
        stars.add(luminance: 50, weight: 10)
        XCTAssertLessThan(try XCTUnwrap(auto.target(stars)), 0)
        XCTAssertNil(auto.target(LuminanceHistogram()))
    }

    /// The camera follows the target at most 2 EV/s up and 1 EV/s down,
    /// settles within ±0.1 EV in under 5 s after a 4-stop change either
    /// way, snaps on its first update, and stays in its range.
    func testAdaptation() throws {
        var a = AutoExposure()
        a.update(target: 12, dt: 0.016)
        XCTAssertEqual(a.ev100, 12, "the first update snaps")
        a.update(target: 20, dt: 0.5)
        XCTAssertEqual(try XCTUnwrap(a.ev100), 13, accuracy: 1e-12, "brighter: 2 EV/s")
        a = AutoExposure(ev100: 12)
        a.update(target: 4, dt: 0.5)
        XCTAssertEqual(try XCTUnwrap(a.ev100), 11.5, accuracy: 1e-12, "darker: 1 EV/s")

        for (from, to) in [(12.0, 8.0), (8.0, 12.0)] {
            var e = AutoExposure(ev100: from)
            var t = 0.0
            while t < 5 {
                e.update(target: to, dt: 1.0 / 60)
                t += 1.0 / 60
            }
            XCTAssertEqual(try XCTUnwrap(e.ev100), to, accuracy: 0.1, "\(from) to \(to) in 5 s")
        }

        var c = AutoExposure(ev100: 10)
        c.update(target: 30, dt: 100)
        XCTAssertEqual(c.ev100, 17, "the range's top")
        c.update(target: 3, dt: 0.1, snap: true)
        XCTAssertEqual(c.ev100, 3)
        c.reset()
        XCTAssertNil(c.ev100)
    }

    /// Settings decode with any member left out.
    func testSettingsDecodePartially() throws {
        let s = try JSONDecoder().decode(PostSettings.self, from: Data(#"{"exposure": {"mode": "manual", "ev100": 0}}"#.utf8))
        XCTAssertEqual(s.exposure.mode, .manual)
        XCTAssertEqual(s.exposure.fixedEV100, 0)
        XCTAssertEqual(s.toneCurve, .agx)
        XCTAssertEqual(s.bloom, 0.03)
        let r = try JSONDecoder().decode(RenderSettings.self, from: Data(#"{"post": {"toneCurve": "neutral"}}"#.utf8))
        XCTAssertEqual(r.post.toneCurve, .neutral)
        XCTAssertEqual(r.post.exposure, ExposureSettings())
    }
}
