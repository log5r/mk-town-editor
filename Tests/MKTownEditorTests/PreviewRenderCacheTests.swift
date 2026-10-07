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

    func testLeastRecentlyUsedEntriesAreTrimmedInsteadOfClearingEverything() throws {
        let analysis = MarkdownAnalysis((1...6).map { "Paragraph \($0)" }.joined(separator: "\n\n"))
        let paragraphs = analysis.blocks.filter { $0.kind == .paragraph }
        let cache = PreviewRenderCache(capacity: 4)
        let context = DocumentContext(fileURL: nil)
        let first = cache.render(paragraphs[0], in: analysis, context: context, zoom: 1)
        for block in paragraphs[1...3] { _ = cache.render(block, in: analysis, context: context, zoom: 1) }
        XCTAssertTrue(cache.render(paragraphs[0], in: analysis, context: context, zoom: 1) === first)
        _ = cache.render(paragraphs[4], in: analysis, context: context, zoom: 1)
        XCTAssertLessThanOrEqual(cache.cachedEntryCount, 4)
        XCTAssertGreaterThan(cache.cachedEntryCount, 0)
        let count = cache.renderCount
        XCTAssertTrue(cache.render(paragraphs[0], in: analysis, context: context, zoom: 1) === first,
                      "A recently used block survives trimming")
        XCTAssertEqual(cache.renderCount, count)
        _ = cache.render(paragraphs[1], in: analysis, context: context, zoom: 1)
        XCTAssertEqual(cache.renderCount, count + 1, "The least recently used block was trimmed")
    }

    func testDocumentLargerThanCapacityKeepsHittingItsWorkingSet() throws {
        let analysis = MarkdownAnalysis((1...50).map { "Row \($0)" }.joined(separator: "\n\n"))
        let paragraphs = analysis.blocks.filter { $0.kind == .paragraph }
        let cache = PreviewRenderCache(capacity: 20)
        let context = DocumentContext(fileURL: nil)
        for block in paragraphs { _ = cache.render(block, in: analysis, context: context, zoom: 1) }
        let count = cache.renderCount
        for _ in 0..<5 {
            for block in paragraphs.suffix(10) { _ = cache.render(block, in: analysis, context: context, zoom: 1) }
        }
        XCTAssertEqual(cache.renderCount, count)
    }

    func testReferenceSignaturesAreComputedOncePerAnalysis() throws {
        let markdown = (1...200).map { "[link \($0)][r\($0)] text[^n\($0)]" }.joined(separator: "\n\n") + "\n\n" +
            (1...200).map { "[r\($0)]: /p\($0)\n[^n\($0)]: note \($0)" }.joined(separator: "\n")
        let analysis = MarkdownAnalysis(markdown)
        let cache = PreviewRenderCache()
        let context = DocumentContext(fileURL: nil)
        for block in analysis.blocks where block.kind == .paragraph {
            _ = cache.render(block, in: analysis, context: context, zoom: 1)
            _ = cache.renderCell(block.content, in: analysis, context: context, zoom: 1)
        }
        XCTAssertEqual(cache.signatureComputationCount, 1)
        let reparsed = MarkdownAnalysis(markdown)
        let first = try XCTUnwrap(analysis.blocks.first { $0.kind == .paragraph })
        let rendered = cache.render(first, in: analysis, context: context, zoom: 1)
        XCTAssertTrue(cache.render(try XCTUnwrap(reparsed.blocks.first { $0.kind == .paragraph }),
                                   in: reparsed, context: context, zoom: 1) === rendered)
        XCTAssertEqual(cache.signatureComputationCount, 2)
    }

    func testResourceRevisionOnlyRerendersBlocksThatMayContainImages() throws {
        let analysis = MarkdownAnalysis("Plain text\n\n![photo](photo.png)\n\n| a |\n|---|\n| ![i](i.png) |")
        let plain = try XCTUnwrap(analysis.blocks.first { $0.content == "Plain text" })
        let image = try XCTUnwrap(analysis.blocks.first { $0.content.hasPrefix("![photo]") })
        let cache = PreviewRenderCache()
        let context = DocumentContext(fileURL: nil)
        let plainRender = cache.render(plain, in: analysis, context: context, zoom: 1, remoteRevision: 1)
        let imageRender = cache.render(image, in: analysis, context: context, zoom: 1, remoteRevision: 1)
        let cell = cache.renderCell("![i](i.png)", in: analysis, context: context, zoom: 1, remoteRevision: 1)
        XCTAssertTrue(cache.render(plain, in: analysis, context: context, zoom: 1, remoteRevision: 2) === plainRender)
        XCTAssertFalse(cache.render(image, in: analysis, context: context, zoom: 1, remoteRevision: 2) === imageRender)
        XCTAssertFalse(cache.renderCell("![i](i.png)", in: analysis, context: context, zoom: 1,
                                        remoteRevision: 2) === cell)
    }

    func testDisplayFormulaValidityIsCachedAndMatchesLabelParsing() throws {
        let cache = PreviewRenderCache()
        let valid = try XCTUnwrap(MarkdownMath.displayFormula("$$\nx^2+y^2\n$$"))
        let invalid = try XCTUnwrap(MarkdownMath.displayFormula("$$\n\\frac{\n$$"))
        XCTAssertEqual(cache.canRenderDisplayFormula(valid), MarkdownMathRenderer.label(valid) != nil)
        XCTAssertEqual(cache.canRenderDisplayFormula(invalid), MarkdownMathRenderer.label(invalid) != nil)
        XCTAssertTrue(cache.canRenderDisplayFormula(valid))
        XCTAssertFalse(cache.canRenderDisplayFormula(invalid))
    }

    func testSnapshotPrecomputesPreviewLayoutAndStructureFlag() {
        for source in ["plain", "# Heading", "```\ncode\n```", "text $x$", "![[Note]]", "a[^1]\n\n[^1]: n"] {
            let snapshot = DocumentSnapshot(source: source)
            XCTAssertEqual(snapshot.needsStructuredPreview,
                           PreviewStructure.needsStructuredLayout(snapshot.analysis, source: source), source)
            XCTAssertEqual(snapshot.previewLayout.visibleBlocks.map(\.id),
                           PreviewLayoutIndex(snapshot.analysis).visibleBlocks.map(\.id))
        }
        XCTAssertFalse(DocumentSnapshot(source: "plain").needsStructuredPreview)
        XCTAssertTrue(DocumentSnapshot(source: "# Heading").needsStructuredPreview)
    }
}
