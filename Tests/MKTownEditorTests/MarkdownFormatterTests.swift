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
}
