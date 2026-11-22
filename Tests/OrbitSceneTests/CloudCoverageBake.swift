import Foundation
import XCTest
@testable import OrbitScene

/// Prints CloudCoverageTables.swift's tables (C2_BAKE_COVERAGE=1): the
/// statistics over every second texel across and every 16th up.
final class CloudCoverageBake: XCTestCase {
    func testBake() throws {
        guard ProcessInfo.processInfo.environment["C2_BAKE_COVERAGE"] != nil else { throw XCTSkip("set C2_BAKE_COVERAGE=1") }
        let start = Date()
        let st = CloudCoverage.statistics(step: 2, stepUp: 16)
        func row(_ t: [Double]) -> String {
            stride(from: 0, to: t.count, by: 6).map { i in
                "        " + t[i..<min(i + 6, t.count)].map { String(format: "%.6f", $0) }.joined(separator: ", ")
            }.joined(separator: ",\n")
        }
        print("BAKE-BEGIN")
        print("densityScale low\n\(row(st.densityScale[0]))")
        print("densityScale mid\n\(row(st.densityScale[1]))")
        print("cirrusThreshold\n\(row(st.cirrusThreshold))")
        print("cirrusScale\n\(row(st.cirrusScale))")
        print("columnDepth low\n\(row(st.columnDepth[0]))")
        print("columnDepth mid\n\(row(st.columnDepth[1]))")
        print("BAKE-END \(Date().timeIntervalSince(start)) s")
    }
}
