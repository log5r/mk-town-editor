import Foundation
import AppKit
import XCTest
@testable import MKTownEditor

final class RegexSearchTests: XCTestCase {
    func testCaseSensitivityAndCaptureReplacement() throws {
        let source = "Name: Alice\nname: Bob"
        let pattern = #"(?m)^(Name): (\w+)$"#
        XCTAssertEqual(try RegexSearch.matches(in: source, pattern: pattern,
                                               caseSensitive: true).count, 1)
        XCTAssertEqual(try RegexSearch.matches(in: source, pattern: pattern).count, 2)
        let edit = try XCTUnwrap(RegexSearch.replacementEdit(in: source, pattern: pattern,
                                                            template: "$2 ($1)"))
        XCTAssertEqual(edit.applying(to: source), "Alice (Name)\nBob (name)")
    }

    func testInvalidPatternAndCaptureAreReported() {
        XCTAssertThrowsError(try RegexSearch.matches(in: "text", pattern: "[")) {
            guard case RegexSearchError.invalidPattern = $0 else { return XCTFail("unexpected error") }
        }
        XCTAssertThrowsError(try RegexSearch.replacementEdit(in: "abc", pattern: "(a)",
                                                                 template: "$2")) {
            XCTAssertEqual($0 as? RegexSearchError, .invalidCapture(2))
        }
    }

    func testZeroWidthMatchesTerminateAndReplaceCorrectly() throws {
        let source = "ab"
        let ranges = try RegexSearch.matches(in: source, pattern: #"(?=.)"#)
        XCTAssertEqual(ranges, [NSRange(location: 0, length: 0), NSRange(location: 1, length: 0)])
        let edit = try XCTUnwrap(RegexSearch.replacementEdit(in: source, pattern: #"(?=.)"#,
                                                            template: "|"))
        XCTAssertEqual(edit.applying(to: source), "|a|b")
    }

    func testSingleMatchEditLeavesOtherMatchesUnchanged() throws {
        let source = "one two one"
        let matches = try RegexSearch.matches(in: source, pattern: "one")
        let edit = try XCTUnwrap(RegexSearch.replacementEdit(in: source, pattern: "one",
                                                            template: "ONE", onlyMatch: matches[1]))
        XCTAssertEqual(edit.range, matches[1])
        XCTAssertEqual(edit.applying(to: source), "one two ONE")
    }

    func testReplaceCurrentSelectedMatchWhileNextSearchAdvances() throws {
        let matches = try RegexSearch.matches(in: "one two one", pattern: "one")
        XCTAssertEqual(RegexSearch.replacementTarget(in: matches, selection: matches[0]), matches[0])
        XCTAssertEqual(RegexSearch.nextMatch(in: matches, after: matches[0]), matches[1])
        XCTAssertEqual(RegexSearch.nextMatch(in: matches, after: matches[1]), matches[0])
    }

    func testSelectionScopeLimitsMatchesAndTracksReplacementLength() throws {
        let source = "red red red"
        var scope = try XCTUnwrap(RegexSelectionScope(NSRange(location: 0, length: 7)))
        XCTAssertEqual(try RegexSearch.matches(in: source, pattern: "red", scope: scope.range).count, 2)
        let edit = try XCTUnwrap(RegexSearch.replacementEdit(in: source, pattern: "red",
                                                            template: "R", scope: scope.range))
        XCTAssertEqual(edit.applying(to: source), "R R red")
        XCTAssertTrue(scope.apply(edit))
        XCTAssertEqual(scope.range, NSRange(location: 0, length: 3))
        XCTAssertEqual(try RegexSearch.matches(in: edit.applying(to: source),
                                               pattern: "red", scope: scope.range).count, 0)
    }

    func testScopeMovesForEarlierEditAndRejectsInvalidRange() throws {
        var scope = try XCTUnwrap(RegexSelectionScope(NSRange(location: 4, length: 3)))
        let edit = MarkdownEdit(range: NSRange(location: 0, length: 2), replacement: "long",
                                selection: NSRange(location: 4, length: 0))
        XCTAssertTrue(scope.apply(edit))
        XCTAssertEqual(scope.range, NSRange(location: 6, length: 3))
        XCTAssertThrowsError(try RegexSearch.matches(in: "short", pattern: "o",
                                                     scope: scope.range)) {
            XCTAssertEqual($0 as? RegexSearchError, .invalidScope)
        }
    }

    func testZeroWidthInsertionAtSelectionStartExtendsScope() throws {
        let source = "ab"
        var scope = try XCTUnwrap(RegexSelectionScope(NSRange(location: 1, length: 1)))
        let edit = try XCTUnwrap(RegexSearch.replacementEdit(in: source, pattern: #"(?=b)"#,
                                                            template: "|", scope: scope.range))
        XCTAssertEqual(edit.applying(to: source), "a|b")
        XCTAssertTrue(scope.apply(edit))
        XCTAssertEqual(scope.range, NSRange(location: 1, length: 2))
    }

    func testScopeRejectsEditCrossingSelectionBoundary() throws {
        var scope = try XCTUnwrap(RegexSelectionScope(NSRange(location: 4, length: 3)))
        let edit = MarkdownEdit(range: NSRange(location: 2, length: 3), replacement: "x",
                                selection: NSRange(location: 3, length: 0))
        XCTAssertFalse(scope.apply(edit))
        XCTAssertEqual(scope.range, NSRange(location: 4, length: 3))
    }
}

final class DocumentSearchTests: XCTestCase {
    func testWidthKanaAndCaseOptionsAreIndependent() throws {
        let source = "ガ ｶﾞ が Ａ a"
        func spelling(_ pattern: String, _ options: DocumentSearchOptions) throws -> [String] {
            try DocumentSearch.matches(in: source, pattern: pattern, mode: .plain, options: options)
                .map { (source as NSString).substring(with: $0.range) }
        }
        XCTAssertEqual(try spelling("ガ", .init()), ["ガ"])
        XCTAssertEqual(try spelling("ガ", .init(ignoresWidth: true)), ["ガ", "ｶﾞ"])
        XCTAssertEqual(try spelling("ガ", .init(ignoresKana: true)), ["ガ", "が"])
        XCTAssertEqual(try spelling("が", .init(ignoresWidth: true, ignoresKana: true)), ["ガ", "ｶﾞ", "が"])
        XCTAssertEqual(try spelling("A", .init(ignoresWidth: true)), ["Ａ", "a"])
        XCTAssertEqual(try spelling("A", .init(caseSensitive: true, ignoresWidth: true)), ["Ａ"])
    }

