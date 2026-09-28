import AppKit
import XCTest
@testable import MKTownEditor

@MainActor
final class MarkdownEditorModelTests: XCTestCase {
    func testRejectedEditDoesNotChangeTextOrSelection() {
        let view = RejectingTextView()
        view.string = "hello"
        view.setSelectedRange(NSRange(location: 1, length: 2))
        let model = MarkdownEditorModel()
        model.connect(view)

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
