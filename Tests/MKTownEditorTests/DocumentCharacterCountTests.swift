import Foundation
import XCTest
@testable import MKTownEditor

final class DocumentCharacterCountTests: XCTestCase {
    func testGraphemeScalarCodeUnitAndByteCounts() {
        let text = "👩‍💻e\u{301}\r\n　"
        XCTAssertEqual(DocumentCountOptions().count(in: text), 4)
        XCTAssertEqual(DocumentCountOptions(unit: .unicodeScalar).count(in: text), 8)
        XCTAssertEqual(DocumentCountOptions(unit: .utf16).count(in: text), 10)
        XCTAssertEqual(DocumentCountOptions(unit: .bytes).count(in: text), 19)
        XCTAssertEqual(DocumentCountOptions(unit: .bytes, encoding: .utf16LE).count(in: text), 20)
        XCTAssertEqual(DocumentCountOptions(unit: .bytes, encoding: .utf16BE).count(in: text), 20)
        XCTAssertEqual(DocumentCountOptions(unit: .bytes, encoding: .shiftJIS).count(in: "あA"), 3)
        XCTAssertNil(DocumentCountOptions(unit: .bytes, encoding: .shiftJIS).count(in: text))
        XCTAssertEqual(DocumentCountOptions(unit: .bytes, encoding: .iso2022JP).count(in: ""), 0)
    }

    func testHorizontalWhitespaceAndNewlinesAreIndependent() {
        let text = "A　 \t\r\n　 B"
        XCTAssertEqual(DocumentCountOptions(unit: .utf16, excludeWhitespace: true).count(in: text), 4)
        XCTAssertEqual(DocumentCountOptions(unit: .utf16, excludeNewlines: true).count(in: text), 7)
        XCTAssertEqual(DocumentCountOptions(unit: .bytes, collapseWhitespace: true).count(in: text), 6)
        XCTAssertEqual(DocumentCountOptions(excludeNewlines: true, collapseWhitespace: true).count(in: text), 3)
    }

    func testNormalizationRunsBeforeMeasurement() {
        XCTAssertEqual(DocumentCountOptions(unit: .unicodeScalar, normalization: .nfc)
            .count(in: "e\u{301}"), 1)
        XCTAssertEqual(DocumentCountOptions(unit: .unicodeScalar, normalization: .nfd)
            .count(in: "é"), 2)
        XCTAssertEqual(DocumentCountOptions(unit: .bytes, encoding: .latin1, normalization: .nfc)
            .count(in: "e\u{301}"), 1)
        XCTAssertEqual(DocumentCountOptions(normalization: .nfkc).count(in: "㍍ｶﾞ"), 5)
        XCTAssertEqual(DocumentCountOptions(unit: .unicodeScalar, normalization: .nfkd).count(in: "㍍ｶﾞ"), 6)
    }

    func testMarkdownExclusionsAreIndependent() {
        let source = "# **Hello** [world](https://example.test)\n"
        XCTAssertEqual(DocumentCountOptions(excludeMarkdownSyntax: true).count(in: source),
                       " Hello worldhttps://example.test\n".count)
        XCTAssertEqual(DocumentCountOptions(excludeLinkDestinations: true).count(in: source),
                       "# **Hello** [world]()\n".count)
        XCTAssertEqual(DocumentCountOptions(excludeMarkdownSyntax: true, excludeLinkDestinations: true)
            .count(in: source), " Hello world\n".count)
        let links = "[![image](pic.png)](https://example.test) [label][id]\n\n[id]: <somewhere>\n"
        XCTAssertEqual(DocumentCountOptions(excludeMarkdownSyntax: true, excludeLinkDestinations: true)
            .count(in: links), "image label\n\n\n".count)
        XCTAssertEqual(DocumentCountOptions(excludeLinkDestinations: true)
            .count(in: "<https://example.test> and `[x](link)`"), "<> and `[x](link)`".count)
    }

    func testCodeAndFrontMatterCanBeExcludedSeparately() {
        let frontMatter = "---\r\ntitle: Book\r\n---\r\n"
        let code = "```swift\r\nlet n = 1\r\n```\r\n"
        let body = "Read `a*b`."
        let source = frontMatter + code + body
        XCTAssertEqual(DocumentCountOptions(excludeCodeBlocks: true).count(in: source),
                       (frontMatter + body).count)
        XCTAssertEqual(DocumentCountOptions(excludeFrontMatter: true).count(in: source), (code + body).count)
        XCTAssertEqual(DocumentCountOptions(excludeMarkdownSyntax: true, excludeCodeBlocks: true,
                                            excludeFrontMatter: true).count(in: source), "Read a*b.".count)
        XCTAssertEqual(DocumentCountOptions(excludeMarkdownSyntax: true).count(in: source),
                       (frontMatter + "\r\nlet n = 1\r\n\r\nRead a*b.").count)
    }

    func testMarkdownFilteringPreservesLiteralPunctuationAndWhitespace() {
        let options = DocumentCountOptions(excludeMarkdownSyntax: true)
        XCTAssertEqual(options.count(in: "***nested*** _foo_bar_ ** unformatted **"),
                       "nested foo_bar ** unformatted **".count)
        XCTAssertEqual(options.count(in: "**a\r\nb** and `*literal*`"), "a\r\nb and *literal*".count)
        XCTAssertEqual(options.count(in: "**!*** ⛄️"), "!* ⛄️".count)
        XCTAssertEqual(options.count(in: "**[link](https://example.test/a_b_c)**"),
                       "linkhttps://example.test/a_b_c".count)
        XCTAssertEqual(options.count(in: "<mark>here</mark>"), "here".count)
        XCTAssertEqual(options.count(in: #"\*literal\* and `\*code\*`"#),
                       #"*literal* and \*code\*"#.count)
    }

    func testSelectionUsesWholeDocumentSyntaxAndCountsEachSelectionSeparately() {
        let text = "**hello** link: [here](https://example.test) e\u{301}"
        let source = text as NSString
        let selections = [source.range(of: "**he"), source.range(of: "https://example.test")]
        XCTAssertEqual(DocumentCountOptions(excludeMarkdownSyntax: true, excludeLinkDestinations: true)
            .count(in: text, ranges: selections), 2)
        let separated = [NSRange(location: 0, length: 1), NSRange(location: 2, length: 1)]
        XCTAssertEqual(DocumentCountOptions(collapseWhitespace: true).count(in: " A　", ranges: separated), 2)
        XCTAssertEqual(DocumentCountOptions().count(in: "🤍", ranges: [NSRange(location: 0, length: 1)]), 0)
    }

    func testPartialOptionsPreserveValidFieldsWhenOthersAreUnknown() throws {
        let data = Data(#"{"normalization":"future","unit":"bytes","excludeCodeBlocks":true}"#.utf8)
        let decoded = try JSONDecoder().decode(DocumentCountOptions.self, from: data)
        XCTAssertEqual(decoded, DocumentCountOptions(unit: .bytes, excludeCodeBlocks: true))
        XCTAssertEqual(try JSONDecoder().decode(DocumentCountOptions.self,
            from: JSONEncoder().encode(decoded)), decoded)
    }
}
