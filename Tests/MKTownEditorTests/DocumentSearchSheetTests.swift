import Foundation
import XCTest
@testable import MKTownEditor

final class DocumentSearchSheetTests: XCTestCase {
    func testSearchHistoryKeepsRecentUniqueValuesAndRoundTrips() throws {
        var history = DocumentSearchHistory()
        for number in 1...25 {
            history.record("語\(number)🌱")
        }
        history.record("語10🌱")
        let restored = try XCTUnwrap(DocumentSearchHistory(rawValue: history.rawValue))

        XCTAssertEqual(restored.entries.count, 20)
        XCTAssertEqual(restored.entries.prefix(2), ["語10🌱", "語25🌱"])
        XCTAssertEqual(restored.entries.filter { $0 == "語10🌱" }.count, 1)
        XCTAssertFalse(restored.entries.contains("語5🌱"))
    }

    func testReplacementHistoryCanStoreDeletionAndLiteralWhitespace() throws {
        var history = DocumentSearchHistory()
        history.record("  ")
        history.record("")
        let restored = try XCTUnwrap(DocumentSearchHistory(rawValue: history.rawValue))

        XCTAssertEqual(restored.entries, ["", "  "])
        XCTAssertTrue(DocumentSearchHistory().entries.isEmpty)
        XCTAssertNil(DocumentSearchHistory(rawValue: "invalid history"))
    }

    func testHistoryKeepsCanonicallyEquivalentRegexPatternsSeparate() throws {
        let composed = "é"
        let decomposed = "e\u{301}"
        var history = DocumentSearchHistory()
        history.record(composed)
        history.record(decomposed)
        let restored = try XCTUnwrap(DocumentSearchHistory(rawValue: history.rawValue))

        XCTAssertEqual(restored.entries.map { Array($0.utf8) }, [Array(decomposed.utf8), Array(composed.utf8)])
    }

    func testPatternStylingUsesOriginalRangesAfterSupplementaryCharacters() {
        let pattern = "😀(語)+"
        let styled = RegexSearchInputStyle.pattern.highlightedRanges(in: pattern)
        XCTAssertEqual(styled.map { (pattern as NSString).substring(with: $0) }, ["(", ")", "+"])
    }

    func testReplacementStylingRecognizesCaptureReferencesButSkipsEscapedDollar() {
        let replacement = #"😀$1 \$2 $12"#
        let styled = RegexSearchInputStyle.replacement.highlightedRanges(in: replacement)
        XCTAssertEqual(styled.map { (replacement as NSString).substring(with: $0) }, ["$1", "$12"])
    }
}
