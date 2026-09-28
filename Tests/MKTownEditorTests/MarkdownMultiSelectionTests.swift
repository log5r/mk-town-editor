import AppKit
import XCTest
@testable import MKTownEditor

final class MarkdownMultiSelectionTests: XCTestCase {
    func testBoldAppliesToSeparateRangesAsOneEditAndPreservesSelections() throws {
        let source = "one and two"
        let plan = try XCTUnwrap(MarkdownMultiSelectionPlan.make(style: .bold, source: source,
            selections: [NSRange(location: 0, length: 3), NSRange(location: 8, length: 3)]))
        XCTAssertEqual(plan.edit.applying(to: source), "**one** and **two**")
        let updated = plan.edit.applying(to: source) as NSString
        XCTAssertEqual(plan.selections.map { updated.substring(with: $0) }, ["one", "two"])
    }

    func testMixedWrappedRangesToggleIndependently() throws {
        let source = "**one** and **two**"
        let text = source as NSString
        let plan = try XCTUnwrap(MarkdownMultiSelectionPlan.make(style: .bold, source: source,
            selections: [text.range(of: "one"), text.range(of: "two")]))
        XCTAssertEqual(plan.edit.applying(to: source), "one and two")
        let updated = plan.edit.applying(to: source) as NSString
        XCTAssertEqual(plan.selections.map { updated.substring(with: $0) }, ["one", "two"])
    }

    func testRejectsOverlappingEditsAndUnsupportedStyles() {
        let source = "**one**"
        XCTAssertNil(MarkdownMultiSelectionPlan.make(style: .bold, source: source,
            selections: [NSRange(location: 2, length: 3), NSRange(location: 3, length: 2)]))
        XCTAssertNil(MarkdownMultiSelectionPlan.make(style: .quote, source: "one two",
            selections: [NSRange(location: 0, length: 3), NSRange(location: 4, length: 3)]))
    }

    func testNextOccurrenceAddsRangesWithoutDuplicates() {
        let source = "🙂 one one one"
        let text = source as NSString
        let first = text.range(of: "one")
        let second = try! XCTUnwrap(MarkdownSelectionOccurrences.addingNext(in: source,
            selections: [first]))
        XCTAssertEqual(second.count, 2)
        let third = try! XCTUnwrap(MarkdownSelectionOccurrences.addingNext(in: source,
            selections: second))
        XCTAssertEqual(third.count, 3)
        XCTAssertNil(MarkdownSelectionOccurrences.addingNext(in: source, selections: third))
    }

    func testSelectionStatisticsSumDisjointRanges() {
        let source = "one and two"
        let stats = DocumentStatistics.selection(in: source,
            ranges: [NSRange(location: 0, length: 3), NSRange(location: 8, length: 3)])
        XCTAssertEqual(stats?.characters, 6)
        XCTAssertEqual(stats?.words, 2)
    }
}

@MainActor
final class MarkdownMultiSelectionModelTests: XCTestCase {
    func testNextOccurrenceCommandCreatesAnotherAppKitSelection() {
        let view = NSTextView()
        view.string = "same and same"
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: 0, length: 4))
        model.selectionDidChange(view.selectedRanges.map(\.rangeValue))
        XCTAssertTrue(EditorCommand.selectNextOccurrence.canExecute(in: model))

        EditorCommand.selectNextOccurrence.perform(on: model)
        XCTAssertEqual(view.selectedRanges.map(\.rangeValue),
                       [NSRange(location: 0, length: 4), NSRange(location: 9, length: 4)])
        XCTAssertFalse(EditorCommand.quote.canExecute(in: model))
    }

    func testMultipleFormattingUsesOneUndoAndKeepsMultipleSelections() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.allowsUndo = true
        view.string = "one and two"
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        let model = MarkdownEditorModel()
        model.connect(view)
        let ranges = [NSRange(location: 0, length: 3), NSRange(location: 8, length: 3)]
        view.setSelectedRanges(ranges.map(NSValue.init(range:)), affinity: .upstream,
                               stillSelecting: false)
        model.selectionDidChange(view.selectedRanges.map(\.rangeValue))
        XCTAssertFalse(EditorCommand.quote.canExecute(in: model))
        XCTAssertTrue(EditorCommand.bold.canExecute(in: model))

        model.apply(.bold)
        XCTAssertEqual(view.string, "**one** and **two**")
        XCTAssertEqual(view.selectedRanges.count, 2)
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "one and two")
    }

    func testModelRestoresMultipleSelectionsAfterViewRecreation() {
        let model = MarkdownEditorModel()
        let oldView = NSTextView()
        oldView.string = "one two"
        model.connect(oldView)
        let ranges = [NSRange(location: 0, length: 3), NSRange(location: 4, length: 3)]
        oldView.setSelectedRanges(ranges.map(NSValue.init(range:)), affinity: .upstream,
                                  stillSelecting: false)
        model.selectionDidChange(oldView.selectedRanges.map(\.rangeValue))
        model.disconnect(oldView)

        let newView = NSTextView()
        newView.string = oldView.string
        model.connect(newView)
        XCTAssertEqual(newView.selectedRanges.map(\.rangeValue), ranges)
    }
}
