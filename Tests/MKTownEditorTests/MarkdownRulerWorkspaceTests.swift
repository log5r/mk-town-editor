import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

@MainActor
final class MarkdownRulerWorkspaceTests: XCTestCase {
    private final class DocumentState: ObservableObject {
        @Published var document: MarkdownDocument

        init(text: String = "") {
            document = MarkdownDocument(text: text)
        }
    }

    private struct Root: View {
        @ObservedObject var state: DocumentState
        var body: some View {
            EditorWorkspace(document: $state.document, fileURL: nil)
        }
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { ([$0 as? T].compactMap { $0 }) + descendants(of: $0, as: type) }
    }

    func testWorkspaceRulerPositionsWhileAppendingAndRemovingBlankLines() async throws {
        let suite = "MarkdownRulerWorkspaceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = EditorSettingsStore(defaults: defaults)
        var appSettings = settings.app
        appSettings.showsLineNumbers = true
        settings.setAppSettings(appSettings)
        let state = DocumentState()
        let controller = NSHostingController(rootView: Root(state: state)
            .environmentObject(settings)
            .environmentObject(DocumentLinkNavigation())
            .environmentObject(WorkspaceStore(defaults: defaults))
            .environmentObject(WorkspaceLayoutActivation()))
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 910, height: 584))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentViewController = nil }

        func settle() async throws {
            for _ in 0..<5 {
                controller.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try await settle()
        let editor = try XCTUnwrap(descendants(of: controller.view, as: EditorTextView.self).first)
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        let ruler = try XCTUnwrap(scroll.verticalRulerView as? MarkdownLineNumberRulerView)
        window.makeFirstResponder(editor)
        try await settle()

        func positions() -> [Int: CGFloat] {
            scroll.displayIfNeeded()
            let labels = MarkdownLineNumberLayout.labels(in: editor,
                visibleRect: editor.visibleRect, cachedIndex: ruler.index)
            let result = Dictionary(uniqueKeysWithValues: labels.map {
                ($0.number, ruler.convert($0.origin, from: editor).y)
            })
            return result
        }

        var previous = positions()
        for count in 1...20 {
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            editor.insertNewline(nil)
            try await settle()
            let current = positions()
            for (number, y) in previous where current[number] != nil {
                XCTAssertEqual(current[number]!, y, accuracy: 0.01, "append \(count), line \(number)")
            }
            XCTAssertEqual(state.document.text, editor.string)
            previous = current
        }
        for count in 1...20 {
            editor.deleteBackward(nil)
            try await settle()
            let current = positions()
            for (number, y) in current where previous[number] != nil {
                XCTAssertEqual(y, previous[number]!, accuracy: 0.01, "remove \(count), line \(number)")
            }
            XCTAssertEqual(state.document.text, editor.string)
            previous = current
        }
    }

    func testOnlyPreviewUserScrollingMovesSourceEditor() async throws {
        let suite = "MarkdownRulerWorkspaceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = DocumentState(text: (0..<100).map {
            "# Heading \($0)\n\nParagraph \($0) for scroll synchronization.\n\n"
        }.joined())
        let controller = NSHostingController(rootView: Root(state: state)
            .environmentObject(EditorSettingsStore(defaults: defaults))
            .environmentObject(DocumentLinkNavigation())
            .environmentObject(WorkspaceStore(defaults: defaults))
            .environmentObject(WorkspaceLayoutActivation()))
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 910, height: 584))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentViewController = nil }

        func settle() async throws {
            for _ in 0..<20 {
                controller.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try await settle()
        let editor = try XCTUnwrap(descendants(of: controller.view, as: EditorTextView.self).first)
        let sourceScroll = try XCTUnwrap(editor.enclosingScrollView)
        let probe = try XCTUnwrap(descendants(of: controller.view,
            as: PreviewUserScrollObserver.ScrollProbe.self).first)
        _ = try XCTUnwrap(probe.monitor, "the preview must retain its scroll monitor")
        let previewScroll = try XCTUnwrap(probe.enclosingScrollView,
            "the observer must be inside the preview's native scroll view")
        XCTAssertFalse(previewScroll === sourceScroll)
        let originalSourceY = sourceScroll.contentView.bounds.origin.y
        let selection = editor.selectedRange()

        previewScroll.contentView.scroll(to: NSPoint(x: previewScroll.contentView.bounds.origin.x, y: 500))
        previewScroll.reflectScrolledClipView(previewScroll.contentView)
        try await settle()
        XCTAssertGreaterThan(previewScroll.contentView.bounds.origin.y, 0)
        XCTAssertEqual(sourceScroll.contentView.bounds.origin.y, originalSourceY, accuracy: 0.01,
            "programmatic preview movement and geometry updates must not scroll the source")

        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: previewScroll)
        try await settle()
        XCTAssertGreaterThan(sourceScroll.contentView.bounds.origin.y, originalSourceY,
            "user scrolling in the actual preview must still synchronize the source")
        XCTAssertEqual(editor.selectedRange(), selection)
    }
}
