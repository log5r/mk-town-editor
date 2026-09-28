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
