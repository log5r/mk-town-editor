import AppKit
import SwiftMath
import SwiftUI
import XCTest
@testable import MKTownEditor

/// プレビューの表示倍率（`MarkdownPreview.zoom`）に数式が追従すること。
/// docs/math-font-size-and-baseline.md の「表示倍率」
@MainActor
final class MarkdownMathZoomTests: XCTestCase {
    private let source = "本文 $ax+b$ と $\\displaystyle ax+b$ の式\n\n$$\nax+b\n$$"

    private func attachments(in text: NSAttributedString) -> [(Int, NSTextAttachment)] {
        var result: [(Int, NSTextAttachment)] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let attachment = value as? NSTextAttachment { result.append((range.location, attachment)) }
        }
        return result
    }

    private func labels(in view: NSView) -> [MTMathUILabel] {
        (view as? MTMathUILabel).map { [$0] } ?? view.subviews.flatMap { labels(in: $0) }
    }

    func testScaledReplacesMathAttachmentsWithoutChangingTheSource() throws {
        let rendered = MarkdownRenderer.render("本文 $ax+b$")
        let (_, original) = try XCTUnwrap(attachments(in: rendered).first)
        XCTAssertTrue(original is MarkdownMathAttachment)
        let bounds = original.bounds
        let scaled = PreviewTypography.scaled(rendered, by: 1.5)
        let (_, zoomed) = try XCTUnwrap(attachments(in: scaled).first)
        XCTAssertFalse(zoomed === original)
        XCTAssertEqual(zoomed.bounds.minX, bounds.minX * 1.5, accuracy: 0.0001)
        XCTAssertEqual(zoomed.bounds.minY, bounds.minY * 1.5, accuracy: 0.0001)
        XCTAssertEqual(zoomed.bounds.width, bounds.width * 1.5, accuracy: 0.0001)
        XCTAssertEqual(zoomed.bounds.height, bounds.height * 1.5, accuracy: 0.0001)
        XCTAssertTrue(zoomed.image === original.image)
        // 元の文字列（キャッシュしている場合がある）の添付は変えない。
        XCTAssertEqual(original.bounds, bounds)
        let (_, again) = try XCTUnwrap(attachments(in: rendered).first)
        XCTAssertTrue(again === original)
        // 倍率1では文字列をそのまま返す。
        XCTAssertTrue(PreviewTypography.scaled(rendered, by: 1) === rendered)
    }

    /// 実際の構造化プレビューで測った、インライン数式2つの `bounds` と、その前の文字の大きさ、数式ブロックのラベル。
    private struct Measured {
        var inline: [NSRect] = []
        var textFontSize: CGFloat = 0
        var blockFontSize: CGFloat = 0
        var blockSize: NSSize = .zero
    }

    private func measure(_ host: NSView, zoom: Double, file: StaticString = #filePath, line: UInt = #line) throws -> Measured {
        let view = try XCTUnwrap(PreviewLayoutTestSupport.textViews(in: host).first { $0.string.contains("\u{FFFC}") },
                                 file: file, line: line)
        let storage = try XCTUnwrap(view.textStorage, file: file, line: line)
        let manager = try XCTUnwrap(view.layoutManager, file: file, line: line)
        let container = try XCTUnwrap(view.textContainer, file: file, line: line)
        manager.ensureLayout(for: container)
        var result = Measured()
        let found = attachments(in: storage)
        XCTAssertEqual(found.count, 2, file: file, line: line)
        for (location, attachment) in found {
            XCTAssertTrue(attachment is MarkdownMathAttachment, file: file, line: line)
            result.inline.append(attachment.bounds)
            // 数式のベースラインは、直後の文字のベースラインと一致する。
            let glyph = manager.glyphIndexForCharacter(at: location)
            let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let mathBaseline = fragment.minY + manager.location(forGlyphAt: glyph).y + attachment.bounds.minY
            let textGlyph = manager.glyphIndexForCharacter(at: location + 2)
            let textBaseline = manager.lineFragmentRect(forGlyphAt: textGlyph, effectiveRange: nil).minY
                + manager.location(forGlyphAt: textGlyph).y
            XCTAssertEqual(mathBaseline, textBaseline, accuracy: 0.5, "zoom \(zoom)", file: file, line: line)
        }
        let font = try XCTUnwrap(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, file: file, line: line)
        result.textFontSize = font.pointSize
        let label = try XCTUnwrap(labels(in: host).first, file: file, line: line)
        result.blockFontSize = label.fontSize
        result.blockSize = label.fittingSize
        return result
    }

    func testMathFollowsZoomInThePreview() throws {
        var base = Measured()
        try PreviewLayoutTestSupport.hosted(PreviewLayoutTestSupport.preview(source, zoom: 1)) { host in
            base = try measure(host, zoom: 1)
        }
        XCTAssertEqual(base.textFontSize, MarkdownRenderer.bodyFontSize)
        for zoom in [0.8, 1.5] {
            let scale = CGFloat(zoom)
            try PreviewLayoutTestSupport.hosted(PreviewLayoutTestSupport.preview(source, zoom: zoom)) { host in
                let zoomed = try measure(host, zoom: zoom)
                XCTAssertEqual(zoomed.textFontSize, MarkdownRenderer.bodyFontSize * scale, accuracy: 0.001)
                for (rect, original) in zip(zoomed.inline, base.inline) {
                    XCTAssertEqual(rect.width, original.width * scale, accuracy: 0.001, "zoom \(zoom)")
                    XCTAssertEqual(rect.height, original.height * scale, accuracy: 0.001, "zoom \(zoom)")
                    XCTAssertEqual(rect.minY, original.minY * scale, accuracy: 0.001, "zoom \(zoom)")
                }
                // 周りの文字（倍率を掛けた大きさ）の1.2倍で組んだ場合と同じ大きさ（画像の切り上げの分だけ違う）。
                let typeset = try XCTUnwrap(MarkdownMathRenderer.image(
                    MarkdownMath.Formula(source: "", latex: "ax+b", display: false),
                    fontSize: MarkdownMathRenderer.fontSize(surrounding: zoomed.textFontSize)))
                XCTAssertEqual(zoomed.inline[0].width, typeset.size.width, accuracy: 1.5, "zoom \(zoom)")
                XCTAssertEqual(zoomed.inline[0].height, typeset.size.height, accuracy: 1.5, "zoom \(zoom)")
                // `$ax+b$` と `$\displaystyle ax+b$` と数式ブロックは同じ大きさ。
                XCTAssertEqual(zoomed.inline[0].size, zoomed.inline[1].size)
                XCTAssertEqual(zoomed.blockFontSize, MarkdownMathRenderer.fontSize(surrounding: 15) * scale,
                               accuracy: 0.001, "zoom \(zoom)")
                XCTAssertEqual(zoomed.blockSize.width, zoomed.inline[0].width, accuracy: 1.5, "zoom \(zoom)")
                XCTAssertEqual(zoomed.blockSize.height, zoomed.inline[0].height, accuracy: 1.5, "zoom \(zoom)")
            }
        }
    }

    /// 表示中のプレビューで倍率を変えると、インライン数式と数式ブロックの両方が新しい倍率で描き直される。
    /// 倍率を戻すと元の大きさに戻る（キャッシュした文字列を変えていない）。
    func testChangingZoomUpdatesAnExistingPreview() throws {
        try PreviewLayoutTestSupport.hosted(PreviewLayoutTestSupport.preview(source, zoom: 1)) { host in
            let base = try measure(host, zoom: 1)
            host.rootView = PreviewLayoutTestSupport.preview(source, zoom: 1.5)
            host.layoutSubtreeIfNeeded()
            let zoomed = try measure(host, zoom: 1.5)
            XCTAssertEqual(zoomed.inline[0].width, base.inline[0].width * 1.5, accuracy: 0.001)
            XCTAssertEqual(zoomed.blockFontSize, base.blockFontSize * 1.5, accuracy: 0.001)
            XCTAssertEqual(zoomed.blockSize.width, base.blockSize.width * 1.5, accuracy: 1.5)
            host.rootView = PreviewLayoutTestSupport.preview(source, zoom: 1)
            host.layoutSubtreeIfNeeded()
            let restored = try measure(host, zoom: 1)
            XCTAssertEqual(restored.inline, base.inline)
            XCTAssertEqual(restored.blockFontSize, base.blockFontSize)
        }
    }

    /// 倍率で広げた数式を2倍の画面に描いても、1倍の画素の画像を引き伸ばしたようにぼやけない。
    func testZoomedFormulaStaysCrisp() throws {
        let rendered = MarkdownRenderer.render("本文 $ax+b$")
        let (_, attachment) = try XCTUnwrap(attachments(in: PreviewTypography.scaled(rendered, by: 1.5)).first)
        let image = try XCTUnwrap(attachment.image)
        XCTAssertFalse(image.representations.contains { $0 is NSBitmapImageRep })
        func dark(_ drawn: NSImage) throws -> Int {
            let size = attachment.bounds.size
            let rep = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
            rep.size = size
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
            try XCTUnwrap(NSAppearance(named: .aqua)).performAsCurrentDrawingAppearance {
                drawn.draw(in: NSRect(origin: .zero, size: size))
            }
            NSGraphicsContext.restoreGraphicsState()
            return (0..<rep.pixelsHigh).reduce(0) { count, y in
                count + (0..<rep.pixelsWide).filter { x in
                    let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                    return ((color?.redComponent ?? 1) + (color?.greenComponent ?? 1) + (color?.blueComponent ?? 1)) / 3 < 0.35
                }.count
            }
        }
        let png = try XCTUnwrap(MarkdownMathRenderer.pngData(image, density: 1))
        let lowResolution = try XCTUnwrap(NSImage(data: png))
        let sharp = try dark(image), stretched = try dark(lowResolution)
        XCTAssertGreaterThan(Double(sharp), Double(stretched) * 1.4, "sharp \(sharp) vs stretched \(stretched)")
    }
}
