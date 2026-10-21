import Metal
import XCTest
@testable import OrbitRender

final class RenderDeviceTests: XCTestCase {
    /// The renderer's tests need a Metal device; every Apple-silicon Mac has one.
    func testMetalDeviceIsAvailable() throws {
        let device = try XCTUnwrap(RenderDevice.shared, "no Metal device")
        XCTAssertTrue(device.supportsTextureSampleCount(4))
    }
}
