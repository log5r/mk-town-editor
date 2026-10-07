import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

@MainActor
final class EditorSourceCacheTests: XCTestCase {
    func testEditingEventReadsSourceOnceAndSelectionDoesNotCopyIt() {
        let view = EditorTextView()
        view.string = "# 日本語🙂\nbody"
        let model = MarkdownEditorModel()
        let coordinator = MarkdownTextEditor.Coordinator(text: .constant(view.editorSource), model: model)
        coordinator.textView = view
        coordinator.usesSharedAnalysis = true
        model.connect(view)
        view.textStorage?.replaceCharacters(in: NSRange(location: 2, length: 0), with: "a")
        let before = view.sourceReadCount
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification))
        XCTAssertEqual(view.sourceReadCount - before, 1)
        XCTAssertTrue(view.sourceText.isContiguousUTF8)
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification))
        _ = view.firstVisibleSourceLocation(in: NSScrollView())
        XCTAssertEqual(view.sourceReadCount - before, 1)
    }

    func testProofingUsesBackgroundRangesAndSuppressesCorrectionWhilePending() {
        let view = EditorTextView()
        view.string = "plain `code` https://example.com"
        let coordinator = MarkdownTextEditor.Coordinator(text: .constant(view.sourceText), model: MarkdownEditorModel())
        coordinator.textView = view
        coordinator.usesSharedAnalysis = true
        coordinator.proofing.checksSpelling = true
        coordinator.proofing.correctsSpelling = true
        coordinator.sharedSnapshot = DocumentSnapshot(source: view.sourceText)
        view.setSelectedRange(NSRange(location: 2, length: 0))
        coordinator.applyProofing()
        XCTAssertTrue(view.isAutomaticSpellingCorrectionEnabled)
        view.setSelectedRange(NSRange(location: 8, length: 0))
        coordinator.applyProofing()
        XCTAssertFalse(view.isAutomaticSpellingCorrectionEnabled)
        view.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "`new` ")
        view.setSelectedRange(NSRange(location: 2, length: 0))
        coordinator.applyProofing()
        XCTAssertFalse(view.isAutomaticSpellingCorrectionEnabled)
        coordinator.sharedSnapshot = DocumentSnapshot(source: view.sourceText)
        view.setSelectedRange(NSRange(location: 8, length: 0))
        coordinator.applyProofing()
        XCTAssertTrue(view.isAutomaticSpellingCorrectionEnabled)
    }

    func testStorageEditsUndoAndReplacementInvalidateCacheButAttributesDoNot() {
        let view = EditorTextView()
        view.string = "abc"
        XCTAssertEqual(view.sourceText, "abc")
        let revision = view.sourceRevision
        view.textStorage?.addAttribute(.foregroundColor, value: NSColor.red,
            range: NSRange(location: 0, length: 1))
        XCTAssertEqual(view.sourceRevision, revision)
        view.textStorage?.replaceCharacters(in: NSRange(location: 1, length: 1), with: "🙂")
        XCTAssertEqual(view.sourceText, "a🙂c")
        XCTAssertGreaterThan(view.sourceRevision, revision)
        view.string = "replacement"
        XCTAssertEqual(view.sourceText, "replacement")
    }
}
