import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

@MainActor
final class EditorInvisibleCharactersTests: XCTestCase {
    func testMarksIndentTabsTrailingSpaceAndCRLFWithoutChangingSource() {
        let source = "    one  \r\n\t two\nlast"
        let plan = InvisibleCharacterPlan(source: source, tabWidth: 4)
        XCTAssertEqual(plan.guides, [3, 11])
        XCTAssertTrue(plan.marks.contains(.init(location: 7, kind: .trailingSpace)))
        XCTAssertTrue(plan.marks.contains(.init(location: 9, kind: .newline)))
        XCTAssertTrue(plan.marks.contains(.init(location: 11, kind: .tab)))
        XCTAssertTrue(plan.marks.contains(.init(location: 16, kind: .newline)))
        XCTAssertEqual(source, "    one  \r\n\t two\nlast")
    }

    func testEditorDisplayPlanDoesNotModifyTextStorageOrUndo() {
        let view = EditorTextView()
        let source = "a b\u{200B}\u{00}\n"
        view.string = source
        view.whitespaceOptions = EditorWhitespaceOptions(showsCharacters: true,
                                                         showsIndentGuides: true)
        view.refreshInvisibles()
        XCTAssertEqual(view.string, source)
        XCTAssertFalse(view.undoManager?.canUndo ?? false)
    }

    func testControlsAndZeroWidthMarksUseUTF16Offsets() {
        let source = "🙂a\u{0000}\u{001F}\u{007F}\u{0085}\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}\u{E0001}b"
        XCTAssertEqual(InvisibleCharacterPlan(source: source, tabWidth: 4).marks, [
            .init(location: 3, kind: .control(0x00)),
            .init(location: 4, kind: .control(0x1F)),
            .init(location: 5, kind: .control(0x7F)),
            .init(location: 6, kind: .control(0x85)),
            .init(location: 7, kind: .zeroWidth),
            .init(location: 8, kind: .zeroWidth),
            .init(location: 9, kind: .zeroWidth),
            .init(location: 10, kind: .zeroWidth),
            .init(location: 11, kind: .zeroWidth),
            .init(location: 12, kind: .zeroWidth),
        ])
    }

    func testEmojiAndIdeographicGraphemesKeepTheirAppearance() {
        let source = "\u{FE0F}👩🏽‍💻 ❤️‍🔥 葛\u{E0100} 🏴\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F} a\u{200D}"
        let plan = InvisibleCharacterPlan(source: source, tabWidth: 4)
        XCTAssertEqual(plan.marks.filter { $0.kind != .space }, [
            .init(location: 0, kind: .zeroWidth),
            .init(location: source.utf16.count - 1, kind: .zeroWidth),
        ])
    }

    func testIndentGuidesAloneDoNotCreateCharacterMarks() {
        let source = "    a\u{200B}\n\t\u{00}b"
        let plan = InvisibleCharacterPlan(source: source, tabWidth: 4, showsCharacters: false)
        XCTAssertEqual(plan.guides, [3, 7])
        XCTAssertTrue(plan.marks.isEmpty)
    }

    func testDifferentSerializedEndingHasItsOwnMarkAtTheNormalizedOffset() throws {
        let document = try MarkdownDocument(data: Data("🙂\r\n二\n三\r\n".utf8))
        let plan = InvisibleCharacterPlan(source: document.text, tabWidth: 4, format: document.format)
        XCTAssertEqual(plan.marks, [.init(location: 2, kind: .newline),
                                    .init(location: 4, kind: .differentNewline),
                                    .init(location: 6, kind: .newline)])
    }

    func testPasteNormalizesOrPreservesClipboardNewlinesThroughUndoAndRedo() throws {
        for preserve in [false, true] {
            var document = try MarkdownDocument(data: Data("一\r\n🙂\n二\r\n".utf8))
            let binding = Binding(get: { document }, set: { document = $0 })
            let editor = EditorTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
            editor.string = document.text
            editor.isRichText = false
            editor.allowsUndo = true
            let window = NSWindow(contentRect: editor.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = editor
            window.makeFirstResponder(editor)
            let coordinator = MarkdownTextEditor.Coordinator(text: binding.text, model: MarkdownEditorModel(),
                                                            document: binding)
            coordinator.textView = editor
            editor.delegate = coordinator
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            board.setString("甲\r乙\r\n丙\n", forType: .string)
            editor.imagePasteboard = board
            editor.setSelectedRange((document.text as NSString).range(of: "🙂\n"))

            if preserve { editor.pastePreservingNewlines() } else { editor.paste(nil) }

            let expected = preserve ? "一\r\n甲\r乙\r\n丙\n二\r\n" : "一\r\n甲\r\n乙\r\n丙\r\n二\r\n"
            XCTAssertEqual(editor.string, "一\n甲\n乙\n丙\n二\n")
            XCTAssertEqual(try document.encodedData(), Data(expected.utf8))
            editor.undoManager?.undo()
            XCTAssertEqual(editor.string, "一\n🙂\n二\n")
            XCTAssertEqual(try document.encodedData(), Data("一\r\n🙂\n二\r\n".utf8))
            editor.undoManager?.redo()
            XCTAssertEqual(try document.encodedData(), Data(expected.utf8))

            // An explicit change of document format invalidates the old line-ending undo.
            document.format.newline = .lf
            coordinator.invalidateNewlineUndo()
            editor.undoManager?.undo()
            XCTAssertEqual(try document.encodedData(), Data("一\n🙂\n二\n".utf8))
            withExtendedLifetime(coordinator) {}
        }
    }
}
