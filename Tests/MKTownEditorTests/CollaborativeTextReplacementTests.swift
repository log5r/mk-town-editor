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
    func testUnlockRetriesRemoteUpdateWithoutAnotherLocalTextEdit() async throws {
        let textView = EditorTextView()
        textView.string = "original"
        let model = MarkdownEditorModel()
        model.connect(textView)
        textView.isEditable = false
        var pending: String? = "remote"
        XCTAssertFalse(model.applyCollaborativeText("remote", expectedSource: "original"))
        let retried = expectation(description: "Pending update applied on editability transition")
        let observer = NotificationCenter.default.publisher(for: EditorTextView.collaborativeReadinessNotification)
            .sink { notification in
                guard notification.object as? EditorTextView === textView, let next = pending else { return }
                XCTAssertEqual(textView.editorSource, "original")
                if model.applyCollaborativeText(next, expectedSource: textView.editorSource) {
                    pending = nil
                    retried.fulfill()
                }
            }
        textView.isEditable = true
        await fulfillment(of: [retried], timeout: 2)
        XCTAssertNil(pending)
        XCTAssertEqual(textView.editorSource, "remote")
        withExtendedLifetime(observer) {}
    }

    @MainActor
    func testEndingMarkedTextNotifiesReadinessWithoutChangingCharacters() async throws {
        let textView = EditorTextView()
        textView.string = "original"
        textView.setSelectedRange(NSRange(location: 0, length: 8))
        textView.setMarkedText("original", selectedRange: NSRange(location: 8, length: 0), replacementRange: NSRange(location: 0, length: 8))
        XCTAssertTrue(textView.hasMarkedText())
        let ready = expectation(description: "IME composition ended")
        let observer = NotificationCenter.default.publisher(for: EditorTextView.collaborativeReadinessNotification)
            .sink { notification in
                guard notification.object as? EditorTextView === textView else { return }
                XCTAssertFalse(textView.hasMarkedText())
                ready.fulfill()
            }
        textView.unmarkText()
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(textView.editorSource, "original")
        withExtendedLifetime(observer) {}
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
