import Foundation
import XCTest
@testable import MKTownEditor

final class WorkspaceDocumentEmbedTests: XCTestCase {
    func testEmbedCacheAvoidsRepeatedReadsAndReflectsDiskAndOpenChanges() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: url) }
        try "first".write(to: url, atomically: true, encoding: .utf8)
        var cache = WorkspaceEmbedFileCache()
        for _ in 0..<10 { XCTAssertEqual(cache.load(url, openBuffers: [:]), "first") }
        XCTAssertEqual(cache.readCount, 1)
        XCTAssertEqual(cache.load(url, openBuffers: [url: Data("unsaved".utf8)]), "unsaved")
        try "second version".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(cache.load(url, openBuffers: [:]), "second version")
        XCTAssertEqual(cache.readCount, 2)
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(cache.load(url, openBuffers: [:]))
    }

    private let root = URL(fileURLWithPath: "/tmp/mktown-embed-tests")

    func testStandaloneSyntaxAndSectionExtraction() throws {
        let block = try XCTUnwrap(MarkdownAnalysis("![[notes#topic]]").blocks.first)
        XCTAssertEqual(block.kind, .paragraph)
        XCTAssertNotNil(WorkspaceDocumentEmbed.reference(in: block.content))
        XCTAssertNil(WorkspaceDocumentEmbed.reference(in: "before ![[notes]]"))
        XCTAssertNil(WorkspaceDocumentEmbed.reference(in: "![[notes]] after"))
        let reference = try XCTUnwrap(WorkspaceDocumentEmbed.reference(in: "![[notes#topic]]"))
        let index = root.appendingPathComponent("index.md")
        let notes = root.appendingPathComponent("notes.md")
        let expansion = WorkspaceDocumentEmbed.expand(reference, from: index,
            documents: [index, notes]) { _ in
                "# Intro\nfirst\n## Topic\nbody\n### Child\nchild\n## Next\nother"
            }
        XCTAssertTrue(expansion.issues.isEmpty)
        XCTAssertEqual(expansion.text, "## Topic\nbody\n### Child\nchild\n")
    }

    func testNestedEmbedTracksCyclesAndDepth() throws {
        let a = root.appendingPathComponent("a.md")
        let b = root.appendingPathComponent("b.md")
        let c = root.appendingPathComponent("c.md")
        let docs = [a, b, c]
        let content = [b: "B\n![[c]]", c: "C\n![[a]]"]
        let reference = try XCTUnwrap(WorkspaceDocumentEmbed.reference(in: "![[b]]"))
        let expansion = WorkspaceDocumentEmbed.expand(reference, from: a,
            documents: docs) { content[$0] }
        XCTAssertTrue(expansion.text.contains("B"))
        XCTAssertTrue(expansion.text.contains("C"))
        XCTAssertEqual(expansion.issues.count, 1)
        XCTAssertTrue(expansion.issues[0].contains("循環"))

        let chain = (0...5).map { root.appendingPathComponent("\($0).md") }
        let limited = WorkspaceDocumentEmbed.expand(
            try XCTUnwrap(WorkspaceDocumentEmbed.reference(in: "![[1]]")),
            from: chain[0], documents: chain) { url in
                guard let number = Int(url.deletingPathExtension().lastPathComponent) else { return nil }
                return "![[\(number + 1)]]"
            }
        XCTAssertTrue(limited.issues.contains { $0.contains("展開深度") })
    }

    func testMissingDocumentAndSectionProduceIssues() throws {
        let index = root.appendingPathComponent("index.md")
        let notes = root.appendingPathComponent("notes.md")
        let missing = WorkspaceDocumentEmbed.expand(
            try XCTUnwrap(WorkspaceDocumentEmbed.reference(in: "![[missing]]")),
            from: index, documents: [index, notes]) { _ in "" }
        XCTAssertEqual(missing.issues.count, 1)
        let section = WorkspaceDocumentEmbed.expand(
            try XCTUnwrap(WorkspaceDocumentEmbed.reference(in: "![[notes#absent]]")),
            from: index, documents: [index, notes]) { _ in "# Present" }
        XCTAssertEqual(section.issues.count, 1)
        XCTAssertTrue(section.issues[0].contains("見出し"))
    }

    func testCodeBlockDoesNotExpandNestedSyntax() throws {
        let index = root.appendingPathComponent("index.md")
        let notes = root.appendingPathComponent("notes.md")
        let nested = root.appendingPathComponent("nested.md")
        let reference = try XCTUnwrap(WorkspaceDocumentEmbed.reference(in: "![[notes]]"))
        let expansion = WorkspaceDocumentEmbed.expand(reference, from: index,
            documents: [index, notes, nested]) { url in
                url == notes ? "```\n![[nested]]\n```" : "expanded"
            }
        XCTAssertEqual(expansion.text, "```\n![[nested]]\n```")
    }

    func testReloadUsesUpdatedDependencyText() throws {
        let index = root.appendingPathComponent("index.md")
        let notes = root.appendingPathComponent("notes.md")
        let reference = try XCTUnwrap(WorkspaceDocumentEmbed.reference(in: "![[notes]]"))
        var current = "first"
        func render() -> WorkspaceEmbedExpansion {
            WorkspaceDocumentEmbed.expand(reference, from: index,
                documents: [index, notes]) { _ in current }
        }
        XCTAssertEqual(render().text, "first")
        current = "second"
        XCTAssertEqual(render().text, "second")
    }

    func testNestedRelativeLinkUsesContainingDocumentLocation() throws {
        let index = root.appendingPathComponent("index.md")
        let parent = root.appendingPathComponent("parent.md")
        let child = root.appendingPathComponent("sub/child.md")
        let reference = try XCTUnwrap(WorkspaceDocumentEmbed.reference(in: "![[parent]]"))
        let expanded = WorkspaceDocumentEmbed.expand(reference, from: index,
            documents: [index, parent, child]) { url in
                url == parent ? "![[sub/child]]" : "[asset](image.png)"
            }
        XCTAssertEqual(expanded.text, "[asset](sub/image.png)")
    }

    func testRenameUpdatesEmbedTargetAndKeepsSection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let old = root.appendingPathComponent("old.md")
        let new = root.appendingPathComponent("new.md")
        let referring = root.appendingPathComponent("index.md")
        try "# Section".write(to: old, atomically: true, encoding: .utf8)
        try "![[old#section]]\n```\n![[old]]\n```".write(to: referring,
            atomically: true, encoding: .utf8)
        let plan = try WorkspaceFileOperations.planMove(source: old,
            destination: new, root: root)
        XCTAssertEqual(plan.changedLinks, 1)
        try plan.apply()
        XCTAssertEqual(try String(contentsOf: referring, encoding: .utf8),
            "![[new#section]]\n```\n![[old]]\n```")
    }
}
