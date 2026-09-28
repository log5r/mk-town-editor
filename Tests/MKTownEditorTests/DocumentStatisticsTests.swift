import XCTest
@testable import MKTownEditor

final class DocumentStatisticsTests: XCTestCase {
    func testCountsCharactersWordsAndLines() {
        let statistics = DocumentStatistics(text: "Hello Markdown\nこんにちは 世界")

        XCTAssertEqual(statistics.characters, 23)
        XCTAssertEqual(statistics.words, 4)
        XCTAssertEqual(statistics.lines, 2)
    }

    func testEmptyDocumentHasNoLines() {
        let statistics = DocumentStatistics(text: "")

        XCTAssertEqual(statistics.characters, 0)
        XCTAssertEqual(statistics.words, 0)
        XCTAssertEqual(statistics.lines, 0)
    }

    func testWhitespaceAndUTF16SelectionCountsGraphemeCharacters() {
        let text = "A🙂 \nB"
        let total = DocumentStatistics(text: text)
        XCTAssertEqual(total.characters, 5)
        XCTAssertEqual(total.nonWhitespaceCharacters, 3)
        let emoji = DocumentStatistics.selection(in: text, range: NSRange(location: 1, length: 2))
        XCTAssertEqual(emoji?.characters, 1)
        XCTAssertEqual(emoji?.nonWhitespaceCharacters, 1)
        XCTAssertNil(DocumentStatistics.selection(in: text,
                                                  range: NSRange(location: NSNotFound, length: 1)))
        XCTAssertNil(DocumentStatistics.selection(in: text, range: NSRange(location: 0, length: 0)))
    }

    func testCurrentSectionEndsAtNextHeadingOfSameOrHigherLevel() throws {
        let text = "# One\nalpha\n## Inner\nbeta\n# Two\ngamma"
        let analysis = MarkdownAnalysis(text)
        let source = text as NSString
        let first = try XCTUnwrap(DocumentStatistics.sectionRange(
            at: source.range(of: "alpha").location, in: analysis, documentLength: source.length))
        XCTAssertEqual(source.substring(with: first), "# One\nalpha\n## Inner\nbeta\n")
        let nested = try XCTUnwrap(DocumentStatistics.sectionRange(
            at: source.range(of: "beta").location, in: analysis, documentLength: source.length))
        XCTAssertEqual(source.substring(with: nested), "## Inner\nbeta\n")
    }
}
