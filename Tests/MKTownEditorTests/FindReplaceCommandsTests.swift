import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

@MainActor
final class FindReplaceCommandsTests: XCTestCase {
    func testFindNavigationPreservesFocusWhileFindBarIsVisible() {
        let view = FinderSpyTextView()
        view.string = "needle needle"
        let scroll = FindBarScrollView()
        scroll.documentView = view
        let window = FinderFocusSpyWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                                          styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        defer { window.orderOut(nil); window.contentView = nil }
        let model = MarkdownEditorModel()
        model.connect(view)
        window.focusRequests = 0

        scroll.simulatesFindBarVisible = true
        model.findNext()
        model.findPrevious()
        XCTAssertEqual(window.focusRequests, 0, "Navigation must not end the search field's session")
        XCTAssertEqual(view.actions, [.nextMatch, .previousMatch])

        scroll.simulatesFindBarVisible = false
        model.findNext()
        XCTAssertEqual(window.focusRequests, 1, "Navigation without a find bar must still target the editor")
        model.showFindBar()
        model.showReplaceBar()
        XCTAssertEqual(window.focusRequests, 3)
    }

    func testRepeatedViewUpdatesOnlyApplyActualEditabilityChanges() {
        let view = ProofingSettingsSpyTextView()
        view.updateEditorEditability(true)
        view.editabilityUpdates = 0
        for _ in 0..<85 { view.updateEditorEditability(true) }
        XCTAssertEqual(view.editabilityUpdates, 0,
                       "Unchanged AppKit settings must preserve the active find session")
        view.updateEditorEditability(false)
        XCTAssertFalse(view.isEditable)
        XCTAssertEqual(view.editabilityUpdates, 1)
        for _ in 0..<85 { view.updateEditorEditability(false) }
        XCTAssertEqual(view.editabilityUpdates, 1)
        view.updateEditorEditability(true)
        XCTAssertTrue(view.isEditable)
        XCTAssertEqual(view.editabilityUpdates, 2)
    }