    func testWidthOptionUsesHangulCompatibilityWidthPairsAndFullwidthSpaces() throws {
        let source = "ㄱ　ㅏ / ﾡ ￂ / ᄀ ᅡ"
        let options = DocumentSearchOptions(ignoresWidth: true)
        let matches = try DocumentSearch.matches(in: source, pattern: "ㄱ ㅏ", mode: .plain, options: options)
        XCTAssertEqual(matches.map { (source as NSString).substring(with: $0.range) }, ["ㄱ　ㅏ", "ﾡ ￂ"])
    }

    func testDiacriticsPreserveOriginalUTF16RangesForReplacement() throws {
        let source = "🙂 Café Cafe\u{301} café が か\u{3099}"
        XCTAssertEqual(try DocumentSearch.matches(in: source, pattern: "Cafe", mode: .plain), [])
        let options = DocumentSearchOptions(caseSensitive: true, ignoresDiacritics: true)
        let words = try DocumentSearch.matches(in: source, pattern: "Cafe", mode: .plain, options: options)
        XCTAssertEqual(words.map(\.range), [NSRange(location: 3, length: 4), NSRange(location: 8, length: 5)])
        let kana = try DocumentSearch.matches(in: source, pattern: "か", mode: .plain, options: options)
        XCTAssertEqual(kana.map { (source as NSString).substring(with: $0.range) }, ["が", "か\u{3099}"])
        let edit = try XCTUnwrap(DocumentSearch.replacementEdit(in: source, pattern: "Cafe",
            template: "$1", mode: .plain, options: options, onlyMatch: words[1].range))
        XCTAssertEqual(edit.applying(to: source), "🙂 Café $1 café が か\u{3099}")
    }

    func testWholeWordsUseUnicodeBoundariesOutsideTheSelectionScope() throws {
        let source = "hey_hey hey heyday 猫ねこ"
        let options = DocumentSearchOptions(wholeWords: true)
        let matches = try DocumentSearch.matches(in: source, pattern: "hey", mode: .plain, options: options)
        XCTAssertEqual(matches.map(\.range), [NSRange(location: 8, length: 3)])
        let partial = try DocumentSearch.matches(in: source, pattern: "hey", mode: .plain, options: options,
                                                scope: NSRange(location: 12, length: 3))
        XCTAssertTrue(partial.isEmpty)
        let bounded = try DocumentSearch.matches(in: source, pattern: "hey", mode: .plain, options: options,
                                                scope: NSRange(location: 8, length: 3))
        XCTAssertEqual(bounded, matches)
        let kana = try DocumentSearch.matches(in: source, pattern: "ねこ", mode: .plain, options: options)
        XCTAssertEqual(kana.map(\.range), [NSRange(location: 20, length: 2)])
    }

