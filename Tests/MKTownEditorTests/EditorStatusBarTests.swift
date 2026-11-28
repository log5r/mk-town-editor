import XCTest
@testable import MKTownEditor

final class EditorStatusBarTests: XCTestCase {
    func testCharacterCountUsesSelectionWhileSelectionIsActive() {
        var counts = DocumentCharacterCounts(document: 42)
        XCTAssertEqual(counts.displayedCount, 42)

        counts.hasSelection = true
        XCTAssertNil(counts.displayedCount)

        counts.selection = 0
        XCTAssertEqual(counts.displayedCount, 0)

        counts.selection = 7
        XCTAssertEqual(counts.displayedCount, 7)

        counts.hasSelection = false
        XCTAssertEqual(counts.displayedCount, 42)
    }

    func testFormattedCountDistinguishesAnUnavailableCountFromZero() {
        var options = DocumentCountOptions()
        options.unit = .bytes
        let zero = 0
        XCTAssertEqual(options.formattedCount(nil), "—")
        XCTAssertEqual(options.formattedCount(zero), String(localized: "\(zero) バイト"))
    }
}
