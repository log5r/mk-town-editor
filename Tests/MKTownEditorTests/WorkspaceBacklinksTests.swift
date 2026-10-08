import Foundation
import XCTest
@testable import MKTownEditor

final class WorkspaceBacklinksTests: XCTestCase {
    func testInlineAndReferenceBacklinksExcludeCodeImagesAndOtherTargets() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mktown-backlinks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.md")
        let referring = root.appendingPathComponent("referring.md")
        try "# Target".write(to: target, atomically: true, encoding: .utf8)
        let source = """
        ---
        description: "[metadata](target.md)"
        ---
        [one](target.md#target)
        [two][ref]

        [ref]: target.md
        ![image](target.md)
        `[code](target.md)`
        ```md
        [fenced](target.md)
        ```
        [external](https://example.com/target.md)
        """
        try source.write(to: referring, atomically: true, encoding: .utf8)
        let nodes = try WorkspaceFileIndex.scan(root: root).nodes
        let analysis = MarkdownAnalysis(source)
        XCTAssertNotNil(analysis.references["ref"])
        XCTAssertTrue(MarkdownContentInspector.items(in: source, analysis: analysis)
            .contains { $0.label == "two" && $0.destination == "target.md" })

        let index = try WorkspaceBacklinkIndex.scan(root: root, targetURL: target,
            nodes: nodes, openBuffers: [:])

        XCTAssertEqual(index.backlinks.count, 2)
        XCTAssertEqual(index.backlinks.map(\.relativePath), ["referring.md", "referring.md"])
        XCTAssertEqual(index.backlinks.map(\.line), [4, 5])
        XCTAssertEqual(index.backlinks.map(\.excerpt), ["[one](target.md#target)", "[two][ref]"])
    }

    func testUnsavedBufferOverridesDiskAndSupportsRelativeParentPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mktown-backlinks-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.md")
        let referring = nested.appendingPathComponent("referring.md")
        try "Target".write(to: target, atomically: true, encoding: .utf8)
        try "No links".write(to: referring, atomically: true, encoding: .utf8)
        let nodes = try WorkspaceFileIndex.scan(root: root).nodes
        let edited = try XCTUnwrap("See [target](../target.md)".data(using: .utf8))

        let index = try WorkspaceBacklinkIndex.scan(root: root, targetURL: target,
            nodes: nodes,
            openBuffers: [referring.resolvingSymlinksInPath().standardizedFileURL: edited])

        XCTAssertEqual(index.backlinks.count, 1)
        XCTAssertEqual(index.backlinks[0].relativePath, "notes/referring.md")
        XCTAssertEqual(index.backlinks[0].sourceRange.location, 4)
    }
}
