import AppKit
import XCTest
@testable import MKTownEditor

final class MarkdownLineContinuationTests: XCTestCase {
    func testBulletsAndOrderedListsContinueAtCaret() {
        assertContinuation("- one|", becomes: "- one\n- |")
        assertContinuation("  + two|", becomes: "  + two\n  + |")
        assertContinuation("9) item|", becomes: "9) item\n10) |")
        assertContinuation("😀\n12. item|", becomes: "😀\n12. item\n13. |")
        assertContinuation("1. foo|bar", becomes: "1. foo\n2. |bar")
    }

    func testTasksResetCompletionAndQuoteLevelContinues() {
        assertContinuation("- [x] done|", becomes: "- [x] done\n- [ ] |")
        assertContinuation("> - [X] done|", becomes: "> - [X] done\n> - [ ] |")
        assertContinuation("> > nested|", becomes: "> > nested\n> > |")
        assertContinuation("> quote|", becomes: "> quote\n> |")
    }

    func testEmptyItemsExitOneStructureAtATime() {
        assertContinuation("- |", becomes: "|")
        assertContinuation("- [ ] |", becomes: "|")
        assertContinuation("- [ ]|", becomes: "|")
        assertContinuation("first\n> - |", becomes: "first\n> |")
        assertContinuation("> > |", becomes: "> |")
        assertContinuation("> |", becomes: "|")
    }

    func testCRLFIsPreservedAndCodeBlocksDoNotContinue() {
        assertContinuation("- one\r\n- two|", becomes: "- one\r\n- two\r\n- |")
        assertContinuation("- one\r- two|", becomes: "- one\r- two\r- |")
        XCTAssertNil(MarkdownLineContinuation.edit(in: "```\n- code", selection: NSRange(location: 6, length: 0)))
        XCTAssertNil(MarkdownLineContinuation.edit(in: "    - code", selection: NSRange(location: 10, length: 0)))
        XCTAssertNil(MarkdownLineContinuation.edit(in: "plain", selection: NSRange(location: 5, length: 0)))
        XCTAssertNil(MarkdownLineContinuation.edit(in: "- item", selection: NSRange(location: 0, length: 0)))
        XCTAssertNil(MarkdownLineContinuation.edit(in: "- item", selection: NSRange(location: 2, length: 2)))
    }

    private func assertContinuation(_ marked: String, becomes expected: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let text = marked.replacingOccurrences(of: "|", with: "")
        let location = (marked as NSString).range(of: "|").location
        let edit = MarkdownLineContinuation.edit(in: text, selection: NSRange(location: location, length: 0))
        XCTAssertNotNil(edit, file: file, line: line)
        guard let edit else { return }
        XCTAssertEqual(edit.applying(to: text), expected.replacingOccurrences(of: "|", with: ""),
                       file: file, line: line)
        XCTAssertEqual(edit.selection.location, (expected as NSString).range(of: "|").location,
                       file: file, line: line)
    }
}

@MainActor
final class MarkdownLineContinuationEditorTests: XCTestCase {
    func testReturnIsUndoableAndKeepsSelection() {
        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.allowsUndo = true
        view.string = "- item"
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        let model = MarkdownEditorModel()
        model.connect(view)
        view.commandModel = model
        view.setSelectedRange(NSRange(location: 6, length: 0))

        view.insertNewline(nil)

        XCTAssertEqual(view.string, "- item\n- ")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 9, length: 0))
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "- item")
    }

    func testRejectedMarkdownEditIsStillHandled() {
        let view = RejectingContinuationTextView()
        view.string = "- item"
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: 6, length: 0))

        XCTAssertTrue(model.continueListOrQuote())

        XCTAssertEqual(view.string, "- item")
    }

    func testMarkedTextIsLeftToInputMethod() {
        let view = ComposingContinuationTextView()
        view.string = "- 日本語"
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))

        XCTAssertFalse(model.continueListOrQuote())
        XCTAssertEqual(view.string, "- 日本語")
    }
}

private final class RejectingContinuationTextView: NSTextView {
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        false
    }
}

private final class ComposingContinuationTextView: NSTextView {
    override func hasMarkedText() -> Bool { true }
}
