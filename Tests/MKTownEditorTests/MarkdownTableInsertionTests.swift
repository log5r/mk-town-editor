import AppKit
import XCTest
@testable import MKTownEditor

final class MarkdownTableInsertionTests: XCTestCase {
    func testCSVConversionHandlesQuotesNewlinesAndMarkdownCharacters() throws {
        let csv = "Name,Note\r\n\"A, B\",\"line 1\r\nline 2\"\r\n\"pipe|slash\\\",\"say \"\"hi\"\"\"\r\n"
        let conversion = try XCTUnwrap(MarkdownTableInsertion.conversion(in: "", selection: NSRange(location: 0, length: 0),
                                                                          delimitedText: csv))
        let result = conversion.edit.applying(to: "")
        let table = try XCTUnwrap(MarkdownAnalysis(result).rootBlocks.first?.table)
        XCTAssertTrue(conversion.hasMultilineCells)
        XCTAssertEqual(table.header, ["Name", "Note"])
        XCTAssertEqual(table.rows[0], ["A, B", "line 1<br>line 2"])
        XCTAssertEqual(table.rows[1], ["pipe\\|slash\\\\", "say \"hi\""])
    }

    func testTSVConversionPadsRowsAndSeparatesSurroundingText() throws {
        let source = "before\r\nafter"
        let conversion = try XCTUnwrap(MarkdownTableInsertion.conversion(in: source,
            selection: NSRange(location: 8, length: 0), delimitedText: "A\tB\tC\nx\ty"))
        let result = conversion.edit.applying(to: source)
        XCTAssertFalse(conversion.hasMultilineCells)
        XCTAssertEqual(MarkdownAnalysis(result).blocks.first(where: { $0.kind == .table })?.table?.rows,
                       [["x", "y", ""]])
        XCTAssertTrue(result.contains("\r\n\r\n| A | B | C |\r\n"))
    }

    func testDelimitedConversionRejectsBrokenQuotesAndSingleValue() {
        let selection = NSRange(location: 0, length: 0)
        XCTAssertNil(MarkdownTableInsertion.conversion(in: "", selection: selection,
                                                        delimitedText: "a,\"unfinished"))
        XCTAssertNil(MarkdownTableInsertion.conversion(in: "", selection: selection,
                                                        delimitedText: "a,\"b\"unexpected"))
        XCTAssertNil(MarkdownTableInsertion.conversion(in: "", selection: selection,
                                                        delimitedText: "only one value"))
    }

    func testCSVWithQuotedTabStillUsesCommaDelimiter() throws {
        let csv = "A,B\n\"contains\ttab\",literal"
        let conversion = try XCTUnwrap(MarkdownTableInsertion.conversion(in: "",
            selection: NSRange(location: 0, length: 0), delimitedText: csv))
        XCTAssertEqual(MarkdownAnalysis(conversion.edit.applying(to: "")).rootBlocks.first?.table?.rows,
                       [["contains\ttab", "literal"]])
    }

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

    func testMovingRowsPreservesHeaderLineEndingsAndSelection() throws {
        let source = "| 名前 | 値 |\r\n| --- | --- |\r\n| あ | 1 |\r\n| い | 2 |"
        let selected = NSRange(location: (source as NSString).range(of: "2").location, length: 0)
        let edit = try XCTUnwrap(MarkdownTableEditing.edit(in: source, selection: selected,
                                                            operation: .moveRowUp))
        let result = edit.applying(to: source)
        XCTAssertEqual(result, "| 名前 | 値 |\r\n| --- | --- |\r\n| い | 2 |\r\n| あ | 1 |")
        XCTAssertEqual((result as NSString).substring(with: edit.selection), "2")
        let back = try XCTUnwrap(MarkdownTableEditing.edit(in: result, selection: edit.selection,
                                                            operation: .moveRowDown))
        XCTAssertEqual(back.applying(to: result), source)
        XCTAssertNil(MarkdownTableEditing.edit(in: source,
                                               selection: NSRange(location: (source as NSString).range(of: "あ").location, length: 0),
                                               operation: .moveRowUp))
        XCTAssertNil(MarkdownTableEditing.edit(in: source,
                                               selection: NSRange(location: (source as NSString).range(of: "名前").location, length: 0),
                                               operation: .moveRowDown))
    }

