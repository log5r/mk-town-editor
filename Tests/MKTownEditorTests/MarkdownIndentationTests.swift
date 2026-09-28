import AppKit
import XCTest
@testable import MKTownEditor

final class MarkdownIndentationTests: XCTestCase {
    func testSelectedListItemIndentsAndOutdents() {
        let text = "- parent\n- child"
        let caret = NSRange(location: (text as NSString).range(of: "child").location, length: 0)
        let indented = tryEdit(text, caret, .indent)
        XCTAssertEqual(indented.applying(to: text), "- parent\n  - child")
        XCTAssertEqual(indented.selection.location, caret.location + 2)

        let outdented = tryEdit(indented.applying(to: text), indented.selection, .outdent)
        XCTAssertEqual(outdented.applying(to: indented.applying(to: text)), text)
    }

    func testParentIndentMovesDescendantsButNotFollowingSibling() {
        let text = "- parent\n  - child\n\n    continuation\n- sibling"
        let edit = tryEdit(text, NSRange(location: 2, length: 0), .indent)

        XCTAssertEqual(edit.applying(to: text),
                       "  - parent\n    - child\n\n      continuation\n- sibling")
    }

    func testQuotePrefixIsKeptAheadOfListIndent() {
        let text = "> - parent\n>   - child"
        let edit = tryEdit(text, NSRange(location: 4, length: 0), .indent)

        XCTAssertEqual(edit.applying(to: text), ">   - parent\n>     - child")
    }

    func testOutdentingRootItemDoesNotOutdentItsChildren() {
        let text = "- parent\n  - child"

        XCTAssertNil(MarkdownIndentation.edit(in: text, selection: NSRange(location: 2, length: 0),
                                             direction: .outdent))
    }

    func testSelectedLinesAndCRLFKeepSelectionAndLineEndings() {
        let text = "- one\r\n- two\r\nplain"
        let edit = tryEdit(text, NSRange(location: 0, length: 14), .indent)

        XCTAssertEqual(edit.applying(to: text), "  - one\r\n  - two\r\nplain")
        XCTAssertEqual(edit.selection, NSRange(location: 2, length: 16))
    }

    func testCodeBlockUsesFourSpacesAndPlainTextHasNoMarkdownEdit() {
        let text = "```\ncode\n```"
        let edit = tryEdit(text, NSRange(location: 4, length: 0), .indent)
        XCTAssertEqual(edit.applying(to: text), "```\n    code\n```")
        let outdent = tryEdit(edit.applying(to: text), edit.selection, .outdent)
        XCTAssertEqual(outdent.applying(to: edit.applying(to: text)), text)
        XCTAssertNil(MarkdownIndentation.edit(in: "plain", selection: NSRange(location: 2, length: 0),
                                             direction: .indent))
    }

    func testConfiguredListAndCodeIndentWidths() {
        let list = "- first\n- second"
        let item = MarkdownIndentation.edit(in: list, selection: NSRange(location: 10, length: 0),
                                            direction: .indent, listIndentWidth: 4, codeIndentWidth: 8)
        XCTAssertEqual(item?.applying(to: list), "- first\n    - second")

        let code = "```\ncode\n```"
        let edit = MarkdownIndentation.edit(in: code, selection: NSRange(location: 4, length: 0),
                                            direction: .indent, listIndentWidth: 4, codeIndentWidth: 8)
        XCTAssertEqual(edit?.applying(to: code), "```\n        code\n```")
    }

    private func tryEdit(_ text: String, _ selection: NSRange,
                         _ direction: MarkdownIndentation.Direction,
                         file: StaticString = #filePath, line: UInt = #line) -> MarkdownEdit {
        let edit = MarkdownIndentation.edit(in: text, selection: selection, direction: direction)
        XCTAssertNotNil(edit, file: file, line: line)
        return edit ?? MarkdownEdit(range: selection, replacement: "", selection: selection)
    }
}

@MainActor
final class MarkdownIndentationEditorTests: XCTestCase {
    func testTabAndBacktabUseUndoableListEdit() {
        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.allowsUndo = true
        view.string = "- first\n- second"
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        let model = MarkdownEditorModel()
        model.connect(view)
        view.commandModel = model
        view.setSelectedRange(NSRange(location: 10, length: 0))

        view.insertTab(nil)
        XCTAssertEqual(view.string, "- first\n  - second")
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "- first\n- second")

        view.setSelectedRange(NSRange(location: 10, length: 0))
        EditorCommand.indentList.perform(on: model)
        XCTAssertEqual(view.string, "- first\n  - second")
        EditorCommand.outdentList.perform(on: model)
        XCTAssertEqual(view.string, "- first\n- second")
    }
}
