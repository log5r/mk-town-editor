import AppKit
import Dispatch
import SwiftUI
import XCTest
@testable import MKTownEditor

@MainActor
final class MarkdownEditorHighlightTests: XCTestCase {
    func testCurrentLineFollowsTheCaretAcrossWrappedRowsAndAnEmptyLastLine() throws {
        let firstLine = String(repeating: "日本語の文章です。 ", count: 16) + "\n"
        let source = firstLine + "次の行\n"
        var highlights = EditorHighlightSettings()
        highlights.currentLine = true
        let (host, window, view) = try makeEditor(source, highlights: highlights, width: 220)
        defer { window.close() }

        let layoutManager = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        layoutManager.ensureLayout(for: container)
        let lastCharacter = firstLine.utf16.count - 2
        let lastGlyph = layoutManager.glyphIndexForCharacter(at: lastCharacter)
        XCTAssertGreaterThan(layoutManager.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil).minY,
                             layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minY)

        let firstLineRange = NSRange(location: 0, length: firstLine.utf16.count)
        view.setSelectedRange(NSRange(location: 1, length: 0))
        XCTAssertEqual(view.currentLineHighlightRange, firstLineRange)
        view.setSelectedRange(NSRange(location: lastCharacter, length: 0))
        XCTAssertEqual(view.currentLineHighlightRange, firstLineRange)
        view.setSelectedRange(NSRange(location: 1, length: 2))
        XCTAssertNil(view.currentLineHighlightRange)

        let end = NSRange(location: source.utf16.count, length: 0)
        view.setSelectedRange(end)
        XCTAssertEqual(view.currentLineHighlightRange, end)

