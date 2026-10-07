import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

@MainActor
final class MarkdownSyntaxHighlighterTests: XCTestCase {
    func testSameSourceDialectSwitchRefreshesColorsAndRejectsPendingSnapshot() {
        let source = "---\n    coode\n---\n\nnormal prose"
        let location = (source as NSString).range(of: "coode").location
        for usesSharedAnalysis in [true, false] {
            let view = NSTextView()
            view.string = source
            let model = MarkdownEditorModel()
            let coordinator = MarkdownTextEditor.Coordinator(text: .constant(source), model: model)
            coordinator.textView = view
            coordinator.usesSharedAnalysis = usesSharedAnalysis
            for dialect in [MarkdownDialect.basic, .extended, .basic] {
                model.markdownDialect = dialect
                if usesSharedAnalysis {
                    let previousColor = color(at: location, in: view)
                    coordinator.refreshSyntax()
                    XCTAssertEqual(color(at: location, in: view), previousColor,
                                   "Pending mode analysis must preserve existing colors")
                    coordinator.sharedSnapshot = DocumentSnapshot(source: source, dialect: dialect)
                }
                coordinator.refreshSyntax()
                XCTAssertEqual(color(at: location, in: view),
                               dialect == .basic ? .systemPurple : nil)
                XCTAssertEqual(view.string, source)
            }
        }
    }

    func testSharedAnalysisKeepsHeadingColorThroughoutPendingEdits() {
        let view = NSTextView()
        view.string = "# Heading\n\nbody"
        let coordinator = MarkdownTextEditor.Coordinator(text: .constant(view.string),
                                                         model: MarkdownEditorModel())
        coordinator.textView = view
        coordinator.usesSharedAnalysis = true
        coordinator.sharedSnapshot = DocumentSnapshot(source: view.string)
        coordinator.refreshSyntax()
        XCTAssertEqual(color(at: 2, in: view), .systemBlue)

        for addition in ["a", "b", "日本語"] {
            view.textStorage?.replaceCharacters(
                in: NSRange(location: (view.string as NSString).length, length: 0), with: addition)
            coordinator.refreshSyntax()
            XCTAssertEqual(color(at: 2, in: view), .systemBlue,
                           "Pending analysis must not clear the heading's color")
        }
        coordinator.sharedSnapshot = DocumentSnapshot(source: view.string)
        coordinator.refreshSyntax()
        XCTAssertEqual(color(at: 2, in: view), .systemBlue)
    }

    func testPendingAnalysisPreservesShiftedColorsThenClearsRemovedHeading() {
        let view = NSTextView()
        view.string = "body\n\n# Heading"
        let coordinator = MarkdownTextEditor.Coordinator(text: .constant(view.string),
                                                         model: MarkdownEditorModel())
        coordinator.textView = view
        coordinator.usesSharedAnalysis = true
        coordinator.sharedSnapshot = DocumentSnapshot(source: view.string)
        coordinator.refreshSyntax()

        view.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "😀")
        let heading = (view.string as NSString).range(of: "Heading")
        coordinator.refreshSyntax()
        XCTAssertEqual(color(at: heading.location, in: view), .systemBlue)

        let marker = (view.string as NSString).range(of: "# ")
        view.textStorage?.replaceCharacters(in: marker, with: "")
        coordinator.refreshSyntax()
        let newHeading = (view.string as NSString).range(of: "Heading")
        XCTAssertEqual(color(at: newHeading.location, in: view), .systemBlue)
        coordinator.sharedSnapshot = DocumentSnapshot(source: view.string)
        coordinator.refreshSyntax()
        XCTAssertNil(color(at: newHeading.location, in: view))
    }

    private func color(at location: Int, in view: NSTextView) -> NSColor? {
        view.layoutManager?.temporaryAttribute(.foregroundColor,
            atCharacterIndex: location, effectiveRange: nil) as? NSColor
    }

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
