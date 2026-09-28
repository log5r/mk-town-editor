import XCTest
@testable import MKTownEditor

final class MarkdownFormatterTests: XCTestCase {
    func testBoldWrapsSelectedTextAndKeepsContentSelected() {
        let result = MarkdownFormatter.apply(.bold, to: "hello world", selection: NSRange(location: 6, length: 5))

        XCTAssertEqual(result.applying(to: "hello world"), "hello **world**")
        XCTAssertEqual(result.selection, NSRange(location: 8, length: 5))
    }

    func testBoldInsertsPlaceholderAtInsertionPoint() {
        let result = MarkdownFormatter.apply(.bold, to: "hello ", selection: NSRange(location: 6, length: 0))

        let updated = result.applying(to: "hello ")
        XCTAssertEqual(updated, "hello **太字**")
        XCTAssertEqual((updated as NSString).substring(with: result.selection), "太字")
    }

    func testLinkSelectsURLForImmediateReplacement() {
        let result = MarkdownFormatter.apply(.link, to: "Apple", selection: NSRange(location: 0, length: 5))

        let updated = result.applying(to: "Apple")
        XCTAssertEqual(updated, "[Apple](https://)")
        XCTAssertEqual((updated as NSString).substring(with: result.selection), "https://")
    }

    func testListPrefixesEverySelectedLine() {
        let source = "one\ntwo\nthree"
        let result = MarkdownFormatter.apply(.unorderedList, to: source, selection: NSRange(location: 0, length: 7))

        XCTAssertEqual(result.applying(to: source), "- one\n- two\nthree")
    }

    func testOutOfBoundsSelectionIsClamped() {
        let result = MarkdownFormatter.apply(.italic, to: "abc", selection: NSRange(location: 99, length: 10))

        XCTAssertEqual(result.applying(to: "abc"), "abc_斜体_")
    }

    func testUTF16SelectionMatchesNSTextViewForJapaneseText() {
        let source = "絵文字🙂と日本語"
        let range = (source as NSString).range(of: "🙂と")
        let result = MarkdownFormatter.apply(.inlineCode, to: source, selection: range)

        let updated = result.applying(to: source)
        XCTAssertEqual(updated, "絵文字`🙂と`日本語")
        XCTAssertEqual((updated as NSString).substring(with: result.selection), "🙂と")
    }

    func testEditChangesOnlySelectedUTF16Range() {
        let source = "前🙂後"
        let selection = (source as NSString).range(of: "🙂")
        let edit = MarkdownFormatter.apply(.bold, to: source, selection: selection)

        XCTAssertEqual(edit.range, selection)
        XCTAssertEqual(edit.replacement, "**🙂**")
        XCTAssertEqual(edit.applying(to: source), "前**🙂**後")
    }

    func testLineEditChangesOnlyAffectedLines() {
        let source = "one\ntwo\nthree"
        let edit = MarkdownFormatter.apply(.quote, to: source, selection: NSRange(location: 5, length: 0))

        XCTAssertEqual(edit.range, NSRange(location: 4, length: 4))
        XCTAssertEqual(edit.replacement, "> two\n")
        XCTAssertEqual(edit.applying(to: source), "one\n> two\nthree")
    }

    func testHeadingLevelReplacesExistingMarkerAndClosingHashes() {
        let source = "  ## 見出し 🙂 ##\n本文"
        let edit = MarkdownFormatter.apply(.heading(level: 4), to: source, selection: NSRange(location: 6, length: 0))

        XCTAssertEqual(edit.applying(to: source), "  #### 見出し 🙂\n本文")
        XCTAssertEqual(edit.range.location, 0)
    }

    func testHeadingCanBecomeBodyWithoutChangingOtherLines() {
        let source = "前\n### 見出し\r\n後"
        let selection = (source as NSString).range(of: "見出し")
        let edit = MarkdownFormatter.apply(.heading(level: 0), to: source, selection: selection)

        XCTAssertEqual(edit.applying(to: source), "前\n見出し\r\n後")
        XCTAssertEqual(edit.replacement, "見出し\r\n")
    }

    func testHeadingChangesEachSelectedLine() {
        let source = "# 一\n## 二\n三"
        let edit = MarkdownFormatter.apply(.heading(level: 2), to: source, selection: NSRange(location: 0, length: 8))

        XCTAssertEqual(edit.applying(to: source), "## 一\n## 二\n三")
    }

    func testHeadingOnEmptyDocumentPlacesInsertionAfterMarker() {
        let edit = MarkdownFormatter.apply(.heading(level: 3), to: "", selection: NSRange(location: 0, length: 0))

        XCTAssertEqual(edit.applying(to: ""), "### ")
        XCTAssertEqual(edit.selection, NSRange(location: 4, length: 0))
    }