    func testMovingColumnsMovesAlignmentAndEscapedPipe() throws {
        let source = "| A | B | C |\n| --- | :---: | ---: |\n| x | a\\|b | 3 |\n"
        let selection = NSRange(location: (source as NSString).range(of: "a\\|b").location, length: 0)
        let edit = try XCTUnwrap(MarkdownTableEditing.edit(in: source, selection: selection,
                                                            operation: .moveColumnRight))
        let result = edit.applying(to: source)
        let table = try XCTUnwrap(MarkdownAnalysis(result).rootBlocks.first?.table)
        XCTAssertEqual(table.header, ["A", "C", "B"])
        XCTAssertEqual(table.alignments, [.leading, .trailing, .center])
        XCTAssertEqual(table.rows, [["x", "3", "a\\|b"]])
        XCTAssertEqual((result as NSString).substring(with: edit.selection), "a\\|b")
        let back = try XCTUnwrap(MarkdownTableEditing.edit(in: result, selection: edit.selection,
                                                            operation: .moveColumnLeft))
        XCTAssertEqual(back.applying(to: result), source)
        XCTAssertNil(MarkdownTableEditing.edit(in: source,
                                               selection: NSRange(location: (source as NSString).range(of: "A").location, length: 0),
                                               operation: .moveColumnLeft))
    }

    func testSortingSelectedColumnKeepsHeaderStableAndTracksRow() throws {
        let source = "| Name | Score |\n| --- | ---: |\n| a | 10 |\n| b | 2 |\n| c | 2 |\n"
        let selection = NSRange(location: (source as NSString).range(of: "10").location, length: 0)
        let edit = try XCTUnwrap(MarkdownTableEditing.edit(in: source, selection: selection,
                                                            operation: .sortRowsAscending))
        let result = edit.applying(to: source)
        XCTAssertEqual(MarkdownAnalysis(result).rootBlocks.first?.table?.rows,
                       [["b", "2"], ["c", "2"], ["a", "10"]])
        XCTAssertEqual((result as NSString).substring(with: edit.selection), "10")
        let descending = try XCTUnwrap(MarkdownTableEditing.edit(in: result, selection: edit.selection,
                                                                  operation: .sortRowsDescending))
        XCTAssertEqual(descending.applying(to: result), source)
        XCTAssertNil(MarkdownTableEditing.edit(in: "| A |\n| --- |\n| x |", selection: NSRange(location: 2, length: 0),
                                               operation: .sortRowsAscending))
    }

    func testGridDraftAndEditKeepSurroundingTextAndMarkdownCells() throws {
        let source = "before\r\n\r\n| A | B |\r\n| --- | :---: |\r\n| [x](a.md) | a\\|b |\r\n\r\nafter"
        let selection = NSRange(location: (source as NSString).range(of: "a\\|b").location, length: 0)
        let draft = try XCTUnwrap(MarkdownTableEditing.gridDraft(in: source, selection: selection))
        XCTAssertEqual(draft.header, ["A", "B"])
        XCTAssertEqual(draft.rows, [["[x](a.md)", "a\\|b"]])
        XCTAssertEqual(draft.alignments, [.leading, .center])
        let edit = try XCTUnwrap(MarkdownTableEditing.gridEdit(
            in: source, draft: draft, header: ["A", "B"],
            rows: [["[x](a.md)", "a|b"], ["日本語", "next\nline"]],
            alignments: [.trailing, .center]))
        let result = edit.applying(to: source)
        XCTAssertTrue(result.hasPrefix("before\r\n\r\n"))
        XCTAssertTrue(result.hasSuffix("\r\n\r\nafter"))
        let table = try XCTUnwrap(MarkdownAnalysis(result).rootBlocks.first(where: { $0.kind == .table })?.table)
        XCTAssertEqual(table.rows, [["[x](a.md)", "a\\|b"], ["日本語", "next<br>line"]])
        XCTAssertEqual(table.alignments, [.trailing, .center])
    }

