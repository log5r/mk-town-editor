import AppKit
import XCTest
@testable import MKTownEditor

@MainActor
final class EditorTextStyleTests: XCTestCase {
    func testJapaneseBaselineStaysStableWhenTypingAndDeletingASCII() throws {
        let families = ["Hiragino Sans", "Times New Roman", "Courier New", "Georgia", "Monaco"]
            .map(EditorFont.family).filter(\.isAvailable)
        for font in EditorFontChoice.allCases.map(EditorFont.builtIn) + families {
            for size in [13.0, 17.5, 26.0] {
                for spacing in [0.0, 3.0, 12.0] {
                    let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
                    view.layoutManager?.delegate = view
                    view.isRichText = false
                    EditorTextStyle(font: font, fontSize: size, lineSpacing: spacing).apply(to: view)
                    let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
                    window.contentView = view
                    window.makeFirstResponder(view)
                    defer { window.orderOut(nil); window.contentView = nil }
                    view.setMarkedText("日本語", selectedRange: NSRange(location: 3, length: 0),
                                       replacementRange: NSRange(location: NSNotFound, length: 0))
                    view.insertText("日本語", replacementRange: NSRange(location: NSNotFound, length: 0))
                    let before = try lineGeometry(in: view)
                    let japaneseFont = view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                    let message = "\(font) \(size)pt spacing=\(spacing)"

                    view.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
                    let mixed = try lineGeometry(in: view)
                    XCTAssertEqual(mixed.baseline, before.baseline, accuracy: 0.01, message)
                    XCTAssertEqual(mixed.height, before.height, accuracy: 0.01, message)
                    XCTAssertEqual(view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, japaneseFont)

                    view.deleteBackward(nil)
                    let after = try lineGeometry(in: view)
                    XCTAssertEqual(view.string, "日本語")
                    XCTAssertEqual(after.baseline, mixed.baseline, accuracy: 0.01, message)
                    XCTAssertEqual(after.height, mixed.height, accuracy: 0.01, message)
                }
            }
        }
    }

    func testWrappedJapaneseAndFollowingLinesKeepTheirPositionsAfterASCIIEdit() throws {
        for spacing in [0.0, 3.0, 12.0] {
            let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 120, height: 600))
            view.layoutManager?.delegate = view
            view.isRichText = false
            EditorTextStyle(font: .builtIn(.menlo), lineSpacing: spacing).apply(to: view)
            let container = try XCTUnwrap(view.textContainer)
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: 120, height: 1000)
            view.replaceEditorText(with: "日本語日本語日本語\n次の行")
            let locations = [0, 8, 10]
            let before = try locations.map { try lineGeometry(in: view, at: $0) }
            XCTAssertGreaterThan(before[1].baseline, before[0].baseline, "the Japanese paragraph must wrap")

            // The final visual fragment has room for ASCII without changing the wrap point.
            view.setSelectedRange(NSRange(location: 9, length: 0))
            view.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
            let mixed = try [0, 8, 11].map { try lineGeometry(in: view, at: $0) }
            view.deleteBackward(nil)
            let after = try locations.map { try lineGeometry(in: view, at: $0) }

            XCTAssertEqual(view.string, "日本語日本語日本語\n次の行")
            for index in locations.indices {
                XCTAssertEqual(mixed[index].baseline, before[index].baseline, accuracy: 0.01)
                XCTAssertEqual(mixed[index].height, before[index].height, accuracy: 0.01)
                XCTAssertEqual(after[index].baseline, mixed[index].baseline, accuracy: 0.01)
                XCTAssertEqual(after[index].height, mixed[index].height, accuracy: 0.01)
            }
        }
    }

    func testChangingFontAndZoomOnLaidOutJapaneseKeepsBaselineStable() throws {
        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        view.layoutManager?.delegate = view
        view.isRichText = false
        view.string = "日本語"
        for font in [EditorFont.builtIn(.monospacedSystem), .builtIn(.menlo), .family("Hiragino Sans"), .builtIn(.menlo)] {
            for size in [13.0, 26.0, 17.5] {
                EditorTextStyle(font: font, fontSize: size).apply(to: view)
                let before = try lineGeometry(in: view)
                view.setSelectedRange(NSRange(location: 3, length: 0))
                view.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
                let mixed = try lineGeometry(in: view)
                XCTAssertEqual(mixed.baseline, before.baseline, accuracy: 0.01, "\(font) \(size)pt")
                XCTAssertEqual(mixed.height, before.height, accuracy: 0.01, "\(font) \(size)pt")
                view.deleteBackward(nil)
                _ = try lineGeometry(in: view)
            }
        }
    }

    func testTallFallbackGlyphsKeepTheirOriginalLineGeometry() throws {
        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        view.isRichText = false
        EditorTextStyle(font: .builtIn(.menlo)).apply(to: view)
        view.replaceEditorText(with: "日本語🙂")
        let manager = try XCTUnwrap(view.layoutManager)
        // Compare with TextKit's unmodified layout to ensure larger fallback metrics survive.
        let original = try lineGeometry(in: view)
        let storage = try XCTUnwrap(view.textStorage)
        let fonts = (0..<storage.length).compactMap { storage.attribute(.font, at: $0, effectiveRange: nil) as? NSFont }
        let bodyFont = try XCTUnwrap(view.appliedBodyFont)
        XCTAssertTrue(fonts.contains { manager.defaultBaselineOffset(for: $0) > manager.defaultBaselineOffset(for: bodyFont) })

        manager.delegate = view
        manager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
        let adjusted = try lineGeometry(in: view)
        XCTAssertEqual(adjusted.baseline, original.baseline, accuracy: 0.01)
        XCTAssertEqual(adjusted.height, original.height, accuracy: 0.01)
    }

    private func lineGeometry(in view: NSTextView, at location: Int = 0) throws -> (baseline: CGFloat, height: CGFloat) {
        let manager = try XCTUnwrap(view.layoutManager)
        manager.ensureLayout(for: try XCTUnwrap(view.textContainer))
        let glyph = manager.glyphIndexForCharacter(at: location)
        let rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return (rect.minY + manager.location(forGlyphAt: glyph).y, rect.height)
    }

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

        EditorTextStyle(font: .builtIn(.menlo), fontSize: 17, lineSpacing: 6,
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