    func testBoldToggleRemovesSurroundingMarkersForInnerAndWholeSelection() {
        let source = "前**強調🙂**後"
        for range in [(source as NSString).range(of: "強調🙂"),
                      (source as NSString).range(of: "**強調🙂**")] {
            let edit = MarkdownFormatter.apply(.bold, to: source, selection: range)
            let updated = edit.applying(to: source)

            XCTAssertEqual(updated, "前強調🙂後")
            XCTAssertEqual((updated as NSString).substring(with: edit.selection), "強調🙂")
        }
    }

    func testEmptySelectionInsideFormattedTextRemovesFormattingAndKeepsCaret() {
        let source = "**hello**"
        let edit = MarkdownFormatter.apply(.bold, to: source,
                                           selection: NSRange(location: 4, length: 0))

        XCTAssertEqual(edit.applying(to: source), "hello")
        XCTAssertEqual(edit.selection, NSRange(location: 2, length: 0))
    }

    func testMixedSelectionBecomesUniformlyFormatted() {
        let source = "**one** and two"
        let edit = MarkdownFormatter.apply(.bold, to: source,
                                           selection: NSRange(location: 0, length: (source as NSString).length))

        XCTAssertEqual(edit.applying(to: source), "**one and two**")
        XCTAssertEqual(edit.selection, NSRange(location: 2, length: 11))
    }

    func testFullyFormattedMixedSpansAreUnwrappedTogether() {
        let source = "**one** **two**"
        let edit = MarkdownFormatter.apply(.bold, to: source,
                                           selection: NSRange(location: 0, length: (source as NSString).length))

        XCTAssertEqual(edit.applying(to: source), "one two")
    }

    func testItalicAndCodeToggleLeaveOtherFormattingInPlace() {
        let italic = MarkdownFormatter.apply(.italic, to: "_word_",
                                              selection: NSRange(location: 1, length: 4))
        let code = MarkdownFormatter.apply(.inlineCode, to: "**`word`**",
                                            selection: NSRange(location: 3, length: 4))

        XCTAssertEqual(italic.applying(to: "_word_"), "word")
        XCTAssertEqual(code.applying(to: "**`word`**"), "**word**")
    }

    func testEscapedMarkersAreNotRemoved() {
        let source = "\\**literal**"
        let edit = MarkdownFormatter.apply(.bold, to: source,
                                           selection: (source as NSString).range(of: "literal"))

        XCTAssertEqual(edit.applying(to: source), "\\****literal****")
    }

    func testLiteralBoldMarkersInsideCodeAreNotToggledAway() {
        let source = "`**literal**`"
        let edit = MarkdownFormatter.apply(.bold, to: source,
                                           selection: (source as NSString).range(of: "literal"))

        XCTAssertEqual(edit.applying(to: source), "`****literal****`")
    }

    func testCaretImmediatelyOutsideFormattingDoesNotRemoveIt() {
        let source = "**word**"
        let edit = MarkdownFormatter.apply(.bold, to: source,
                                           selection: NSRange(location: 0, length: 0))

        XCTAssertEqual(edit.applying(to: source), "**太字****word**")
    }

    func testAlternativeMarkersAndLongCodeDelimiterCanBeToggled() {
        for (style, source, word) in [
            (MarkdownFormattingStyle.bold, "__strong__", "strong"),
            (.italic, "*emphasis*", "emphasis"),
            (.inlineCode, "``a`b``", "a`b")
        ] {
            let edit = MarkdownFormatter.apply(style, to: source,
                                               selection: (source as NSString).range(of: word))
            XCTAssertEqual(edit.applying(to: source), word)
        }
    }

    func testToggleHandlesNestedAlternativeMarkersAndCodeChild() {
        let nested = "**outer __inner__**"
        let whole = MarkdownFormatter.apply(.bold, to: nested,
                                            selection: NSRange(location: 0, length: (nested as NSString).length))
        XCTAssertEqual(whole.applying(to: nested), "outer inner")

        let inner = MarkdownFormatter.apply(.bold, to: nested,
                                            selection: (nested as NSString).range(of: "inner"))
        XCTAssertEqual(inner.applying(to: nested), "**outer inner**")

        let withCode = "**one `two` three**"
        let codeChild = MarkdownFormatter.apply(.bold, to: withCode,
                                                selection: (withCode as NSString).range(of: "one `two` three"))
        XCTAssertEqual(codeChild.applying(to: withCode), "one `two` three")
    }

    func testPartialSelectionExpandsAcrossExistingFormatting() {
        let source = "**one** and two"
        let edit = MarkdownFormatter.apply(.bold, to: source,
                                           selection: (source as NSString).range(of: "one** and"))
        XCTAssertEqual(edit.applying(to: source), "**one and** two")
    }
}
