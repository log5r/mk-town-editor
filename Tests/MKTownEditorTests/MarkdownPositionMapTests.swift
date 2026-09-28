import Foundation
import XCTest
@testable import MKTownEditor

final class MarkdownPositionMapTests: XCTestCase {
    func testUnicodeAndCRLFRoundTrip() {
        let source = "A🙂e\u{301}日本語\r\n次の行\n"
        let map = MarkdownPositionMap(source)
        let offsets = [0, 1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]

        for offset in offsets where offset <= (source as NSString).length {
            guard let position = map.position(forUTF16Offset: offset) else { continue }
            XCTAssertEqual(map.utf16Offset(for: position), offset)
        }
        XCTAssertNil(map.position(forUTF16Offset: 2), "A surrogate pair cannot be split")
        XCTAssertEqual(map.position(forUTF16Offset: 3), MarkdownSourcePosition(line: 1, utf8Column: 6))
        XCTAssertEqual(map.position(forUTF16Offset: 5), MarkdownSourcePosition(line: 1, utf8Column: 9))
        let secondLine = (source as NSString).range(of: "次")
        XCTAssertEqual(map.position(forUTF16Offset: secondLine.location), MarkdownSourcePosition(line: 2, utf8Column: 1))
        XCTAssertEqual(map.position(forUTF16Offset: (source as NSString).length), MarkdownSourcePosition(line: 3, utf8Column: 1))
    }

    func testRangeRoundTripAndInvalidBoundaries() {
        let source = "🙂\r\n日本語"
        let map = MarkdownPositionMap(source)
        let range = (source as NSString).range(of: "日本")
        let positions = try! XCTUnwrap(map.positions(for: range))

        XCTAssertEqual(positions.start, MarkdownSourcePosition(line: 2, utf8Column: 1))
        XCTAssertEqual(positions.end, MarkdownSourcePosition(line: 2, utf8Column: 7))
        XCTAssertEqual(map.utf16Range(from: positions.start, to: positions.end), range)
        XCTAssertNil(map.positions(for: NSRange(location: 1, length: 1)))
        XCTAssertNil(map.positions(for: NSRange(location: NSNotFound, length: 1)))
        XCTAssertNil(map.utf16Range(from: positions.end, to: positions.start))
    }

    func testEmptyDocumentAndStandaloneCarriageReturn() {
        let empty = MarkdownPositionMap("")
        XCTAssertEqual(empty.position(forUTF16Offset: 0), MarkdownSourcePosition(line: 1, utf8Column: 1))

        let map = MarkdownPositionMap("a\rb")
        XCTAssertEqual(map.position(forUTF16Offset: 2), MarkdownSourcePosition(line: 2, utf8Column: 1))
        XCTAssertNil(map.utf16Offset(for: MarkdownSourcePosition(line: 4, utf8Column: 1)))
    }
}
