import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

/// Hosts the real EditorWorkspace to cover state persistence wired up in the view itself.
@MainActor
final class EditorWorkspacePersistenceTests: XCTestCase {
    private struct Host {
        let controller: NSHostingController<AnyView>
        let window: NSWindow
        let settings: EditorSettingsStore
        let make: (URL?) -> AnyView
    }

    private func host(fileURL: URL, defaults: UserDefaults) -> Host {
        let settings = EditorSettingsStore(defaults: defaults)
        let workspaceStore = WorkspaceStore(defaults: defaults)
        let navigation = DocumentLinkNavigation()
        let activation = WorkspaceLayoutActivation()
        let document = Binding.constant(MarkdownDocument(text: "# Title\n\nfirst line\nsecond line\n"))
        let make: (URL?) -> AnyView = { url in
            AnyView(EditorWorkspace(document: document, fileURL: url)
                .environmentObject(settings)
                .environmentObject(navigation)
                .environmentObject(workspaceStore)
                .environmentObject(activation))
        }
        let controller = NSHostingController(rootView: make(fileURL))
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 1100, height: 700))
        controller.view.layoutSubtreeIfNeeded()
        return Host(controller: controller, window: window, settings: settings, make: make)
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { ([$0 as? T].compactMap { $0 }) + descendants(of: $0, as: type) }
    }

    private func splitViewControllers(in controller: NSViewController) -> [NSSplitViewController] {
        controller.children.flatMap { ([$0 as? NSSplitViewController].compactMap { $0 }) + splitViewControllers(in: $0) }
    }

    private func settle(_ host: Host, for duration: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: duration)
        while ContinuousClock.now < deadline {
            host.controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func temporaryDocuments() throws -> (URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let a = root.appendingPathComponent("a.md"), b = root.appendingPathComponent("b.md")
        try "# Title\n".write(to: a, atomically: true, encoding: .utf8)
        try "# Title\n".write(to: b, atomically: true, encoding: .utf8)
        return (root, a, b)
    }

    func testRenameWithinPendingPositionSaveDoesNotRecreateStateUnderOldPath() async throws {
        let suite = "EditorWorkspacePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (root, a, b) = try temporaryDocuments()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = host(fileURL: a, defaults: defaults)
        defer { host.window.orderOut(nil) }
        try await settle(host, for: .milliseconds(1500))
        let editor = try XCTUnwrap(descendants(of: host.controller.view, as: EditorTextView.self).first)

        editor.setSelectedRange(NSRange(location: 12, length: 4)) // schedules a save in 1 s
        try await settle(host, for: .milliseconds(150))
        host.controller.rootView = host.make(b)                    // renamed before it fires
        try await settle(host, for: .milliseconds(1600))

        XCTAssertNil(host.settings.displayState(for: a), "the stale save recreated state under the old path")
        XCTAssertEqual(host.settings.displayState(for: b)?.selectionLocation, 12)
        XCTAssertEqual(host.settings.displayState(for: b)?.selectionLength, 4)
    }

    func testShowingTheSidebarIsSavedWithoutMovingTheCaret() async throws {
        let suite = "EditorWorkspacePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (root, a, _) = try temporaryDocuments()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = host(fileURL: a, defaults: defaults)
        defer { host.window.orderOut(nil) }
        try await settle(host, for: .milliseconds(1500))
        XCTAssertNotEqual(host.settings.displayState(for: a)?.sidebarVisible, true)

        let split = try XCTUnwrap(
            splitViewControllers(in: host.controller).first
                ?? descendants(of: host.controller.view, as: NSSplitView.self)
                    .lazy.compactMap { $0.delegate as? NSSplitViewController }.first,
            "NavigationSplitView should be backed by an NSSplitViewController")
        split.toggleSidebar(nil)
        try await settle(host, for: .milliseconds(1600))
        XCTAssertEqual(host.settings.displayState(for: a)?.sidebarVisible, true,
                       "a sidebar change must be persisted even when nothing else changes")
    }

    func testBusyDocumentOperationReportsInsteadOfDroppingTheRequest() {
        var messages: [String] = []
        XCTAssertTrue(DocumentOperationGate.admit(running: false) { messages.append($0) })
        XCTAssertTrue(messages.isEmpty)
        XCTAssertFalse(DocumentOperationGate.admit(running: true) { messages.append($0) })
        XCTAssertEqual(messages, [DocumentOperationGate.busyMessage])
        XCTAssertFalse(DocumentOperationGate.busyMessage.isEmpty)
    }
}
