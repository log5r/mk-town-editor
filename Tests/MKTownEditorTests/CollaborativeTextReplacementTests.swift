import AppKit
import Foundation
import XCTest
@testable import MKTownEditor

final class CollaborativeTextReplacementTests: XCTestCase {
    func testUnicodeEditUsesWholeGraphemeAndMovesLaterSelection() throws {
        let edit = try XCTUnwrap(CollaborativeTextReplacement.between("A👨‍👩‍👧B", "A🌟B"))
        XCTAssertEqual(edit.range, NSRange(location: 1, length: 8))
        XCTAssertEqual(edit.replacement, "🌟")
        XCTAssertEqual(edit.mapped(NSRange(location: 9, length: 1)),
                       NSRange(location: 3, length: 1))
    }

    func testInsertionLeavesEarlierCursorAndShiftsLaterCursor() throws {
        let edit = try XCTUnwrap(CollaborativeTextReplacement.between("ab", "aXb"))
        XCTAssertEqual(edit.range, NSRange(location: 1, length: 0))
        XCTAssertEqual(edit.mapped(NSRange(location: 1, length: 0)),
                       NSRange(location: 1, length: 0))
        XCTAssertEqual(edit.mapped(NSRange(location: 2, length: 0)),
                       NSRange(location: 3, length: 0))
    }

    @MainActor
    func testRemoteEditUpdatesTextViewAndSelection() {
        let textView = NSTextView()
        textView.string = "A👨‍👩‍👧B"
        textView.isEditable = true
        let model = MarkdownEditorModel()
        model.connect(textView)
        textView.setSelectedRange(NSRange(location: 9, length: 1))
        XCTAssertTrue(model.applyCollaborativeText("A🌟B", expectedSource: "A👨‍👩‍👧B"))
        XCTAssertEqual(textView.string, "A🌟B")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 3, length: 1))
        XCTAssertFalse(model.applyCollaborativeText("wrong", expectedSource: "stale"))
    }
}
