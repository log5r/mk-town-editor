import Foundation
import XCTest
@testable import MKTownEditor

final class WorkspaceReplaceTests: XCTestCase {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testSelectedFilesReplaceAndKeepNewlineAndBOM() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.md")
        let b = root.appendingPathComponent("b.md")
        let original = Data([0xEF, 0xBB, 0xBF]) + Data("Foo\r\nfoo".utf8)
        try original.write(to: a)
        try Data("foo".utf8).write(to: b)
        let plan = try WorkspaceReplace.plan(root: root,
            options: WorkspaceSearchOptions(query: "foo"), replacement: "bar")
        XCTAssertEqual(plan.matchCount, 3)
        XCTAssertTrue(plan.changes.first { $0.relativePath == "a.md" }?.previews.first?.before
            .contains("Foo") == true)
        XCTAssertTrue(plan.changes.first { $0.relativePath == "a.md" }?.previews.first?.after
            .contains("bar") == true)
        try plan.apply(selectedURLs: [a], openDocuments: [])
        XCTAssertEqual(try Data(contentsOf: a),
                       Data([0xEF, 0xBB, 0xBF]) + Data("bar\r\nbar".utf8))
        XCTAssertEqual(try Data(contentsOf: b), Data("foo".utf8))
    }

    func testExternalChangeOrOpenDocumentStopsBeforeAnyWrite() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.md")
        let b = root.appendingPathComponent("b.md")
        try "foo".write(to: a, atomically: true, encoding: .utf8)
        try "foo".write(to: b, atomically: true, encoding: .utf8)
        let plan = try WorkspaceReplace.plan(root: root,
            options: WorkspaceSearchOptions(query: "foo"), replacement: "bar")
        XCTAssertThrowsError(try plan.apply(selectedURLs: [a, b], openDocuments: [a]))
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "foo")
        try "changed".write(to: b, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try plan.apply(selectedURLs: [a, b], openDocuments: []))
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "foo")
    }

    func testMidWriteFailureRestoresEveryTouchedFile() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.md")
        let b = root.appendingPathComponent("b.md")
        try "foo a".write(to: a, atomically: true, encoding: .utf8)
        try "foo b".write(to: b, atomically: true, encoding: .utf8)
        let plan = try WorkspaceReplace.plan(root: root,
            options: WorkspaceSearchOptions(query: "foo"), replacement: "bar")
        var writes = 0
        XCTAssertThrowsError(try plan.apply(selectedURLs: [a, b], openDocuments: []) { data, url in
            try data.write(to: url, options: .atomic)
            writes += 1
            if writes == 2 { throw CocoaError(.fileWriteUnknown) }
        })
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "foo a")
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "foo b")
    }

    func testStructuralScopeLimitsReplacementToCodeBlocks() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("scope.md")
        try "# token\n\ntext token\n\n```\ntoken\n```".write(
            to: file, atomically: true, encoding: .utf8)
        let plan = try WorkspaceReplace.plan(root: root,
            options: WorkspaceSearchOptions(query: "token", scope: .code), replacement: "changed")
        XCTAssertEqual(plan.matchCount, 1)
        try plan.apply(selectedURLs: [file], openDocuments: [])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8),
                       "# token\n\ntext token\n\n```\nchanged\n```")
    }
}
