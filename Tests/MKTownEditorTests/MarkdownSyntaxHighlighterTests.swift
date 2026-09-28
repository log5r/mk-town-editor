import AppKit
import XCTest
@testable import MKTownEditor

@MainActor
final class MarkdownSyntaxHighlighterTests: XCTestCase {
    func testBlockAndInlineSyntaxUseUTF16SourceRanges() {
        let text = "# 😀 Title\n> - [x] task\n| a | b |\n|---|---|\n| c | d |\n[link](path) `code` **bold**"
        let source = text as NSString
        let spans = MarkdownSyntaxHighlighter.spans(in: text)

        assertSpan(.heading, "# 😀 Title", in: source, spans: spans)
        assertSpan(.quoteMarker, "> ", in: source, spans: spans)
        assertSpan(.listMarker, "-", in: source, spans: spans)
        assertSpan(.taskMarker, "[x]", in: source, spans: spans)
        assertSpan(.tableMarker, "|", in: source, spans: spans)
        assertSpan(.link, "[link](path)", in: source, spans: spans)
        assertSpan(.code, "`code`", in: source, spans: spans)
        assertSpan(.marker, "**", in: source, spans: spans)
    }

    func testCodeBlocksDoNotStyleInnerMarkdown() {
        let text = "```markdown\n# literal\n[link](path) **bold**\n```\n[real](path)"
        let source = text as NSString
        let spans = MarkdownSyntaxHighlighter.spans(in: text)
        let code = source.range(of: "```markdown\n# literal\n[link](path) **bold**\n```")

        XCTAssertTrue(spans.contains { $0.role == .code &&
            $0.range.location <= code.location && NSMaxRange($0.range) >= NSMaxRange(code) })
        XCTAssertFalse(spans.contains { $0.role != .code && NSIntersectionRange($0.range, code).length > 0 })
        assertSpan(.link, "[real](path)", in: source, spans: spans)
    }

    func testEscapedAndInlineCodeMarkersAreNotStyled() {
        let text = #"\*literal* `**code**` **real** \[escaped](url)"#
        let source = text as NSString
        let spans = MarkdownSyntaxHighlighter.spans(in: text)

        XCTAssertFalse(spans.contains { $0.role == .link })
        XCTAssertEqual(spans.filter { $0.role == .marker }.count, 2)
        assertSpan(.code, "`**code**`", in: source, spans: spans)
    }

    func testTemporaryColorsDoNotChangeSourceOrUndoHistory() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.allowsUndo = true
        view.string = "# Heading\nplain"
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        view.undoManager?.removeAllActions()

        MarkdownSyntaxHighlighter.apply(to: view)

        XCTAssertEqual(view.string, "# Heading\nplain")
        XCTAssertNotNil(view.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 0,
                                                               effectiveRange: nil))
        XCTAssertNil(view.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 10,
                                                            effectiveRange: nil))
        XCTAssertFalse(view.undoManager?.canUndo ?? false)
    }

    func testReapplyingAfterSourceChangeRemovesObsoleteColor() {
        let view = NSTextView()
        view.string = "# Heading"
        MarkdownSyntaxHighlighter.apply(to: view)
        XCTAssertNotNil(view.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 0,
                                                               effectiveRange: nil))

        view.string = "plain text"
        MarkdownSyntaxHighlighter.apply(to: view)

        XCTAssertNil(view.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 0,
                                                            effectiveRange: nil))
    }

    func testCompositionDoesNotReplaceExistingTemporaryAttributes() {
        let view = ComposingTextView()
        view.string = "# 日本語"
        view.layoutManager?.addTemporaryAttribute(.foregroundColor, value: NSColor.systemRed,
                                                  forCharacterRange: NSRange(location: 0, length: 1))

        MarkdownSyntaxHighlighter.apply(to: view)

        let color = view.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 0,
                                                            effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, .systemRed)
    }

    private func assertSpan(_ role: MarkdownSyntaxSpan.Role, _ token: String,
                            in source: NSString, spans: [MarkdownSyntaxSpan],
                            file: StaticString = #filePath, line: UInt = #line) {
        let range = source.range(of: token)
        XCTAssertNotEqual(range.location, NSNotFound, file: file, line: line)
        XCTAssertTrue(spans.contains { $0.role == role &&
            $0.range.location <= range.location && NSMaxRange($0.range) >= NSMaxRange(range) },
                      "Missing \(role) at \(range)", file: file, line: line)
    }
}

private final class ComposingTextView: NSTextView {
    override func hasMarkedText() -> Bool { true }
}
