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

final class MarkdownTableEditingTests: XCTestCase {
    func testTableFormattingAlignsJapaneseCellsAndIsIdempotent() throws {
        let source = "before\n\n| A | B |\n| :---: | ---: |\n| 日本 | 1 |\n| x | 22 |\n\nafter"
        let selection = NSRange(location: (source as NSString).range(of: "日本").location, length: 0)
        let edit = try XCTUnwrap(MarkdownTableEditing.edit(in: source, selection: selection,
                                                            operation: .formatTable))
        let result = edit.applying(to: source)
        XCTAssertTrue(result.contains("| :---: | ---: |"))
        XCTAssertTrue(result.contains("| 日本  |    1 |"))
        XCTAssertTrue(result.hasPrefix("before\n\n"))
        XCTAssertTrue(result.hasSuffix("\n\nafter"))
        let again = try XCTUnwrap(MarkdownTableEditing.edit(in: result, selection: edit.selection,
                                                             operation: .formatTable))
        XCTAssertEqual(again.applying(to: result), result)
    }

    func testTableFormattingTreatsEscapedCodePipeAsCellContent() throws {
        let source = "| A | B | C |\r\n| --- | --- | --- |\r\n| `a\\|b` | q |  |\r\n| `a|b` | q |\r\n"
        let selection = NSRange(location: (source as NSString).range(of: "q").location, length: 0)
        let edit = try XCTUnwrap(MarkdownTableEditing.edit(in: source, selection: selection,
                                                            operation: .formatTable))
        let result = edit.applying(to: source)
        let table = try XCTUnwrap(MarkdownAnalysis(result).rootBlocks.first?.table)
        XCTAssertEqual(table.rows[0], ["`a\\|b`", "q", ""])
        XCTAssertEqual(table.rows[1], ["`a", "b`", "q"])
        XCTAssertTrue(result.contains("\r\n"))
    }

    func testTabMovesThroughSourceCellsAndBackwards() throws {
        let source = "| 名前 | 値 |\n| --- | --- |\n| あ | 1 |\n"
        let name = (source as NSString).range(of: "名前")
        let value = (source as NSString).range(of: "値")
        let firstBody = (source as NSString).range(of: "あ")
        XCTAssertEqual(MarkdownTableEditing.tabAction(in: source, selection: name,
                                                       backwards: false, addsRowAtEnd: true),
                       .select(value))
        XCTAssertEqual(MarkdownTableEditing.tabAction(in: source, selection: value,
                                                       backwards: false, addsRowAtEnd: true),
                       .select(firstBody))
        XCTAssertEqual(MarkdownTableEditing.tabAction(in: source, selection: firstBody,
                                                       backwards: true, addsRowAtEnd: true),
                       .select(value))
    }

    func testTabAtLastCellAddsRowOrLeavesTableByPreference() throws {
        let source = "| A | B |\n| --- | --- |\n| x | y |"
        let selection = NSRange(location: (source as NSString).range(of: "y").location, length: 0)
        let action = try XCTUnwrap(MarkdownTableEditing.tabAction(in: source, selection: selection,
                                                                   backwards: false, addsRowAtEnd: true))
        guard case let .edit(edit) = action else { return XCTFail("行追加が必要") }
        XCTAssertEqual(MarkdownAnalysis(edit.applying(to: source)).rootBlocks.first?.table?.rows.count, 2)
        XCTAssertEqual(MarkdownTableEditing.tabAction(in: source, selection: selection,
                                                       backwards: false, addsRowAtEnd: false),
                       .select(NSRange(location: (source as NSString).length, length: 0)))
    }

    func testTabMaterializesMissingCellBeforeSelectingIt() throws {
        let source = "| A | B |\n| --- | --- |\n| only |\n"
        let selection = NSRange(location: (source as NSString).range(of: "only").location,
                                length: 0)
        let action = try XCTUnwrap(MarkdownTableEditing.tabAction(in: source, selection: selection,
                                                                   backwards: false, addsRowAtEnd: true))
        guard case let .edit(edit) = action else { return XCTFail("空セルの追加が必要") }
        let result = edit.applying(to: source)
        XCTAssertEqual(MarkdownAnalysis(result).rootBlocks.first?.table?.rows, [["only", ""]])
        XCTAssertTrue(edit.selection.location < NSMaxRange((result as NSString).range(of: "| only |  |")))
    }

    func testColumnAlignmentChangesOnlySelectedDelimiterAndReportsCurrentValue() throws {
        let source = "| 名前 | 点数 |\n| --- | :---: |\n| あ | 10 |\n"
        let selection = NSRange(location: (source as NSString).range(of: "10").location, length: 0)
        XCTAssertEqual(MarkdownTableEditing.alignment(in: source, selection: selection), .center)
        let edit = try XCTUnwrap(MarkdownTableEditing.edit(in: source, selection: selection,
                                                            operation: .alignColumn(.trailing)))
        let result = edit.applying(to: source)
        XCTAssertTrue(result.contains("| --- | ---: |"))
        XCTAssertEqual(MarkdownTableEditing.alignment(in: result, selection: edit.selection), .trailing)
        XCTAssertEqual(MarkdownAnalysis(result).rootBlocks.first?.table?.alignments,
                       [.leading, .trailing])
    }