    func testGridRejectsStaleSourceAndInvalidShape() throws {
        let source = "| A |\n| --- |\n| x |"
        let draft = try XCTUnwrap(MarkdownTableEditing.gridDraft(in: source,
            selection: NSRange(location: (source as NSString).range(of: "x").location, length: 0)))
        XCTAssertNil(MarkdownTableEditing.gridEdit(in: source, draft: draft,
                                                   header: draft.header, rows: draft.rows,
                                                   alignments: draft.alignments))
        XCTAssertNil(MarkdownTableEditing.gridEdit(in: source + " ", draft: draft,
                                                   header: ["A"], rows: [["x"]],
                                                   alignments: [.leading]))
        XCTAssertNil(MarkdownTableEditing.gridEdit(in: source, draft: draft,
                                                   header: ["A", "B"], rows: [["x"]],
                                                   alignments: [.leading, .leading]))
        XCTAssertNil(MarkdownTableEditing.gridEdit(in: source, draft: draft,
                                                   header: [], rows: [], alignments: []))
        XCTAssertNil(MarkdownTableEditing.gridDraft(in: "plain", selection: NSRange(location: 0, length: 0)))
    }

    func testGridCanChangeColumnCountInQuotedTableWithoutFinalNewline() throws {
        let source = "> | A | B |\n> | --- | ---: |\n> | x | a\\|b |"
        let draft = try XCTUnwrap(MarkdownTableEditing.gridDraft(in: source,
            selection: NSRange(location: (source as NSString).range(of: "x").location, length: 0)))
        let added = try XCTUnwrap(MarkdownTableEditing.gridEdit(in: source, draft: draft,
            header: ["A", "B", "C"], rows: [["x", "a\\|b", "new"]],
            alignments: [.leading, .trailing, .center]))
        let result = added.applying(to: source)
        XCTAssertTrue(result.hasPrefix("> | A | B | C |\n> | --- | ---: | :---: |\n"))
        XCTAssertFalse(result.hasSuffix("\n"))
        let table = try XCTUnwrap(MarkdownAnalysis(result).blocks.first(where: { $0.kind == .table })?.table)
        XCTAssertEqual(table.rows, [["x", "a\\|b", "new"]])
        let nextDraft = try XCTUnwrap(MarkdownTableEditing.gridDraft(in: result, selection: added.selection))
        let removed = try XCTUnwrap(MarkdownTableEditing.gridEdit(in: result, draft: nextDraft,
            header: ["A"], rows: [["x"]], alignments: [.leading]))
        XCTAssertEqual(MarkdownAnalysis(removed.applying(to: result))
            .blocks.first(where: { $0.kind == .table })?.table?.header, ["A"])
    }
}

@MainActor
final class MarkdownTableInsertionEditorTests: XCTestCase {
    func testClipboardConversionIsUndoable() {
        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.allowsUndo = true
        view.string = ""
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.clearContents()
        pasteboard.setString("A,B\nx,y", forType: .string)
        let model = MarkdownEditorModel()
        model.tablePasteboard = pasteboard
        model.connect(view)
        model.convertClipboardTable()
        XCTAssertEqual(MarkdownAnalysis(view.string).rootBlocks.first?.table?.rows, [["x", "y"]])
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "")
    }

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

    func testTableSortIsOneUndoableEdit() {
        let source = "| A |\n| --- |\n| b |\n| a |\n"
        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.allowsUndo = true
        view.string = source
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: (source as NSString).range(of: "b").location, length: 0))
        XCTAssertTrue(model.editTable(.sortRowsAscending))
        XCTAssertEqual(MarkdownAnalysis(view.string).rootBlocks.first?.table?.rows, [["a"], ["b"]])
        view.undoManager?.undo()
        XCTAssertEqual(view.string, source)
    }

    func testGridEditIsOneUndoableEdit() {
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
        model.presentTableGrid()
        XCTAssertNotNil(model.tableGridDraft)
        XCTAssertTrue(model.commitTableGrid(header: ["New"], rows: [["y"]], alignments: [.center]))
        XCTAssertEqual(MarkdownAnalysis(view.string).rootBlocks.first?.table?.rows, [["y"]])
        view.undoManager?.undo()
        XCTAssertEqual(view.string, source)
    }

    func testUnchangedGridClosesWithoutEditing() {
        let source = "| A |\n| --- |\n| x |"
        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.string = source
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: (source as NSString).range(of: "x").location, length: 0))
        model.presentTableGrid()
        let draft = model.tableGridDraft!
        XCTAssertTrue(model.commitTableGrid(header: draft.header, rows: draft.rows,
                                            alignments: draft.alignments))
        XCTAssertNil(model.tableGridDraft)
        XCTAssertEqual(view.string, source)
    }
}
