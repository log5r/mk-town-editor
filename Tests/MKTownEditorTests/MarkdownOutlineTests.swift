import Foundation
import XCTest
@testable import MKTownEditor

final class MarkdownOutlineTests: XCTestCase {
    func testEntriesKeepHeadingOrderLevelAndUTF16SourceLocations() {
        let source = "# 最初🙂\n\n段落\n\n### 子\n\n# 最初🙂"
        let entries = MarkdownOutline.entries(in: MarkdownAnalysis(source))

        XCTAssertEqual(entries.map(\.level), [1, 3, 1])
        XCTAssertEqual(entries.map(\.title), ["最初🙂", "子", "最初🙂"])
        let nsSource = source as NSString
        let expected = [nsSource.range(of: "# 最初🙂"),
                        nsSource.range(of: "### 子"),
                        nsSource.range(of: "# 最初🙂", options: .backwards)]
        XCTAssertEqual(entries.map(\.sourceRange.location), expected.map(\.location))
        for (entry, range) in zip(entries, expected) {
            XCTAssertTrue(nsSource.substring(with: entry.sourceRange).hasPrefix(nsSource.substring(with: range)))
        }
        XCTAssertEqual(Set(entries.map(\.id)).count, 3)
    }

    func testCodeFenceAndParagraphDoNotBecomeHeadings() {
        let source = "```\n# code\n```\n\nplain"
        XCTAssertTrue(MarkdownOutline.entries(in: MarkdownAnalysis(source)).isEmpty)
    }
}
