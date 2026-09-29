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
