import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

@MainActor
final class EditorScrollClippingTests: XCTestCase {
    func testSourceEditorClipsRulerAndBackgroundAtPaneBoundary() throws {
        let model = MarkdownEditorModel()
        let host = NSHostingView(rootView: MarkdownTextEditor(
            text: .constant("# Heading\n\nBody"), model: model))
        try checkClipping(in: host) { scroll in
            XCTAssertTrue(scroll.rulersVisible)
            XCTAssertTrue(scroll.verticalRulerView is MarkdownLineNumberRulerView)
            XCTAssertTrue(scroll.documentView is EditorTextView)
        }
    }

    func testPlainTextPreviewClipsBackgroundAtPaneBoundary() throws {
        // Plain paragraphs use the AppKit preview, unlike structured headings.
        let host = NSHostingView(rootView: MarkdownPreview(markdown: "Plain paragraph",
            documentContext: DocumentContext(fileURL: nil)))
        try checkClipping(in: host) { scroll in
            let text = try XCTUnwrap(scroll.documentView as? NSTextView)
            XCTAssertTrue(text.isSelectable)
            XCTAssertFalse(text.isEditable)
        }
    }

    func testStructuredPreviewRetainsEmbeddedStateAfterUpstreamInsertion() async throws {
        // Exercise the actual row subtree: recreating it reruns the embed's task.
        for sharedAnalysis in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let document = root.appendingPathComponent("main.md")
            let embedded = root.appendingPathComponent("note.md")
            var loads = 0
            func preview(_ source: String) -> MarkdownPreview {
                MarkdownPreview(markdown: source, documentContext: DocumentContext(fileURL: document),
                    snapshot: sharedAnalysis ? DocumentSnapshot(source: source) : nil,
                    usesSharedAnalysis: sharedAnalysis, workspaceDocumentURLs: [document, embedded],
                    workspaceDiskRevision: 0, loadWorkspaceOpenBuffers: {
                        loads += 1
                        return [embedded: Data("Embedded body".utf8)]
                    })
            }
            let host = NSHostingView(rootView: preview("![[note]]"))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            for _ in 0..<100 where loads == 0 { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(loads, 1)
            try await Task.sleep(for: .milliseconds(100))
            host.rootView = preview("Inserted paragraph\n\n![[note]]")
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(loads, 1, "An unchanged embed must retain state despite a changed parser block ID")
            window.orderOut(nil)
            window.contentView = nil
        }
    }

    private func checkClipping<V: View>(
        in host: NSHostingView<V>, inspect: (NSScrollView) throws -> Void
    ) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }
        for size in [NSSize(width: 600, height: 400), NSSize(width: 320, height: 240)] {
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(findTextScrollView(in: host))
            XCTAssertTrue(scroll.clipsToBounds,
                          "Unclipped AppKit drawing leaks the ruler/background into the titlebar.")
            try inspect(scroll)
        }
    }

    private func findTextScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.documentView is NSTextView { return scroll }
        return view.subviews.lazy.compactMap { self.findTextScrollView(in: $0) }.first
    }
}