    func testRepeatedMatchSelectionsDoNotReapplyUnchangedProofingSettings() throws {
        let view = ProofingSettingsSpyTextView()
        view.string = String(repeating: "日本語😀 needle\n", count: 40)
        let model = MarkdownEditorModel()
        model.connect(view)
        let coordinator = MarkdownTextEditor.Coordinator(text: .constant(view.string), model: model)
        coordinator.textView = view
        coordinator.proofing.checksSpelling = true
        coordinator.proofing.correctsSpelling = true
        view.delegate = coordinator
        coordinator.applyProofing()
        view.checkingUpdates = 0
        view.correctionUpdates = 0
        let matches = try RegexSearch.matches(in: view.string, pattern: "needle")
        XCTAssertEqual(matches.count, 40)
        for ranges in [matches, Array(matches.reversed()), matches] {
            for range in ranges {
                view.setSelectedRange(range)
                coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification))
            }
        }
        XCTAssertEqual(view.checkingUpdates, 0)
        XCTAssertEqual(view.correctionUpdates, 0)
        XCTAssertTrue(view.isContinuousSpellCheckingEnabled)
        XCTAssertTrue(view.isAutomaticSpellingCorrectionEnabled)
        XCTAssertEqual(view.string.components(separatedBy: "needle").count - 1, 40)
    }

    func testCommandsUseStandardTextFinderActions() {
        let view = FinderSpyTextView()
        view.string = "alpha beta alpha"
        let model = MarkdownEditorModel()
        model.connect(view)

        model.showFindBar()
        model.showReplaceBar()
        model.findNext()
        model.findPrevious()
        model.replaceAllMatches()

        XCTAssertEqual(view.actions, [.showFindInterface, .showReplaceInterface,
                                      .nextMatch, .previousMatch, .replaceAll])
    }

    func testReplaceAllIsDisabledDuringMarkedText() {
        let view = FinderSpyTextView()
        view.simulatesMarkedText = true
        let model = MarkdownEditorModel()
        model.connect(view)

        model.replaceAllMatches()

        XCTAssertTrue(view.actions.isEmpty)
    }

    func testReplaceAllInSelectionUsesStandardActionOnlyWhenSelected() {
        let view = FinderSpyTextView()
        view.string = "alpha beta"
        let model = MarkdownEditorModel()
        model.connect(view)
        model.replaceAllInSelection()
        XCTAssertTrue(view.actions.isEmpty)

        view.setSelectedRange(NSRange(location: 0, length: 5))
        model.replaceAllInSelection()
        XCTAssertEqual(view.actions, [.replaceAllInSelection])
    }

    func testDocumentSearchNavigationUsesExactUTF16RangeAndKeepsListFocus() {
        let source = "e\u{301} 😀 needle"
        let equivalentSource = "é 😀 needle"
        let view = FinderSpyTextView()
        view.string = source
        let window = FinderFocusSpyWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                                          styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil); window.contentView = nil }
        let model = MarkdownEditorModel()
        model.connect(view)
        window.focusRequests = 0

        let stale = (equivalentSource as NSString).range(of: "😀")
        XCTAssertFalse(model.selectDocumentSearchResult(stale, expectedSource: equivalentSource))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 0))
        let match = (source as NSString).range(of: "😀")
        XCTAssertTrue(model.selectDocumentSearchResult(match, expectedSource: source))
        XCTAssertEqual(view.selectedRange(), match)
        XCTAssertEqual(model.selectedRange, match)
        XCTAssertEqual(window.focusRequests, 0)
        view.simulatesMarkedText = true
        XCTAssertFalse(model.selectDocumentSearchResult(match, expectedSource: source))
    }

    func testDocumentSearchHighlightsAreDisplayOnlyAndDiscardedByAnEdit() {
        let source = "日本語😀 needle\nneedle"
        let view = EditorTextView()
        view.string = source
        let model = MarkdownEditorModel()
        model.connect(view)
        view.commandModel = model
        view.updateEditorEditability(false)
        let before = NSAttributedString(attributedString: view.attributedString())
        let found = (source as NSString).range(of: "needle")
        let second = (source as NSString).range(of: "needle", options: .backwards)
        model.showDocumentSearchHighlights([found, second], expectedSource: source)

        XCTAssertTrue(model.hasDocumentSearchHighlights)
        XCTAssertEqual(Array(model.documentSearchHighlights(overlapping:
            NSRange(location: NSMaxRange(found), length: 1))), [])
        XCTAssertEqual(Array(model.documentSearchHighlights(overlapping:
            NSRange(location: NSMaxRange(found) - 1, length: 3))), [found, second])
        XCTAssertEqual(view.attributedString(), before)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 0))

        model.clearDocumentSearchHighlights()
        XCTAssertFalse(model.hasDocumentSearchHighlights)
        model.showDocumentSearchHighlights([found, second], expectedSource: source)
        view.replaceEditorText(with: "Changed " + source)
        XCTAssertFalse(model.hasDocumentSearchHighlights)
        XCTAssertTrue(model.documentSearchHighlights(overlapping: found).isEmpty)
    }

    func testDocumentSearchHighlightsSurvivePreviewUntilSourceChanges() {
        let source = "é needle"
        let first = EditorTextView()
        first.string = source
        let model = MarkdownEditorModel()
        model.connect(first)
        let range = (source as NSString).range(of: "needle")
        model.showDocumentSearchHighlights([range], expectedSource: source)
        model.disconnect(first)

        let second = EditorTextView()
        second.string = source
        model.connect(second)
        XCTAssertTrue(model.hasDocumentSearchHighlights)
        XCTAssertEqual(Array(model.documentSearchHighlights(overlapping: range)), [range])
        model.disconnect(second)

        let third = EditorTextView()
        third.string = "e\u{301} needle"
        model.connect(third)
        XCTAssertFalse(model.hasDocumentSearchHighlights)
        XCTAssertTrue(model.documentSearchHighlights(overlapping: range).isEmpty)
    }
}

@MainActor
private final class FinderSpyTextView: NSTextView {
    var actions: [NSTextFinder.Action] = []
    var simulatesMarkedText = false

    override func hasMarkedText() -> Bool { simulatesMarkedText }

    override func performTextFinderAction(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let action = NSTextFinder.Action(rawValue: item.tag) else { return }
        actions.append(action)
    }
}

@MainActor
private final class ProofingSettingsSpyTextView: NSTextView {
    var editabilityUpdates = 0
    override var isEditable: Bool {
        didSet { editabilityUpdates += 1 }
    }
    var checkingUpdates = 0
    var correctionUpdates = 0
    override var isContinuousSpellCheckingEnabled: Bool {
        didSet { checkingUpdates += 1 }
    }
    override var isAutomaticSpellingCorrectionEnabled: Bool {
        didSet { correctionUpdates += 1 }
    }
}

@MainActor
private final class FindBarScrollView: NSScrollView {
    var simulatesFindBarVisible = false
    override var isFindBarVisible: Bool {
        get { simulatesFindBarVisible }
        set { simulatesFindBarVisible = newValue }
    }
}

@MainActor
private final class FinderFocusSpyWindow: NSWindow {
    var focusRequests = 0
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        focusRequests += 1
        return super.makeFirstResponder(responder)
    }
}
