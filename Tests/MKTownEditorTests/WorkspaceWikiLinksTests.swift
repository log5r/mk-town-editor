import Foundation
import XCTest
@testable import MKTownEditor

final class WorkspaceWikiLinksTests: XCTestCase {
    func testParsingExcludesCodeFrontMatterAndEscapes() {
        let source = "---\ntitle: [[hidden]]\n---\n[[ノート|表示]] `[[code]]`\\[[escaped]]\n```\n[[block]]\n```"
        let links = WorkspaceWikiLinks.links(in: source)
        XCTAssertEqual(links.map(\.target), ["ノート"])
        XCTAssertEqual(links.first?.alias, "表示")
        XCTAssertEqual((source as NSString).substring(with: links[0].range), "[[ノート|表示]]")
    }

    func testSameNameResolutionRequiresUniqueTitleUnlessRelativePathMatches() {
        let root = URL(fileURLWithPath: "/tmp/wiki-resolution")
        let current = root.appendingPathComponent("index.md")
        let one = root.appendingPathComponent("one/Note.md")
        let two = root.appendingPathComponent("two/Note.md")
        XCTAssertNil(WorkspaceWikiLinks.resolve("Note", from: current, documents: [one, two]))
        XCTAssertEqual(WorkspaceWikiLinks.resolve("one/Note", from: current,
            documents: [one, two]), one)
        XCTAssertEqual(WorkspaceWikiLinks.resolve("Note", from: one,
            documents: [one, two]), one)
        XCTAssertNil(WorkspaceWikiLinks.resolve("https://example.com", from: current,
            documents: [one]))
    }

    func testInsertCompletesExistingAndConvertsToMarkdown() throws {
        let root = URL(fileURLWithPath: "/tmp/wiki-convert")
        let current = root.appendingPathComponent("index.md")
        let target = root.appendingPathComponent("note file.md")
        let source = "[[draft|表示]]"
        let edit = try XCTUnwrap(WorkspaceWikiLinks.insertion(in: source,
            selection: NSRange(location: 4, length: 0), target: "note file"))
        XCTAssertEqual(edit.applying(to: source), "[[note file|表示]]")
        let converted = try XCTUnwrap(WorkspaceWikiLinks.conversion(in: edit.applying(to: source),
            selection: NSRange(location: 4, length: 0), documentURL: current,
            documents: [current, target]))
        XCTAssertEqual(converted.applying(to: edit.applying(to: source)),
            "[表示](note%20file.md)")
        XCTAssertNil(WorkspaceWikiLinks.insertion(in: "bad|alias",
            selection: NSRange(location: 0, length: 9), target: "note"))
    }

    func testRenameRewritesOnlyResolvedWikiLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let old = root.appendingPathComponent("before.md")
        let new = root.appendingPathComponent("after.md")
        let referring = root.appendingPathComponent("index.md")
        try "body".write(to: old, atomically: true, encoding: .utf8)
        try "[[before|label]] `[[before]]`\\[[before]]".write(to: referring,
            atomically: true, encoding: .utf8)
        let plan = try WorkspaceFileOperations.planMove(source: old, destination: new, root: root)
        XCTAssertEqual(plan.changedLinks, 1)
        try plan.apply()
        XCTAssertEqual(try String(contentsOf: referring, encoding: .utf8),
            "[[after|label]] `[[before]]`\\[[before]]")
    }

    func testWikiLinkAppearsInBacklinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("note.md")
        let source = root.appendingPathComponent("index.md")
        try "note".write(to: target, atomically: true, encoding: .utf8)
        try "[[note]]\n`[[note]]`".write(to: source, atomically: true, encoding: .utf8)
        let index = WorkspaceFileIndex.scan(root: root)
        let backlinks = try WorkspaceBacklinkIndex.scan(root: root, targetURL: target,
            nodes: index.nodes, openBuffers: [:])
        XCTAssertEqual(backlinks.backlinks.count, 1)
        XCTAssertEqual(backlinks.backlinks.first?.excerpt, "[[note]]")
    }
}
