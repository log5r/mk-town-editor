import AppKit
import XCTest
@testable import MKTownEditor

final class MarkdownSymbolCompletionTests: XCTestCase {
    func testMarkersInsideMultilineCodeAreNotCompleted() {
        for text in ["`first\nsecond`", "``first `\nsecond``", "😀 `first\r\nsecond`"] {
            let caret = (text as NSString).range(of: "second").location + 2
            for marker in ["*", "_", "`"] {
                XCTAssertNil(MarkdownSymbolCompletion.edit(in: text,
                    selection: NSRange(location: caret, length: 0), typed: marker))
                XCTAssertNil(MarkdownSymbolCompletion.edit(in: text,
                    selection: NSRange(location: caret, length: 0), typed: marker,
                    allowsAnalysis: false))
            }
        }
    }

    func testPairsAtUTF16CaretPosition() {
        for (opening, expected) in [("(", "()"), ("[", "[]"), ("{", "{}"),
                                    ("`", "``"), ("*", "**"), ("_", "__")] {
            let text = "😀"
            let edit = MarkdownSymbolCompletion.edit(in: text, selection: NSRange(location: 2, length: 0),
                                                     typed: opening)
            XCTAssertEqual(edit?.applying(to: text), text + expected)
            XCTAssertEqual(edit?.selection, NSRange(location: 3, length: 0))
        }
    }

    func testSelectedTextIsWrappedAndSelectionRemainsInside() {
        let text = "abc"
        let edit = MarkdownSymbolCompletion.edit(in: text, selection: NSRange(location: 0, length: 3),
                                                 typed: "*")
        XCTAssertEqual(edit?.applying(to: text), "*abc*")
        XCTAssertEqual(edit?.selection, NSRange(location: 1, length: 3))

        let code = MarkdownSymbolCompletion.edit(in: "a`b", selection: NSRange(location: 0, length: 3),
                                                 typed: "`")
        XCTAssertEqual(code?.applying(to: "a`b"), "``a`b``")
        XCTAssertEqual(code?.selection, NSRange(location: 2, length: 3))
    }

    func testEscapedMarkersAndCodeContext() {
        XCTAssertNil(MarkdownSymbolCompletion.edit(in: "\\", selection: NSRange(location: 1, length: 0),
                                                   typed: "*"))
        XCTAssertNotNil(MarkdownSymbolCompletion.edit(in: "\\\\", selection: NSRange(location: 2, length: 0),
                                                      typed: "*"))
        let fenced = "```\ncode\n```"
        XCTAssertNil(MarkdownSymbolCompletion.edit(in: fenced, selection: NSRange(location: 5, length: 0),
                                                   typed: "`"))
        XCTAssertNil(MarkdownSymbolCompletion.edit(in: fenced, selection: NSRange(location: 5, length: 0),
                                                   typed: "*"))
        XCTAssertNotNil(MarkdownSymbolCompletion.edit(in: fenced, selection: NSRange(location: 5, length: 0),
                                                      typed: "("))
        XCTAssertNil(MarkdownSymbolCompletion.edit(in: "`code`", selection: NSRange(location: 2, length: 0),
                                                   typed: "_"))
    }

    func testPasteAndOtherCharactersAreNotCompleted() {
        XCTAssertNil(MarkdownSymbolCompletion.edit(in: "", selection: NSRange(location: 0, length: 0),
                                                   typed: "ab"))
        XCTAssertNil(MarkdownSymbolCompletion.edit(in: "", selection: NSRange(location: 0, length: 0),
                                                   typed: "x"))
    }
}

