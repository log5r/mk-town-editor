import Foundation
import XCTest
@testable import MKTownEditor

@MainActor
final class WorkspaceFileIndexTests: XCTestCase {
    func testScanBuildsTreeAndSkipsHiddenAndSymbolicLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = root.appendingPathComponent("章")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "本文".write(to: folder.appendingPathComponent("日本語.md"), atomically: true, encoding: .utf8)
        try Data([0]).write(to: root.appendingPathComponent("figure.png"))
        try "hidden".write(to: root.appendingPathComponent(".secret.md"), atomically: true, encoding: .utf8)
        try "other".write(to: root.appendingPathComponent("ignored.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"),
                                                    withDestinationURL: root)
        let result = WorkspaceFileIndex.scan(root: root)
        XCTAssertFalse(result.isTruncated)
        XCTAssertEqual(result.nodes.map(\.name), ["章", "figure.png"])
        XCTAssertEqual(result.nodes[0].children?.map(\.name), ["日本語.md"])
        XCTAssertTrue(result.nodes[0].children?[0].isEditableDocument == true)
        XCTAssertFalse(result.nodes[1].isEditableDocument)
    }

    func testRescanDetectsExternalFileChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertTrue(WorkspaceFileIndex.scan(root: root).nodes.isEmpty)
        let file = root.appendingPathComponent("new.markdown")
        try "new".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(WorkspaceFileIndex.scan(root: root).nodes.map(\.name), ["new.markdown"])
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(WorkspaceFileIndex.scan(root: root).nodes.isEmpty)
    }

    func testOpenDocumentRegistryCountsMultipleWindows() throws {
        let suite = "mktown-workspace-registry-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspaceStore(defaults: defaults)
        let document = URL(fileURLWithPath: "/private/tmp/shared.md")
        store.registerOpenDocument(document)
        store.registerOpenDocument(document)
        XCTAssertEqual(store.openDocumentURLs.count, 1)
        store.unregisterOpenDocument(document)
        XCTAssertEqual(store.openDocumentURLs.count, 1)
        store.unregisterOpenDocument(document)
        XCTAssertTrue(store.openDocumentURLs.isEmpty)
    }

    func testAttachmentAuditFindsMissingAndUnusedAcrossDocuments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = root.appendingPathComponent("assets")
        let images = root.appendingPathComponent("images")
        let chapter = root.appendingPathComponent("chapter")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chapter, withIntermediateDirectories: true)
        let used = assets.appendingPathComponent("図 one.png")
        let unused = assets.appendingPathComponent("old.heic")
        let unusedInImages = images.appendingPathComponent("old.png")
        try Data([1]).write(to: used)
        try Data([2]).write(to: unused)
        try Data([3]).write(to: unusedInImages)
        let first = root.appendingPathComponent("index.md")
        let second = chapter.appendingPathComponent("note.md")
        try "![used](assets/%E5%9B%B3%20one.png)\n![missing](assets/lost.png)\n`![code](assets/old.heic)`".write(
            to: first, atomically: true, encoding: .utf8)
        try "![reference][figure]\n\n[figure]: ../assets/%E5%9B%B3%20one.png".write(
            to: second, atomically: true, encoding: .utf8)

        let result = try await WorkspaceAttachmentAudit.scan(root: root)

        XCTAssertEqual(result.missing.map { $0.url.lastPathComponent }, ["lost.png"])
        XCTAssertEqual(result.missing[0].sources, [first])
        XCTAssertEqual(Set(result.unused.map { $0.url.lastPathComponent }), ["old.heic", "old.png"])
        XCTAssertEqual(result.used.map { $0.url.lastPathComponent }, ["図 one.png"])
        XCTAssertEqual(Set(result.used[0].sources), Set([first, second]))

        let changed = try await WorkspaceAttachmentAudit.scan(root: root,
            openDocuments: [first: Data("![now used](assets/old.heic)".utf8)])
        XCTAssertEqual(changed.unused.map { $0.url.lastPathComponent }, ["old.png"])
        XCTAssertEqual(changed.used.first(where: { $0.url == unused })?.sources, [first])
    }
}
