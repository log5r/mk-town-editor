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

    func testCurrentSectionFollowsCaretAcrossNestedHeadingsAndDuplicateNames() {
        let text = "intro\n# Parent\nbody\n## Child\nmore\n# Parent\nend"
        let entries = MarkdownOutline.entries(in: MarkdownAnalysis(text))
        let source = text as NSString

        XCTAssertNil(MarkdownOutline.currentSection(at: 0, in: entries))
        XCTAssertEqual(MarkdownOutline.currentSection(at: source.range(of: "body").location,
                                                     in: entries)?.id, entries[0].id)
        XCTAssertEqual(MarkdownOutline.currentSection(at: source.range(of: "more").location,
                                                     in: entries)?.id, entries[1].id)
        XCTAssertEqual(MarkdownOutline.currentSection(at: source.length, in: entries)?.id, entries[2].id)
    }
}
