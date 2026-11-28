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

    /// Hosts the workspace as a new window. `opening` defaults to `.lastUsed` so the tests that
    /// exercise the editor see it without switching away from the opening preview.
    private func host(fileURL: URL?, defaults: UserDefaults,
                      opening: DocumentOpeningMode = .lastUsed,
                      navigation: DocumentLinkNavigation = DocumentLinkNavigation(),
                      activation: WorkspaceLayoutActivation = WorkspaceLayoutActivation(),
                      savedMode: EditorMode? = nil,
                      document: MarkdownDocument = MarkdownDocument(text: "# Title\n\nfirst line\nsecond line\n")) -> Host {
        let settings = EditorSettingsStore(defaults: defaults)
        var app = settings.app
        app.documentOpeningMode = opening
        settings.setAppSettings(app)
        if let savedMode, let fileURL { settings.setMode(savedMode, for: fileURL) }
        let workspaceStore = WorkspaceStore(defaults: defaults)
        let document = Binding.constant(document)
        let make: (URL?) -> AnyView = { url in
            AnyView(MarkdownDocumentWindow(document: document, fileURL: url)
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

    private func showsEditor(_ host: Host) -> Bool {
        !descendants(of: host.controller.view, as: EditorTextView.self).isEmpty
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

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "EditorWorkspacePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    // MARK: 書類を開いたときの表示

    func testAlwaysPreviewOpensSavedDocumentInPreviewWithoutSavingIt() async throws {
        let defaults = try isolatedDefaults()
        let (root, a, _) = try temporaryDocuments()
        defer { try? FileManager.default.removeItem(at: root) }
        let opened = host(fileURL: a, defaults: defaults, opening: .alwaysPreview, savedMode: .editor)
        defer { opened.window.orderOut(nil) }
        XCTAssertFalse(showsEditor(opened), "the editor pane was built by the first layout")
        try await settle(opened, for: .milliseconds(300))
        XCTAssertFalse(showsEditor(opened))
        XCTAssertEqual(opened.settings.mode(for: a), .editor, "the saved mode is kept")
    }

    func testModeChosenAfterOpeningInPreviewSticksAndIsSaved() async throws {
        let defaults = try isolatedDefaults()
        let (root, a, _) = try temporaryDocuments()
        defer { try? FileManager.default.removeItem(at: root) }
        let navigation = DocumentLinkNavigation()
        let opened = host(fileURL: a, defaults: defaults, opening: .alwaysPreview,
                          navigation: navigation, savedMode: .split)
        defer { opened.window.orderOut(nil) }
        try await settle(opened, for: .milliseconds(300))
        XCTAssertFalse(showsEditor(opened))
        // A search result in the open window switches it to the editor, as the toolbar would.
        navigation.requestPosition(in: a, range: NSRange(location: 9, length: 5))
        try await settle(opened, for: .milliseconds(500))
        XCTAssertTrue(showsEditor(opened))
        XCTAssertEqual(opened.settings.mode(for: a), .editor)
        try await settle(opened, for: .milliseconds(300))
        XCTAssertTrue(showsEditor(opened), "the window went back to the preview")
    }

    func testLastUsedOpensTheSavedMode() throws {
        let defaults = try isolatedDefaults()
        let (root, a, _) = try temporaryDocuments()
        defer { try? FileManager.default.removeItem(at: root) }
        let opened = host(fileURL: a, defaults: defaults, opening: .lastUsed, savedMode: .editor)
        defer { opened.window.orderOut(nil) }
        XCTAssertTrue(showsEditor(opened))
    }

    func testLineRequestOpensTheEditorEvenWithAlwaysPreview() async throws {
        let defaults = try isolatedDefaults()
        let (root, a, _) = try temporaryDocuments()
        defer { try? FileManager.default.removeItem(at: root) }
        let navigation = DocumentLinkNavigation()
        navigation.requestLine(in: a, line: 3)
        let opened = host(fileURL: a, defaults: defaults, opening: .alwaysPreview,
                          navigation: navigation, savedMode: .preview)
        defer { opened.window.orderOut(nil) }
        try await settle(opened, for: .milliseconds(300))
        XCTAssertTrue(showsEditor(opened))
        XCTAssertEqual(opened.settings.mode(for: a), .editor, "mktown-open --line switches to the editor as before")
    }

    func testReadOnlyOpenAppliesToTheRequestedWindowAndDoesNotPersist() async throws {
        let defaults = try isolatedDefaults()
        let (root, a, b) = try temporaryDocuments()
        defer { try? FileManager.default.removeItem(at: root) }
        let navigation = DocumentLinkNavigation()
        navigation.requestReadOnlyOpen(for: a)
        let first = host(fileURL: a, defaults: defaults, navigation: navigation, savedMode: .editor)
        first.window.isReleasedWhenClosed = false
        defer { first.window.orderOut(nil) }
        let firstEditor = try XCTUnwrap(descendants(of: first.controller.view, as: EditorTextView.self).first)
        XCTAssertFalse(firstEditor.isEditable)

        let second = host(fileURL: b, defaults: defaults, navigation: navigation, savedMode: .editor)
        defer { second.window.orderOut(nil) }
        let secondEditor = try XCTUnwrap(descendants(of: second.controller.view, as: EditorTextView.self).first)
        XCTAssertTrue(secondEditor.isEditable)
        navigation.requestReadOnlyOpen(for: b)
        try await settle(second, for: .milliseconds(300))
        XCTAssertFalse(secondEditor.isEditable)
        XCTAssertTrue(secondEditor.isSelectable)
        XCTAssertFalse(navigation.hasPendingReadOnlyOpen(for: a))
        XCTAssertFalse(navigation.hasPendingReadOnlyOpen(for: b))

        first.window.close()
        let reopened = host(fileURL: a, defaults: defaults, navigation: navigation)
        defer { reopened.window.orderOut(nil) }
        let reopenedEditor = try XCTUnwrap(descendants(of: reopened.controller.view, as: EditorTextView.self).first)
        XCTAssertTrue(reopenedEditor.isEditable)
    }

    func testSaveWhitespaceFollowsFolderAndApplicationSettingsAndSkipsReadOnly() async throws {
        let defaults = try isolatedDefaults()
        let (root, file, _) = try temporaryDocuments()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "paragraph \n\t \n"
        let document = MarkdownDocument(text: text)
        let navigation = DocumentLinkNavigation()
        let opened = host(fileURL: file, defaults: defaults, navigation: navigation, document: document)
        defer { opened.window.orderOut(nil) }

        try await settle(opened, for: .milliseconds(200))
        XCTAssertEqual(try document.dataForSave(), Data(text.utf8))

        opened.settings.setFolderSettings(.init(trimsTrailingWhitespaceOnSave: true,
                                                trimsWhitespaceOnlyLines: true), for: root)
        try await settle(opened, for: .milliseconds(200))
        XCTAssertEqual(try document.dataForSave(), Data("paragraph\n\n".utf8))
        XCTAssertEqual(try document.encodedData(), Data(text.utf8))

        var app = opened.settings.app
        app.trimsTrailingWhitespaceOnSave = true
        opened.settings.setAppSettings(app)
        opened.settings.setFolderSettings(nil, for: root)
        try await settle(opened, for: .milliseconds(200))
        XCTAssertEqual(try document.dataForSave(), Data("paragraph\n\t \n".utf8))

        navigation.requestReadOnlyOpen(for: file)
        try await settle(opened, for: .milliseconds(200))
        XCTAssertEqual(try document.dataForSave(), Data(text.utf8))
    }

    func testNamedLayoutDocumentOpensInTheLayoutMode() async throws {
        let defaults = try isolatedDefaults()
        let (root, a, _) = try temporaryDocuments()
        defer { try? FileManager.default.removeItem(at: root) }
        let activation = WorkspaceLayoutActivation()
        let layout = WorkspaceNamedLayout.capture(name: "Edit", root: root, openDocuments: [a],
            activeDocument: a, mode: .editor, sidebarTab: "outline", sidebarVisible: false,
            splitRatio: 0.5, splitOrientation: .sideBySide, previewFirst: false)
        activation.activate(layout, documents: [a])
        // applyNamedLayout saves the layout's mode for each document before opening it.
        let opened = host(fileURL: a, defaults: defaults, opening: .alwaysPreview,
                          activation: activation, savedMode: layout.mode)
        defer { opened.window.orderOut(nil) }
        try await settle(opened, for: .milliseconds(300))
        XCTAssertTrue(showsEditor(opened))
        XCTAssertFalse(activation.isOpening(a))
    }

    func testUntitledDocumentIgnoresAlwaysPreview() throws {
        let defaults = try isolatedDefaults()
        let untitled = host(fileURL: nil, defaults: defaults, opening: .alwaysPreview)
        defer { untitled.window.orderOut(nil) }
        XCTAssertTrue(showsEditor(untitled), "a new document starts in the app default (split)")
    }
}
