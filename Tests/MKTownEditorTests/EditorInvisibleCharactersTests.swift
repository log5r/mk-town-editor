import AppKit
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
        view.string = "a b\n"
        view.whitespaceOptions = EditorWhitespaceOptions(showsCharacters: true,
                                                         showsIndentGuides: true)
        view.refreshInvisibles()
        XCTAssertEqual(view.string, "a b\n")
        XCTAssertFalse(view.undoManager?.canUndo ?? false)
    }
}
