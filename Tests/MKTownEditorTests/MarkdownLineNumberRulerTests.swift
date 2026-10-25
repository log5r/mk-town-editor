import AppKit
import XCTest
@testable import MKTownEditor

@MainActor
final class MarkdownLineNumberRulerTests: XCTestCase {
    func testLineNumberVerticalPositionStaysStableWhenAddingAndRemovingNewlines() throws {
        for font in EditorFontChoice.allCases {
            for spacing in [0.0, 3.0, 12.0] {
                let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
                EditorTextStyle(fontChoice: font, lineSpacing: spacing).apply(to: view)
                let manager = try XCTUnwrap(view.layoutManager)
                let container = try XCTUnwrap(view.textContainer)
                var firstY: CGFloat?
                for text in ["", "\n", "\n\n\n", "\n", "", "text", "text\n", "text"] {
                    view.string = text
                    manager.ensureLayout(for: container)
                    let labels = MarkdownLineNumberLayout.labels(in: view, visibleRect: view.bounds)
                    let first = try XCTUnwrap(labels.first)
                    let y = first.origin.y + first.height / 2
                    if let firstY {
                        XCTAssertEqual(y, firstY, accuracy: 0.01,
                            "font=\(font) spacing=\(spacing) text=\(text.debugDescription)")
                    } else {
                        firstY = y
                    }
                    for label in labels {
                        XCTAssertEqual(label.height, first.height, accuracy: 0.01,
                            "normal and trailing empty lines must use the same vertical alignment")
                    }
                }
            }
        }
    }

    func testMovingCaretAndRelayoutKeepWrappedAndTrailingLineNumbersInPlace() throws {
        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 160, height: 600))
        EditorTextStyle(fontSize: 17.5, lineSpacing: 7).apply(to: view)
        view.string = "a long line that wraps onto several visual lines\nsecond\n\n"
        let manager = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        manager.ensureLayout(for: container)
        let expected = MarkdownLineNumberLayout.labels(in: view, visibleRect: view.bounds)
        XCTAssertEqual(expected.map(\.number), [1, 2, 3, 4])

        for location in 0...view.string.utf16.count {
            view.setSelectedRange(NSRange(location: location, length: 0))
            manager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: view.string.utf16.count),
                                     actualCharacterRange: nil)
            manager.ensureLayout(for: container)
            let actual = MarkdownLineNumberLayout.labels(in: view, visibleRect: view.bounds)
            XCTAssertEqual(actual.map(\.number), expected.map(\.number))
            XCTAssertEqual(actual.map(\.origin), expected.map(\.origin))
            XCTAssertEqual(actual.map(\.height), expected.map(\.height))
        }
    }

    func testIncrementalIndexMatchesRebuildForEveryEditBoundary() {
        for text in ["", "a\r\nb\nc\r", "🙂a\r\n\r\nz", "a\nb"] {
            let source = text as NSString
            for location in 0...source.length {
                for count in 0...(source.length - location) {
                    for replacement in ["", "x", "\r", "\n", "🙂\r\n"] {
                        // NSString offsets may split surrogate pairs; use valid Swift ranges.
                        let range = NSRange(location: location, length: count)
                        guard Range(range, in: text) != nil else { continue }
                        let result = source.replacingCharacters(in: range, with: replacement)
                        var index = MarkdownLineNumberIndex(text)
                        index.update(in: result as NSString,
                            editedRange: NSRange(location: location, length: replacement.utf16.count),
                            changeInLength: replacement.utf16.count - count)
                        XCTAssertEqual(index.starts, MarkdownLineNumberIndex(result).starts,
                            "source=\(text.debugDescription) range=\(range) replacement=\(replacement.debugDescription)")
                    }
                }
            }
        }
    }

    func testScrollingLabelsReuseIndexWithoutReadingEditorSource() {
        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        view.string = "one\ntwo\n"
        let scroll = NSScrollView()
        scroll.documentView = view
        let ruler = MarkdownLineNumberRulerView(scrollView: scroll, editor: view)
        view.textStorage?.replaceCharacters(in: NSRange(location: 1, length: 0), with: "\n")
        let reads = view.sourceReadCount
        for _ in 0..<10 {
            _ = MarkdownLineNumberLayout.labels(in: view, visibleRect: view.bounds, cachedIndex: ruler.index)
        }
        XCTAssertEqual(view.sourceReadCount, reads)
        XCTAssertEqual(ruler.index.starts, MarkdownLineNumberIndex(view.string).starts)
    }

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

    func testDeletingAcrossDigitBoundaryInWrappedEditorDoesNotRetileDuringProcessEditing() async throws {
        for lineCount in [12, 105] {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            let view = EditorTextView(frame: scroll.bounds)
            _ = view.layoutManager // TextKit 1, as in the app
            scroll.documentView = view
            EditorLayoutOptions(wrapsLines: true).apply(to: view, in: scroll)
            let ruler = MarkdownLineNumberRulerView(scrollView: scroll, editor: view)
            scroll.verticalRulerView = ruler
            scroll.hasVerticalRuler = true
            scroll.rulersVisible = true
            let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled, .resizable],
                                  backing: .buffered, defer: false)
            window.contentView = scroll
            defer { window.orderOut(nil); window.contentView = nil }
            view.string = (1...lineCount).map { "line \($0) with some wrapped text" }.joined(separator: "\n")
            ruler.refresh()
            scroll.layoutSubtreeIfNeeded()
            view.layoutManager?.ensureLayout(for: try XCTUnwrap(view.textContainer))
            let wide = ruler.ruleThickness

            view.selectAll(nil)
            view.deleteBackward(nil) // raised NSRangeException inside processEditing
            XCTAssertEqual(view.string, "")
            XCTAssertEqual(ruler.index.starts.count, 1)
            for _ in 0..<50 where ruler.ruleThickness == wide { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertLessThan(ruler.ruleThickness, wide, "the gutter narrows once editing has finished")

            view.insertText(String(repeating: "x\n", count: lineCount),
                            replacementRange: NSRange(location: 0, length: 0))
            for _ in 0..<50 where ruler.ruleThickness != wide { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertEqual(ruler.ruleThickness, wide)
        }
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
