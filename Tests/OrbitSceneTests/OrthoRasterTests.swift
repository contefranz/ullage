import Foundation
import XCTest
@testable import OrbitCore

/// The ortho gallery's machinery (Support/OrthoRaster.swift, PNG.swift):
/// the PNG codec against zlib's and Pillow's output, the views' axes
/// against the Positions, the drawn outline against `Silhouette`, the
/// paint hook and the crops.
final class OrthoRasterTests: XCTestCase {
    static let stack = VesselLibrary.saturnV()
    static let stackScene = OrthoScene(stack)

    func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    // MARK: PNG

    func testChecksumsGiveTheirCheckValues() {
        XCTAssertEqual(PNG.crc32(Array("123456789".utf8)), 0xCBF4_3926)    // CRC-32's catalogued check value
        XCTAssertEqual(PNG.crc32(Array("IEND".utf8)), 0xAE42_6082)         // every PNG's last four bytes
        XCTAssertEqual(PNG.adler32(Array("Wikipedia".utf8)), 0x11E6_0398)  // the usual worked example
        XCTAssertEqual(PNG.adler32([]), 1)
    }

    /// A 2×1 PNG written by Python's zlib at level 0 (stored blocks) and
    /// `struct`, which Pillow reads: the encoder writes it byte for byte.
    func testEncoderWritesWhatZlibLevel0Writes() throws {
        var image = RGBImage(width: 2, height: 1)
        image[0, 0] = (255, 0, 0)
        image[1, 0] = (0, 128, 255)
        let reference = bytes("89504e470d0a1a0a0000000d49484452000000020000000108020000007b40e8dd0000001249444154"
                              + "7801010700f8ff00ff00000080ff0800027fd5706eaa0000000049454e44ae426082")
        XCTAssertEqual(PNG.encode(image), reference)
        XCTAssertEqual(try PNG.decode(reference), image)
    }

    /// A 3×5 RGBA PNG from Python's zlib whose rows use filters 0-4 in
    /// turn; the pixels are Pillow's reading of it.
    func testDecoderUndoesEveryFilter() throws {
        let png = bytes("89504e470d0a1a0a0000000d4948445200000003000000050806000000807156a20000004c49444154"
                        + "7801014100beff0000030c1b75788190eaedf605017b7e8796752ee7a0752ee7a0027b7b7b7b7b34eda67bed5f"
                        + "d103f6f87c84786adcce784795e4047b7b7b7b75d43d217bed5f21d33c1f62e4148b350000000049454e44ae426082")
        let pillow: [(UInt8, UInt8, UInt8)] = [
            (0, 3, 12), (117, 120, 129), (234, 237, 246), (123, 126, 135), (240, 172, 110), (101, 218, 85),
            (246, 249, 2), (107, 224, 91), (224, 199, 180), (113, 116, 125), (230, 20, 72), (91, 180, 19),
            (236, 239, 248), (97, 72, 53), (214, 161, 114),
        ]
        let image = try PNG.decode(png)
        XCTAssertEqual(image.width, 3)
        XCTAssertEqual(image.height, 5)
        for (i, p) in pillow.enumerated() {
            let q = image[i % 3, i / 3]
            XCTAssertTrue(q == p, "pixel \(i): \(q) against \(p)")
        }
    }

    /// More than one stored block's worth round-trips; a flipped bit is caught.
    func testRoundTripAcrossStoredBlocks() throws {
        var image = RGBImage(width: 200, height: 150)
        var seed: UInt32 = 12345
        for i in image.bytes.indices {
            seed = seed &* 1_103_515_245 &+ 12345
            image.bytes[i] = UInt8(truncatingIfNeeded: seed >> 16)
        }
        let png = PNG.encode(image)
        XCTAssertGreaterThan(image.bytes.count, PNG.storedBlockLimit)
        XCTAssertEqual(try PNG.decode(png), image)

        var damaged = png
        damaged[damaged.count / 2] ^= 0x10
        XCTAssertThrowsError(try PNG.decode(damaged)) { error in
            XCTAssertEqual(error as? PNG.DecodeError, .badCRC("IDAT"))
        }
        XCTAssertThrowsError(try PNG.decode(Array(png.prefix(100))))
    }

    // MARK: Views

