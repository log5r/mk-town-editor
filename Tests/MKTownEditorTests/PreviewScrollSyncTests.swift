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
