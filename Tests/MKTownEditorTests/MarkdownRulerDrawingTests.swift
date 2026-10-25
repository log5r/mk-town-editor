import AppKit
import XCTest
@testable import MKTownEditor

@MainActor
final class MarkdownRulerDrawingTests: XCTestCase {
    func testRenderedNumbersDoNotMoveWhenAppendingAndDeletingTrailingNewlines() throws {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let view = EditorTextView(frame: scroll.bounds)
        _ = view.layoutManager
        view.isRichText = false
        view.isVerticallyResizable = true
        EditorTextStyle().apply(to: view)
        scroll.documentView = view
        EditorLayoutOptions().apply(to: view, in: scroll)
        let ruler = MarkdownLineNumberRulerView(scrollView: scroll, editor: view)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = scroll
        defer { window.orderOut(nil); window.contentView = nil }
        var knownRows: [Int: [Int]] = [:]
        var knownOrigins: [Int: Int] = [:]
        for count in Array(0...8) + Array((0...7).reversed()) {
            let oldLength = view.string.utf16.count
            view.setSelectedRange(NSRange(location: oldLength, length: 0))
            if count > oldLength {
                view.insertText("\n", replacementRange: NSRange(location: oldLength, length: 0))
            } else if count < oldLength {
                view.deleteBackward(nil)
            }
            XCTAssertEqual(view.string, String(repeating: "\n", count: count))
            ruler.refresh()
            scroll.layoutSubtreeIfNeeded()
            view.layoutManager?.ensureLayout(for: try XCTUnwrap(view.textContainer))
            let bitmap = try XCTUnwrap(ruler.bitmapImageRepForCachingDisplay(in: ruler.bounds))
            ruler.cacheDisplay(in: ruler.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsHigh) / ruler.bounds.height
            let labels = MarkdownLineNumberLayout.labels(in: view, visibleRect: view.visibleRect,
                                                         cachedIndex: ruler.index)
            for label in labels {
                let origin = ruler.convert(label.origin, from: view)
                let lower = max(0, Int(floor(origin.y * scale)))
                let upper = min(bitmap.pixelsHigh, Int(ceil((origin.y + label.height) * scale)))
                // Compare row intensities as well as occupied rows so a fractional-pixel
                // change in antialiasing is detected even if the bounding rows stay equal.
                let rows = (lower..<upper).map { y in
                    (3..<max(4, bitmap.pixelsWide - Int(5 * scale))).reduce(0) { result, x in
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                              color.alphaComponent > 0.1 else { return result }
                        let brightness = min(color.redComponent, color.greenComponent, color.blueComponent)
                        return result + Int(((1 - brightness) * 255).rounded())
                    }
                }
                XCTAssertTrue(rows.contains(where: { $0 > 0 }), "number=\(label.number) count=\(count)")
                if let known = knownRows[label.number] {
                    XCTAssertEqual(lower, knownOrigins[label.number], "number=\(label.number) count=\(count)")
                    XCTAssertEqual(rows, known, "number=\(label.number) count=\(count)")
                } else {
                    knownRows[label.number] = rows
                    knownOrigins[label.number] = lower
                }
            }
        }
    }
}
