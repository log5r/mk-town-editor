import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

/// プレビューを `NSHostingView` に載せ、`NSTextView` で描いた文字の位置を測るための補助。
/// 構造化プレビューは文字列をすべて `NSTextView` で描くため、ビューの階層から位置を取れる。
@MainActor
enum PreviewLayoutTestSupport {
    static func hosted<Content: View>(_ view: Content, width: CGFloat = 600,
                                      body: (NSHostingView<Content>) throws -> Void) rethrows {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = window.contentView?.bounds ?? .zero
        host.layoutSubtreeIfNeeded()
        defer { window.contentView = nil }
        try body(host)
    }

    static func preview(_ source: String, zoom: Double = 1,
                        onRevealSource: ((NSRange) -> Void)? = nil) -> MarkdownPreview {
        var preview = MarkdownPreview(markdown: source, documentContext: DocumentContext(fileURL: nil))
        preview.zoom = zoom
        preview.onRevealSource = onRevealSource
        return preview
    }

    static func textViews(in view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
    }

    static func textView(_ text: String, in host: NSView) throws -> NSTextView {
        try XCTUnwrap(textViews(in: host).first { $0.string == text }, "Missing text view for \(text)")
    }

    /// `needle` が現れるたびに、その先頭の文字の左端の位置を返す。`host` を渡すとその座標系で返す。
    static func positions(of needle: String, in view: NSTextView, relativeTo host: NSView? = nil) throws -> [CGFloat] {
        let manager = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        manager.ensureLayout(for: container)
        let offset = host.map { view.convert(NSPoint(x: view.textContainerOrigin.x, y: 0), to: $0).x }
            ?? view.textContainerOrigin.x
        let source = view.string as NSString
        var result: [CGFloat] = []
        var location = 0
        while location < source.length {
            let range = source.range(of: needle, range: NSRange(location: location, length: source.length - location))
            guard range.location != NSNotFound else { break }
            let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: range.location, length: 1),
                                            actualCharacterRange: nil)
            result.append(offset + manager.boundingRect(forGlyphRange: glyphs, in: container).minX)
            location = NSMaxRange(range)
        }
        return result
    }

    static func position(of needle: String, in view: NSTextView, relativeTo host: NSView? = nil) throws -> CGFloat {
        try XCTUnwrap(positions(of: needle, in: view, relativeTo: host).first, needle)
    }

    /// 各行の先頭の文字の位置。折り返した行の左端を確かめるために使う。
    static func lineStarts(in view: NSTextView) throws -> [CGFloat] {
        let manager = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        manager.ensureLayout(for: container)
        var result: [CGFloat] = []
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) {
            rect, _, _, glyphs, _ in
            result.append(rect.minX + manager.location(forGlyphAt: glyphs.location).x)
        }
        return result
    }

    /// `aligned` などで整えた文字列を、`HoverLinkText` と同じく行の余白なしの `NSTextView` に置く。
    static func standaloneTextView(_ text: NSAttributedString, width: CGFloat = 480) -> NSTextView {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 2000))
        view.textContainer?.lineFragmentPadding = 0
        view.textStorage?.setAttributedString(text)
        return view
    }

    /// 選択面を全選択して専用のペーストボードへ書き出し、コピーで得られる文字列を返す。
    static func copiedString(_ view: NSTextView) -> String? {
        view.selectAll(nil)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PreviewLayoutTestSupport-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        // NSTextView は文字列を旧来の種類（NSStringPboardType）で書き出し、`.string` として読める。
        guard view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes) else { return nil }
        return pasteboard.string(forType: .string)
    }
}
