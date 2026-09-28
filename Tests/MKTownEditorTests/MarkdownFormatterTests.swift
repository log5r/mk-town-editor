import XCTest
@testable import MKTownEditor

final class MarkdownFormatterTests: XCTestCase {
    func testBoldWrapsSelectedTextAndKeepsContentSelected() {
        let result = MarkdownFormatter.apply(.bold, to: "hello world", selection: NSRange(location: 6, length: 5))

        XCTAssertEqual(result.text, "hello **world**")
        XCTAssertEqual(result.selection, NSRange(location: 8, length: 5))
    }

    func testBoldInsertsPlaceholderAtInsertionPoint() {
        let result = MarkdownFormatter.apply(.bold, to: "hello ", selection: NSRange(location: 6, length: 0))

        XCTAssertEqual(result.text, "hello **太字**")
        XCTAssertEqual((result.text as NSString).substring(with: result.selection), "太字")
    }

    func testLinkSelectsURLForImmediateReplacement() {
        let result = MarkdownFormatter.apply(.link, to: "Apple", selection: NSRange(location: 0, length: 5))

        XCTAssertEqual(result.text, "[Apple](https://)")
        XCTAssertEqual((result.text as NSString).substring(with: result.selection), "https://")
    }

    func testListPrefixesEverySelectedLine() {
        let source = "one\ntwo\nthree"
        let result = MarkdownFormatter.apply(.unorderedList, to: source, selection: NSRange(location: 0, length: 7))

        XCTAssertEqual(result.text, "- one\n- two\nthree")
    }

    func testOutOfBoundsSelectionIsClamped() {
        let result = MarkdownFormatter.apply(.italic, to: "abc", selection: NSRange(location: 99, length: 10))

        XCTAssertEqual(result.text, "abc_斜体_")
    }

    func testUTF16SelectionMatchesNSTextViewForJapaneseText() {
        let source = "絵文字🙂と日本語"
        let range = (source as NSString).range(of: "🙂と")
        let result = MarkdownFormatter.apply(.inlineCode, to: source, selection: range)

        XCTAssertEqual(result.text, "絵文字`🙂と`日本語")
        XCTAssertEqual((result.text as NSString).substring(with: result.selection), "🙂と")
    }
}