    func testViewsFollowThePositions() {
        // Right, top, left, bottom, facing.
        let expected: [(OrthoView.Direction, [Int?])] = [
            (.side(azimuth: 0), [2, nil, 4, nil, 1]),
            (.side(azimuth: Double.pi / 2), [3, nil, 1, nil, 2]),
            (.side(azimuth: Double.pi), [4, nil, 2, nil, 3]),
            (.side(azimuth: 3 * Double.pi / 2), [1, nil, 3, nil, 4]),
            (.side(azimuth: Double.pi / 4), [nil, nil, nil, nil, nil]),
            (.top, [2, 3, 4, 1, nil]),
            (.bottom, [4, 3, 2, 1, nil]),
        ]
        for (direction, positions) in expected {
            let view = OrthoView(direction, scale: 1)
            let l = view.positionLabels
            XCTAssertEqual([l.right, l.top, l.left, l.bottom, l.facing], positions, "\(direction)")
            let b = view.basis
            XCTAssertEqual((b.right.cross(b.up) - b.towards).length, 0, accuracy: 1e-15, "\(direction)")
            XCTAssertEqual(b.right.dot(b.up), 0, accuracy: 1e-15)
        }
        for n in 1...4 {
            XCTAssertEqual(OrthoView.position(n, scale: 1).positionLabels.facing, n)
        }
    }

    /// A marker box at Position II on a cylinder lands where each view's
    /// labels say Position II is.
    func testMarkerAtPositionIILandsWhereTheViewsSay() throws {
        let body = VisualShape.frustum(from: .zero, length: 4, baseRadius: 1, topRadius: 1, color: (0.9, 0.9, 0.9))
        let marker = VisualShape.box(from: Vec3(1.5, -1.25, 0), length: 1, width: 0.5, height: 0.5,
                                     color: (0.9, 0.1, 0.1))
        let scene = OrthoScene(shapes: [body, marker])
        /// The marker's mean pixel, as fractions of the image (0 left/top, 1 right/bottom).
        func where_(_ view: OrthoView) throws -> (x: Double, y: Double) {
            let image = OrthoRaster.render(scene, view, style: .albedo)
            var sx = 0.0, sy = 0.0, n = 0.0
            for y in 0..<image.height {
                for x in 0..<image.width where image.surface(x, y) == 1 {
                    sx += Double(x) + 0.5
                    sy += Double(y) + 0.5
                    n += 1
                }
            }
            XCTAssertGreaterThan(n, 0, "the marker is seen")
            return (sx / n / Double(image.width), sy / n / Double(image.height))
        }
        XCTAssertGreaterThan(try where_(.position(1, scale: 40)).x, 0.75)      // II on the right
        XCTAssertEqual(try where_(.position(2, scale: 40)).x, 0.5, accuracy: 0.02)   // facing
        XCTAssertLessThan(try where_(.position(3, scale: 40)).x, 0.25)         // II on the left
        XCTAssertGreaterThan(try where_(OrthoView(.top, scale: 40)).x, 0.75)
        XCTAssertEqual(try where_(OrthoView(.top, scale: 40)).y, 0.5, accuracy: 0.02)
        XCTAssertLessThan(try where_(OrthoView(.bottom, scale: 40)).x, 0.25)
        // From IV the marker is behind the body.
        let hidden = OrthoRaster.render(scene, .position(4, scale: 40), style: .albedo)
        XCTAssertFalse(hidden.surfaces.contains(1))
    }

    // MARK: The drawn outline against the silhouette

