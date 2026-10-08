import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

/// Input methods such as Google Japanese Input keep text "marked" while the user composes it.
/// A SwiftUI re-render during that composition must not reset the text view from the binding,
/// because that destroys the composition and makes AppKit ask the input method to commit.
@MainActor
final class EditorCompositionTests: XCTestCase {
    private final class Document: ObservableObject {
        @Published var text: String
        init(text: String) { self.text = text }
    }

    private struct Host: View {
        @ObservedObject var document: Document
        let model: MarkdownEditorModel
        var body: some View {
            MarkdownTextEditor(text: $document.text, model: model)
        }
    }

    private func findTextView(in view: NSView) -> EditorTextView? {
        if let scroll = view as? NSScrollView, let text = scroll.documentView as? EditorTextView { return text }
        return view.subviews.lazy.compactMap { self.findTextView(in: $0) }.first
    }

    func testReRenderDuringCompositionKeepsMarkedText() async throws {
        let document = Document(text: "")
        let model = MarkdownEditorModel()
        let host = NSHostingView(rootView: Host(document: document, model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(findTextView(in: host))
        window.makeFirstResponder(textView)

        textView.setMarkedText("にほんご", selectedRange: NSRange(location: 4, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(textView.hasMarkedText())
        XCTAssertEqual(textView.string, "にほんご")

        // Any observed object change re-renders the editor while the user is still composing.
        document.objectWillChange.send()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(textView.hasMarkedText(), "a re-render must not end the composition")
        XCTAssertEqual(textView.string, "にほんご", "a re-render must not discard composed text")

        textView.insertText("日本語", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(textView.hasMarkedText())
        XCTAssertEqual(textView.string, "日本語")
        XCTAssertEqual(document.text, "日本語", "the committed text must reach the binding")
    }
}