        host.rootView.highlights = EditorHighlightSettings()
        host.layoutSubtreeIfNeeded()
        XCTAssertNil(view.currentLineHighlightRange)
        XCTAssertEqual(view.selectedRange(), end)
    }

    func testCurrentLineFillsTheEmptyAreaInAPartialRedraw() throws {
        let source = "Short\nAnother line"
        let (_, window, view) = try makeEditor(source, highlights: EditorHighlightSettings(currentLine: true))
        defer { window.close() }

        let layoutManager = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        layoutManager.ensureLayout(for: container)
        let firstRow = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let usedRow = layoutManager.lineFragmentUsedRect(forGlyphAt: 0, effectiveRange: nil)
        let drawingOrigin = view.textContainerOrigin
        let dirty = NSRect(x: floor(view.bounds.maxX) - 30, y: floor(firstRow.midY + drawingOrigin.y) - 2,
                           width: 10, height: 4)
        XCTAssertGreaterThan(dirty.minX, usedRow.maxX + drawingOrigin.x)
        view.setSelectedRange(NSRange(location: 1, length: 0))
        let active = try backgroundColor(of: view, in: dirty)
        view.setSelectedRange(NSRange(location: (source as NSString).range(of: "Another").location, length: 0))
        let inactive = try backgroundColor(of: view, in: dirty)

        let difference = abs(active.redComponent - inactive.redComponent)
            + abs(active.greenComponent - inactive.greenComponent)
            + abs(active.blueComponent - inactive.blueComponent)
        XCTAssertGreaterThan(difference, 0.03)
    }

    func testCrossingABracketHighlightsItsPartnerUntilTheTimerExpires() async throws {
        let source = "lead ([inner]) tail"
        let text = source as NSString
        var highlights = EditorHighlightSettings()
        highlights.matchingBrackets = true
        let (_, window, view) = try makeEditor(source, highlights: highlights)
        defer { window.close() }

        let opening = text.range(of: "[")
        let closing = text.range(of: "]")
        view.setSelectedRange(NSRange(location: NSMaxRange(closing), length: 0))
        XCTAssertNil(view.matchingBracketHighlightRange, "Jumping over several characters is not crossing one bracket")
        view.moveLeft(nil)
        for _ in 0..<30 where view.matchingBracketHighlightRange == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(view.matchingBracketHighlightRange, opening)
        for _ in 0..<100 where view.matchingBracketHighlightRange != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(view.matchingBracketHighlightRange)

        view.setSelectedRange(NSRange(location: opening.location, length: 0))
        view.moveRight(nil)
        for _ in 0..<30 where view.matchingBracketHighlightRange == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(view.matchingBracketHighlightRange, closing)
    }

    func testBracketCrossingAwaitsAnAnalysisOfTheCurrentSource() async throws {
        let source = "lead ([inner]) tail"
        let text = source as NSString
        let (host, window, view) = try makeEditor(source, highlights: EditorHighlightSettings(matchingBrackets: true),
                                                  usesSharedAnalysis: true)
        defer { window.close() }
        let opening = text.range(of: "[")
        let closing = text.range(of: "]")
        view.setSelectedRange(NSRange(location: NSMaxRange(closing), length: 0))
        view.moveLeft(nil)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(view.matchingBracketHighlightRange)

        host.rootView.sharedSnapshot = DocumentSnapshot(source: "lead ([other]) tail")
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(view.matchingBracketHighlightRange)

        host.rootView.sharedSnapshot = DocumentSnapshot(source: source)
        host.layoutSubtreeIfNeeded()
        for _ in 0..<30 where view.matchingBracketHighlightRange == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(view.matchingBracketHighlightRange, opening)
    }

    func testSelectedWordWaitsForTheSelectionAndDoesNotChangeTextUndoOrCopy() async throws {
        let source = "stone and stones and stone"
        let text = source as NSString
        var highlights = EditorHighlightSettings()
        highlights.selectedWord = true
        highlights.wordDelay = 0.2
        let (_, window, view) = try makeEditor(source, highlights: highlights)
        defer { window.close() }
        let undoManager = try XCTUnwrap(view.undoManager)
        undoManager.removeAllActions()
        let revision = view.sourceRevision

        view.setSelectedRange(text.range(of: "stone"))
        XCTAssertNil(view.selectedWordHighlight)
        view.setSelectedRange(text.range(of: "stones"))
        XCTAssertNil(view.selectedWordHighlight)
        for _ in 0..<100 where view.selectedWordHighlight == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(view.selectedWordHighlight, "stones")

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes))
        XCTAssertEqual(pasteboard.string(forType: .string), "stones")
        XCTAssertEqual(view.sourceText, source)
        XCTAssertEqual(view.sourceRevision, revision)
        XCTAssertFalse(undoManager.canUndo)

        view.setSelectedRange(text.range(of: "tone"))
        XCTAssertNil(view.selectedWordHighlight)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(view.selectedWordHighlight)
    }

    func testLargeDocumentInputLatency() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MKTOWN_PERF"] == "1",
                          "MKTOWN_PERF=1 のときだけ計測する")
        let paragraph = "長い文書の編集例。 A paragraph with Markdown links [example](page.md) and `code`.\n\n"
        let paragraphCount = 10_000
        let source = String(repeating: paragraph, count: paragraphCount)
        let disabled = EditorHighlightSettings()
        var enabled = disabled
        enabled.currentLine = true
        enabled.matchingBrackets = true
        enabled.selectedWord = true
        let (host, window, view) = try makeEditor(source, highlights: disabled, usesSharedAnalysis: true)
        defer { window.close() }
        let caret = NSRange(location: 5, length: 0)
        let selectionReplacement = NSRange(location: NSNotFound, length: 0)
        view.setSelectedRange(caret)

        func measurePair() -> [Double] {
            let beforeInsert = DispatchTime.now().uptimeNanoseconds
            view.insertText("x", replacementRange: selectionReplacement)
            let beforeDelete = DispatchTime.now().uptimeNanoseconds
            view.deleteBackward(nil)
            let afterDelete = DispatchTime.now().uptimeNanoseconds
            return [Double(beforeDelete - beforeInsert) / 1_000_000,
                    Double(afterDelete - beforeDelete) / 1_000_000]
        }

        let warmUpPairs = 4
        let measuredPairs = 25
        var samples = [[Double](), [Double]()]
        for run in 0..<6 {
            let toggled = run % 2 == 1
            host.rootView.highlights = toggled ? enabled : disabled
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.currentLineHighlightRange != nil, toggled)
            let revision = view.sourceRevision
            for _ in 0..<warmUpPairs { _ = measurePair() }
            for _ in 0..<measuredPairs { samples[run % 2] += measurePair() }
            XCTAssertEqual(view.sourceRevision - revision, 2 * (warmUpPairs + measuredPairs))
            XCTAssertEqual(view.selectedRange(), caret)
        }
        XCTAssertEqual(view.sourceText, source)

        for (index, label) in ["off", "on"].enumerated() {
            let sorted = samples[index].sorted()
            let median = (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            let p95 = sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]
            print(String(format: "PERF editor-input highlights=%@ utf16=%d samples=%d median_ms=%.3f p95_ms=%.3f",
                         label, source.utf16.count, sorted.count, median, p95))
        }
    }

    private func makeEditor(_ source: String, highlights: EditorHighlightSettings, width: CGFloat = 600,
                            usesSharedAnalysis: Bool = false) throws
        -> (NSHostingView<MarkdownTextEditor>, NSWindow, EditorTextView) {
        let host = NSHostingView(rootView: MarkdownTextEditor(
            text: .constant(source), model: MarkdownEditorModel(), usesSharedAnalysis: usesSharedAnalysis,
            highlights: highlights))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(host.rootView.model.textView as? EditorTextView)
        XCTAssertTrue(window.makeFirstResponder(editor))
        return (host, window, editor)
    }

    private func backgroundColor(of view: EditorTextView, in rect: NSRect) throws -> NSColor {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width),
            pixelsHigh: Int(rect.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
        view.drawBackground(in: rect)
        let center = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
        return try XCTUnwrap(center?.usingColorSpace(.sRGB))
    }
}
