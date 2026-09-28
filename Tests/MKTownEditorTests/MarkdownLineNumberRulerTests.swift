import AppKit
import XCTest
@testable import MKTownEditor

@MainActor
final class MarkdownLineNumberRulerTests: XCTestCase {
    func testLineStartsCountCRLFAndTrailingEmptyLineInUTF16() {
        let index = MarkdownLineNumberIndex("😀\r\nsecond\n")

        XCTAssertEqual(index.starts, [0, 4, 11])
        XCTAssertEqual(index.number(atFragmentStart: 0), 1)
        XCTAssertEqual(index.number(atFragmentStart: 4), 2)
        XCTAssertEqual(index.number(atFragmentStart: 11), 3)
        XCTAssertNil(index.number(atFragmentStart: 5))
    }

    func testWrappedFragmentsShowOneNumberPerLogicalLine() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 80, height: 300))
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        view.textContainer?.containerSize = NSSize(width: 60, height: 1000)
        view.textContainer?.widthTracksTextView = false
        view.string = "abcdefghijabcdefghij\nshort"
        view.layoutManager?.ensureLayout(for: view.textContainer!)

        let labels = MarkdownLineNumberLayout.labels(in: view,
                                                     visibleRect: NSRect(x: 0, y: 0, width: 80, height: 300))

        XCTAssertEqual(labels.map(\.number), [1, 2])
        XCTAssertGreaterThan(labels[1].origin.y, labels[0].origin.y)
    }

    func testGutterWidthGrowsWithLineCount() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let view = NSTextView(frame: scrollView.bounds)
        scrollView.documentView = view
        let ruler = MarkdownLineNumberRulerView(scrollView: scrollView, editor: view)
        view.string = "single"
        ruler.refresh()
        let oneDigit = ruler.ruleThickness

        view.string = (0..<100).map { _ in "line" }.joined(separator: "\n")
        ruler.refresh()

        XCTAssertGreaterThan(ruler.ruleThickness, oneDigit)
    }

    func testEmptyAndTrailingBlankLinesHaveNumbers() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        view.string = ""
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let visible = NSRect(x: 0, y: 0, width: 200, height: 200)
        XCTAssertEqual(MarkdownLineNumberLayout.labels(in: view, visibleRect: visible).map(\.number), [1])

        view.string = "one\n"
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        XCTAssertEqual(MarkdownLineNumberLayout.labels(in: view, visibleRect: visible).map(\.number), [1, 2])
    }
}
