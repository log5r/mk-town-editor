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
