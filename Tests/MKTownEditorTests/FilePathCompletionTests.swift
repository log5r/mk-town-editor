import Foundation
import XCTest
@testable import MKTownEditor

final class FilePathCompletionTests: XCTestCase {
    func testScansCurrentFolderWithoutHiddenFilesOrSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("notes"),
                                                withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("notes/first draft.md"))
        try Data().write(to: root.appendingPathComponent(".hidden.md"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside.md"),
                                                   withDestinationURL: URL(fileURLWithPath: "/tmp/outside.md"))


        let candidates = FilePathCompletion.scan(in: root)
        XCTAssertEqual(candidates.map(\.path), ["notes/", "notes/first draft.md"])
        XCTAssertEqual(FilePathCompletion.matches("draft", in: candidates).map(\.path),
                       ["notes/first draft.md"])
        let file = try XCTUnwrap(candidates.first { !$0.isDirectory })
        XCTAssertEqual(MarkdownLinkSyntax.makeLink(label: "次", destination: file.path),
                       "[次](notes/first%20draft.md)")
    }

    func testQueriesRejectExternalAndAbsolutePathsAndRespectLimit() {
        let candidates = [FilePathSuggestion(path: "a.md", isDirectory: false),
                          FilePathSuggestion(path: "b.md", isDirectory: false)]
        XCTAssertTrue(FilePathCompletion.matches("https://example.com", in: candidates).isEmpty)
        XCTAssertTrue(FilePathCompletion.matches("/tmp", in: candidates).isEmpty)
        XCTAssertTrue(FilePathCompletion.matches("#heading", in: candidates).isEmpty)
        XCTAssertEqual(FilePathCompletion.matches(".md", in: candidates, limit: 1).map(\.path), ["a.md"])
    }
}
