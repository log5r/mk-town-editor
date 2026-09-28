import Foundation
import XCTest
@testable import MKTownEditor

@MainActor
final class WorkspaceViewSettingsTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/private/tmp/mktown-workspace-settings", isDirectory: true)

    private var nodes: [WorkspaceNode] {
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        return [
            WorkspaceNode(url: root.appendingPathComponent("older.md"), name: "older.md",
                          children: nil, modifiedAt: Date(timeIntervalSince1970: 1)),
            WorkspaceNode(url: root.appendingPathComponent("newer.md"), name: "newer.md",
                          children: nil, modifiedAt: Date(timeIntervalSince1970: 2)),
            WorkspaceNode(url: folder, name: "folder", children: [
                WorkspaceNode(url: folder.appendingPathComponent("figure.png"),
                              name: "figure.png", children: nil)
            ])
        ]
    }

    func testPinSortAndFilterAreAppliedWithoutChangingIndex() {
        var settings = WorkspaceViewSettings()
        settings.sortOrder = .modified
        XCTAssertEqual(settings.display(nodes, root: root).map(\.name),
                       ["folder", "newer.md", "older.md"])
        settings.togglePin(nodes[0].url, root: root)
        XCTAssertEqual(settings.display(nodes, root: root).first?.name, "older.md")
        settings.filter = .documents
        XCTAssertEqual(settings.display(nodes, root: root).map(\.name),
                       ["older.md", "newer.md"])
        settings.filter = .attachments
        XCTAssertEqual(settings.display(nodes, root: root).map(\.name), ["folder"])
        XCTAssertEqual(settings.display(nodes, root: root).first?.children?.map(\.name), ["figure.png"])
        settings.fileExtension = "png"
        XCTAssertEqual(settings.display(nodes, root: root).map(\.name), ["folder"])
        settings.fileExtension = "jpg"
        XCTAssertTrue(settings.display(nodes, root: root).isEmpty)
        XCTAssertEqual(WorkspaceViewSettings.availableExtensions(in: nodes), ["md", "png"])
        XCTAssertEqual(nodes.count, 3)
    }

    func testSettingsPersistPerWorkspaceRoot() throws {
        let suite = "mktown-view-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspaceStore(defaults: defaults)
        store.setRoot(root)
        store.setSortOrder(.modified)
        store.setFileFilter(.documents)
        store.setExtensionFilter("md")
        store.togglePin(nodes[0].url)
        store.setRoot(root.appendingPathComponent("other", isDirectory: true))
        XCTAssertEqual(store.viewSettings, WorkspaceViewSettings())
        store.setRoot(root)
        XCTAssertEqual(store.viewSettings.sortOrder, .modified)
        XCTAssertEqual(store.viewSettings.filter, .documents)
        XCTAssertEqual(store.viewSettings.fileExtension, "md")
        XCTAssertTrue(store.viewSettings.isPinned(nodes[0].url, root: root))
    }

    func testPinPathsFollowFolderMoveAndTrash() {
        var settings = WorkspaceViewSettings()
        let folder = root.appendingPathComponent("folder")
        let image = folder.appendingPathComponent("figure.png")
        settings.togglePin(folder, root: root)
        settings.togglePin(image, root: root)
        let renamed = root.appendingPathComponent("renamed")
        settings.remapPins(from: folder, to: renamed, root: root)
        XCTAssertTrue(settings.isPinned(renamed, root: root))
        XCTAssertTrue(settings.isPinned(renamed.appendingPathComponent("figure.png"), root: root))
        settings.removePins(under: renamed, root: root)
        XCTAssertTrue(settings.pinnedPaths.isEmpty)
    }
}
