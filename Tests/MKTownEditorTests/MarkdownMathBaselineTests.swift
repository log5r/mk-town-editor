import AppKit
import SwiftUI
import SwiftMath
import WebKit
import XCTest
@testable import MKTownEditor

/// 数式の文字の大きさ（周りの文字の1.2倍、`\displaystyle` によらない）と、数式のベースラインの位置（issue #97）。
/// docs/math-font-size-and-baseline.md
@MainActor
final class MarkdownMathBaselineTests: XCTestCase {
    private func inline(_ latex: String) -> MarkdownMath.Formula {
        MarkdownMath.Formula(source: "$\(latex)$", latex: latex, display: false)
    }

    private func block(_ latex: String) -> MarkdownMath.Formula {
        MarkdownMath.Formula(source: "$$\(latex)$$", latex: latex, display: true)
    }

    private func attachments(in text: NSAttributedString) -> [NSTextAttachment] {
        var result: [NSTextAttachment] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { result.append(attachment) }
        }
        return result
    }

    // MARK: - 数式の文字の大きさ（1つの規則）

    /// 周りの文字の大きさ（プレビューの本文は15pt）。
    private let body = MarkdownRenderer.bodyFontSize

    func testFontSizeIsSurroundingSizeTimesOnePointTwo() {
        XCTAssertEqual(MarkdownMathRenderer.fontScale, 1.2)
        XCTAssertEqual(MarkdownRenderer.bodyFontSize, 15)
        XCTAssertEqual(MarkdownMathRenderer.fontSize(surrounding: 15), 18, accuracy: 0.0001)
        XCTAssertEqual(MarkdownMathRenderer.fontSize(surrounding: 16), 19.2, accuracy: 0.0001)
        XCTAssertEqual(MarkdownMathRenderer.fontSize(surrounding: 24), 28.8, accuracy: 0.0001)
    }

    /// 1つの段落の `$ax+b$`・`$\displaystyle ax+b$` と、続く `$$ax+b$$` は同じ大きさの文字で描く。
    /// `ax+b` は書体（`\displaystyle`）で組み方が変わらない式なので、画像の大きさも一致する。
    func testPreviewDrawsInlineDisplayStyleInlineAndBlockAtOneSize() throws {
        let rendered = MarkdownRenderer.render("本文 $ax+b$ と $\\displaystyle ax+b$\n\n$$\nax+b\n$$")
        let sizes = attachments(in: rendered).compactMap { $0.image?.size }
        XCTAssertEqual(sizes.count, 3)
        let expected = try XCTUnwrap(MarkdownMathRenderer.image(inline("ax+b"), fontSize: body * 1.2)).size
        XCTAssertEqual(sizes, [expected, expected, expected])
        // 小さい文字で描いた場合（従来のインライン数式の15pt）より大きい。
        let unscaled = try XCTUnwrap(MarkdownMathRenderer.image(inline("ax+b"), fontSize: body)).size
        XCTAssertGreaterThan(expected.width, unscaled.width)
    }

    /// 構造化プレビューは数式ブロックを `MarkdownMathView`（`MTMathUILabel`）で描く。その大きさも本文の1.2倍。
    func testStructuredPreviewBlockMathUsesTheSameSize() throws {
        try PreviewLayoutTestSupport.hosted(PreviewLayoutTestSupport.preview("本文 $ax+b$\n\n$$\nax+b\n$$")) { host in
            func labels(in view: NSView) -> [MTMathUILabel] {
                (view as? MTMathUILabel).map { [$0] } ?? view.subviews.flatMap { labels(in: $0) }
            }
            let label = try XCTUnwrap(labels(in: host).first)
            XCTAssertEqual(label.fontSize, body * 1.2, accuracy: 0.0001)
            let inlineView = try XCTUnwrap(PreviewLayoutTestSupport.textViews(in: host)
                .first { $0.string.contains("\u{FFFC}") })
            let location = (inlineView.string as NSString).range(of: "\u{FFFC}").location
            let attachment = try XCTUnwrap(inlineView.attributedString().attribute(
                .attachment, at: location, effectiveRange: nil) as? NSTextAttachment)
            let inlineSize = try XCTUnwrap(attachment.image?.size)
            // 画像は整数に切り上げているため、ラベルの大きさも切り上げて比べる。
            XCTAssertEqual(ceil(label.fittingSize.width), inlineSize.width)
            XCTAssertEqual(ceil(label.fittingSize.height), inlineSize.height)
        }
    }

    func testHeadingInlineMathFollowsHeadingSize() throws {
        let rendered = MarkdownRenderer.render("# 見出し $ax+b$")
        let font = try XCTUnwrap(rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(font.pointSize, body)
        let size = try XCTUnwrap(attachments(in: rendered).first?.image?.size)
        XCTAssertEqual(size, try XCTUnwrap(MarkdownMathRenderer.image(inline("ax+b"), fontSize: font.pointSize * 1.2)).size)
    }

    /// `\displaystyle` は組み方（分数の大きさ）だけを変え、文字の大きさは変えない。
    func testDisplayStyleChangesOnlyTheTeXStyle() throws {
        let rendered = MarkdownRenderer.render(#"確率 $\displaystyle\frac{1}{k}$ と $\frac{1}{k}$ で当選する。"#)
        let sizes = attachments(in: rendered).compactMap { $0.image?.size }
        XCTAssertEqual(sizes.count, 2)
        // どちらも本文の1.2倍の文字で描く。
        XCTAssertEqual(sizes[0], try XCTUnwrap(MarkdownMathRenderer.image(inline(#"\displaystyle\frac{1}{k}"#),
                                                                         fontSize: body * 1.2)).size)
        XCTAssertEqual(sizes[1], try XCTUnwrap(MarkdownMathRenderer.image(inline(#"\frac{1}{k}"#),
                                                                         fontSize: body * 1.2)).size)
        // 表示用の書体の分数は分子・分母を小さくしないため、高い。
        XCTAssertGreaterThan(sizes[0].height, sizes[1].height + 5)
    }

    // MARK: - ベースライン

    /// 数式の画像の中で、行のすべての列に色がある（分数の横線の）行の中央の、画像の下端からの高さ。
    private func fractionRuleHeight(in image: NSImage) throws -> CGFloat {
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let scale = CGFloat(bitmap.pixelsHigh) / image.size.height
        let rows = (0..<bitmap.pixelsHigh).filter { y in
            (0..<bitmap.pixelsWide).allSatisfy { x in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 }
        }
        let first = try XCTUnwrap(rows.first, "Fraction rule not found")
        let last = try XCTUnwrap(rows.last)
        // ビットマップの行は上から数える。
        return CGFloat(bitmap.pixelsHigh) / scale - CGFloat(first + last + 1) / 2 / scale
    }

    /// 色のある一番下の行の下端の、画像の下端からの高さ。
    private func inkBottom(in image: NSImage) throws -> CGFloat {
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let scale = CGFloat(bitmap.pixelsHigh) / image.size.height
        let last = try XCTUnwrap((0..<bitmap.pixelsHigh).last { y in
            (0..<bitmap.pixelsWide).contains { x in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 }
        })
        return CGFloat(bitmap.pixelsHigh - 1 - last) / scale
    }

    func testAttachmentPlacesFormulaBaselineOnTextBaseline() throws {
        for latex in ["x", "E = mc^2", "x_i", #"\frac{a}{b}"#, #"\displaystyle\frac{1}{k}"#,
                      #"\lim_{k\to\infty} P_k"#, "-"] {
            let formula = inline(latex)
            let size = MarkdownMathRenderer.fontSize(surrounding: body)
            let rendered = try XCTUnwrap(MarkdownMathRenderer.render(formula, fontSize: size), latex)
            let string = try XCTUnwrap(MarkdownMathRenderer.attachment(formula, fontSize: size), latex)
            let attachment = try XCTUnwrap(string.attribute(.attachment, at: 0, effectiveRange: nil)
                as? NSTextAttachment, latex)
            XCTAssertEqual(attachment.bounds.minY, -rendered.baseline, accuracy: 0.001, latex)
            XCTAssertEqual(attachment.bounds.size, rendered.image.size, latex)
            XCTAssertGreaterThanOrEqual(rendered.baseline, 0, latex)
            XCTAssertLessThanOrEqual(rendered.baseline, rendered.image.size.height, latex)
            // HTMLの `width`・`height` で拡大縮小されないよう、画像の大きさは整数にする。
            XCTAssertEqual(rendered.image.size.width, rendered.image.size.width.rounded(), latex)
            XCTAssertEqual(rendered.image.size.height, rendered.image.size.height.rounded(), latex)
        }

        // `x` はベースラインの上に乗り、ほとんど下げない（以前は一律に2pt下げていた）。
        let x = try XCTUnwrap(MarkdownMathRenderer.render(inline("x"), fontSize: body * 1.2))
        XCTAssertLessThan(x.baseline, 1.5)
        XCTAssertEqual(try inkBottom(in: x.image), x.baseline, accuracy: 1.5)

        // 分数は分母がベースラインの下に出る。横線は数式の軸（ベースラインの約0.25em上）に来る。
        let fraction = inline(#"\displaystyle\frac{1}{k}"#)
        let fractionSize = MarkdownMathRenderer.fontSize(surrounding: body)
        let rendered = try XCTUnwrap(MarkdownMathRenderer.render(fraction, fontSize: fractionSize))
        XCTAssertGreaterThan(rendered.baseline, rendered.image.size.height * 0.25)
        XCTAssertGreaterThan(rendered.baseline, 8)
        let axis = try fractionRuleHeight(in: rendered.image) - rendered.baseline
        XCTAssertGreaterThan(axis, fractionSize * 0.1)
        XCTAssertLessThan(axis, fractionSize * 0.45)

        // `\lim` の下付きはベースラインの下に出る。
        let limit = try XCTUnwrap(MarkdownMathRenderer.render(inline(#"\lim_{k\to\infty} P_k"#), fontSize: body * 1.2))
        XCTAssertGreaterThan(limit.baseline, 2)
    }

    // MARK: - 行の高さ（実際のプレビュー）

    /// 背の高いインライン数式を段落の途中の行に置き、数式が前後の行に重ならないこと、
    /// 数式のベースラインが同じ行の文字のベースラインと一致すること、ビューの高さが数式の分だけ増えることを確かめる。
    func testTallInlineFormulaGetsItsOwnLineHeightInPreview() throws {
        let before = String(repeating: "前", count: 50)
        let after = String(repeating: "後", count: 80)
        let source = "\(before) 確率 $\\displaystyle\\frac{1}{k}$ で当選する\(after)"
        for zoom in [1.0, 1.5] {
            try PreviewLayoutTestSupport.hosted(PreviewLayoutTestSupport.preview(source, zoom: zoom)) { host in
                let view = try XCTUnwrap(PreviewLayoutTestSupport.textViews(in: host)
                    .first { $0.string.contains("\u{FFFC}") }, "zoom \(zoom)")
                let manager = try XCTUnwrap(view.layoutManager)
                let container = try XCTUnwrap(view.textContainer)
                manager.ensureLayout(for: container)
                let storage = try XCTUnwrap(view.textStorage)
                let location = (view.string as NSString).range(of: "\u{FFFC}").location
                let attachment = try XCTUnwrap(storage.attribute(.attachment, at: location,
                                                                  effectiveRange: nil) as? NSTextAttachment)
                XCTAssertLessThan(attachment.bounds.minY, -8, "zoom \(zoom)")

                var lines: [(rect: NSRect, used: NSRect, glyphs: NSRange)] = []
                manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) {
                    rect, used, _, glyphs, _ in lines.append((rect, used, glyphs))
                }
                let glyph = manager.glyphIndexForCharacter(at: location)
                let index = try XCTUnwrap(lines.firstIndex { NSLocationInRange(glyph, $0.glyphs) })
                XCTAssertGreaterThan(index, 0, "The formula must be on a middle line (zoom \(zoom))")
                XCTAssertLessThan(index, lines.count - 1, "The formula must be on a middle line (zoom \(zoom))")

                // 添付の位置（`location(forGlyphAt:)`）は画像の下端。数式のベースラインはそこから `bounds.minY` 上。
                let line = lines[index]
                let size = manager.attachmentSize(forGlyphAt: glyph)
                let bottom = line.rect.minY + manager.location(forGlyphAt: glyph).y
                let imageRect = NSRect(x: line.rect.minX + manager.location(forGlyphAt: glyph).x,
                                       y: bottom - size.height, width: size.width, height: size.height)
                let mathBaseline = bottom + attachment.bounds.minY
                let textGlyph = manager.glyphIndexForCharacter(at: location + 2) // 「で」
                XCTAssertTrue(NSLocationInRange(textGlyph, line.glyphs))
                let textBaseline = line.rect.minY + manager.location(forGlyphAt: textGlyph).y
                XCTAssertEqual(mathBaseline, textBaseline, accuracy: 0.5, "zoom \(zoom)")

                // 前後の行の文字に重ならない。
                XCTAssertGreaterThanOrEqual(imageRect.minY, lines[index - 1].used.maxY - 0.5, "zoom \(zoom)")
                XCTAssertLessThanOrEqual(imageRect.maxY, lines[index + 1].used.minY + 0.5, "zoom \(zoom)")
                XCTAssertGreaterThanOrEqual(line.rect.height, size.height, "zoom \(zoom)")

                // 行の高さの増えた分が、ビューの高さと別のレイアウトでの測定（`HoverLinkTextMeasurer`）に入る。
                let used = manager.usedRect(for: container)
                XCTAssertGreaterThanOrEqual(view.frame.height, used.maxY - 0.5, "zoom \(zoom)")
                let extra = line.rect.height - lines[index - 1].rect.height
                // 数式は本文の1.2倍（18pt）。倍率1.5では文字も大きくなるため、広がる分は小さくなる（約10pt）。
                XCTAssertGreaterThan(extra, 5, "zoom \(zoom)")
                // 同じ文字列の数式を文字（`1/k`）に置き換えた場合より、少なくとも数式の行が広がった分だけ高い。
                let plain = NSMutableAttributedString(attributedString: view.attributedString())
                plain.replaceCharacters(in: NSRange(location: location, length: 1), with: NSAttributedString(
                    string: "1/k", attributes: plain.attributes(at: location + 2, effectiveRange: nil)))
                let plainHeight = HoverLinkTextMeasurer.usedRect(of: plain, width: container.size.width).height
                XCTAssertGreaterThanOrEqual(used.height, plainHeight + extra - 1, "zoom \(zoom)")
                let measured = HoverLinkTextMeasurer.usedRect(of: view.attributedString(), width: container.size.width)
                XCTAssertEqual(measured.height, used.height, accuracy: 0.5, "zoom \(zoom)")
            }
        }
    }

    // MARK: - HTML・PDF

    private func imageTags(in html: String) -> [String] {
        html.components(separatedBy: "<img class=\"math\"").dropFirst().map { $0.components(separatedBy: ">").first ?? "" }
    }

    private func attribute(_ name: String, in tag: String) -> String? {
        guard let range = tag.range(of: "\(name)=\"") else { return nil }
        return tag[range.upperBound...].components(separatedBy: "\"").first
    }

    /// 標準のプリセット（本文16px）では、インライン数式も数式ブロックも19.2で描く。
    private let htmlSize = MarkdownMathRenderer.fontSize(surrounding: CGFloat(MarkdownExportPreset.standard.fontSize))

    func testHTMLUsesOneSizeAndTheBaselineForInlineMath() throws {
        let html = MarkdownHTMLExporter.render(#"確率 $\displaystyle\frac{1}{k}$ と $\frac{1}{k}$ で当選する。"#)
        let tags = imageTags(in: html)
        XCTAssertEqual(tags.count, 2)
        XCTAssertFalse(html.contains("vertical-align:middle"))
        let display = try XCTUnwrap(MarkdownMathRenderer.render(inline(#"\displaystyle\frac{1}{k}"#), fontSize: htmlSize))
        let plain = try XCTUnwrap(MarkdownMathRenderer.render(inline(#"\frac{1}{k}"#), fontSize: htmlSize))
        XCTAssertEqual(attribute("style", in: tags[0]),
                       "vertical-align:\(MarkdownMathRenderer.cssLength(-display.baseline));max-width:none")
        XCTAssertEqual(attribute("style", in: tags[1]),
                       "vertical-align:\(MarkdownMathRenderer.cssLength(-plain.baseline));max-width:none")
        XCTAssertEqual(attribute("height", in: tags[0]), "\(Int(display.image.size.height))")
        XCTAssertEqual(attribute("height", in: tags[1]), "\(Int(plain.image.size.height))")
        // 数式ブロックは縮めてよい（`max-width:none` を付けない）。
        let blockTag = try XCTUnwrap(imageTags(in: MarkdownHTMLExporter.render("$$\n\\frac{1}{k}\n$$")).first)
        XCTAssertEqual(attribute("style", in: blockTag), "display:block;margin:1em auto")
    }

    func testHTMLKeepsBlockAndInlineFormulasApart() throws {
        // 同じ式・同じ大きさでも、数式ブロックとインライン数式は置き方（`style`）が異なる。
        let latex = "ax+b"
        let source = "$$\(latex)$$\n\n本文 $\(latex)$ と $\\displaystyle \(latex)$\n\n脚注[^1]\n\n[^1]: 脚注の $\(latex)$"
        let html = MarkdownHTMLExporter.render(source)
        let tags = imageTags(in: html)
        XCTAssertEqual(tags.count, 4)
        XCTAssertEqual(tags.filter { attribute("style", in: $0)?.hasPrefix("display:block") == true }.count, 1)
        XCTAssertEqual(tags.filter { attribute("style", in: $0)?.hasPrefix("vertical-align:-") == true ||
                                     attribute("style", in: $0)?.hasPrefix("vertical-align:0") == true }.count, 3)
        // 数式ブロック・本文のインライン数式・`\displaystyle` は同じ大きさ。脚注は脚注の文字に合わせて小さい。
        let found = sizes(of: tags)
        XCTAssertEqual(found[0], try expectedSize(block(latex), fontSize: htmlSize))
        XCTAssertEqual(found[1], found[0])
        XCTAssertEqual(found[2], found[0])
        XCTAssertEqual(found[3], try expectedSize(inline(latex), fontSize: MarkdownMathRenderer.fontSize(
            surrounding: 16 * MarkdownHTMLExporter.footnoteFontScale)))
    }

    func testHTMLAsyncMatchesSync() async throws {
        let source = #"確率 $\displaystyle\frac{1}{k}$ で当選する。"#
        let sync = MarkdownHTMLExporter.render(source)
        let async = try await MarkdownHTMLExporter.renderAsync(source)
        XCTAssertEqual(imageTags(in: async), imageTags(in: sync))
        XCTAssertEqual(imageTags(in: async).count, 1)
    }

    func testCSSLength() {
        XCTAssertEqual(MarkdownMathRenderer.cssLength(-14.717), "-14.72px")
        XCTAssertEqual(MarkdownMathRenderer.cssLength(-3), "-3px")
        XCTAssertEqual(MarkdownMathRenderer.cssLength(-0.001), "0")
        XCTAssertEqual(MarkdownMathRenderer.cssLength(-0.5), "-0.5px")
    }

    func testPDFPlacesInlineFormulaOnTextBaseline() throws {
        let info = MarkdownPDFExporter.printInfo(destination:
            URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("baseline.pdf"))
        let view = try MarkdownPDFExporter.printableView(#"確率 $\displaystyle\frac{1}{k}$ で当選する。"#,
                                                         documentURL: nil, printInfo: info)
        let storage = try XCTUnwrap(view.textStorage)
        let manager = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        manager.ensureLayout(for: container)
        let location = (storage.string as NSString).range(of: "\u{FFFC}").location
        XCTAssertNotEqual(location, NSNotFound)
        let attachment = try XCTUnwrap(storage.attribute(.attachment, at: location,
                                                          effectiveRange: nil) as? NSTextAttachment)
        // HTMLの `vertical-align` から読み込んだ下げ幅は、文字の `NSBaselineOffset` ではなく添付の位置に移す。
        XCTAssertNil(storage.attribute(.baselineOffset, at: location, effectiveRange: nil))
        let rendered = try XCTUnwrap(MarkdownMathRenderer.render(inline(#"\displaystyle\frac{1}{k}"#),
                                                                fontSize: htmlSize))
        XCTAssertEqual(attachment.bounds.minY, -rendered.baseline, accuracy: 0.01)
        XCTAssertEqual(attachment.bounds.size, rendered.image.size)

        let glyph = manager.glyphIndexForCharacter(at: location)
        let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let mathBaseline = line.minY + manager.location(forGlyphAt: glyph).y + attachment.bounds.minY
        let textGlyph = manager.glyphIndexForCharacter(at: location + 2) // 「で」
        let textBaseline = line.minY + manager.location(forGlyphAt: textGlyph).y
        XCTAssertEqual(mathBaseline, textBaseline, accuracy: 0.5)
        // 行の上側には、画像のベースラインより上の部分だけを取る（下げる前の高さを取らない）。
        let imageTop = line.minY + manager.location(forGlyphAt: glyph).y - rendered.image.size.height
        XCTAssertLessThan(imageTop - line.minY, 4)
    }

    func testImportedAttachmentAlignmentLeavesOtherImagesAlone() {
        let other = NSTextAttachment()
        other.image = NSImage(size: NSSize(width: 10, height: 10))
        let text = NSMutableAttributedString(attachment: other)
        text.append(NSAttributedString(string: "x", attributes: [.baselineOffset: -3]))
        MarkdownMathRenderer.alignImportedMathAttachments(in: text)
        XCTAssertTrue(text.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment === other)
        XCTAssertEqual(other.bounds, .zero)
        XCTAssertEqual(text.attribute(.baselineOffset, at: 1, effectiveRange: nil) as? Int, -3)
    }

    // MARK: - HTML：狭い幅でインライン数式を縮めない

    private final class LoadDelegate: NSObject, WKNavigationDelegate {
        let loaded: XCTestExpectation
        init(_ loaded: XCTestExpectation) { self.loaded = loaded }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
    }

    /// 書き出したHTMLを狭いWebKitのビューに置き、インライン数式の画像が元の大きさのまま、
    /// 数式のベースラインが本文のベースラインにそろうことを確かめる。数式ブロックは幅に合わせて縮む。
    func testInlineMathKeepsNaturalSizeAndBaselineOnNarrowPage() async throws {
        let latex = #"\sum_{k=1}^{n} \frac{1}{k^2} = 1 + \frac{1}{4} + \frac{1}{9} + \frac{1}{16} + \frac{1}{25} + \cdots + \frac{1}{n^2}"#
        let html = MarkdownHTMLExporter.render("和は $\(latex)$ となる。\n\n$$\(latex)$$")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        let loaded = expectation(description: "Exported HTML loaded")
        let delegate = LoadDelegate(loaded)
        webView.navigationDelegate = delegate
        webView.loadHTMLString(html, baseURL: nil)
        await fulfillment(of: [loaded], timeout: 15)
        // 中身のない inline-block の下端は、その行のベースラインになる。
        let script = """
        JSON.stringify([...document.querySelectorAll('img.math')].map(image => {
          const rect = image.getBoundingClientRect();
          // 画像と目印を同じ行に置いて測る（大きさは折り返しを止める前に測った値を使う）。
          const parent = image.parentElement;
          const width = parent.clientWidth;
          parent.style.whiteSpace = 'nowrap';
          const probe = document.createElement('span');
          probe.style.cssText = 'display:inline-block;width:0;height:0';
          image.after(probe);
          const bottom = image.getBoundingClientRect().bottom;
          const baseline = probe.getBoundingClientRect().bottom;
          probe.remove();
          parent.style.whiteSpace = '';
          return [rect.width, rect.height, +image.getAttribute('width'), +image.getAttribute('height'),
                  bottom - baseline, width];
        }))
        """
        let result = try await webView.evaluateJavaScript(script)
        let json = try XCTUnwrap(result as? String)
        let values = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[Double]])
        XCTAssertEqual(values.count, 2)
        let inlineImage = values[0], blockImage = values[1]
        // 前提：数式の画像は本文の幅より広い。
        XCTAssertGreaterThan(inlineImage[2], inlineImage[5])
        // インライン数式は元の大きさのまま。
        XCTAssertEqual(inlineImage[0], inlineImage[2], accuracy: 0.5)
        XCTAssertEqual(inlineImage[1], inlineImage[3], accuracy: 0.5)
        // 画像の下端は、ベースラインより `baseline`（`vertical-align` の値）だけ下にある。
        let rendered = try XCTUnwrap(MarkdownMathRenderer.render(inline(latex), fontSize: htmlSize))
        XCTAssertEqual(inlineImage[4], rendered.baseline, accuracy: 0.6)
        // 数式ブロックは本文の幅に合わせて縮む（従来どおり）。
        XCTAssertLessThanOrEqual(blockImage[0], blockImage[5] + 0.5)
        XCTAssertLessThan(blockImage[0], blockImage[2])
        withExtendedLifetime(delegate) {}
    }

    // MARK: - HTML：書き出す場所の文字の大きさ

    private func preset(fontSize: Int) -> MarkdownExportPreset {
        MarkdownExportPreset(id: UUID(), name: "\(fontSize)px", bodyWidth: 800, fontSize: fontSize,
                             font: .system, margin: 48, cover: false, tableOfContents: false)
    }

    /// `latex` を `fontSize` で描いたときの画像の大きさ（HTMLの `width`・`height`）。
    private func expectedSize(_ formula: MarkdownMath.Formula, fontSize: CGFloat,
                              file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        let image = try XCTUnwrap(MarkdownMathRenderer.image(formula, fontSize: fontSize), file: file, line: line)
        return ["\(Int(image.size.width))", "\(Int(image.size.height))"]
    }

    private func sizes(of tags: [String]) -> [[String]] {
        tags.map { [attribute("width", in: $0) ?? "", attribute("height", in: $0) ?? ""] }
    }

    func testStandardPresetDrawsAllBodyMathAt19Point2() throws {
        let html = MarkdownHTMLExporter.render("本文 $x^2+1$ と $\\displaystyle\\frac{1}{k}$\n\n$$\\frac{1}{k}$$")
        XCTAssertEqual(htmlSize, 19.2, accuracy: 0.0001)
        XCTAssertEqual(sizes(of: imageTags(in: html)), [
            try expectedSize(inline("x^2+1"), fontSize: htmlSize),
            try expectedSize(inline(#"\displaystyle\frac{1}{k}"#), fontSize: htmlSize),
            try expectedSize(block(#"\frac{1}{k}"#), fontSize: htmlSize)
        ])
    }

    func testLargerPresetScalesAllMath() async throws {
        let source = "本文 $ax+b$ と $\\displaystyle ax+b$\n\n$$ax+b$$\n\n# 見出し $ax+b$\n\n脚注[^1]\n\n[^1]: 脚注の $ax+b$"
        let large = preset(fontSize: 24)
        let size = MarkdownMathRenderer.fontSize(surrounding: 24)
        XCTAssertEqual(size, 28.8, accuracy: 0.0001)
        let expected = [
            try expectedSize(inline("ax+b"), fontSize: size),
            try expectedSize(inline("ax+b"), fontSize: size),
            try expectedSize(block("ax+b"), fontSize: size),
            // 見出し1は本文の2倍、脚注は0.9倍。
            try expectedSize(inline("ax+b"), fontSize: MarkdownMathRenderer.fontSize(surrounding: 24 * 2)),
            try expectedSize(inline("ax+b"), fontSize: MarkdownMathRenderer.fontSize(surrounding: 24 * 0.9))
        ]
        XCTAssertEqual(sizes(of: imageTags(in: MarkdownHTMLExporter.render(source, preset: large))), expected)
        let async = try await MarkdownHTMLExporter.renderAsync(source, preset: large)
        XCTAssertEqual(sizes(of: imageTags(in: async)), expected)
    }

    func testHeadingAndParagraphGetSeparateImagesForSameFormula() throws {
        let latex = #"\displaystyle x"#
        let html = MarkdownHTMLExporter.render("# 見出し $\(latex)$\n\n本文 $\(latex)$")
        let found = sizes(of: imageTags(in: html))
        XCTAssertEqual(found.count, 2)
        // 見出し1は本文の2倍（32px）なので、数式は38.4。本文は19.2。
        XCTAssertEqual(found[0], try expectedSize(inline(latex), fontSize: MarkdownMathRenderer.fontSize(surrounding: 16 * 2)))
        XCTAssertEqual(found[1], try expectedSize(inline(latex), fontSize: htmlSize))
        XCTAssertNotEqual(found[0], found[1])
    }

    /// 場所ごとに、集めた画像と埋め込むときのキーが一致すること（原文に戻らないこと）と、その場所の大きさで描くこと。
    func testEveryContextFindsItsMathImageAtTheContextSize() async throws {
        let latex = "x^2+1"
        let formula = inline(latex)
        var cases: [(source: String, scale: CGFloat)] = (1...6).map { level in
            (String(repeating: "#", count: level) + " 見出し $\(latex)$", MarkdownHTMLExporter.headingFontScale(level: level))
        }
        cases += [
            ("本文 $\(latex)$", 1),
            ("| 式 |\n| --- |\n| $\(latex)$ |", 1),
            ("| $\(latex)$ |\n| --- |\n| 値 |", 1),
            ("脚注[^1]\n\n[^1]: 脚注の $\(latex)$", MarkdownHTMLExporter.footnoteFontScale),
            ("- 項目 $\(latex)$", 1),
            ("1. 項目 $\(latex)$", 1),
            ("- [ ] タスク $\(latex)$", 1),
            ("- 項目\n  - 入れ子 $\(latex)$", 1),
            ("> 引用 $\(latex)$", 1),
            ("> [!NOTE]\n> 注記 $\(latex)$", 1),
            ("> # 引用の見出し $\(latex)$", MarkdownHTMLExporter.headingFontScale(level: 1)),
            ("用語\n: 定義 $\(latex)$", 1)
        ]
        for bodySize in [16, 24] {
            let preset = preset(fontSize: bodySize)
            for (source, scale) in cases {
                let expected = try expectedSize(formula,
                                                fontSize: MarkdownMathRenderer.fontSize(surrounding: CGFloat(bodySize) * scale))
                let asyncHTML = try await MarkdownHTMLExporter.renderAsync(source, preset: preset)
                for html in [MarkdownHTMLExporter.render(source, preset: preset), asyncHTML] {
                    XCTAssertFalse(html.contains("$\(latex)$"), "\(source) (\(bodySize)px)")
                    XCTAssertEqual(sizes(of: imageTags(in: html)), [expected], "\(source) (\(bodySize)px)")
                }
            }
        }
    }

    func testStylesheetUsesTheSameScalesAsMath() {
        let html = MarkdownHTMLExporter.render("本文")
        XCTAssertEqual(MarkdownHTMLExporter.headingFontScales, [2, 1.5, 1.17, 1, 0.83, 0.67])
        for rule in ["h1 { font-size: 2em; }", "h2 { font-size: 1.5em; }", "h3 { font-size: 1.17em; }",
                       "h4 { font-size: 1em; }", "h5 { font-size: 0.83em; }", "h6 { font-size: 0.67em; }",
                       "font-size: 0.9em; }"] {
            XCTAssertTrue(html.contains(rule), rule)
        }
        XCTAssertTrue(html.contains(".footnotes { margin-top: 2em; border-top: 1px solid #8888; font-size: 0.9em; }"))
    }
}
