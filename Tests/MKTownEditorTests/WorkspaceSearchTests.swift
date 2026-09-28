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

    func testStructuralScopeSeparatesHeadingBodyAndCode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = "# target\n\nbody target\n\n> quoted target\n\n```swift\ntarget\n```\n"
        try source.write(to: root.appendingPathComponent("structure.md"),
                         atomically: true, encoding: .utf8)
        func search(_ scope: WorkspaceSearchScope) throws -> [WorkspaceSearchResult] {
            try WorkspaceSearch.search(root: root,
                options: WorkspaceSearchOptions(query: "target", scope: scope))
        }
        XCTAssertEqual(try search(.all).count, 4)
        XCTAssertEqual(try search(.headings).map(\.line), [1])
        XCTAssertEqual(try search(.body).map(\.line), [3, 5])
        XCTAssertEqual(try search(.code).map(\.line), [8])
    }
}
