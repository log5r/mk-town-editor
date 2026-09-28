import AppKit
import XCTest
@testable import MKTownEditor

@MainActor
final class MarkdownEditorModelTests: XCTestCase {
    func testRejectedEditDoesNotChangeTextOrSelection() {
        let view = RejectingTextView()
        view.string = "hello"
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: 1, length: 2))

        model.apply(.bold)

        XCTAssertEqual(view.string, "hello")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 2))
    }

    func testMarkedTextDoesNotChangeDuringComposition() {
        let view = MarkedTextView()
        view.string = "日本語"
        let model = MarkdownEditorModel()
        model.connect(view)

        model.apply(.bold)

        XCTAssertEqual(view.string, "日本語")
    }

    func testConsecutiveCommandsUndoIndividually() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.allowsUndo = true
        view.string = "hello"
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: 0, length: 5))

        model.apply(.bold)
        XCTAssertEqual(view.string, "**hello**")
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        model.apply(.italic)
        XCTAssertEqual(view.string, "**_hello_**")
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "**hello**")
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "hello")
    }

    func testToggleRemovesFormattingAndUndoRestoresMarkersAndSelection() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.allowsUndo = true
        view.string = "**word**"
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: 2, length: 4))

        model.apply(.bold)
        XCTAssertEqual(view.string, "word")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 4))
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "**word**")
    }

    func testTaskCompletionCommandIsUndoable() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.allowsUndo = true
        view.string = "- [ ] first\n- [x] second"
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))

        model.toggleTaskCompletion()
        XCTAssertEqual(view.string, "- [x] first\n- [x] second")
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "- [ ] first\n- [x] second")
    }

    func testPreviewTaskActionPreservesSourceSelectionAndFocus() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.string = "- [ ] first\n- [ ] second"
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: 22, length: 0))

        model.toggleTask(at: 0)

        XCTAssertEqual(view.string, "- [x] first\n- [ ] second")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 22, length: 0))
    }

    func testCodeBlockCommandIsUndoable() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.allowsUndo = true
        view.string = "print(1)"
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: 0, length: 8))

        model.apply(.codeBlock(language: .swift))
        XCTAssertEqual(view.string, "```swift\nprint(1)\n```")
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "print(1)")
    }

    func testDisconnectAndReconnectRestoreSelectionWithoutKeepingOldView() {
        let oldView = NSTextView()
        oldView.string = "前🙂後"
        let model = MarkdownEditorModel()
        model.connect(oldView)
        oldView.setSelectedRange(NSRange(location: 1, length: 2))
        model.selectionDidChange(oldView.selectedRange())
        model.disconnect(oldView)
        XCTAssertNil(model.textView)

        let newView = NSTextView()
        newView.string = oldView.string
        model.connect(newView)
        model.disconnect(oldView)

        XCTAssertTrue(model.textView === newView)
        XCTAssertEqual(newView.selectedRange(), NSRange(location: 1, length: 2))
    }

    func testReconnectClampsSelectionAfterExternalTextChange() {
        let view = NSTextView()
        view.string = "long text"
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: 5, length: 4))
        model.disconnect(view)

        let replacement = NSTextView()
        replacement.string = "短"
        model.connect(replacement)

        XCTAssertEqual(replacement.selectedRange(), NSRange(location: 1, length: 0))
    }

    func testFocusRestoresOnlyForCurrentEditorView() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        let model = MarkdownEditorModel()
        model.connect(view)
        model.disconnect(view)
        XCTAssertTrue(model.shouldRestoreFocus)

        let replacement = NSTextView(frame: view.frame)
        window.contentView = replacement
        model.connect(replacement)
        model.restoreFocusIfNeeded(view)
        XCTAssertFalse(window.firstResponder === view)
        model.restoreFocusIfNeeded(replacement)
        XCTAssertTrue(window.firstResponder === replacement)
    }

    func testReconnectRestoresScrollPosition() {
        let model = MarkdownEditorModel()
        let oldView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 1_000))
        let oldScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        oldScrollView.documentView = oldView
        model.connect(oldView, scrollView: oldScrollView)
        oldScrollView.contentView.scroll(to: NSPoint(x: 0, y: 200))
        model.disconnect(oldView, scrollView: oldScrollView)

        let newView = NSTextView(frame: oldView.frame)
        let newScrollView = NSScrollView(frame: oldScrollView.frame)
        newScrollView.documentView = newView
        model.connect(newView, scrollView: newScrollView)

        XCTAssertEqual(newScrollView.contentView.bounds.origin.y, 200)
    }

    func testFocusStateSurvivesViewRemovalBeforeDisconnect() {
        let model = MarkdownEditorModel()
        let view = NSTextView()
        model.connect(view)
        model.editorDidGainFocus(view)

        model.disconnect(view)

        XCTAssertTrue(model.shouldRestoreFocus)
    }

    func testPlainTextHeadingCommandDoesNotCreateAnEdit() {
        let view = ChangeCountingTextView()
        view.string = "本文"
        let model = MarkdownEditorModel()
        model.connect(view)

        model.apply(.heading(level: 0))

        XCTAssertEqual(view.string, "本文")
        XCTAssertEqual(view.changeRequests, 0)
    }
}

private final class RejectingTextView: NSTextView {
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        false
    }
}

private final class MarkedTextView: NSTextView {
    override func hasMarkedText() -> Bool {
        true
    }
}

private final class ChangeCountingTextView: NSTextView {
    var changeRequests = 0

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        changeRequests += 1
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }
}
