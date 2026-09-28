import Foundation
import XCTest
@testable import MKTownEditor

final class PreviewSearchTests: XCTestCase {
    func testUnicodeCaseAndNewlineMatchesUseSourceOffsets() {
        let text = "# 題名\n🙂 Apple\napple\n"
        let matches = PreviewSearch.matches(in: text, query: "apple")
        XCTAssertEqual(matches.map(\.line), [2, 3])
        XCTAssertEqual(matches[0].range.location, ("# 題名\n🙂 " as NSString).length)
        XCTAssertEqual(PreviewSearch.matches(in: text, query: "Apple", caseSensitive: true).count, 1)
        let multiline = PreviewSearch.matches(in: text, query: "Apple\napple")
        XCTAssertEqual(multiline.count, 1)
        XCTAssertEqual(multiline[0].range.length, ("Apple\napple" as NSString).length)
    }

    func testNextAndPreviousWrapWithoutSkippingFirstMatch() {
        let matches = PreviewSearch.matches(in: "one two one", query: "one")
        XCTAssertEqual(PreviewSearch.next(in: matches, after: nil)?.range.location, 0)
        XCTAssertEqual(PreviewSearch.next(in: matches, after: 0)?.range.location, 8)
        XCTAssertEqual(PreviewSearch.next(in: matches, after: 8)?.range.location, 0)
        XCTAssertEqual(PreviewSearch.next(in: matches, after: nil, backwards: true)?.range.location, 8)
        XCTAssertEqual(PreviewSearch.next(in: matches, after: 0, backwards: true)?.range.location, 8)
    }
}
