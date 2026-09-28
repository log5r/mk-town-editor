import AppKit
import XCTest
@testable import MKTownEditor

final class MarkdownTableInsertionTests: XCTestCase {
    func testGeneratedTableParsesWithRequestedShapeAndSelectsFirstHeader() {
        let draft = MarkdownTableInsertion.draft(in: "", selection: NSRange(location: 0, length: 0))
        let edit = try! XCTUnwrap(MarkdownTableInsertion.edit(in: "", draft: draft, rows: 3, columns: 2))
        let text = edit.applying(to: "")
        let table = try! XCTUnwrap(MarkdownAnalysis(text).rootBlocks.first?.table)

        XCTAssertEqual(table.header, ["列1", "列2"])
        XCTAssertEqual(table.rows, [["", ""], ["", ""], ["", ""]])
        XCTAssertEqual((text as NSString).substring(with: edit.selection), "列1")
    }

    func testInsertionSeparatesNearbyParagraphsAndKeepsCRLF() {
        let text = "before\r\nafter"
        let draft = MarkdownTableInsertion.draft(in: text, selection: NSRange(location: 8, length: 0))
        let edit = try! XCTUnwrap(MarkdownTableInsertion.edit(in: text, draft: draft, rows: 1, columns: 1))
        let result = edit.applying(to: text)

        XCTAssertTrue(result.hasPrefix("before\r\n\r\n| 列1 |\r\n| --- |\r\n|   |\r\n\r\nafter"))
        XCTAssertEqual(MarkdownAnalysis(result).rootBlocks.map(\.kind),
                       [.paragraph, .blank, .table, .blank, .paragraph])
    }

    func testSelectedTextIsReplacedAndStaleDraftIsRejected() {
        let draft = MarkdownTableInsertion.draft(in: "abc", selection: NSRange(location: 1, length: 1))
        let edit = try! XCTUnwrap(MarkdownTableInsertion.edit(in: "abc", draft: draft, rows: 1, columns: 1))
        XCTAssertFalse(edit.applying(to: "abc").contains("b"))
        XCTAssertNil(MarkdownTableInsertion.edit(in: "abx", draft: draft, rows: 1, columns: 1))
        XCTAssertNil(MarkdownTableInsertion.edit(in: "abc", draft: draft, rows: 0, columns: 1))
        XCTAssertNil(MarkdownTableInsertion.edit(in: "abc", draft: draft, rows: 1, columns: 13))
    }
}

@MainActor
final class MarkdownTableInsertionEditorTests: XCTestCase {
    func testCommandOpensSheetDraftAndCommitIsUndoable() {
        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.allowsUndo = true
        view.string = ""
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        let model = MarkdownEditorModel()
        model.connect(view)

        EditorCommand.table.perform(on: model)
        XCTAssertNotNil(model.tableDraft)
        XCTAssertTrue(model.commitTable(rows: 2, columns: 2))
        XCTAssertNil(model.tableDraft)
        XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "列1")
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "")
    }
}
