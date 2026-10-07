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

    func testSectionLevelChangesParentAndChildrenButNotFollowingSection() throws {
        let source = "# Parent\n## Child\ntext\n### Deep\nmore\n# Next\nend"
        let location = (source as NSString).range(of: "# Parent").location
        let edit = try XCTUnwrap(MarkdownSectionLevel.edit(in: source,
            headingLocation: location, by: 1))
        XCTAssertEqual(edit.applying(to: source),
            "## Parent\n### Child\ntext\n#### Deep\nmore\n# Next\nend")
        XCTAssertNil(MarkdownSectionLevel.edit(in: source,
            headingLocation: location, by: -1))
        let deep = (source as NSString).range(of: "### Deep").location
        let promoted = try XCTUnwrap(MarkdownSectionLevel.edit(in: source,
            headingLocation: deep, by: -1))
        XCTAssertTrue(try XCTUnwrap(promoted.applying(to: source)).contains("## Deep\nmore"))
    }

    func testSectionLevelConvertsSetextAndRejectsH6Overflow() throws {
        let source = "Title\n=====\n## Child\n###### Deep\n"
        let start = 0
        XCTAssertNil(MarkdownSectionLevel.edit(in: source,
            headingLocation: start, by: 1))
        let child = (source as NSString).range(of: "## Child").location
        XCTAssertNil(MarkdownSectionLevel.edit(in: source,
            headingLocation: child, by: 1))
        let simple = "Title\n=====\nbody\n"
        let edit = try XCTUnwrap(MarkdownSectionLevel.edit(in: simple,
            headingLocation: 0, by: 1))
        XCTAssertEqual(edit.applying(to: simple), "## Title\nbody\n")
        let crlf = "## 親\r\n### 子\r\n本文"
        let crlfEdit = try XCTUnwrap(MarkdownSectionLevel.edit(in: crlf,
            headingLocation: 0, by: -1))
        XCTAssertEqual(crlfEdit.applying(to: crlf), "# 親\r\n## 子\r\n本文")
    }

    func testSectionActionsRespectSiblingParentAndSubtreeLevelBoundaries() throws {
        let source = "# Parent\n### First\n###### Deep\n### Second\n## Other branch\n### Only\n# Next"
        let entries = MarkdownOutline.entries(in: MarkdownAnalysis(source))
        let actions = MarkdownSectionActions.all(in: entries)
        let expected = [
            MarkdownSectionActions(canMoveUp: false, canMoveDown: true, canPromote: false, canDemote: false),
            MarkdownSectionActions(canMoveUp: false, canMoveDown: true, canPromote: true, canDemote: false),
            MarkdownSectionActions(canMoveUp: false, canMoveDown: false, canPromote: true, canDemote: false),
            MarkdownSectionActions(canMoveUp: true, canMoveDown: false, canPromote: true, canDemote: true),
            MarkdownSectionActions(canMoveUp: false, canMoveDown: false, canPromote: true, canDemote: true),
            MarkdownSectionActions(canMoveUp: false, canMoveDown: false, canPromote: true, canDemote: true),
            MarkdownSectionActions(canMoveUp: true, canMoveDown: false, canPromote: false, canDemote: true)
        ]
        XCTAssertEqual(entries.map { actions[$0.id] }, expected.map(Optional.some))
        XCTAssertTrue(MarkdownSectionActions.all(in: []).isEmpty)
    }

    func testCachedSectionActionsAgreeWithEditsAcrossHeadingLevelCombinations() throws {
        // Cover skipped levels, roots without H1, parent changes, H1/H6 limits,
        // Setext headings, CRLF and headings inside code fences.
        var sources = ["Title\r\n=====\r\n## Child\r\n###### Deep\r\n# Next",
                       "# A\n```md\n###### Code\n```\n# B\n",
                       "# Same🙂\n## Same🙂\n# Same🙂"]
        for first in 1...6 {
            for second in 1...6 {
                for third in 1...6 {
                    sources.append([first, second, third].enumerated().map {
                        String(repeating: "#", count: $0.element) + " Heading \($0.offset)\n本文🙂"
                    }.joined(separator: "\n"))
                }
            }
        }
        for source in sources {
            let entries = MarkdownOutline.entries(in: MarkdownAnalysis(source))
            let actions = MarkdownSectionActions.all(in: entries)
            for entry in entries {
                let availability = try XCTUnwrap(actions[entry.id])
                for (direction, available) in [(SectionMoveDirection.up, availability.canMoveUp),
                                              (.down, availability.canMoveDown)] {
                    let edit = MarkdownSectionMove.edit(in: source, entries: entries,
                        headingLocation: entry.sourceRange.location, direction: direction)
                    XCTAssertEqual(available, edit != nil, source)
                    XCTAssertEqual(edit, MarkdownSectionMove.edit(in: source,
                        headingLocation: entry.sourceRange.location, direction: direction))
                }
                for (delta, available) in [(-1, availability.canPromote), (1, availability.canDemote)] {
                    let edit = MarkdownSectionLevel.edit(in: source, entries: entries,
                        headingLocation: entry.sourceRange.location, by: delta)
                    XCTAssertEqual(available, edit != nil, source)
                    XCTAssertEqual(edit, MarkdownSectionLevel.edit(in: source,
                        headingLocation: entry.sourceRange.location, by: delta))
                }
            }
            XCTAssertNil(MarkdownSectionMove.edit(in: source, entries: entries,
                headingLocation: -1, direction: .up))
            XCTAssertNil(MarkdownSectionLevel.edit(in: source, entries: entries,
                headingLocation: -1, by: 1))
            XCTAssertNil(MarkdownSectionLevel.edit(in: source, entries: entries,
                headingLocation: 0, by: 2))
        }
    }

    func testFourHundredHeadingActionsNeedOnlyOutlineEntries() {
        // No document text or parser is supplied to the availability calculation.
        // Nonsequential IDs also guard against accidentally indexing by block ID.
        let entries = (0..<400).map { index in
            MarkdownOutlineEntry(id: index * 3, level: 2, title: "Heading \(index)",
                sourceRange: NSRange(location: index * 1_600, length: 20))
        }
        let actions = MarkdownSectionActions.all(in: entries)
        XCTAssertEqual(actions.count, 400)
        for (index, entry) in entries.enumerated() {
            XCTAssertEqual(actions[entry.id], MarkdownSectionActions(
                canMoveUp: index > 0, canMoveDown: index < 399,
                canPromote: true, canDemote: true))
        }
    }

    func testContentInspectorListsTasksLinksImagesAndSkipsCode() {
        let text = "- [ ] 未完了\n- [x] 完了\n\n[site](https://example.com) " +
            "![図](assets/a.png) [参照][id] ![参照画像][image]\n\n" +
            "[id]: note.md\n[image]: assets/b.png\n\n" +
            "`[fake](ignored.md)`\n\n```md\n![code](ignored.png)\n```"
        let items = MarkdownContentInspector.items(in: text,
            analysis: MarkdownAnalysis(text))
        XCTAssertEqual(items.filter { $0.kind == .task }.map(\.label),
            ["未完了: 未完了", "完了: 完了"])
        XCTAssertEqual(items.filter { $0.kind == .link }.map(\.destination),
            ["https://example.com", "note.md"])
        XCTAssertEqual(items.filter { $0.kind == .image }.map(\.destination),
            ["assets/a.png", "assets/b.png"])
        XCTAssertEqual((text as NSString).substring(with: items[2].sourceRange),
            "[site](https://example.com)")
    }
}
