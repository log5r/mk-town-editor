import Foundation
import XCTest
@testable import MKTownEditor

final class EditorHighlightMatchingTests: XCTestCase {
    func testOnlyAdjacentCursorMovesCrossABracket() {
        let text = "🙂（語）" as NSString
        XCTAssertEqual(EditorHighlightMatching.crossedBracket(in: text, from: 2, to: 3), 2)
        XCTAssertEqual(EditorHighlightMatching.crossedBracket(in: text, from: 3, to: 2), 2)
        XCTAssertEqual(EditorHighlightMatching.crossedBracket(in: text, from: 5, to: 4), 4)
        XCTAssertNil(EditorHighlightMatching.crossedBracket(in: text, from: 0, to: 3))
        XCTAssertNil(EditorHighlightMatching.crossedBracket(in: text, from: 3, to: 4))
        XCTAssertNil(EditorHighlightMatching.crossedBracket(in: text, from: 4, to: 4))
        XCTAssertNil(EditorHighlightMatching.crossedBracket(in: text, from: 5, to: 6))
    }

    func testNestedAndAdjacentBracketsMatchInEitherDirectionUsingUTF16Offsets() {
        let text = "🙂{[（「『語』」）]}【項目】" as NSString
        assertPair("{", "}", in: text)
        assertPair("[", "]", in: text)
        assertPair("（", "）", in: text)
        assertPair("「", "」", in: text)
        assertPair("『", "』", in: text)
        assertPair("【", "】", in: text)
    }

    func testMismatchedUnclosedAndEscapedMarkdownBrackets() {
        let mismatch = "([)] {開いたまま" as NSString
        for bracket in ["(", "[", ")", "]", "{"] {
            XCTAssertNil(EditorHighlightMatching.matchingBracket(
                in: mismatch, at: mismatch.range(of: bracket).location, codeRanges: []))
        }

        let escaped = #"\[literal (real) \] \\[even]"# as NSString
        XCTAssertNil(EditorHighlightMatching.matchingBracket(
            in: escaped, at: escaped.range(of: "[").location, codeRanges: []))
        assertPair("(", ")", in: escaped)
        let open = escaped.range(of: "[", options: .backwards).location
        XCTAssertEqual(EditorHighlightMatching.matchingBracket(in: escaped, at: open, codeRanges: []),
                       escaped.range(of: "]", options: .backwards))
    }

    func testProseCanEncloseCodeButBracketsInSeparateCodeSpansDoNotPair() {
        let text = "{ `[left` `right] （code）` }" as NSString
        let firstCode = text.range(of: "`[left`")
        let secondCode = text.range(of: "`right] （code）`")
        let code = [secondCode, firstCode]
        assertPair("{", "}", in: text, code: code)
        assertPair("（", "）", in: text, code: code)
        for bracket in ["[", "]"] {
            XCTAssertNil(EditorHighlightMatching.matchingBracket(
                in: text, at: text.range(of: bracket).location, codeRanges: code))
        }
    }

    func testFencedCodeAcceptsLiteralBackslashesAndDoesNotUseProseBrackets() {
        let text = "outside (\n~~~\n\\[literal] stray )\n~~~\n" as NSString
        let code = [text.range(of: "~~~\n\\[literal] stray )\n~~~")]
        assertPair("[", "]", in: text, code: code)
        for bracket in ["(", ")"] {
            XCTAssertNil(EditorHighlightMatching.matchingBracket(
                in: text, at: text.range(of: bracket).location, codeRanges: code))
        }
    }

    func testLongBracketScansCanBeCancelledBetweenChunks() {
        let text = ("(" + String(repeating: "x", count: 12_500) + ")") as NSString
        var checks = 0
        XCTAssertNil(EditorHighlightMatching.matchingBracket(in: text, at: 0, codeRanges: []) {
            checks += 1
            return checks == 3
        })
        XCTAssertEqual(checks, 3)
        assertPair("(", ")", in: text)
    }

    func testWordSelectionRejectsPartialWordsWhitespaceAndSymbols() {
        let text = "cat scatter x_cat can't 🙂 42" as NSString
        for partial in ["scatter", "x_cat"] {
            let inside = text.range(of: "cat", range: text.range(of: partial))
            XCTAssertNil(EditorHighlightMatching.selectedWord(in: text, selection: inside))
        }
        for nonword in ["can", " ", "🙂"] {
            XCTAssertNil(EditorHighlightMatching.selectedWord(in: text, selection: text.range(of: nonword)))
        }
        for word in ["cat", "x_cat", "can't", "42"] {
            XCTAssertEqual(EditorHighlightMatching.selectedWord(in: text, selection: text.range(of: word)), word)
        }
    }

    func testOccurrencesUseWholeWordsCanonicalUnicodeAndExactCase() {
        let text = "🙂 café cafe\u{301} cafeteria Café" as NSString
        let expected = [text.range(of: "café", options: .literal),
                        text.range(of: "cafe\u{301}", options: .literal)]
        XCTAssertEqual(EditorHighlightMatching.wordOccurrences(in: text, word: "café",
                        within: NSRange(location: 0, length: text.length)), expected)
        XCTAssertEqual(EditorHighlightMatching.selectedWord(in: text, selection: expected[1]), "cafe\u{301}")
    }

    func testJapaneseWordsCanBeHighlightedWithoutSpaces() {
        let text = "文章を書く。文章を読む。" as NSString
        let first = text.range(of: "文章")
        let last = text.range(of: "文章", options: .backwards)
        XCTAssertEqual(EditorHighlightMatching.selectedWord(in: text, selection: first), "文章")
        XCTAssertEqual(EditorHighlightMatching.wordOccurrences(in: text, word: "文章",
                        within: NSRange(location: 0, length: text.length)), [first, last])
    }

    func testLargeSourceOnlyReturnsWholeTokensOverlappingTheVisibleRange() {
        let prefix = String(repeating: "cat scatter ", count: 20_000)
        let text = (prefix + "cat catapult cat cat") as NSString
        let offset = prefix.utf16.count
        let visible = NSRange(location: offset + 1, length: 13)
        XCTAssertEqual(EditorHighlightMatching.wordOccurrences(in: text, word: "cat", within: visible),
                       [NSRange(location: offset, length: 3), NSRange(location: offset + 13, length: 3)])
    }

    private func assertPair(_ opening: String, _ closing: String, in source: NSString,
                            code: [NSRange] = [], file: StaticString = #filePath, line: UInt = #line) {
        let left = source.range(of: opening)
        let right = source.range(of: closing)
        XCTAssertEqual(EditorHighlightMatching.matchingBracket(in: source, at: left.location, codeRanges: code),
                       right, file: file, line: line)
        XCTAssertEqual(EditorHighlightMatching.matchingBracket(in: source, at: right.location, codeRanges: code),
                       left, file: file, line: line)
    }
}