    func testScopeDoesNotAllowPartOfAFoldedGrapheme() throws {
        let source = "a\u{301} a"
        let options = DocumentSearchOptions(ignoresDiacritics: true)
        let matches = try DocumentSearch.matches(in: source, pattern: "a", mode: .plain, options: options,
                                                scope: NSRange(location: 1, length: 3))
        XCTAssertEqual(matches.map(\.range), [NSRange(location: 3, length: 1)])
    }

    func testResultUsesOriginalContextAndLineNumbersAcrossMixedLineEndings() throws {
        let source = "top\r\n🙂 前 ｶﾞ 後\r\nhello\rthere\nend"
        let plain = try XCTUnwrap(DocumentSearch.matches(in: source, pattern: "が", mode: .plain,
            options: .init(ignoresWidth: true, ignoresKana: true)).first)
        XCTAssertEqual(plain.lineNumber, 2)
        XCTAssertEqual(plain.range, NSRange(location: 10, length: 2))
        XCTAssertEqual(plain.snippet, "🙂 前 ｶﾞ 後")
        let regex = try XCTUnwrap(DocumentSearch.matches(in: source, pattern: #"lo\rth"#, mode: .regex).first)
        XCTAssertEqual(regex.lineNumber, 3)
        XCTAssertEqual(regex.snippet, "hello↵there")
    }

    func testSnippetIsBoundedButKeepsContextBeforeAndAfterLongMatch() throws {
        let pattern = String(repeating: "a", count: 250)
        let source = "PRE" + pattern + "POST"
        let match = try XCTUnwrap(DocumentSearch.matches(in: source, pattern: pattern, mode: .plain).first)
        XCTAssertTrue(match.snippet.hasPrefix("PRE"))
        XCTAssertTrue(match.snippet.hasSuffix("POST"))
        XCTAssertTrue(match.snippet.contains("…"))
        XCTAssertLessThan(match.snippet.count, 160)
    }

    func testSnippetDoesNotExpandToIncludeAllMarksInAnOversizedGrapheme() throws {
        let source = "pre a" + String(repeating: "\u{301}", count: 2500) + " post"
        let matches = try DocumentSearch.matches(in: source, pattern: "a", mode: .plain,
                                                 options: .init(ignoresDiacritics: true))
        let match = try XCTUnwrap(matches.first)
        XCTAssertEqual(match.range, NSRange(location: 4, length: 2501))
        XCTAssertLessThan(match.snippet.utf16.count, 160)
        XCTAssertTrue(match.snippet.utf16.starts(with: "pre a".utf16))
        XCTAssertTrue(match.snippet.hasSuffix(" post"))
    }

    func testWrapIsOptionalInBothDirectionsIncludingZeroWidthMatches() {
        let first = NSRange(location: 3, length: 0)
        let last = NSRange(location: 11, length: 0)
        let ranges = [first, last]
        XCTAssertEqual(DocumentSearch.nextMatch(in: ranges, after: first, wraps: false), last)
        XCTAssertEqual(DocumentSearch.previousMatch(in: ranges, before: last, wraps: false), first)
        XCTAssertNil(DocumentSearch.nextMatch(in: ranges, after: last, wraps: false))
        XCTAssertNil(DocumentSearch.previousMatch(in: ranges, before: first, wraps: false))
        XCTAssertEqual(DocumentSearch.nextMatch(in: ranges, after: last, wraps: true), first)
        XCTAssertEqual(DocumentSearch.previousMatch(in: ranges, before: first, wraps: true), last)
        XCTAssertEqual(DocumentSearch.index(of: last, in: ranges), 1)
        XCTAssertNil(DocumentSearch.index(of: NSRange(location: 3, length: 1), in: ranges))
    }

    func testFindAllInOneHundredThousandLines() throws {
        let source = String(repeating: "通常の本文にｈｉｔがあります。\r\n", count: 99_999) + "最終行にＨＩＴがあります。"
        let matches = try DocumentSearch.matches(in: source, pattern: "hit", mode: .plain,
                                                 options: .init(ignoresWidth: true))
        XCTAssertEqual(matches.count, 100_000)
        XCTAssertEqual(matches.last?.lineNumber, 100_000)
        XCTAssertEqual(matches.last?.snippet, "最終行にＨＩＴがあります。")
    }
}

@MainActor
final class RegexSearchEditorTests: XCTestCase {
    func testReplacementUsesSingleUndoableEditorEdit() throws {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.allowsUndo = true
        view.string = "alpha beta alpha"
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        let model = MarkdownEditorModel()
        model.connect(view)
        let edit = try XCTUnwrap(RegexSearch.replacementEdit(in: view.string, pattern: "alpha",
                                                            template: "A"))

        XCTAssertTrue(model.applyRegexEdit(edit, expectedSource: "alpha beta alpha"))
        XCTAssertEqual(view.string, "A beta A")
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "alpha beta alpha")
        XCTAssertFalse(model.applyRegexEdit(edit, expectedSource: "stale"))
    }
}
