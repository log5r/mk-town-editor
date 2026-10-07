import Foundation
import XCTest
@testable import MKTownEditor

@MainActor
final class WorkspaceViewSettingsTests: XCTestCase {
    func testDisplayUsesScannedPathsWithoutFollowingSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias.md")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root.appendingPathComponent("actual.md"))
        let nodes = [WorkspaceNode(url: alias, name: "alias.md", children: nil),
                     WorkspaceNode(url: root.appendingPathComponent("first.md"), name: "first.md", children: nil)]
        var settings = WorkspaceViewSettings()
        settings.pinnedPaths = ["alias.md"]
        XCTAssertEqual(settings.display(nodes, root: root).first?.url, alias)
    }

    @MainActor
    func testVisibleTreeUpdatesOnSettingsChangesAndIsCachedBetweenReads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "b".write(to: root.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        try "a".write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.setRoot(root)
        for _ in 0..<200 where store.visibleNodes.count != 2 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.visibleNodes.map(\.name), ["a.md", "b.md"])
        store.togglePin(root.appendingPathComponent("b.md"))
        for _ in 0..<200 where store.visibleNodes.first?.name != "b.md" { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.visibleNodes.map(\.name), ["b.md", "a.md"])
        var notifications = 0
        let observation = store.objectWillChange.sink { notifications += 1 }
        for _ in 0..<100 { _ = store.visibleNodes }
        XCTAssertEqual(notifications, 0)
        withExtendedLifetime(observation) {}
    }

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
