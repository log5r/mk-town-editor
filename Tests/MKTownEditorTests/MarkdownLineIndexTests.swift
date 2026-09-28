import Foundation
import XCTest
@testable import MKTownEditor

final class MarkdownLineIndexTests: XCTestCase {
    func testLineStartsHandleUnicodeCRLFCRAndTrailingBlankLine() {
        let text = "🙂日本語\r\nsecond\rthird\n"
        let index = MarkdownLineIndex(text)
        let source = text as NSString

        XCTAssertEqual(index.lineCount, 4)
        XCTAssertEqual(index.destination(for: 1).utf16Location, 0)
        XCTAssertEqual(index.destination(for: 2).utf16Location, source.range(of: "second").location)
        XCTAssertEqual(index.destination(for: 3).utf16Location, source.range(of: "third").location)
        XCTAssertEqual(index.destination(for: 4).utf16Location, source.length)
        XCTAssertEqual(index.line(containingUTF16Offset: source.range(of: "third").location + 2), 3)
    }

    func testOutOfRangeLineNumbersClampWithoutSplittingUnicode() {
        let index = MarkdownLineIndex("a\n🙂")
        XCTAssertEqual(index.destination(for: 0), MarkdownLineDestination(requestedLine: 0,
                                                                           resolvedLine: 1, utf16Location: 0))
        XCTAssertEqual(index.destination(for: 99), MarkdownLineDestination(requestedLine: 99,
                                                                            resolvedLine: 2, utf16Location: 2))
        XCTAssertTrue(index.destination(for: 99).wasClamped)
        XCTAssertEqual(MarkdownLineIndex("").destination(for: 8).utf16Location, 0)
    }
}
