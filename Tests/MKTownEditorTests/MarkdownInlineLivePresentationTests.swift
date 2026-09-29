import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

@MainActor
final class MarkdownInlineLivePresentationTests: XCTestCase {
    func testMarkersExcludeCodeBlocksAndKeepVisibleLabels() {
        let source = "# 😀 Title\n**bold** [label](target.md) `code`\n```md\n**literal** [no](url)\n```"
        let text = source as NSString
        let ranges = MarkdownInlineLivePresentation.markerRanges(
            in: source, spans: MarkdownSyntaxHighlighter.spans(in: source))
        let fragments = ranges.map { text.substring(with: $0) }

        XCTAssertTrue(fragments.contains("#"))
        XCTAssertEqual(fragments.filter { $0 == "**" }.count, 2)
        XCTAssertTrue(fragments.contains("["))
        XCTAssertTrue(fragments.contains("](target.md)"))
        XCTAssertEqual(fragments.filter { $0 == "`" }.count, 2)
        XCTAssertFalse(ranges.contains { $0.location >= text.range(of: "```md").location })
        XCTAssertFalse(fragments.contains("label"))
    }

    func testActiveLinesUseUTF16SelectionAcrossCRLF() {
        let source = "😀 first\r\nsecond\nthird" as NSString
        let selection = source.range(of: "second")
        let lines = MarkdownInlineLivePresentation.activeLines(in: source as String,
            selections: [selection, NSRange(location: source.length + 1, length: 0)])

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(source.substring(with: lines[0]), "second\n")
    }

    func testPresentationRestoresActiveMarkersWithoutChangingTextCopyOrUndo() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.allowsUndo = true
        view.string = "**bold**\n# Heading"
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        view.undoManager?.removeAllActions()
        MarkdownSyntaxHighlighter.apply(to: view)
        let source = view.string
        let ranges = MarkdownInlineLivePresentation.markerRanges(in: source,
            spans: MarkdownSyntaxHighlighter.spans(in: source))
        let display = MarkdownInlineLiveDisplay(textView: view, ranges: ranges)
        let firstLine = (source as NSString).lineRange(for: NSRange(location: 0, length: 0))
        let original = color(at: 0, in: view)

        display.update(in: view, activeLines: [], force: true)
        XCTAssertEqual(color(at: 0, in: view), .tertiaryLabelColor)
        display.update(in: view, activeLines: [firstLine])
        XCTAssertEqual(color(at: 0, in: view), original)
        XCTAssertEqual(color(at: (source as NSString).range(of: "#").location, in: view),
                       .tertiaryLabelColor)
        view.setSelectedRange((source as NSString).range(of: "bold"))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        view.copy(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), "bold")
        XCTAssertEqual(view.string, source)
        XCTAssertFalse(view.undoManager?.canUndo ?? false)
    }

    func testCompositionLeavesCurrentColorsUntouched() {
        let view = ComposingInlineTextView()
        view.string = "**日本語**"
        MarkdownSyntaxHighlighter.apply(to: view)
        let ranges = MarkdownInlineLivePresentation.markerRanges(in: view.string,
            spans: MarkdownSyntaxHighlighter.spans(in: view.string))
        let display = MarkdownInlineLiveDisplay(textView: view, ranges: ranges)
        view.layoutManager?.addTemporaryAttribute(.foregroundColor, value: NSColor.systemRed,
            forCharacterRange: ranges[0])
        display.update(in: view, activeLines: [], force: true)
        XCTAssertEqual(color(at: ranges[0].location, in: view), .systemRed)
    }

    func testCoordinatorUpdatesActiveLineAndCanDisableMode() {
        let source = "**first**\n**second**"
        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.string = source
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        let coordinator = MarkdownTextEditor.Coordinator(text: .constant(source),
                                                         model: MarkdownEditorModel())
        coordinator.textView = view
        coordinator.sharedSnapshot = DocumentSnapshot(source: source)
        coordinator.usesSharedAnalysis = true
        coordinator.usesInlineLivePresentation = true
        coordinator.refreshSyntax()

        XCTAssertEqual(color(at: 0, in: view), .secondaryLabelColor)
        let second = (source as NSString).range(of: "**second")
        XCTAssertEqual(color(at: second.location, in: view), .tertiaryLabelColor)
        view.setSelectedRange(NSRange(location: second.location + 3, length: 0))
        coordinator.refreshSyntax()
        XCTAssertEqual(color(at: 0, in: view), .tertiaryLabelColor)
        XCTAssertEqual(color(at: second.location, in: view), .secondaryLabelColor)

        coordinator.usesInlineLivePresentation = false
        coordinator.refreshSyntax()
        XCTAssertEqual(color(at: 0, in: view), .secondaryLabelColor)
        XCTAssertEqual(color(at: second.location, in: view), .secondaryLabelColor)
    }

    private func color(at location: Int, in view: NSTextView) -> NSColor? {
        view.layoutManager?.temporaryAttribute(.foregroundColor,
            atCharacterIndex: location, effectiveRange: nil) as? NSColor
    }
}

private final class ComposingInlineTextView: NSTextView {
    override func hasMarkedText() -> Bool { true }
}
