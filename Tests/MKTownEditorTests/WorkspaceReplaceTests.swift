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

    func testLegacyAndUTF16SearchAndReplaceKeepOriginalBytesAndLineEndings() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("shift-jis.md")
        let utf16 = root.appendingPathComponent("utf16.md")
        let original = "# 日本語\r\n本文を検索\n"
        let edited = "# 日本語\r\n本文を置換\n"
        let bom = Data([0xFF, 0xFE])
        try XCTUnwrap(original.data(using: .shiftJIS)).write(to: legacy)
        try (bom + XCTUnwrap(original.data(using: .utf16LittleEndian))).write(to: utf16)

        let options = WorkspaceSearchOptions(query: "検索")
        let results = try WorkspaceSearch.report(root: root, options: options)
        XCTAssertEqual(results.results.map(\.line), [2, 2])
        XCTAssertTrue(results.skippedDocuments.isEmpty)
        let plan = try WorkspaceReplace.plan(root: root, options: options, replacement: "置換")
        try plan.apply(selectedURLs: [legacy, utf16], openDocuments: [])
        XCTAssertEqual(try Data(contentsOf: legacy), try XCTUnwrap(edited.data(using: .shiftJIS)))
        XCTAssertEqual(try Data(contentsOf: utf16), try bom + XCTUnwrap(edited.data(using: .utf16LittleEndian)))
    }

    func testUnrepresentableReplacementFailsBeforeWritingAnyFiles() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let unicode = root.appendingPathComponent("a.md")
        let legacy = root.appendingPathComponent("b.md")
        let text = "日本語の原稿"
        let bytes = try XCTUnwrap(text.data(using: .shiftJIS))
        try Data(text.utf8).write(to: unicode)
        try bytes.write(to: legacy)
        XCTAssertThrowsError(try WorkspaceReplace.plan(root: root,
            options: WorkspaceSearchOptions(query: "原稿"), replacement: "😀")) { error in
            guard case let .unrepresentableText(url, encoding, line)? = error as? WorkspaceFileOperationError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(url.lastPathComponent, "b.md")
            XCTAssertEqual(encoding, .shiftJIS)
            XCTAssertEqual(line, 1)
        }
        XCTAssertEqual(try Data(contentsOf: legacy), bytes)
        XCTAssertEqual(try Data(contentsOf: unicode), Data(text.utf8))
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
