import Foundation
import XCTest

/// The rows of a tools/data CSV (comment lines dropped), by column name;
/// the test is skipped when the file is not there.
func toolsData(_ name: String) throws -> [[String: String]] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("tools/data/\(name)")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        throw XCTSkip("tools/data/\(name) not found")
    }
    let lines = text.split(separator: "\n").filter { !$0.hasPrefix("#") }
    let header = lines[0].split(separator: ",").map(String.init)
    return lines.dropFirst().map { line in
        var cells: [String] = [], cell = "", quoted = false
        for ch in line {
            if ch == "\"" {
                quoted.toggle()
            } else if ch == "," && !quoted {
                cells.append(cell)
                cell = ""
            } else {
                cell.append(ch)
            }
        }
        cells.append(cell)
        return Dictionary(uniqueKeysWithValues: zip(header, cells))
    }
}

extension Dictionary where Key == String, Value == String {
    /// The cell `column` as a number (nil when empty or not a number).
    func number(_ column: String) -> Double? { self[column].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } }
}
