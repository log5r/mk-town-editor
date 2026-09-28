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
}
