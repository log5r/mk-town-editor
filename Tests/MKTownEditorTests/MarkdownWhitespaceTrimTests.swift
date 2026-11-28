import XCTest
@testable import MKTownEditor

final class MarkdownWhitespaceTrimTests: XCTestCase {
    func testKeepsHardBreaksCodeAndFrontMatterWithMixedLineEndings() throws {
        let preserved = "---\r\nyaml: |\r\n  value \r\n---\r\n"
            + "強制改行  \r\n次の行\r\n\r\n"
            + "    indented code \t\r    second \r\r"
            + "> ```swift \n> print(1) \t\n>    \n> ``` \n\n"
            + "~~~txt\ncode \t\n  \t\n~~~ \n"
        let text = preserved + "🙂文 \t\r\n空白 \r\t  \n終わり \t"
        let edit = try XCTUnwrap(MarkdownWhitespaceTrim.edit(in: text,
            selection: NSRange(location: 0, length: 0),
            includingWhitespaceOnlyLines: false, dialect: .extended))
        XCTAssertEqual(edit.applying(to: text), preserved + "🙂文\r\n空白\r\t  \n終わり")
        XCTAssertEqual(edit.selection, NSRange(location: 0, length: 0))
    }

    func testWhitespaceOnlyLinesAreTrimmedOnlyWhenEnabled() throws {
        let text = "one \r\n\t  \r\n\nlast \n  "
        let selection = NSRange(location: (text as NSString).length, length: 0)
        let edit = try XCTUnwrap(MarkdownWhitespaceTrim.edit(in: text, selection: selection,
            includingWhitespaceOnlyLines: true, dialect: .basic))
        let result = "one\r\n\r\n\nlast\n"
        XCTAssertEqual(edit.applying(to: text), result)
        XCTAssertEqual(edit.selection, NSRange(location: (result as NSString).length, length: 0))
    }

    func testCommandOnlyRemovesWhitespaceInTheSelectedRangeAndMapsUTF16Selection() throws {
        let text = "外 \t\n🙂対象 \t\r終端 \t"
        let selection = (text as NSString).range(of: "🙂対象 \t\r終端 ")
        let edit = try XCTUnwrap(MarkdownWhitespaceTrim.edit(in: text, selection: selection,
            includingWhitespaceOnlyLines: false, dialect: .basic))
        let expected = "外 \t\n🙂対象\r終端\t"
        XCTAssertEqual(edit.applying(to: text), expected)
        XCTAssertEqual(edit.selection, (expected as NSString).range(of: "🙂対象\r終端"))
        XCTAssertNil(MarkdownWhitespaceTrim.edit(in: text, selection: (text as NSString).range(of: "対象"),
            includingWhitespaceOnlyLines: false, dialect: .basic))
    }

    func testTrimmingCannotIntroduceHardBreaks() throws {
        let text = "odd\\ \ncontinuation\n\neven\\\\ \ncontinuation\n\nspaces  \t\ncontinuation"
        let edit = try XCTUnwrap(MarkdownWhitespaceTrim.edit(in: text, selection: NSRange(location: 0, length: 0),
            includingWhitespaceOnlyLines: false, dialect: .extended))
        XCTAssertEqual(edit.applying(to: text),
                       "odd\\ \ncontinuation\n\neven\\\\\ncontinuation\n\nspaces\ncontinuation")

        let tabOnly = (text as NSString).range(of: "\t")
        XCTAssertNil(MarkdownWhitespaceTrim.edit(in: text, selection: tabOnly,
            includingWhitespaceOnlyLines: false, dialect: .extended))
    }

    func testUnterminatedFenceRemainsProtected() {
        let text = "```swift\nprint(1) \t\n  \t"
        XCTAssertNil(MarkdownWhitespaceTrim.edit(in: text, includingWhitespaceOnlyLines: true, dialect: .basic))
    }

    func testTrimKeepsEmptyListMarkerSeparatorsAndMultilineInlineCode() throws {
        let preserved = "- \n1. \n\n> * \n\n`inline \ncode`\n"
        let text = preserved + "other \n"
        let edit = try XCTUnwrap(MarkdownWhitespaceTrim.edit(in: text,
            selection: NSRange(location: 0, length: 0),
            includingWhitespaceOnlyLines: true, dialect: .extended))
        XCTAssertEqual(edit.applying(to: text), preserved + "other\n")
    }

    func testTrimKeepsFootnoteCodeAndBlankContinuationLines() throws {
        let text = "本文[^note] \n\n[^note]: `one \n    two` \n    \n    continuation \n\n"
            + "[^unused]: `unreferenced \n\tcode` \n\nother \n"
        let edit = try XCTUnwrap(MarkdownWhitespaceTrim.edit(in: text,
            includingWhitespaceOnlyLines: true, dialect: .extended))
        let updated = edit.applying(to: text)

        XCTAssertEqual(updated, "本文[^note]\n\n[^note]: `one \n    two`\n    \n    continuation\n\n"
            + "[^unused]: `unreferenced \n\tcode`\n\nother\n")
        XCTAssertEqual(MarkdownAnalysis(updated).footnotes.entry(for: "note")?.content,
                       "`one \ntwo`\n\ncontinuation")
    }
}