    /// Row by row, a side view's outline is the silhouette's radius towards
    /// the view's right and left, to within a pixel; a section's from above,
    /// the largest radius over its stations.
    func testDrawnOutlineIsTheSilhouette() {
        let silhouette = Silhouette(Self.stackScene)
        let k = 40.0
        let band = AS506.station(2700)...AS506.station(2900)   // the S-IVB's aft skirt, APS modules and ullage rockets
        for n in [1, 2] {
            let image = OrthoRaster.render(Self.stackScene, .position(n, scale: k, stations: band),
                                           style: OrthoStyle(lighting: .albedo, outlines: false, annotations: false))
            let azimuth = Double(n - 1) * Double.pi / 2
            var rows = 0
            for y in 0..<image.height {
                let covered = (0..<image.width).filter { image.surface($0, y) != nil }
                guard let first = covered.first, let last = covered.last else { continue }
                let x = image.screen(0, y).up
                guard let right = silhouette.radius(at: x, azimuth: azimuth + Double.pi / 2),
                      let left = silhouette.radius(at: x, azimuth: azimuth - Double.pi / 2) else { continue }
                XCTAssertEqual(image.screen(last, y).right, right, accuracy: 1 / k, "Position \(n), row \(y)")
                XCTAssertEqual(-image.screen(first, y).right, left, accuracy: 1 / k, "Position \(n), row \(y)")
                rows += 1
            }
            XCTAssertGreaterThan(rows, 190)
        }

        let top = OrthoRaster.render(Self.stackScene, OrthoView(.top, scale: k, stations: band),
                                     style: OrthoStyle(lighting: .albedo, outlines: false, annotations: false))
        var xs: [Int] = [], ys: [Int] = []
        for y in 0..<top.height {
            for x in 0..<top.width where top.surface(x, y) != nil {
                xs.append(x)
                ys.append(y)
            }
        }
        let (minX, maxX, minY, maxY) = (xs.min()!, xs.max()!, ys.min()!, ys.max()!)
        // Right is Position II, up Position III, left IV, down I.
        let expected: [(Double, Double)] = [
            (top.screen(maxX, 0).right, silhouette.radius(over: band, azimuth: Double.pi / 2)!),
            (top.screen(0, minY).up, silhouette.radius(over: band, azimuth: Double.pi)!),
            (-top.screen(minX, 0).right, silhouette.radius(over: band, azimuth: 3 * Double.pi / 2)!),
            (-top.screen(0, maxY).up, silhouette.radius(over: band, azimuth: 0)!),
        ]
        for (drawn, measured) in expected { XCTAssertEqual(drawn, measured, accuracy: 1 / k) }
    }

    // MARK: Paint and crops

    /// The default paint is the shape's colour; the hook sees the vehicle
    /// frame's azimuth across the S-IVB's skin.
    func testPaintHookAndDefaultColour() throws {
        let band = AS506.station(2900)...AS506.station(3100)
        let view = OrthoView.position(1, scale: 40, stations: band)
        let plain = OrthoRaster.render(Self.stackScene, view, style: .albedo)
        let cx = plain.width / 2, cy = plain.height / 2
        let skin = Self.stackScene.surfaces[try XCTUnwrap(plain.surface(cx, cy))].shape
        XCTAssertEqual(skin.material, .apolloWhitePaint)
        let c = skin.color
        XCTAssertTrue(plain.image[cx, cy] == (OrthoRaster.srgb(c.0), OrthoRaster.srgb(c.1), OrthoRaster.srgb(c.2)))

        // Red facing Position I, blue elsewhere, from the interpolated v.
        let painted = OrthoRaster.render(Self.stackScene, view, style: .albedo) { f in
            cos(f.surface.v) > 0.9 ? (1, 0, 0) : (0, 0, 1)
        }
        XCTAssertTrue(painted.image[cx, cy] == (255, 0, 0))
        let covered = (0..<painted.width).filter { painted.surface($0, cy) != nil }
        let edge = try XCTUnwrap(covered.last) - 2
        XCTAssertTrue(painted.image[edge, cy] == (0, 0, 255))
    }

    /// A side view's crop sets the window; a section from above drops what
    /// lies above it.
    func testCropsAndSections() throws {
        let band = AS506.station(2450)...AS506.station(2900)
        let style = OrthoStyle(lighting: .albedo, outlines: false, annotations: false, margin: 5)
        let crop = OrthoRaster.render(Self.stackScene, .position(1, scale: 20, stations: band), style: style)
        XCTAssertEqual(crop.height, Int(((band.upperBound - band.lowerBound) * 20 + 10).rounded(.up)))
        XCTAssertEqual(crop.screen(0, 0).up, band.upperBound + 4.5 / 20, accuracy: 1e-9)

        // From above, the whole stack shows the LES's nose at the centre;
        // cut below the gimbal plane, only the five F-1 bells.
        let whole = OrthoRaster.render(Self.stackScene, OrthoView(.top, scale: 20), style: style)
        let nose = Self.stackScene.surfaces[try XCTUnwrap(whole.surface(whole.width / 2, whole.height / 2))]
        XCTAssertEqual(nose.part?.name, "LES")
        let engines = OrthoRaster.render(Self.stackScene, OrthoView(.top, scale: 20, stations: AS506.station(-120)...AS506.station(90)),
                                         style: style)
        let seen = Set(engines.surfaces.filter { $0 >= 0 }).map { Self.stackScene.surfaces[Int($0)] }
        XCTAssertEqual(seen.count, 5)
        for s in seen {
            XCTAssertEqual(s.part?.name, "S-IC")
            XCTAssertEqual(s.shape.material, .apolloEngineBell)
            XCTAssertNotNil(s.shape.thruster)
        }
    }
}
