import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

@MainActor
final class MarkdownProofingTests: XCTestCase {
    // Extended Markdown treats this as front matter; Basic parses indented code.
    private let source = "---\n    coode\n---\n\nnormal prose"

    func testSameSourceDialectSwitchUpdatesSharedProofingInBothDirections() {
        let view = NSTextView()
        view.string = source
        view.setSelectedRange(NSRange(location: (source as NSString).range(of: "coode").location,
                                      length: 0))
        let model = MarkdownEditorModel()
        let coordinator = MarkdownTextEditor.Coordinator(text: .constant(source), model: model)
        coordinator.textView = view
        coordinator.usesSharedAnalysis = true
        for dialect in [MarkdownDialect.basic, .extended, .basic, .extended] {
            model.markdownDialect = dialect
            coordinator.sharedSnapshot = DocumentSnapshot(source: source, dialect: dialect)
            coordinator.applyProofing()
            XCTAssertEqual(view.isContinuousSpellCheckingEnabled, dialect == .extended)
            XCTAssertEqual(view.isAutomaticSpellingCorrectionEnabled, dialect == .extended)
            XCTAssertEqual(view.string, source)
        }
    }

    func testPendingDialectAnalysisSuppressesCorrectionAndRejectsOldSnapshots() {
        let view = NSTextView()
        view.string = source
        view.setSelectedRange(NSRange(location: (source as NSString).range(of: "normal").location,
                                      length: 0))
        let model = MarkdownEditorModel()
        let coordinator = MarkdownTextEditor.Coordinator(text: .constant(source), model: model)
        coordinator.textView = view
        coordinator.usesSharedAnalysis = true
        for dialect in [MarkdownDialect.extended, .basic, .extended] {
            model.markdownDialect = dialect
            // The old snapshot remains published while background analysis runs.
            coordinator.applyProofing()
            XCTAssertFalse(view.isContinuousSpellCheckingEnabled)
            XCTAssertFalse(view.isAutomaticSpellingCorrectionEnabled)
            coordinator.sharedSnapshot = nil
            coordinator.applyProofing()
            XCTAssertFalse(view.isAutomaticSpellingCorrectionEnabled)
            coordinator.sharedSnapshot = DocumentSnapshot(source: source,
                dialect: dialect == .basic ? .extended : .basic)
            coordinator.applyProofing()
            XCTAssertFalse(view.isAutomaticSpellingCorrectionEnabled,
                           "A late result for the previous dialect must not enable correction")
            coordinator.sharedSnapshot = DocumentSnapshot(source: source, dialect: dialect)
            coordinator.applyProofing()
            XCTAssertTrue(view.isContinuousSpellCheckingEnabled)
            XCTAssertTrue(view.isAutomaticSpellingCorrectionEnabled)
        }
    }

    func testSameSourceDialectSwitchUpdatesProofingWithoutSharedAnalysis() {
        let view = NSTextView()
        view.string = source
        view.setSelectedRange(NSRange(location: (source as NSString).range(of: "coode").location,
                                      length: 0))
        let model = MarkdownEditorModel()
        let coordinator = MarkdownTextEditor.Coordinator(text: .constant(source), model: model)
        coordinator.textView = view
        for dialect in [MarkdownDialect.basic, .extended, .basic] {
            model.markdownDialect = dialect
            coordinator.applyProofing()
            XCTAssertEqual(view.isContinuousSpellCheckingEnabled, dialect == .extended)
            XCTAssertEqual(view.isAutomaticSpellingCorrectionEnabled, dialect == .extended)
        }
    }

    // MARK: - Spelling markers

    private let codeSource = """
        Some speling here.

        ```cpp
        #include <iostream>
        int mian() { return 0; }
        ```

        Use `iostreem` or https://exampel.com/iostreamm today.

        """

    /// An editor in a window, as continuous checking only marks text in a window.
    private func makeEditor(_ source: String, sharedAnalysis: Bool)
        -> (EditorTextView, MarkdownTextEditor.Coordinator, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        _ = view.layoutManager
        view.string = source
        window.contentView = view
        let model = MarkdownEditorModel()
        let coordinator = MarkdownTextEditor.Coordinator(text: .constant(source), model: model)
        coordinator.textView = view
        view.delegate = coordinator
        coordinator.usesSharedAnalysis = sharedAnalysis
        coordinator.proofing.checksSpelling = true
        coordinator.proofing.correctsSpelling = true
        NSSpellChecker.shared.automaticallyIdentifiesLanguages = !NSSpellChecker.shared.setLanguage("en")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        return (view, coordinator, window)
    }

