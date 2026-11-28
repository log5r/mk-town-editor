import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

@MainActor
final class MarkdownProofingTests: XCTestCase {
    // Extended Markdown treats the title as front matter. In Basic it is prose.
    private let source = "---\ntitle: coode\n---\n\nnormal prose"

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
            XCTAssertEqual(view.isContinuousSpellCheckingEnabled, dialect == .basic)
            XCTAssertEqual(view.isAutomaticSpellingCorrectionEnabled, dialect == .basic)
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
            XCTAssertEqual(view.isContinuousSpellCheckingEnabled, dialect == .basic)
            XCTAssertEqual(view.isAutomaticSpellingCorrectionEnabled, dialect == .basic)
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
        view.isRichText = false
        view.string = source
        window.contentView = view
        let model = MarkdownEditorModel()
        model.markdownDialect = .extended
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

    func testNativeProofingOptionsAndSubstitutions() {
        let source = """
        ---
        title: "front -- matter"
        ---

        Try "ordinary" prose -- here.

        ```
        "fenced -- code"
        ```

        Try `"inline -- code"` and https://example.com/path--part.
        Also try $"inline -- math"$.

          $$
          "display -- math"
          $$
        """
        let (view, coordinator, window) = makeEditor(source, sharedAnalysis: false)
        defer { window.close() }
        let protected = [#""front -- matter""#, #""fenced -- code""#, #""inline -- code""#,
                         "https://example.com/path--part", #""inline -- math""#, #""display -- math""#]
        let prose = #"Try "ordinary" prose -- here."#
        select(prose, in: view)
        coordinator.applyProofing()
        XCTAssertFalse(view.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(view.isAutomaticDashSubstitutionEnabled)
        XCTAssertFalse(view.isAutomaticTextReplacementEnabled)
        XCTAssertFalse(view.isGrammarCheckingEnabled)
        XCTAssertFalse(view.smartInsertDeleteEnabled)

        coordinator.proofing.usesSmartQuotes = true
        coordinator.proofing.usesSmartDashes = true
        coordinator.proofing.usesTextReplacement = true
        coordinator.proofing.checksGrammar = true
        coordinator.proofing.usesSmartInsertDelete = true
        coordinator.applyProofing()
        XCTAssertTrue(view.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertTrue(view.isAutomaticDashSubstitutionEnabled)
        XCTAssertTrue(view.isAutomaticTextReplacementEnabled)
        XCTAssertTrue(view.isGrammarCheckingEnabled)
        XCTAssertTrue(view.smartInsertDeleteEnabled)

        select(prose, in: view)
        view.checkTextInDocument(nil)
        let deadline = Date().addingTimeInterval(2)
        while view.string.contains(prose), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertFalse(view.string.contains(#""ordinary""#), "AppKit should substitute prose quotes")
        XCTAssertFalse(view.string.contains("prose -- here"), "AppKit should substitute prose dashes")
        for fragment in protected {
            XCTAssertTrue(view.string.contains(fragment), "\(fragment) should retain the source punctuation")
        }
    }

    func testSystemReplacementResultsAreFilteredForAllProtectedRanges() {
        let source = """
        ---
        title: frontmatter
        ---

        prose replace

        ```
        fenced
        ```

        `inlinecode` https://example.com/urlpath $inlinemath$

        $$
        displaymath
        $$
        """
        let (view, coordinator, window) = makeEditor(source, sharedAnalysis: true)
        defer { window.close() }
        coordinator.proofing.usesTextReplacement = true
        coordinator.sharedSnapshot = DocumentSnapshot(source: source)
        coordinator.applyProofing()
        let words = ["replace", "frontmatter", "fenced", "inlinecode", "urlpath", "inlinemath", "displaymath"]
        let results = words.map { word in
            NSTextCheckingResult.replacementCheckingResult(range: (source as NSString).range(of: word),
                                                           replacementString: "substituted")
        }
        let orthography = NSOrthography(dominantScript: "Latn", languageMap: ["Latn": ["en"]])
        let type = NSTextCheckingResult.CheckingType.replacement.rawValue
        let filtered = view.delegate?.textView?(view, didCheckTextIn: NSRange(location: 0, length: source.utf16.count),
            types: type, options: [:], results: results, orthography: orthography, wordCount: words.count)
        XCTAssertEqual(filtered?.map(\.range), [results[0].range])
    }

    func testDoubleSpaceSubstitutesOnlyWhenEnabledInProse() {
        let tests = [
            (source: "ordinary text", after: "ordinary", enabled: true, expected: "ordinary.  text"),
            (source: "ordinary text", after: "ordinary", enabled: false, expected: "ordinary   text"),
            (source: "`inline code`", after: "inline", enabled: true, expected: "`inline   code`"),
            (source: "$inline + math$", after: "inline", enabled: true, expected: "$inline   + math$"),
            (source: "https://example.com/path", after: "/path", enabled: true, expected: "https://example.com/path  ")
        ]
        for test in tests {
            let (view, coordinator, window) = makeEditor(test.source, sharedAnalysis: false)
            defer { window.close() }
            coordinator.proofing.insertsPeriodOnDoubleSpace = test.enabled
            let precedingText = (test.source as NSString).range(of: test.after)
            view.setSelectedRange(NSRange(location: NSMaxRange(precedingText), length: 0))
            coordinator.applyProofing()
            let insertion = NSRange(location: NSNotFound, length: 0)
            view.insertText(" ", replacementRange: insertion)
            view.insertText(" ", replacementRange: insertion)
            XCTAssertEqual(view.string, test.expected)
        }
    }

    func testMovingCaretCancelsTheFirstSpace() {
        let (view, coordinator, window) = makeEditor("sentence", sharedAnalysis: false)
        defer { window.close() }
        coordinator.proofing.insertsPeriodOnDoubleSpace = true
        view.setSelectedRange(NSRange(location: 8, length: 0))
        coordinator.applyProofing()
        let insertion = NSRange(location: NSNotFound, length: 0)
        view.insertText(" ", replacementRange: insertion)
        let afterFirstSpace = view.selectedRange()
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.setSelectedRange(afterFirstSpace)
        view.insertText(" ", replacementRange: insertion)
        XCTAssertEqual(view.string, "sentence  ")
    }

    func testFencedCodeAtEndOfDocumentProtectsOnlyTheOpenBlock() {
        for (source, allowsSubstitutions) in [("```\ncode\n```\n", true), ("```\ncode\n", false)] {
            let (view, coordinator, window) = makeEditor(source, sharedAnalysis: false)
            defer { window.close() }
            coordinator.proofing.usesSmartQuotes = true
            let end = NSRange(location: source.utf16.count, length: 0)
            view.setSelectedRange(end)
            coordinator.applyProofing()
            XCTAssertEqual(view.isAutomaticQuoteSubstitutionEnabled, allowsSubstitutions)
            XCTAssertEqual(coordinator.allowsProofingEdit(end, in: view), allowsSubstitutions)
        }
    }

    func testSmartSpacingHonorsTheRangeBeingEdited() {
        let source = "Keep one two three and `one four three`."
        let (view, coordinator, window) = makeEditor(source, sharedAnalysis: false)
        defer { window.close() }
        coordinator.proofing.usesSmartInsertDelete = true
        coordinator.applyProofing()

        for (word, protected) in [("two", false), ("four", true)] {
            let wordRange = (source as NSString).range(of: word)
            let insertion = NSRange(location: wordRange.location + 1, length: 0)
            var before: NSString?
            var after: NSString?
            view.smartInsert(for: "new", replacing: insertion, before: &before, after: &after)
            XCTAssertEqual(before, protected ? nil : " ")
            XCTAssertEqual(after, protected ? nil : " ")

            let delete = view.smartDeleteRange(forProposedRange: wordRange)
            XCTAssertEqual(delete.length, wordRange.length + (protected ? 0 : 1))
        }
    }

    func testMultilineSmartPastePreservesTheRequestedLineEndings() throws {
        let cases = [
            (source: "foobar", marker: true, preserves: false, expected: "foo hello\nword bar"),
            (source: "foobar", marker: false, preserves: false, expected: "foohello\nwordbar"),
            (source: "foobar", marker: true, preserves: true, expected: "foo hello\r\nword bar"),
            (source: "```\nfoobar\n```", marker: true, preserves: true, expected: "```\nfoohello\r\nwordbar\n```")
        ]
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let smartPasteType = NSPasteboard.PasteboardType("NeXT smart paste pasteboard type")
        for test in cases {
            let (view, coordinator, window) = makeEditor(test.source, sharedAnalysis: false)
            defer { window.close() }
            var document = MarkdownDocument(text: test.source)
            coordinator.document = Binding(get: { document }, set: { document = $0 })
            coordinator.proofing.usesSmartInsertDelete = true
            let prefix = (test.source as NSString).range(of: "foo")
            view.setSelectedRange(NSRange(location: NSMaxRange(prefix), length: 0))
            coordinator.applyProofing()

            board.clearContents()
            XCTAssertTrue(board.setString("hello\r\nword", forType: .string))
            if test.marker { XCTAssertTrue(board.setData(Data(), forType: smartPasteType)) }
            view.imagePasteboard = board
            if test.preserves { view.pastePreservingNewlines() } else { view.paste(nil) }

            XCTAssertEqual(view.string, MarkdownTextFormat.normalizedText(test.expected))
            XCTAssertEqual(String(decoding: try document.encodedData(), as: UTF8.self), test.expected)
        }
    }

    private func select(_ substring: String, in view: NSTextView) {
        let range = (view.string as NSString).range(of: substring)
        XCTAssertNotEqual(range.location, NSNotFound)
        view.setSelectedRange(NSRange(location: range.location, length: 0))
    }
}
