import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

final class SidebarToolbarTests: XCTestCase {
    @MainActor
    func testWorkspaceDoesNotAddADuplicateSidebarToolbarItem() async throws {
        let suite = "SidebarToolbarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = EditorWorkspace(document: .constant(MarkdownDocument(text: "# Test")), fileURL: nil)
            .environmentObject(EditorSettingsStore(defaults: defaults))
            .environmentObject(DocumentLinkNavigation())
            .environmentObject(WorkspaceStore(defaults: defaults))
            .environmentObject(WorkspaceLayoutActivation())
        let controller = NSHostingController(rootView: workspace)
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 1200, height: 800))
        defer { window.orderOut(nil) }
        controller.view.layoutSubtreeIfNeeded()
        for _ in 0..<50 where window.toolbar?.items.isEmpty != false {
            try await Task.sleep(for: .milliseconds(20))
        }
        let toolbar = try XCTUnwrap(window.toolbar)
        // NSHostingController does not install SwiftUI's scene-owned standard items.
        // Check that the editor toolbar loaded, then guard against the extra custom toggle.
        XCTAssertTrue(toolbar.items.contains { $0.itemIdentifier.rawValue == "display-mode" })
        XCTAssertFalse(toolbar.items.contains { $0.itemIdentifier.rawValue == "sidebar" },
                       "A custom toggle duplicates NavigationSplitView's standard sidebar button.")
    }
}
