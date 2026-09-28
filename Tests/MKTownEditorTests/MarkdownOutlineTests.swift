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

    func testQuickSearchIgnoresCaseAndKeepsDuplicateHeadingLocations() {
        let entries = MarkdownOutline.entries(in: MarkdownAnalysis("# Alpha\n## beta\n# ALPHA"))
        XCTAssertEqual(MarkdownOutline.search("  alpha  ", in: entries).map(\.id),
                       [entries[0].id, entries[2].id])
        XCTAssertEqual(MarkdownOutline.search("BETA", in: entries).map(\.id), [entries[1].id])
        XCTAssertEqual(MarkdownOutline.search("", in: entries), entries)
        XCTAssertTrue(MarkdownOutline.search("missing", in: entries).isEmpty)
    }

    func testSectionMoveCarriesChildHeadingsAndUsesOneEdit() throws {
        let source = "# A\n本文\n## 子\n子本文\n\n# B\n別本文\n\n# C\n末尾"
        let location = (source as NSString).range(of: "# A").location
        let edit = try XCTUnwrap(MarkdownSectionMove.edit(in: source,
            headingLocation: location, direction: .down))
        let moved = try XCTUnwrap(edit.applying(to: source))
        XCTAssertTrue(moved.hasPrefix("# B\n別本文\n\n# A\n本文\n## 子\n子本文"))
        XCTAssertTrue(moved.hasSuffix("# C\n末尾"))
        XCTAssertEqual(edit.selection.location, (moved as NSString).range(of: "# A").location)
        XCTAssertNil(MarkdownSectionMove.edit(in: source,
            headingLocation: location, direction: .up))
    }

    func testSectionMovePreservesFinalNewlinePolicyAndParentBoundary() throws {
        let source = "# Parent\r\n## First\r\nOne\r\n\r\n## Second\r\nTwo\r\n# Other\r\nEnd"
        let first = (source as NSString).range(of: "## First").location
        let edit = try XCTUnwrap(MarkdownSectionMove.edit(in: source,
            headingLocation: first, direction: .down))
        let moved = try XCTUnwrap(edit.applying(to: source))
        XCTAssertTrue(moved.contains("# Parent\r\n## Second\r\nTwo\r\n\r\n## First\r\nOne"), moved.debugDescription)
        XCTAssertTrue(moved.hasSuffix("# Other\r\nEnd"))
        XCTAssertFalse(moved.hasSuffix("\n"))
        let other = (source as NSString).range(of: "# Other").location
        XCTAssertNil(MarkdownSectionMove.edit(in: source,
            headingLocation: other, direction: .down))
    }
}
