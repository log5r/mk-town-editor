import Foundation
import XCTest
@testable import MKTownEditor

final class WorkspaceTagsTests: XCTestCase {
    func testInlineAndFrontMatterTagsExcludeHeadingsCodeAndDestinations() {
        let source = """
        ---
        tags: [Swift, "日本語"]
        ---
        # Heading
        本文 #Work #日本語/技術 `#inline`
        ```md
        #fenced
        ```
        [label](#destination) https://example.com/#remote
        """
        XCTAssertEqual(MarkdownTags.inDocument(source),
                       Set(["swift", "日本語", "work", "日本語/技術"]))
    }

    func testFrontMatterBlockListAndCaseInsensitiveDeduplication() {
        let source = "---\ntags:\n  - \"#Swift\"\n  - '日本語'\n  - swift\nother: value\n---\n#SWIFT"
        XCTAssertEqual(MarkdownTags.inDocument(source), Set(["swift", "日本語"]))
        XCTAssertEqual(MarkdownTags.inDocument("---\ntags: [alpha, beta # note]\n---\n"),
                       Set(["alpha", "beta"]))
    }

    func testWorkspaceIndexUsesUnsavedBufferAndFiltersDocumentsByTag() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mktown-tags-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.md")
        let second = root.appendingPathComponent("second.md")
        try "#old".write(to: first, atomically: true, encoding: .utf8)
        try "#shared".write(to: second, atomically: true, encoding: .utf8)
        let nodes = WorkspaceFileIndex.scan(root: root).nodes
        let buffer = try XCTUnwrap("#shared #new".data(using: .utf8))

        let index = try WorkspaceTagIndex.scan(root: root, nodes: nodes,
            openBuffers: [first.resolvingSymlinksInPath().standardizedFileURL: buffer])

        XCTAssertEqual(index.tags, ["new", "shared"])
        XCTAssertEqual(Set(index.documents(for: "shared").map(\.relativePath)),
                       Set(["first.md", "second.md"]))
        XCTAssertEqual(index.documents(for: "new").map(\.relativePath), ["first.md"])
        XCTAssertTrue(index.documents(for: "old").isEmpty)
        XCTAssertEqual(index.skippedDocuments, 0)
    }
}
