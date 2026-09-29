import Foundation
import XCTest
@testable import MKTownEditor

final class WorkspaceNamedLayoutTests: XCTestCase {
    func testCaptureStoresWorkspaceDocumentsAndRestoresActiveLast() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("a.md")
        let second = root.appendingPathComponent("b.md")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside.md")
        try "a".write(to: first, atomically: true, encoding: .utf8)
        try "b".write(to: second, atomically: true, encoding: .utf8)
        let layout = WorkspaceNamedLayout.capture(name: "Writing", root: root,
            openDocuments: [second, first, outside], activeDocument: first,
            mode: .split, sidebarTab: "ファイル", sidebarVisible: true,
            splitRatio: 0.65, splitOrientation: .stacked, previewFirst: true)
        XCTAssertEqual(layout.documentPaths, ["a.md", "b.md"])
        XCTAssertEqual(layout.activePath, "a.md")
        XCTAssertEqual(layout.resolveDocuments(root: root).urls, [second, first])
        XCTAssertEqual(layout.splitRatio, 0.65)
    }

    func testMissingAndOutsideSymlinkDocumentsAreSkipped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.md"),
            withDestinationURL: outside)
        var layout = WorkspaceNamedLayout.capture(name: "Missing", root: root,
            openDocuments: [], activeDocument: nil, mode: .editor,
            sidebarTab: "アウトライン", sidebarVisible: false, splitRatio: 0.5,
            splitOrientation: .sideBySide, previewFirst: false)
        layout.documentPaths = ["link.md", "missing.md", "../outside.md"]
        let resolved = layout.resolveDocuments(root: root)
        XCTAssertTrue(resolved.urls.isEmpty)
        XCTAssertEqual(resolved.missing.count, 3)
    }

    func testSavedLayoutsAreScopedByRootAndSameNameReplaces() throws {
        let suite = "WorkspaceNamedLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspaceNamedLayoutStore(defaults: defaults)
        let firstRoot = URL(fileURLWithPath: "/tmp/layout-a")
        let secondRoot = URL(fileURLWithPath: "/tmp/layout-b")
        var layout = WorkspaceNamedLayout.capture(name: "Draft", root: firstRoot,
            openDocuments: [], activeDocument: nil, mode: .editor,
            sidebarTab: "アウトライン", sidebarVisible: false, splitRatio: 0.5,
            splitOrientation: .sideBySide, previewFirst: false)
        store.save(layout, for: firstRoot)
        XCTAssertTrue(store.layouts(for: secondRoot).isEmpty)
        let id = try XCTUnwrap(store.layouts(for: firstRoot).first?.id)
        layout.name = "draft"
        layout.mode = .preview
        store.save(layout, for: firstRoot)
        XCTAssertEqual(store.layouts(for: firstRoot).count, 1)
        XCTAssertEqual(store.layouts(for: firstRoot)[0].id, id)
        XCTAssertEqual(store.layouts(for: firstRoot)[0].mode, .preview)
        store.delete(id, for: firstRoot)
        XCTAssertTrue(store.layouts(for: firstRoot).isEmpty)
    }

    @MainActor
    func testApplyingLayoutKeepsSelectionAndScroll() throws {
        let suite = "WorkspaceNamedLayoutSettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = EditorSettingsStore(defaults: defaults)
        let root = URL(fileURLWithPath: "/tmp/layout-settings")
        let url = root.appendingPathComponent("note.md")
        settings.savePosition(for: url, selection: NSRange(location: 12, length: 3),
            scrollX: 4, scrollY: 90, splitRatio: 0.5,
            sidebarTab: "アウトライン", sidebarVisible: false)
        let layout = WorkspaceNamedLayout.capture(name: "Review", root: root,
            openDocuments: [url], activeDocument: url, mode: .split,
            sidebarTab: "ファイル", sidebarVisible: true, splitRatio: 0.7,
            splitOrientation: .stacked, previewFirst: true)
        settings.applyWorkspaceLayout(layout, to: url)
        let state = try XCTUnwrap(settings.displayState(for: url))
        XCTAssertEqual(state.mode, .split)
        XCTAssertEqual(state.selectionLocation, 12)
        XCTAssertEqual(state.selectionLength, 3)
        XCTAssertEqual(state.scrollY, 90)
        XCTAssertEqual(state.splitRatio, 0.7)
        XCTAssertEqual(state.splitOrientation, .stacked)
    }

    @MainActor
    func testActivationTargetsOnlySavedDocuments() {
        let activation = WorkspaceLayoutActivation()
        let root = URL(fileURLWithPath: "/tmp/layout-event")
        let first = root.appendingPathComponent("first.md")
        let second = root.appendingPathComponent("second.md")
        let layout = WorkspaceNamedLayout.capture(name: "Work", root: root,
            openDocuments: [first], activeDocument: first, mode: .split,
            sidebarTab: "ファイル", sidebarVisible: true, splitRatio: 0.5,
            splitOrientation: .sideBySide, previewFirst: false)
        activation.activate(layout, documents: [first])
        XCTAssertEqual(activation.layout(for: first), layout)
        XCTAssertNil(activation.layout(for: second))
    }

    func testFolderMoveRebasesStoredDocumentPaths() throws {
        let suite = "WorkspaceNamedLayoutMove.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspaceNamedLayoutStore(defaults: defaults)
        let root = URL(fileURLWithPath: "/tmp/layout-folder-move")
        let old = root.appendingPathComponent("drafts")
        let new = root.appendingPathComponent("archive")
        let file = old.appendingPathComponent("note.md")
        let layout = WorkspaceNamedLayout.capture(name: "Writing", root: root,
            openDocuments: [file], activeDocument: file, mode: .split,
            sidebarTab: "ファイル", sidebarVisible: true, splitRatio: 0.5,
            splitOrientation: .sideBySide, previewFirst: false)
        store.save(layout, for: root)
        store.remapDocuments(from: old, to: new, root: root)
        let updated = try XCTUnwrap(store.layouts(for: root).first)
        XCTAssertEqual(updated.documentPaths, ["archive/note.md"])
        XCTAssertEqual(updated.activePath, "archive/note.md")
    }
}
