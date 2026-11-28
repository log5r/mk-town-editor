import XCTest
@testable import MKTownEditor

final class EditorTextTransformationTests: XCTestCase {
    func testCaseConversionHandlesExpansionAndKeepsOtherWordLetters() {
        assertTransform(.uppercase, "Straße と 👩‍💻", to: "STRASSE と 👩‍💻")
        assertTransform(.lowercase, "ÉCOLE test", to: "école test")
        assertTransform(.capitalized, "éCOLE and iPhone", to: "ÉCOLE And IPhone")
        assertTransform(.capitalized, "aか\u{301}", to: "Aか\u{301}")
    }

    func testWidthCategoriesCanBeConvertedIndependently() {
        let fullwidth = "Ａｂ１！　「ガ・パ」😀"
        assertTransform(.fullwidthToHalfwidth, fullwidth, to: "Ab1！　「ガ・パ」😀", widthCharacters: [.alphanumeric])
        assertTransform(.fullwidthToHalfwidth, fullwidth, to: "Ａｂ１! ｢ガ･パ｣😀", widthCharacters: [.symbols])
        assertTransform(.fullwidthToHalfwidth, fullwidth, to: "Ａｂ１！　「ｶﾞ・ﾊﾟ」😀", widthCharacters: [.kana])
        assertTransform(.halfwidthToFullwidth, "Ab1! ｢ｶﾞ･ﾊﾟ｣😀", to: fullwidth)
    }

    func testWidthConversionComposesKanaVoicingWithoutNormalizingOtherCharacters() {
        assertTransform(.halfwidthToFullwidth, "ｳﾞﾊﾟｶﾞ A\u{301} 1️⃣ 👩‍💻", to: "ヴパガ　Ａ\u{301}　1️⃣　👩‍💻")
        assertTransform(.fullwidthToHalfwidth, "カ\u{3099}パゔ ① Ａ\u{301} 👩‍💻", to: "ｶﾞﾊﾟゔ ① A\u{301} 👩‍💻")
        assertTransform(.halfwidthToFullwidth, "ｶﾞ Aﾞ", to: "ガ　Ａﾞ")
    }

    func testKanaConversionKeepsOtherScriptsAndEmoji() {
        assertTransform(.hiraganaToKatakana, "ひらがな ゔゕゖ か\u{3099} ｶﾅ ABC👩‍💻",
                        to: "ヒラガナ ヴヵヶ ガ ｶﾅ ABC👩‍💻")
        assertTransform(.katakanaToHiragana, "カタカナ ヴヵヶ ｶﾞﾊﾟ ABC👩‍💻",
                        to: "かたかな ゔゕゖ がぱ ABC👩‍💻")
    }

    func testNormalizationChangesCanonicalCodeUnitsAndKeepsJoinedEmoji() {
        assertTransform(.nfc, "か\u{3099}e\u{301}①👩‍💻", to: "がé①👩‍💻")
        assertTransform(.nfd, "がé①👩‍💻", to: "か\u{3099}e\u{301}①👩‍💻")
        assertTransform(.nfkc, "ｶﾞ①Ａfé👩‍💻", to: "ガ1Afé👩‍💻")
        assertTransform(.nfkd, "ｶﾞ①Ａfé👩‍💻", to: "カ\u{3099}1Afe\u{301}👩‍💻")
    }

    func testMarkdownProtectionUsesTheOriginalDocumentForAPartialSelection() throws {
        let source = """
            ~~~swift
            let first = "hello"
            ~~~
            prose `inline code` [guide](../ReadMe.md) HTTPS://example.com/Part(One)

            [ref]: ../Other.md

            more prose
            """
        let start = try XCTUnwrap(source.range(of: "first")).lowerBound
        let end = try XCTUnwrap(source.range(of: "more prose")).lowerBound
        let range = NSRange(start..<end, in: source)
        XCTAssertEqual(EditorTextTransformation.uppercase.replacement(in: source, range: range), """
            first = "hello"
            ~~~
            PROSE `inline code` [GUIDE](../ReadMe.md) HTTPS://example.com/Part(One)

            [ref]: ../Other.md


            """)
        let codeOnly = (source as NSString).range(of: "inline code")
        XCTAssertNil(EditorTextTransformation.uppercase.replacement(in: source, range: codeOnly))
        XCTAssertEqual(EditorTextTransformation.uppercase.replacement(in: source, range: codeOnly,
                                                                      protectsMarkdown: false), "INLINE CODE")
    }

    func testProtectedMarkdownLinksStayValidWhenWideningSymbols() {
        let source = "[hello](../Docs/readme.md) <custom:abc>"
        let range = NSRange(location: 0, length: source.utf16.count)
        XCTAssertEqual(EditorTextTransformation.halfwidthToFullwidth.replacement(in: source, range: range),
                       "[ｈｅｌｌｏ](../Docs/readme.md)　<custom:abc>")
    }

    func testInlineCodeDoesNotPairWithAnUnmatchedBacktickInAFencedBlock() {
        let source = "~~~\nlet x = `\n~~~\n\nprose `inline` more"
        let range = NSRange(location: 0, length: source.utf16.count)
        XCTAssertEqual(EditorTextTransformation.uppercase.replacement(in: source, range: range),
                       "~~~\nlet x = `\n~~~\n\nPROSE `inline` MORE")
    }

    func testInlineCodeDoesNotPairWithAnUnmatchedBacktickInAnotherTableCell() {
        let source = "| marker | value |\n| --- | --- |\n| stray ` | keep `inline` |"
        let range = NSRange(location: 0, length: source.utf16.count)
        XCTAssertEqual(EditorTextTransformation.uppercase.replacement(in: source, range: range),
                       "| MARKER | VALUE |\n| --- | --- |\n| STRAY ` | KEEP `inline` |")
    }

    func testNestedImageDestinationsAndReferenceKeysStayIntact() {
        let source = """
            [![alt](Photo.PNG)](../View.md)

            [read][id] [id][] [id]

            [id]: ../Docs/ReadMe.md
            """
        let range = NSRange(location: 0, length: source.utf16.count)
        XCTAssertEqual(EditorTextTransformation.halfwidthToFullwidth.replacement(in: source, range: range), """
            [![ａｌｔ](Photo.PNG)](../View.md)

            [ｒｅａｄ][id]　[id][]　[id]

            [id]: ../Docs/ReadMe.md
            """)
    }

    func testEmptyInvalidAndUnchangedSelectionsProduceNoReplacement() {
        let source = "👩‍💻 unchanged"
        let conversion = EditorTextTransformation.lowercase
        for range in [NSRange(location: 0, length: 0), NSRange(location: 0, length: source.utf16.count),
                      NSRange(location: 1, length: 1), NSRange(location: NSNotFound, length: 1),
                      NSRange(location: 1, length: Int.max)] {
            XCTAssertNil(conversion.replacement(in: source, range: range))
        }
        let fullwidth = "Ａ１ガ！"
        XCTAssertNil(EditorTextTransformation.fullwidthToHalfwidth.replacement(
            in: fullwidth, range: NSRange(location: 0, length: fullwidth.utf16.count), widthCharacters: []))
    }

    private func assertTransform(_ transformation: EditorTextTransformation, _ input: String, to expected: String,
                                 widthCharacters: EditorTextTransformation.WidthCharacters = .all,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let result = transformation.replacement(in: input, range: NSRange(location: 0, length: input.utf16.count),
                                                widthCharacters: widthCharacters, protectsMarkdown: false)
        XCTAssertEqual(result.map { Array($0.utf16) }, Array(expected.utf16), file: file, line: line)
    }
}
