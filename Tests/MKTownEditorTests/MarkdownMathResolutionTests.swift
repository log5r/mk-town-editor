import AppKit
import XCTest
@testable import MKTownEditor

/// 数式の画像を描く先の解像度で描くこと（Retinaの画面でぼやけない）と、HTMLのPNGの画素密度。
/// docs/math-font-size-and-baseline.md の「Retinaの画面でぼやける」
@MainActor
final class MarkdownMathResolutionTests: XCTestCase {
    private let fontSize = MarkdownMathRenderer.fontSize(surrounding: MarkdownRenderer.bodyFontSize)

    private func inline(_ latex: String) -> MarkdownMath.Formula {
        MarkdownMath.Formula(source: "$\(latex)$", latex: latex, display: false)
    }

    /// `image` を `scale` 倍の画素の白い背景に描いたビットマップ。
    private func draw(_ image: NSImage, scale: CGFloat, appearance: NSAppearance.Name = .aqua) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * scale), pixelsHigh: Int(image.size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = image.size
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        try XCTUnwrap(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
            image.draw(in: NSRect(origin: .zero, size: image.size))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func luminances(_ rep: NSBitmapImageRep) -> [CGFloat] {
        (0..<rep.pixelsHigh).flatMap { y in
            (0..<rep.pixelsWide).map { x in
                let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                return color.map { ($0.redComponent + $0.greenComponent + $0.blueComponent) / 3 } ?? 1
            }
        }
    }

    func testPreviewMathImageIsDrawnAtTheDestinationResolution() throws {
        let rendered = try XCTUnwrap(MarkdownMathRenderer.render(inline("ax+b"), fontSize: fontSize))
        // 画素の画像を持たない（描く先の解像度で描く）。
        XCTAssertFalse(rendered.image.representations.contains { $0 is NSBitmapImageRep })
        // 大きさとベースラインは、1倍の画素の画像で描いていたときと同じ。
        XCTAssertEqual(rendered.image.size, NSSize(width: 50, height: 14))
        XCTAssertEqual(rendered.baseline, 1.501, accuracy: 0.001)

        // 2倍の画面に描いた結果を、1倍の画素の画像を2倍に引き伸ばした場合（修正前）と比べる。
        let sharp = try draw(rendered.image, scale: 2)
        let png = try XCTUnwrap(MarkdownMathRenderer.pngData(rendered.image, density: 1))
        let lowResolution = try XCTUnwrap(NSImage(data: png))
        XCTAssertEqual(lowResolution.size, rendered.image.size)
        let stretched = try draw(lowResolution, scale: 2)
        XCTAssertEqual(sharp.pixelsWide, 100)
        let sharpDark = luminances(sharp).filter { $0 < 0.35 }.count
        let stretchedDark = luminances(stretched).filter { $0 < 0.35 }.count
        // 引き伸ばした画像は輪郭がぼやけ、濃い画素が少ない。描く先の解像度で描くと、濃い画素がずっと多い。
        XCTAssertGreaterThan(Double(sharpDark), Double(stretchedDark) * 1.4,
                             "sharp \(sharpDark) vs stretched \(stretchedDark)")
    }

    func testInlineAndDisplayStyleFormulasDrawIdentically() throws {
        // `\displaystyle` は `ax+b` の組み方を変えないため、同じ画像になる（濃さの違いは置く位置の端数による）。
        let plain = try XCTUnwrap(MarkdownMathRenderer.image(inline("ax+b"), fontSize: fontSize))
        let display = try XCTUnwrap(MarkdownMathRenderer.image(inline(#"\displaystyle ax+b"#), fontSize: fontSize))
        XCTAssertEqual(luminances(try draw(plain, scale: 2)), luminances(try draw(display, scale: 2)))
    }

    func testMathColorFollowsTheDrawingAppearance() throws {
        let image = try XCTUnwrap(MarkdownMathRenderer.image(inline("ax+b"), fontSize: fontSize))
        // ライトでは暗い文字、ダークでは明るい文字（`labelColor` を描くときに解決する）。
        let light = try draw(image, scale: 2, appearance: .aqua)
        XCTAssertLessThan(luminances(light).min() ?? 1, 0.3)
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 28, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = image.size
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        try XCTUnwrap(NSAppearance(named: .darkAqua)).performAsCurrentDrawingAppearance {
            image.draw(in: NSRect(origin: .zero, size: image.size))
        }
        NSGraphicsContext.restoreGraphicsState()
        // 透明な背景に描き、色のある画素の明るさを見る。
        let inked = (0..<rep.pixelsHigh).flatMap { y in (0..<rep.pixelsWide).compactMap { x -> CGFloat? in
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else {
                return nil
            }
            return (color.redComponent + color.greenComponent + color.blueComponent) / 3
        } }
        XCTAssertFalse(inked.isEmpty)
        XCTAssertGreaterThan(inked.max() ?? 0, 0.8)
    }

    func testHTMLEmbedsPNGAtThreeTimesThePixelDensity() throws {
        XCTAssertEqual(MarkdownMathRenderer.htmlPixelDensity, 3)
        let html = MarkdownHTMLExporter.render("本文 $ax+b$ と $\\displaystyle\\frac{1}{k}$\n\n$$\\frac{1}{k}$$")
        let tags = html.components(separatedBy: "<img class=\"math\"").dropFirst()
            .map { $0.components(separatedBy: ">").first ?? "" }
        XCTAssertEqual(tags.count, 3)
        for tag in tags {
            func value(_ name: String) -> String? {
                guard let range = tag.range(of: "\(name)=\"") else { return nil }
                return tag[range.upperBound...].components(separatedBy: "\"").first
            }
            let width = try XCTUnwrap(Int(value("width") ?? ""), tag)
            let height = try XCTUnwrap(Int(value("height") ?? ""), tag)
            let source = try XCTUnwrap(value("src"), tag)
            let data = try XCTUnwrap(Data(base64Encoded: String(source.dropFirst("data:image/png;base64,".count))))
            let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
            XCTAssertEqual(rep.pixelsWide, width * 3, tag)
            XCTAssertEqual(rep.pixelsHigh, height * 3, tag)
            // PNGの解像度の情報から、読み込み側は `width`・`height` と同じ大きさ（ポイント）を求められる。
            XCTAssertEqual(rep.size, NSSize(width: width, height: height), tag)
        }
    }

    func testPDFKeepsPointSizeAndExtraResolution() throws {
        let info = MarkdownPDFExporter.printInfo(destination:
            URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("resolution.pdf"))
        let view = try MarkdownPDFExporter.printableView(#"確率 $\displaystyle\frac{1}{k}$ で当選する。"#,
                                                         documentURL: nil, printInfo: info)
        let storage = try XCTUnwrap(view.textStorage)
        let location = (storage.string as NSString).range(of: "\u{FFFC}").location
        let attachment = try XCTUnwrap(storage.attribute(.attachment, at: location, effectiveRange: nil) as? NSTextAttachment)
        let htmlSize = MarkdownMathRenderer.fontSize(surrounding: CGFloat(MarkdownExportPreset.standard.fontSize))
        let rendered = try XCTUnwrap(MarkdownMathRenderer.render(inline(#"\displaystyle\frac{1}{k}"#), fontSize: htmlSize))
        // 置く大きさはポイント（HTMLの `width`・`height`）で、画素数（3倍）ではない。
        XCTAssertEqual(attachment.bounds.size, rendered.image.size)
        // 画像は3倍の画素を保つ。
        let pixels = try XCTUnwrap(attachment.image?.representations.map(\.pixelsWide).max())
        XCTAssertEqual(pixels, Int(rendered.image.size.width) * 3)
    }
}