    private func checkSpelling(_ view: NSTextView) {
        view.checkText(in: NSRange(location: 0, length: (view.string as NSString).length),
                       types: NSTextCheckingResult.CheckingType.spelling.rawValue, options: [:])
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    private func isMarked(_ word: String, in view: NSTextView) -> Bool {
        let location = (view.string as NSString).range(of: word).location
        XCTAssertNotEqual(location, NSNotFound, word)
        let state = view.layoutManager?.temporaryAttribute(.spellingState, atCharacterIndex: location,
                                                          effectiveRange: nil) as? Int
        return (state ?? 0) != 0
    }

    private func assertOnlyProseIsMarked(_ view: NSTextView, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(isMarked("speling", in: view), "prose must still be checked", file: file, line: line)
        for word in ["iostream", "mian", "iostreem", "exampel", "iostreamm"] {
            XCTAssertFalse(isMarked(word, in: view), "\(word) is code or a URL", file: file, line: line)
        }
    }

    func testOpeningWithCaretInProseDoesNotMarkCodeOrURLs() {
        let (view, coordinator, window) = makeEditor(codeSource, sharedAnalysis: false)
        defer { window.close() }
        coordinator.applyProofing()
        XCTAssertTrue(view.isContinuousSpellCheckingEnabled)
        checkSpelling(view)
        assertOnlyProseIsMarked(view)
    }

    func testSnapshotArrivingAfterOpenDoesNotMarkCodeOrURLs() {
        let (view, coordinator, window) = makeEditor(codeSource, sharedAnalysis: true)
        defer { window.close() }
        coordinator.applyProofing()
        XCTAssertFalse(view.isContinuousSpellCheckingEnabled, "no ranges are known before the first analysis")
        coordinator.sharedSnapshot = DocumentSnapshot(source: codeSource)
        coordinator.applyProofing()
        XCTAssertTrue(view.isContinuousSpellCheckingEnabled)
        checkSpelling(view)
        assertOnlyProseIsMarked(view)
    }

    func testWordsThatBecomeCodeLoseTheirMarkersWhenTheAnalysisArrives() {
        let source = "Some speling here.\n\nwrongg\n\nmore prose\n"
        let (view, coordinator, window) = makeEditor(source, sharedAnalysis: true)
        defer { window.close() }
        coordinator.sharedSnapshot = DocumentSnapshot(source: source)
        coordinator.applyProofing()
        checkSpelling(view)
        XCTAssertTrue(isMarked("wrongg", in: view))

        // Fencing the word while the next analysis is pending, then a pending inline span.
        let text = view.string as NSString
        let word = text.range(of: "wrongg")
        view.textStorage?.replaceCharacters(in: NSRange(location: NSMaxRange(word) + 1, length: 0), with: "```\n")
        view.textStorage?.replaceCharacters(in: NSRange(location: word.location, length: 0), with: "```\n")
        let more = (view.string as NSString).range(of: "more")
        view.textStorage?.replaceCharacters(in: NSRange(location: NSMaxRange(more) + 1, length: 0),
                                            with: "`inlinne` ")
        coordinator.applyProofing()
        checkSpelling(view)
        XCTAssertFalse(isMarked("inlinne", in: view), "inline code typed while pending is not marked")

        coordinator.sharedSnapshot = DocumentSnapshot(source: view.sourceText)
        coordinator.applyProofing()
        XCTAssertFalse(isMarked("wrongg", in: view), "the marker set while it was prose must be removed")
        XCTAssertTrue(isMarked("speling", in: view))
    }

    func testReloadingTheWholeTextWaitsForItsAnalysisBeforeChecking() {
        let original = "Some prose here.\n"
        let (view, coordinator, window) = makeEditor(original, sharedAnalysis: true)
        defer { window.close() }
        coordinator.sharedSnapshot = DocumentSnapshot(source: original)
        coordinator.applyProofing()
        XCTAssertTrue(view.isContinuousSpellCheckingEnabled)

        // updateNSView replaces the whole text when the document is reloaded.
        view.string = codeSource
        view.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.applyProofing()
        XCTAssertFalse(view.isContinuousSpellCheckingEnabled,
                       "the old ranges say nothing about where code is in the reloaded text")
        XCTAssertFalse(view.isAutomaticSpellingCorrectionEnabled)

        coordinator.sharedSnapshot = DocumentSnapshot(source: codeSource)
        coordinator.applyProofing()
        XCTAssertTrue(view.isContinuousSpellCheckingEnabled)
        checkSpelling(view)
        assertOnlyProseIsMarked(view)
    }
}
