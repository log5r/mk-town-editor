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

    // MARK: - 色を指定した部分（`\color`・`\textcolor`・`\colorbox`）

    private struct Pixel {
        let x: Int, red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat
        var isRed: Bool { alpha > 0.5 && red > 0.8 && green < 0.3 && blue < 0.3 }
        var isYellow: Bool { alpha > 0.5 && red > 0.85 && green > 0.85 && blue < 0.3 }
        var luminance: CGFloat { (red + green + blue) / 3 }
    }

    /// 透明な背景に描いた画素（色は不透明度で割り戻した値）。
    private func pixels(of rep: NSBitmapImageRep) -> [Pixel] {
        (0..<rep.pixelsHigh).flatMap { y in (0..<rep.pixelsWide).compactMap { x -> Pixel? in
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else {
                return nil
            }
            return Pixel(x: x, red: color.redComponent, green: color.greenComponent, blue: color.blueComponent,
                         alpha: color.alphaComponent)
        } }
    }

    /// `image` を `scale` 倍（既定は2倍）の画素の透明な背景に、`appearance` の外観で描く。
    private func drawTransparent(_ image: NSImage, appearance: NSAppearance.Name,
                                 scale: CGFloat = 2) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * scale), pixelsHigh: Int(image.size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = image.size
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        try XCTUnwrap(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
            image.draw(in: NSRect(origin: .zero, size: image.size))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// `\color{#FF0000}{x} + y` の `x` は赤のまま、`+ y` は外観に合わせた文字色で描く。
    private func assertColoredX(_ rep: NSBitmapImageRep, dark: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let inked = pixels(of: rep)
        let half = rep.pixelsWide / 2
        let red = inked.filter(\.isRed)
        XCTAssertGreaterThan(red.count, 10, "x must stay red", file: file, line: line)
        XCTAssertTrue(red.allSatisfy { $0.x < half }, "only x is red", file: file, line: line)
        let rest = inked.filter { $0.x >= half }
        XCTAssertGreaterThan(rest.count, 10, file: file, line: line)
        XCTAssertFalse(rest.contains(where: \.isRed), file: file, line: line)
        let darkest = rest.map(\.luminance).min() ?? 1, lightest = rest.map(\.luminance).max() ?? 0
        if dark {
            XCTAssertGreaterThan(lightest, 0.8, "+ y must be light in dark appearance", file: file, line: line)
        } else {
            XCTAssertLessThan(darkest, 0.3, "+ y must be dark in light appearance", file: file, line: line)
        }
    }

    /// `\colorbox{#FFFF00}{x}` は黄色の背景と、背景と異なる色の文字を描く。
    private func assertColorBox(_ rep: NSBitmapImageRep, dark: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let inked = pixels(of: rep)
        XCTAssertGreaterThan(inked.filter(\.isYellow).count, inked.count / 2, "yellow background", file: file, line: line)
        let glyph = inked.filter { !$0.isYellow && $0.alpha > 0.9 }
        if dark {
            XCTAssertTrue(glyph.contains { $0.luminance > 0.85 && $0.blue > 0.8 }, "light glyph", file: file, line: line)
        } else {
            XCTAssertTrue(glyph.contains { $0.luminance < 0.3 }, "dark glyph", file: file, line: line)
        }
    }

    func testExplicitColorsSurviveInEveryAppearance() throws {
        let colored = try XCTUnwrap(MarkdownMathRenderer.image(inline(#"\color{#FF0000}{x} + y"#), fontSize: fontSize))
        let textColored = try XCTUnwrap(MarkdownMathRenderer.image(inline(#"\textcolor{#FF0000}{x} + y"#),
                                                                   fontSize: fontSize))
        let box = try XCTUnwrap(MarkdownMathRenderer.image(inline(#"\colorbox{#FFFF00}{x}"#), fontSize: fontSize))
        for (appearance, dark) in [(NSAppearance.Name.aqua, false), (.darkAqua, true)] {
            assertColoredX(try drawTransparent(colored, appearance: appearance), dark: dark)
            assertColoredX(try drawTransparent(textColored, appearance: appearance), dark: dark)
            assertColorBox(try drawTransparent(box, appearance: appearance), dark: dark)
        }
        // 外観を戻しても既定の色の部分は戻る（色を設定し直す）。
        assertColoredX(try drawTransparent(colored, appearance: .aqua), dark: false)
    }

    func testHTMLKeepsExplicitColors() throws {
        let previous = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = previous }
        for (appearance, dark) in [(NSAppearance.Name.aqua, false), (.darkAqua, true)] {
            // HTMLの数式の既定の文字色は、書き出すときのアプリの外観で決まる（従来どおり）。
            NSApplication.shared.appearance = NSAppearance(named: appearance)
            for (latex, check) in [(#"\color{#FF0000}{x} + y"#, assertColoredX),
                                   (#"\colorbox{#FFFF00}{x}"#, assertColorBox)] {
                let html = try XCTUnwrap(MarkdownMathRenderer.htmlImage(inline(latex), fontSize: fontSize), latex)
                let source = try XCTUnwrap(html.components(separatedBy: "base64,").last?
                    .components(separatedBy: "\"").first)
                let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(Data(base64Encoded: source))))
                check(rep, dark, #filePath, #line)
            }
        }
    }

    /// 構造化プレビューで数式ブロックを描く `MTMathUILabel`（ビュー）と同じ画素になる。
    func testImageMatchesTheLiveLabelForColoredFormula() throws {
        let formula = inline(#"\color{#FF0000}{x} + \colorbox{#FFFF00}{y} + z"#)
        let rendered = try XCTUnwrap(MarkdownMathRenderer.render(formula, fontSize: fontSize))
        let label = try XCTUnwrap(MarkdownMathRenderer.label(formula, fontSize: fontSize))
        label.appearance = NSAppearance(named: .aqua)
        label.frame = NSRect(origin: .zero, size: rendered.image.size)
        try XCTUnwrap(NSAppearance(named: .aqua)).performAsCurrentDrawingAppearance {
            label.textColor = .labelColor
            label.needsLayout = true
            label.layoutSubtreeIfNeeded()
        }
        let live = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(rendered.image.size.width * 2),
            pixelsHigh: Int(rendered.image.size.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        live.size = rendered.image.size
        label.cacheDisplay(in: label.bounds, to: live)
        let drawn = try drawTransparent(rendered.image, appearance: .aqua)
        var largest: CGFloat = 0
        for y in 0..<live.pixelsHigh {
            for x in 0..<live.pixelsWide {
                let a = live.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                let b = drawn.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                let difference = [abs((a?.redComponent ?? 0) - (b?.redComponent ?? 0)),
                                  abs((a?.greenComponent ?? 0) - (b?.greenComponent ?? 0)),
                                  abs((a?.blueComponent ?? 0) - (b?.blueComponent ?? 0)),
                                  abs((a?.alphaComponent ?? 0) - (b?.alphaComponent ?? 0))].max() ?? 0
                largest = max(largest, difference)
            }
        }
        XCTAssertLessThan(largest, 0.05)
    }

    /// HTMLのPNGは、画像全体を3倍の画素で描く（画像の左下の一部に1倍で描かない）。
    func testHTMLPNGDrawsTheWholeFormulaAtThreeTimes() throws {
        let previous = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = previous }
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        for latex in ["ax+b", #"\displaystyle\frac{1}{k}"#, #"\color{#FF0000}{x} + y"#] {
            let image = try XCTUnwrap(MarkdownMathRenderer.image(inline(latex), fontSize: fontSize), latex)
            let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(MarkdownMathRenderer.pngData(image, density: 3))))
            let expected = try drawTransparent(image, appearance: .aqua, scale: 3)
            XCTAssertEqual(png.pixelsWide, expected.pixelsWide, latex)
            XCTAssertEqual(png.pixelsHigh, expected.pixelsHigh, latex)
            var largest: CGFloat = 0
            for y in 0..<png.pixelsHigh {
                for x in 0..<png.pixelsWide {
                    let a = png.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                    let b = expected.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                    largest = max(largest, abs((a?.alphaComponent ?? 0) - (b?.alphaComponent ?? 0)))
                }
            }
            XCTAssertLessThan(largest, 0.05, latex)
        }
    }
}
