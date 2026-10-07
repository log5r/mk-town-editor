import AppKit
import XCTest
@testable import MKTownEditor

final class PreviewScrollSyncTests: XCTestCase {
    func testSourceLocationMapsToNearestVisibleBlock() {
        let analysis = MarkdownAnalysis("# One\n\nParagraph\n\n# Two")
        let blocks = analysis.blocks.filter { $0.kind != .blank }
        XCTAssertEqual(PreviewScrollSync.block(containingOrBefore: 0, in: analysis)?.id, blocks[0].id)
        XCTAssertEqual(PreviewScrollSync.block(containingOrBefore: 10, in: analysis)?.id, blocks[1].id)
        XCTAssertEqual(PreviewScrollSync.block(containingOrBefore: 999, in: analysis)?.id,
                       blocks.last?.id)
    }

    func testIndexedLookupMatchesLinearScanForNestedStructures() {
        let source = """
        # Title

        > quote line
        > - item in quote
        >   > nested quote

        - first
          - second
            continuation
        1. ordered

        > [!NOTE]
        > callout body

        ```swift
        let x = 1
        ```

        | a | b |
        |---|---|
        | 1 | 2 |

        Tail paragraph
        """
        let analysis = MarkdownAnalysis(source)
        let index = PreviewScrollIndex(analysis)
        let visible = analysis.blocks.filter { $0.kind != .quote }
        for location in 0...((source as NSString).length + 2) {
            let expected = visible.last(where: { $0.sourceRange.location <= location }) ?? visible.first
            XCTAssertEqual(index.block(containingOrBefore: location, in: analysis)?.id, expected?.id,
                           "location \(location)")
        }
        for block in visible {
            XCTAssertEqual(index.sourceLocation(ofBlockID: block.id), block.sourceRange.location)
        }
        let empty = MarkdownAnalysis("")
        XCTAssertEqual(PreviewScrollIndex(empty).block(containingOrBefore: 0, in: empty)?.id,
                       empty.blocks.first { $0.kind != .quote }?.id)
    }

    func testSnapshotProvidesScrollIndex() {
        let snapshot = DocumentSnapshot(source: "# One\n\nTwo")
        let block = snapshot.scrollIndex.block(containingOrBefore: 8, in: snapshot.analysis)
        XCTAssertEqual(block?.content, "Two")
    }

    func testTopVisibleBlockUsesPartiallyScrolledBlock() {
        XCTAssertEqual(PreviewScrollSync.topBlockID(from: [1: -60, 2: 8, 3: 100]), 2)
        XCTAssertEqual(PreviewScrollSync.topBlockID(from: [1: -20, 2: 40]), 1)
        XCTAssertEqual(PreviewScrollSync.topBlockID(from: [1: 40, 2: 100]), 1)
        XCTAssertNil(PreviewScrollSync.topBlockID(from: [:]))
    }
}

@MainActor
final class EditorScrollSyncTests: XCTestCase {
    func testScrollToBlockDoesNotMoveSelection() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let editor = EditorTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 100))
        editor.isVerticallyResizable = true
        editor.textContainer?.widthTracksTextView = true
        editor.string = (0..<100).map { "Line \($0)" }.joined(separator: "\n")
        scrollView.documentView = editor
        editor.layoutManager?.ensureLayout(for: editor.textContainer!)
        let model = MarkdownEditorModel()
        model.connect(editor)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        let target = (editor.string as NSString).range(of: "Line 50").location

        model.scrollToTop(sourceLocation: target)

        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertGreaterThan(scrollView.contentView.bounds.origin.y, 0)
        XCTAssertNotNil(editor.firstVisibleSourceLocation(in: scrollView))
    }
}
