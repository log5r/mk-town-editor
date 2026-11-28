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

        let child = NSRange(location: (text as NSString).range(of: "child").location, length: 0)
        XCTAssertEqual(tryEdit(text, child, .outdent).applying(to: text), "> - parent\n> - child")
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

    func testDetectsDominantStyleAndSpaceWidth() {
        XCTAssertEqual(MarkdownIndentation.detect(in: "いち\r\n   二\r\n      👪\n   三\n\t  \n"),
                       .init(style: .spaces, width: 3))
        XCTAssertEqual(MarkdownIndentation.detect(in: "root\n\tchild\n\t  alignment\n  other"),
                       .init(style: .tabs, width: nil))
        XCTAssertNil(MarkdownIndentation.detect(in: "root\n  spaces\n\ttabs"))
        XCTAssertNil(MarkdownIndentation.detect(in: "root\n one\n  \n \t mixed"))
    }

    func testConvertSelectedLinesKeepsColumnsUnicodeAndCRLF() {
        let text = "    対象外\r\n  \t猫\t本文\r\n      🐈\r\n    対象外"
        let source = text as NSString
        let selected = source.range(of: "猫\t本文\r\n      🐈\r\n")
        let tabs = MarkdownIndentation.conversionEdit(in: text, selection: selected, to: .tabs)
        XCTAssertEqual(tabs?.applying(to: text), "    対象外\r\n\t猫\t本文\r\n\t  🐈\r\n    対象外")
        guard let tabs else { return }

        let tabText = tabs.applying(to: text)
        let spaces = MarkdownIndentation.conversionEdit(in: tabText, selection: tabs.selection, to: .spaces)
        XCTAssertEqual(spaces?.applying(to: tabText), "    対象外\r\n    猫\t本文\r\n      🐈\r\n    対象外")
        XCTAssertNil(MarkdownIndentation.conversionEdit(in: text, selection: NSRange(location: 0, length: 0),
                                                        to: .tabs))
    }

    func testOutdentMixedPrefixReducesMarkdownColumn() {
        let text = "- parent\n  \t- child"
        let caret = NSRange(location: (text as NSString).range(of: "child").location, length: 0)
        let edit = tryEdit(text, caret, .outdent)
        XCTAssertEqual(edit.applying(to: text), "- parent\n  - child")
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

    func testSelectedProseTabPreservesTextSelectionAndUndo() {
        let text = "猫🐈\n犬\n未選択"
        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.allowsUndo = true
        view.string = text
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        let model = MarkdownEditorModel()
        model.connect(view)
        model.usesSharedAnalysis = true
        model.configureWhitespaceEditing(.init(indentationStyle: .tabs), source: text, fileURL: nil, tabWidth: 4)
        view.commandModel = model
        let selection = (text as NSString).range(of: "🐈\n犬\n")
        view.setSelectedRange(selection)

        view.insertTab(nil)
        XCTAssertEqual(view.string, "\t猫🐈\n\t犬\n未選択")
        XCTAssertEqual(view.selectedRange(), NSRange(location: selection.location + 1, length: selection.length + 1))
        view.undoManager?.undo()
        XCTAssertEqual(view.string, text)

        view.setSelectedRange(selection)
        view.insertTab(nil)
        view.insertBacktab(nil)
        XCTAssertEqual(view.string, text)
    }

    func testDetectionKeepsOpeningStyleAndFallsBackForNextDocument() {
        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let model = MarkdownEditorModel()
        model.connect(view)
        view.commandModel = model
        let document = URL(fileURLWithPath: "/detected.md")
        let options = EditorWhitespaceEditingOptions(detectsIndentation: true)
        model.configureWhitespaceEditing(options, source: "root\n   child\n      grandchild", fileURL: document,
                                         tabWidth: 6)
        model.configureWhitespaceEditing(options, source: "now\n\tafter editing", fileURL: document, tabWidth: 6)
        view.string = "字"
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertTab(nil)
        XCTAssertEqual(view.string, "   字")

        view.string = "文"
        model.configureWhitespaceEditing(options, source: view.string, fileURL: URL(fileURLWithPath: "/new.md"),
                                         tabWidth: 6)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertTab(nil)
        XCTAssertEqual(view.string, "      文")
    }

    func testTabInListUsesStructureWhileSharedAnalysisIsPending() {
        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.string = "- parent\n- item"
        let model = MarkdownEditorModel()
        model.connect(view)
        model.usesSharedAnalysis = true
        view.commandModel = model
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))

        view.insertTab(nil)
        XCTAssertEqual(view.string, "- parent\n  - item")
    }
}
