import Foundation
import XCTest
@testable import MKTownEditor

final class WorkspaceSearchTests: XCTestCase {
    func testSearchAcrossFilesWithIncludeExcludeAndUnicodeLocations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archived = root.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        try "# 題名\r\n🙂 apple\r\nAPPLE".write(to: root.appendingPathComponent("a.md"),
                                              atomically: true, encoding: .utf8)
        try "apple".write(to: archived.appendingPathComponent("old.md"),
                          atomically: true, encoding: .utf8)
        try "apple".write(to: root.appendingPathComponent("notes.txt"),
                          atomically: true, encoding: .utf8)
        let options = WorkspaceSearchOptions(query: "apple", includePatterns: ["*.md"],
                                              excludePatterns: ["archive/*"])
        let results = try WorkspaceSearch.search(root: root, options: options)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.map(\.relativePath), ["a.md", "a.md"])
        XCTAssertEqual(results.map(\.line), [2, 3])
        XCTAssertEqual(results[0].sourceRange.location, ("# 題名\n🙂 " as NSString).length)
        XCTAssertEqual(results[0].excerpt, "🙂 apple")
        XCTAssertEqual(try WorkspaceSearch.search(root: root, options: WorkspaceSearchOptions(
            query: "APPLE", includePatterns: ["*.md"], excludePatterns: ["archive/*"],
            caseSensitive: true)).count, 1)
    }

    func testSearchCanMatchAcrossNewlineAndLimitResults() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "first\nsecond\nfirst\nsecond".write(
            to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        let results = try WorkspaceSearch.search(root: root,
            options: WorkspaceSearchOptions(query: "first\nsecond"), maximumResults: 1)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].line, 1)
        XCTAssertEqual(results[0].sourceRange.length, ("first\nsecond" as NSString).length)
    }
}
