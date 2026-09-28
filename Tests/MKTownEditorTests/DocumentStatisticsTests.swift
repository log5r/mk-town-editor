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
}
