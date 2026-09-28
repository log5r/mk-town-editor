import AppKit
import XCTest
@testable import MKTownEditor

@MainActor
final class PreviewRenderCacheTests: XCTestCase {
    func testUnchangedBlockReusesRenderedAttributesAfterOtherBlockChanges() throws {
        let first = MarkdownAnalysis("# Heading\n\nFirst\n\nSecond")
        let changed = MarkdownAnalysis("# Heading\n\nFirst\n\nChanged")
        let context = DocumentContext(fileURL: nil)
        let cache = PreviewRenderCache()
        let heading = try XCTUnwrap(first.blocks.first { $0.kind == .heading(level: 1) })
        let last = try XCTUnwrap(first.blocks.last { $0.kind == .paragraph })
        let firstRender = cache.render(heading, in: first, context: context, zoom: 1)
        _ = cache.render(last, in: first, context: context, zoom: 1)
        XCTAssertEqual(cache.renderCount, 2)

        let sameHeading = try XCTUnwrap(changed.blocks.first { $0.kind == .heading(level: 1) })
        let changedLast = try XCTUnwrap(changed.blocks.last { $0.kind == .paragraph })
        let reused = cache.render(sameHeading, in: changed, context: context, zoom: 1)
        _ = cache.render(changedLast, in: changed, context: context, zoom: 1)

        XCTAssertTrue(firstRender === reused)
        XCTAssertEqual(cache.renderCount, 3)
    }

    func testReferenceAndZoomChangesInvalidateCachedRendering() throws {
        let first = MarkdownAnalysis("[link][ref]\n\n[ref]: /a")
        let changed = MarkdownAnalysis("[link][ref]\n\n[ref]: /b")
        let context = DocumentContext(fileURL: nil)
        let cache = PreviewRenderCache()
        let firstBlock = try XCTUnwrap(first.blocks.first { $0.kind == .paragraph })
        let changedBlock = try XCTUnwrap(changed.blocks.first { $0.kind == .paragraph })

        let initial = cache.render(firstBlock, in: first, context: context, zoom: 1)
        let updated = cache.render(changedBlock, in: changed, context: context, zoom: 1)
        let enlarged = cache.render(changedBlock, in: changed, context: context, zoom: 1.5)

        XCTAssertEqual(initial.attribute(.link, at: 0, effectiveRange: nil) as? URL, URL(string: "/a"))
        XCTAssertEqual(updated.attribute(.link, at: 0, effectiveRange: nil) as? URL, URL(string: "/b"))
        XCTAssertFalse(updated === enlarged)
        XCTAssertEqual(cache.renderCount, 3)
    }

    func testSourceOffsetShiftDoesNotRerenderUnchangedLaterBlock() throws {
        let first = MarkdownAnalysis("# Short\n\nStable")
        let changed = MarkdownAnalysis("# Longer heading\n\nStable")
        let cache = PreviewRenderCache()
        let context = DocumentContext(fileURL: nil)
        let before = try XCTUnwrap(first.blocks.first { $0.kind == .paragraph })
        let after = try XCTUnwrap(changed.blocks.first { $0.kind == .paragraph })
        XCTAssertNotEqual(before.sourceRange.location, after.sourceRange.location)

        let rendered = cache.render(before, in: first, context: context, zoom: 1)
        let reused = cache.render(after, in: changed, context: context, zoom: 1)

        XCTAssertTrue(rendered === reused)
        XCTAssertEqual(cache.renderCount, 1)
    }

    func testInsertedBlockDoesNotRerenderUnchangedFollowingBlock() throws {
        let first = MarkdownAnalysis("# Title\n\nStable")
        let changed = MarkdownAnalysis("# Title\n\nInserted\n\nStable")
        let cache = PreviewRenderCache()
        let context = DocumentContext(fileURL: nil)
        let before = try XCTUnwrap(first.blocks.last { $0.kind == .paragraph })
        let after = try XCTUnwrap(changed.blocks.last { $0.kind == .paragraph })
        XCTAssertNotEqual(before.id, after.id)

        let rendered = cache.render(before, in: first, context: context, zoom: 1)
        let reused = cache.render(after, in: changed, context: context, zoom: 1)

        XCTAssertTrue(rendered === reused)
        XCTAssertEqual(cache.renderCount, 1)
    }

    func testLayoutIndexPreservesNestedQuoteDepth() throws {
        let analysis = MarkdownAnalysis("> first\n> > nested\n\nregular")
        let layout = PreviewLayoutIndex(analysis)
        let nested = try XCTUnwrap(layout.visibleBlocks.first { $0.content.contains("nested") })
        let regular = try XCTUnwrap(layout.visibleBlocks.first { $0.content == "regular" })
        XCTAssertEqual(layout.quoteDepth(for: nested.id), 2)
        XCTAssertEqual(layout.quoteDepth(for: regular.id), 0)
    }

    func testFootnoteRenumberingInvalidatesCachedBlock() throws {
        let first = MarkdownAnalysis("Text[^a]\n\n[^a]: Alpha\n[^b]: Beta")
        let changed = MarkdownAnalysis("Other[^b]\n\nText[^a]\n\n[^a]: Alpha\n[^b]: Beta")
        let cache = PreviewRenderCache()
        let context = DocumentContext(fileURL: nil)
        let oldBlock = try XCTUnwrap(first.blocks.first { $0.content.contains("Text") })
        let newBlock = try XCTUnwrap(changed.blocks.first { $0.content.contains("Text") })
        let before = cache.render(oldBlock, in: first, context: context, zoom: 1)
        let after = cache.render(newBlock, in: changed, context: context, zoom: 1)
        XCTAssertFalse(before === after)
        XCTAssertEqual(before.string, "Text1")
        XCTAssertEqual(after.string, "Text2")
    }

    func testCalloutAppearsAsOneVisibleBlock() throws {
        let analysis = MarkdownAnalysis("> [!NOTE]\n> Paragraph\n> - item")
        let layout = PreviewLayoutIndex(analysis)
        XCTAssertEqual(layout.visibleBlocks.count, 1)
        XCTAssertEqual(layout.visibleBlocks.first?.calloutKind, .note)
    }
}