@MainActor
final class MarkdownSymbolCompletionEditorTests: XCTestCase {
    func testEscapedAutomaticClosersAreInsertedLiterally() {
        for (input, expected) in [("*a\\*", "*a\\**"), ("_a\\_", "_a\\__"),
                                  ("(a\\)", "(a\\))"), ("[a\\]", "[a\\]]"),
                                  ("(a\\\\)", "(a\\\\)"), ("`a\\`", "`a\\`")] {
            let view = EditorTextView()
            let model = MarkdownEditorModel()
            model.connect(view)
            view.commandModel = model
            for character in input {
                view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            XCTAssertEqual(view.string, expected, input)
            XCTAssertEqual(view.selectedRange().location, input.utf16.count)
        }
    }

    func testSharedSnapshotProtectsMultilineInlineCodeDuringTyping() {
        for prefix in ["", String(repeating: "prose\n", count: 2_000)] {
            let view = EditorTextView()
            view.string = prefix + "`first\nsecond`"
            let model = MarkdownEditorModel()
            model.connect(view)
            view.commandModel = model
            model.usesSharedAnalysis = true
            model.sharedSnapshot = DocumentSnapshot(source: view.string)
            view.setSelectedRange(NSRange(location: (view.string as NSString).range(of: "second").location,
                                          length: 0))
            view.insertText("*", replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertEqual(view.string, prefix + "`first\n*second`")
            model.sharedSnapshot = DocumentSnapshot(source: view.string)
            view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
            view.insertText("*", replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertEqual(view.string, prefix + "`first\n*second`**",
                           "Matching background ranges must allow completion outside code in large text")
        }
    }

    func testTypingCompleteMarkdownConsumesOnlyAutomaticClosers() {
        for (input, expected) in [("**bold**", "**bold**"), ("`code`", "`code`"), ("(x)", "(x)"),
                                  ("[x]", "[x]"), ("((x))", "((x))"), ("__日本語🙂__", "__日本語🙂__")] {
            let view = EditorTextView()
            let model = MarkdownEditorModel()
            model.connect(view)
            view.commandModel = model
            for character in input {
                view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            XCTAssertEqual(view.string, expected, input)
            XCTAssertEqual(view.selectedRange().location, expected.utf16.count)
        }
    }

    func testBackspaceInsideAutomaticPairDoesNotLeaveStrayMarker() {
        for marker in ["*", "_", "`"] {
            let view = EditorTextView()
            let model = MarkdownEditorModel()
            model.connect(view)
            view.commandModel = model
            func type(_ text: String) {
                for character in text {
                    view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
                }
            }
            type(marker + marker)
            XCTAssertEqual(view.string, String(repeating: marker, count: 4))
            view.deleteBackward(nil)
            XCTAssertEqual(view.string, String(repeating: marker, count: 3))
            type(marker)
            XCTAssertEqual(view.string, String(repeating: marker, count: 4),
                           "typing the marker again restores the balanced pair")
            XCTAssertEqual(view.selectedRange().location, 2)
            type("x" + marker + marker)
            XCTAssertEqual(view.string, marker + marker + "x" + marker + marker, marker)
            XCTAssertEqual(view.selectedRange().location, 5)
        }
    }

    func testExistingManualCloserIsNotSkippedAndReplacementClearsTracking() {
        let view = EditorTextView()
        let model = MarkdownEditorModel()
        model.connect(view)
        view.commandModel = model
        view.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.string = "()"
        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.insertText(")", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.string, "())")
        XCTAssertNil(MarkdownSymbolCompletion.edit(in: "*", selection: NSRange(location: 0, length: 0), typed: "*"))
    }

    func testTypedBracketIsUndoableAndPlacesCaretBetweenPair() {
        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.allowsUndo = true
        view.string = "before"
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        let model = MarkdownEditorModel()
        model.connect(view)
        view.commandModel = model
        view.setSelectedRange(NSRange(location: 6, length: 0))

        view.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(view.string, "before()")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 7, length: 0))
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "before")
    }

    func testInputMethodReplacementRangeBypassesCompletion() {
        let view = EditorTextView()
        view.string = "abc"
        let model = MarkdownEditorModel()
        model.connect(view)

        XCTAssertFalse(model.completeSymbol("(", replacementRange: NSRange(location: 1, length: 1)))
        XCTAssertEqual(view.string, "abc")
    }

    func testRejectedEditIsConsumedWithoutChangingSource() {
        let view = RejectingSymbolTextView()
        view.string = "abc"
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: 3, length: 0))

        XCTAssertTrue(model.completeSymbol("(", replacementRange: NSRange(location: NSNotFound, length: 0)))
        XCTAssertEqual(view.string, "abc")
    }
}

private final class RejectingSymbolTextView: NSTextView {
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        false
    }
}