    func testAddingAndDeletingRowsPreservesColumnCountAndCRLF() throws {
        let source = "| 名前 | 値 |\r\n| --- | --- |\r\n| あ | 1 |\r\n"
        let selection = NSRange(location: (source as NSString).range(of: "あ").location, length: 0)
        let added = try XCTUnwrap(MarkdownTableEditing.edit(in: source, selection: selection,
                                                             operation: .insertRow))
        let result = added.applying(to: source)
        let table = try XCTUnwrap(MarkdownAnalysis(result).rootBlocks.first?.table)
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertEqual(table.rows.map(\.count), [2, 2])
        XCTAssertTrue(result.contains("| あ | 1 |\r\n|   |   |\r\n"))
        let removed = try XCTUnwrap(MarkdownTableEditing.edit(in: result, selection: added.selection,
                                                               operation: .deleteRow))
        XCTAssertEqual(removed.applying(to: result), source)
    }

    func testColumnsPreserveEscapedPipesAndDelimiterShape() throws {
        let source = "| A | B |\n| --- | :---: |\n| a\\|b | `c\\|d` |\n"
        let selection = NSRange(location: (source as NSString).range(of: "B").location, length: 0)
        let inserted = try XCTUnwrap(MarkdownTableEditing.edit(in: source, selection: selection,
                                                                operation: .insertColumn))
        let result = inserted.applying(to: source)
        let table = try XCTUnwrap(MarkdownAnalysis(result).rootBlocks.first?.table)
        XCTAssertEqual(table.header.count, 3)
        XCTAssertEqual(table.rows[0], ["a\\|b", "`c\\|d`", ""])
        XCTAssertEqual(table.alignments, [.leading, .center, .leading])
        let deleted = try XCTUnwrap(MarkdownTableEditing.edit(in: result, selection: inserted.selection,
                                                               operation: .deleteColumn))
        XCTAssertEqual(deleted.applying(to: result), source)
    }

    func testStructuralEditRequiresTableAndKeepsOneColumn() throws {
        XCTAssertNil(MarkdownTableEditing.edit(in: "ordinary text", selection: NSRange(location: 0, length: 0),
                                               operation: .insertRow))
        let source = "| A |\n| --- |\n| x |"
        let header = NSRange(location: 2, length: 0)
        XCTAssertNil(MarkdownTableEditing.edit(in: source, selection: header, operation: .deleteRow))
        XCTAssertNil(MarkdownTableEditing.edit(in: source, selection: header, operation: .deleteColumn))
        let added = try XCTUnwrap(MarkdownTableEditing.edit(in: source, selection: header,
                                                             operation: .insertRow))
        XCTAssertEqual(MarkdownAnalysis(added.applying(to: source)).rootBlocks.first?.table?.rows.count, 2)
    }

    func testQuotedTableKeepsQuotePrefixWhenAddingRow() throws {
        let source = "> | A | B |\n> | --- | --- |\n> | x | y |\n"
        let selection = NSRange(location: (source as NSString).range(of: "x").location, length: 0)
        let edit = try XCTUnwrap(MarkdownTableEditing.edit(in: source, selection: selection,
                                                            operation: .insertRow))
        let result = edit.applying(to: source)
        XCTAssertTrue(result.contains("> | x | y |\n> |   |   |\n"))
        XCTAssertEqual(MarkdownAnalysis(result).blocks.first(where: { $0.kind == .table })?.table?.rows.count, 2)
    }

    func testColumnsHandleRowsWithoutOuterPipesAndTrailingSpaces() throws {
        let source = "A | B  \n--- | ---  \nx | y  \n"
        let selection = NSRange(location: (source as NSString).range(of: "y").location, length: 0)
        let edit = try XCTUnwrap(MarkdownTableEditing.edit(in: source, selection: selection,
                                                            operation: .insertColumn))
        let table = try XCTUnwrap(MarkdownAnalysis(edit.applying(to: source)).rootBlocks.first?.table)
        XCTAssertEqual(table.header.count, 3)
        XCTAssertEqual(table.rows, [["x", "y", ""]])
    }

    func testAddingColumnPadsShortRowsAndKeepsEmptyCells() throws {
        let source = "| A | B | C |\n| --- | --- | --- |\n| x || z |\n| only |\n"
        let selection = NSRange(location: (source as NSString).range(of: "only").location, length: 0)
        let edit = try XCTUnwrap(MarkdownTableEditing.edit(in: source, selection: selection,
                                                            operation: .insertColumn))
        let table = try XCTUnwrap(MarkdownAnalysis(edit.applying(to: source)).rootBlocks.first?.table)
        XCTAssertEqual(table.header.count, 4)
        XCTAssertEqual(table.rows, [["x", "", "", "z"], ["only", "", "", ""]])
    }
}

@MainActor
final class MarkdownTableInsertionEditorTests: XCTestCase {
    func testTabUsesCellNavigationAndAddsUndoableRow() {
        let source = "| A | B |\n| --- | --- |\n| x | y |"
        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.allowsUndo = true
        view.string = source
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        let model = MarkdownEditorModel()
        model.connect(view)
        view.commandModel = model
        view.setSelectedRange((source as NSString).range(of: "A"))
        view.insertTab(nil)
        XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "B")
        view.setSelectedRange(NSRange(location: (source as NSString).range(of: "y").location, length: 0))
        view.insertTab(nil)
        XCTAssertEqual(MarkdownAnalysis(view.string).rootBlocks.first?.table?.rows.count, 2)
        view.undoManager?.undo()
        XCTAssertEqual(view.string, source)
    }

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

    func testTableRowEditIsUndoable() {
        let source = "| A |\n| --- |\n| x |\n"
        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.allowsUndo = true
        view.string = source
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: (source as NSString).range(of: "x").location, length: 0))
        XCTAssertTrue(model.editTable(.insertRow))
        XCTAssertEqual(MarkdownAnalysis(view.string).rootBlocks.first?.table?.rows.count, 2)
        view.undoManager?.undo()
        XCTAssertEqual(view.string, source)
    }
}
