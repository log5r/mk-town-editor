import AppKit
import XCTest
@testable import MKTownEditor

@MainActor
final class EditorTextStyleTests: XCTestCase {
    func testInitiallyEmptyEditorCoversViewportForMouseInput() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let textView = EditorTextView()
        textView.isVerticallyResizable = true
        scrollView.documentView = textView
        EditorTextStyle().apply(to: textView)
        EditorLayoutOptions().apply(to: textView, in: scrollView)
        scrollView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThanOrEqual(textView.frame.height, scrollView.contentSize.height)
        let point = NSPoint(x: 100, y: 150)
        XCTAssertTrue(scrollView.hitTest(point) === textView)
    }

    func testApplyingStyleUpdatesLayoutWithoutChangingSourceOrUndo() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        textView.allowsUndo = true
        textView.string = "# 見出し\n本文"
        let source = textView.string
        let selection = NSRange(location: 3, length: 2)
        textView.setSelectedRange(selection)

        EditorTextStyle(fontChoice: .menlo, fontSize: 17, lineSpacing: 6,
                        horizontalMargin: 22, verticalMargin: 16).apply(to: textView)

        XCTAssertEqual(textView.font?.pointSize, 17)
        XCTAssertEqual(textView.textContainerInset, NSSize(width: 22, height: 16))
        XCTAssertEqual(textView.defaultParagraphStyle?.lineSpacing, 6)
        XCTAssertGreaterThan(textView.defaultParagraphStyle?.defaultTabInterval ?? 0, 0)
        XCTAssertEqual(textView.string, source)
        XCTAssertEqual(textView.selectedRange(), selection)
        XCTAssertFalse(textView.undoManager?.canUndo ?? false)
    }

    func testTabWidthAndWrappingUpdateTextContainerAndScrollers() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 100))
        let textView = NSTextView(frame: scrollView.contentView.bounds)
        scrollView.documentView = textView
        let style = EditorTextStyle(tabWidth: 6)
        style.apply(to: textView)
        let space = (" " as NSString).size(withAttributes: [.font: textView.font!]).width
        XCTAssertEqual(textView.defaultParagraphStyle?.defaultTabInterval ?? -1, space * 6, accuracy: 0.01)

        EditorLayoutOptions(wrapsLines: false).apply(to: textView, in: scrollView)
        XCTAssertTrue(scrollView.hasHorizontalScroller)
        XCTAssertFalse(textView.textContainer!.widthTracksTextView)
        XCTAssertTrue(textView.isHorizontallyResizable)
        XCTAssertEqual(textView.textContainer!.containerSize.width, CGFloat.greatestFiniteMagnitude)

        textView.string = String(repeating: "W", count: 120)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        EditorLayoutOptions(wrapsLines: false).synchronizeWidth(of: textView, in: scrollView)
        XCTAssertGreaterThan(textView.frame.width, scrollView.contentSize.width)

        textView.string = "short"
        EditorLayoutOptions(wrapsLines: false).synchronizeWidth(of: textView, in: scrollView)
        XCTAssertEqual(textView.frame.width, scrollView.contentSize.width)

        EditorLayoutOptions(wrapsLines: true).apply(to: textView, in: scrollView)
        XCTAssertFalse(scrollView.hasHorizontalScroller)
        XCTAssertTrue(textView.textContainer!.widthTracksTextView)
        XCTAssertFalse(textView.isHorizontallyResizable)
    }
}
