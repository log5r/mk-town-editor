import AppKit
import XCTest
@testable import MKTownEditor

/// The empty-document guidance is drawn, never inserted as text (#28).
@MainActor
final class EditorPlaceholderTests: XCTestCase {
    func testPlaceholderShowsOnlyWhileDocumentIsEmptyAndIsNotText() {
        let view = EditorTextView()
        view.placeholder = "Start writing"
        XCTAssertTrue(view.showsPlaceholder)
        XCTAssertEqual(view.string, "")
        XCTAssertEqual(view.accessibilityPlaceholderValue(), "Start writing")

        view.insertText("a", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertFalse(view.showsPlaceholder)
        view.string = ""
        XCTAssertTrue(view.showsPlaceholder)
    }

    func testPlaceholderHidesDuringInputMethodComposition() {
        let view = EditorTextView()
        view.placeholder = "Start writing"
        view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.showsPlaceholder)
    }

    func testNoPlaceholderWhenUnset() {
        let view = EditorTextView()
        XCTAssertFalse(view.showsPlaceholder)
        view.placeholder = ""
        XCTAssertFalse(view.showsPlaceholder)
    }
}
