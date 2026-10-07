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

    func testTypingProseKeepsCorrectionWhileSnapshotIsPendingButProtectsNewAndShiftedCode() {
        let view = EditorTextView()
        view.string = "intro\n\n```\ncoode\n```\n\nprose"
        let coordinator = MarkdownTextEditor.Coordinator(text: .constant(view.sourceText), model: MarkdownEditorModel())
        coordinator.textView = view
        coordinator.usesSharedAnalysis = true
        coordinator.proofing.checksSpelling = true
        coordinator.proofing.correctsSpelling = true
        coordinator.sharedSnapshot = DocumentSnapshot(source: view.sourceText)
        coordinator.applyProofing()

        // Typing prose in front of the fenced block: the snapshot is now stale.
        view.textStorage?.replaceCharacters(in: NSRange(location: 5, length: 0), with: " teh")
        view.setSelectedRange(NSRange(location: 9, length: 0))
        coordinator.applyProofing()
        XCTAssertNotEqual(coordinator.sharedSnapshot?.source, view.sourceText)
        XCTAssertTrue(view.isContinuousSpellCheckingEnabled, "prose must keep spell checking while analysis is pending")
        XCTAssertTrue(view.isAutomaticSpellingCorrectionEnabled, "prose must keep autocorrect while analysis is pending")

        // The fenced block moved by four characters and stays protected.
        let code = (view.sourceText as NSString).range(of: "coode").location
        view.setSelectedRange(NSRange(location: code + 2, length: 0))
        coordinator.applyProofing()
        XCTAssertFalse(view.isAutomaticSpellingCorrectionEnabled)

        // Inline code and URLs typed since the snapshot are protected in the caret's paragraph.
        let end = (view.sourceText as NSString).length
        view.textStorage?.replaceCharacters(in: NSRange(location: end, length: 0), with: " `nwe")
        view.setSelectedRange(NSRange(location: end + 4, length: 0))
        coordinator.applyProofing()
        XCTAssertTrue(view.isAutomaticSpellingCorrectionEnabled, "an unclosed backtick is not code yet")
        view.textStorage?.replaceCharacters(in: NSRange(location: end + 5, length: 0), with: "`")
        view.setSelectedRange(NSRange(location: end + 3, length: 0))
        coordinator.applyProofing()
        XCTAssertFalse(view.isAutomaticSpellingCorrectionEnabled)
        let urlEnd = (view.sourceText as NSString).length
        view.textStorage?.replaceCharacters(in: NSRange(location: urlEnd, length: 0), with: " https://exampel.com")
        view.setSelectedRange(NSRange(location: urlEnd + 20, length: 0))
        coordinator.applyProofing()
        XCTAssertFalse(view.isAutomaticSpellingCorrectionEnabled)
    }

    func testShiftedProofingRangesFollowInsertionsDeletionsAndDropCutRanges() {
        typealias Range = MarkdownProofingContext.ProtectedRange
        let code = Range(range: NSRange(location: 10, length: 5), includesEnd: false)
        let url = Range(range: NSRange(location: 20, length: 8), includesEnd: true)
        func shift(_ location: Int, inserted: Int, removed: Int) -> [Range] {
            MarkdownProofingContext.shifted([code, url],
                editedRange: NSRange(location: location, length: inserted), changeInLength: inserted - removed)
        }
        XCTAssertEqual(shift(0, inserted: 3, removed: 0).map(\.range),
                       [NSRange(location: 13, length: 5), NSRange(location: 23, length: 8)])
        XCTAssertEqual(shift(12, inserted: 2, removed: 0).map(\.range),
                       [NSRange(location: 10, length: 7), NSRange(location: 22, length: 8)])
        XCTAssertEqual(shift(15, inserted: 1, removed: 0).map(\.range),
                       [code.range, NSRange(location: 21, length: 8)], "text after inline code is not code")
        XCTAssertEqual(shift(28, inserted: 4, removed: 0).map(\.range),
                       [code.range, NSRange(location: 20, length: 12)], "typing at a URL's end extends it")
        XCTAssertEqual(shift(9, inserted: 0, removed: 3).map(\.range), [NSRange(location: 17, length: 8)],
                       "a deletion that cuts a range drops it until the next snapshot")
        XCTAssertEqual(shift(0, inserted: 0, removed: 2).map(\.range),
                       [NSRange(location: 8, length: 5), NSRange(location: 18, length: 8)])
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
