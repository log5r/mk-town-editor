import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

/// An empty untitled window must not be saved for state restoration; otherwise every relaunch
/// restored the empty windows and `DocumentGroup` added one more (docs/untitled-window-accumulation.md).
@MainActor
final class EditorWindowRestorationTests: XCTestCase {
    func testEmptyUntitledDocumentIsNotRestored() {
        XCTAssertFalse(EditorWindowRestoration.isRestorable(fileURL: nil, isTextEmpty: true))
    }

    func testUntitledDocumentWithTextIsRestored() {
        XCTAssertTrue(EditorWindowRestoration.isRestorable(fileURL: nil, isTextEmpty: false))
    }

    func testSavedDocumentIsRestoredEvenWhenEmpty() {
        let url = URL(fileURLWithPath: "/tmp/empty.md")
        XCTAssertTrue(EditorWindowRestoration.isRestorable(fileURL: url, isTextEmpty: true))
        XCTAssertTrue(EditorWindowRestoration.isRestorable(fileURL: url, isTextEmpty: false))
    }

    func testSetterAppliesTheValueWhenJoiningTheWindowAndWhenItChanges() {
        let hosting = NSHostingView(rootView: WindowRestorationSetter(isRestorable: false))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: true)
        defer { window.orderOut(nil) }
        XCTAssertTrue(window.isRestorable, "AppKit restores titled windows by default")

        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.isRestorable)

        hosting.rootView = WindowRestorationSetter(isRestorable: true)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.isRestorable)

        hosting.rootView = WindowRestorationSetter(isRestorable: false)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.isRestorable)
    }

    /// Hosts the real workspace so the setter is checked where `DocumentGroup` puts it.
    func testWorkspaceWindowFollowsTheTextAndTheFileURL() throws {
        let suite = "EditorWindowRestorationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let saved = root.appendingPathComponent("saved.md")
        try "".write(to: saved, atomically: true, encoding: .utf8)

        let settings = EditorSettingsStore(defaults: defaults)
        let workspaceStore = WorkspaceStore(defaults: defaults)
        let navigation = DocumentLinkNavigation()
        let activation = WorkspaceLayoutActivation()
        func workspace(text: String, fileURL: URL?) -> AnyView {
            AnyView(EditorWorkspace(document: .constant(MarkdownDocument(text: text)), fileURL: fileURL)
                .environmentObject(settings)
                .environmentObject(navigation)
                .environmentObject(workspaceStore)
                .environmentObject(activation))
        }
        let controller = NSHostingController(rootView: workspace(text: "", fileURL: nil))
        let window = NSWindow(contentViewController: controller)
        defer { window.orderOut(nil) }
        window.setContentSize(NSSize(width: 1100, height: 700))
        func show(text: String, fileURL: URL?) {
            controller.rootView = workspace(text: text, fileURL: fileURL)
            controller.view.layoutSubtreeIfNeeded()
        }

        show(text: "", fileURL: nil)
        XCTAssertFalse(window.isRestorable, "an empty untitled window is not restored")
        show(text: "a", fileURL: nil)
        XCTAssertTrue(window.isRestorable, "typed text makes the untitled window restorable")
        show(text: "", fileURL: nil)
        XCTAssertFalse(window.isRestorable, "deleting all text makes it empty again")
        show(text: "", fileURL: saved)
        XCTAssertTrue(window.isRestorable, "a saved document is restored even when it is empty")
    }
}
