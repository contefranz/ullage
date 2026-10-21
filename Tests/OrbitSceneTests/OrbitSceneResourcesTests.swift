import XCTest
@testable import OrbitScene

final class OrbitSceneResourcesTests: XCTestCase {
    /// The resource folder is bundled, on Linux as on the Mac.
    func testResourceFolderIsBundled() throws {
        let url = try XCTUnwrap(OrbitSceneResources.url("README.md"))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("OrbitSceneResources"))
        XCTAssertNil(OrbitSceneResources.url("no-such-file.bin"))
    }
}
