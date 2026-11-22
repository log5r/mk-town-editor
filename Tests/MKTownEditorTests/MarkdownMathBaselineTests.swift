import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import MKTownEditor

/// インライン数式の `\displaystyle` の大きさと、数式のベースラインの位置（issue #97）。
/// docs/inline-math-baseline-and-display-size.md
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

    // MARK: - 数式ブロックと同じ大きさで描く式の判定

    func testUsesDisplaySizeOnlyForLeadingDisplayStyle() {
        for latex in [#"\displaystyle\frac{1}{k}"#, #"\displaystyle \frac{1}{k}"#, #"  \displaystyle x"#,
                      #"\displaystyle"#, #"\displaystyle{x}"#, "\\displaystyle\n\\sum_k x_k"] {
            XCTAssertTrue(inline(latex).usesDisplaySize, latex)
        }
        for latex in [#"\displaystylefoo x"#, #"x + \displaystyle\frac{1}{k}"#, #"\dfrac{1}{k}"#,
                      #"{\displaystyle x}"#, #"\textstyle\frac{1}{k}"#, #"\frac{1}{k}"#, "x"] {
            XCTAssertFalse(inline(latex).usesDisplaySize, latex)
        }
        XCTAssertTrue(block("x").usesDisplaySize)
        XCTAssertTrue(block(#"\textstyle x"#).usesDisplaySize)
        // 本文から切り出したインライン数式でも判定する。
        let formulas = MarkdownMath.segments(#"確率 $\displaystyle\frac{1}{k}$ と $\frac{1}{k}$"#)
            .compactMap { segment -> MarkdownMath.Formula? in
                if case let .formula(formula) = segment { return formula }
                return nil
            }
        XCTAssertEqual(formulas.map(\.usesDisplaySize), [true, false])
    }

    func testFontSizeResolvesDisplaySizeAgainstSurroundingText() {
        let display = inline(#"\displaystyle\frac{1}{k}"#)
        let plain = inline(#"\frac{1}{k}"#)
        XCTAssertEqual(MarkdownMathRenderer.displayFontSize, 21)
        XCTAssertEqual(MarkdownMathRenderer.fontSize(for: display, inlineSize: 15), 21)
        XCTAssertEqual(MarkdownMathRenderer.fontSize(for: display, inlineSize: 16), 21)
        // 見出しのように周りの文字が大きければ、周りに合わせる。
        XCTAssertEqual(MarkdownMathRenderer.fontSize(for: display, inlineSize: 28), 28)
        XCTAssertEqual(MarkdownMathRenderer.fontSize(for: plain, inlineSize: 15), 15)
        XCTAssertEqual(MarkdownMathRenderer.fontSize(for: block("x"), inlineSize: 15), 21)
    }

    // MARK: - プレビューの大きさ

    func testInlineDisplayStyleRendersAtBlockSizeInPreview() throws {
        let rendered = MarkdownRenderer.render(#"確率 $\displaystyle\frac{1}{k}$ と $\frac{1}{k}$ で当選する。"#)
        let found = attachments(in: rendered)
        XCTAssertEqual(found.count, 2)
        let display = try XCTUnwrap(found.first?.image?.size)
        let plain = try XCTUnwrap(found.last?.image?.size)
        let blockImage = try XCTUnwrap(MarkdownMathRenderer.image(block(#"\frac{1}{k}"#),
                                                                  fontSize: MarkdownMathRenderer.displayFontSize))
        // `$$\frac{1}{k}$$` と同じ大きさで描く。
        XCTAssertEqual(display.height, blockImage.size.height, accuracy: 0.5)
        XCTAssertEqual(display.width, blockImage.size.width, accuracy: 0.5)
        XCTAssertGreaterThan(display.height, plain.height + 10)
        XCTAssertGreaterThan(display.width, plain.width)
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
            let size = MarkdownMathRenderer.fontSize(for: formula, inlineSize: 15)
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
        let x = try XCTUnwrap(MarkdownMathRenderer.render(inline("x"), fontSize: 15))
        XCTAssertLessThan(x.baseline, 1.5)
        XCTAssertEqual(try inkBottom(in: x.image), x.baseline, accuracy: 1.5)

        // 分数は分母がベースラインの下に出る。横線は数式の軸（ベースラインの約0.25em上）に来る。
        let fraction = inline(#"\displaystyle\frac{1}{k}"#)
        let fractionSize = MarkdownMathRenderer.fontSize(for: fraction, inlineSize: 15)
        let rendered = try XCTUnwrap(MarkdownMathRenderer.render(fraction, fontSize: fractionSize))
        XCTAssertGreaterThan(rendered.baseline, rendered.image.size.height * 0.25)
        XCTAssertGreaterThan(rendered.baseline, 8)
        let axis = try fractionRuleHeight(in: rendered.image) - rendered.baseline
        XCTAssertGreaterThan(axis, fractionSize * 0.1)
        XCTAssertLessThan(axis, fractionSize * 0.45)

        // `\lim` の下付きはベースラインの下に出る。
        let limit = try XCTUnwrap(MarkdownMathRenderer.render(inline(#"\lim_{k\to\infty} P_k"#), fontSize: 15))
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
                XCTAssertGreaterThan(extra, 10, "zoom \(zoom)")
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

    func testHTMLUsesBlockSizeAndBaselineForInlineDisplayStyle() throws {
        let html = MarkdownHTMLExporter.render(#"確率 $\displaystyle\frac{1}{k}$ と $\frac{1}{k}$ で当選する。"#)
        let tags = imageTags(in: html)
        XCTAssertEqual(tags.count, 2)
        let blockTag = try XCTUnwrap(imageTags(in: MarkdownHTMLExporter.render("$$\n\\frac{1}{k}\n$$")).first)
        XCTAssertEqual(attribute("height", in: tags[0]), attribute("height", in: blockTag))
        XCTAssertEqual(attribute("width", in: tags[0]), attribute("width", in: blockTag))
        XCTAssertGreaterThan(Int(attribute("height", in: tags[0]) ?? "") ?? 0,
                             Int(attribute("height", in: tags[1]) ?? "") ?? .max)
        XCTAssertFalse(html.contains("vertical-align:middle"))

        let display = inline(#"\displaystyle\frac{1}{k}"#)
        let rendered = try XCTUnwrap(MarkdownMathRenderer.render(display, fontSize: MarkdownMathRenderer.displayFontSize))
        XCTAssertEqual(attribute("style", in: tags[0]),
                       "vertical-align:\(MarkdownMathRenderer.cssLength(-rendered.baseline));max-width:none")
        XCTAssertTrue(attribute("style", in: tags[0])?.hasPrefix("vertical-align:-") == true)
        let plain = try XCTUnwrap(MarkdownMathRenderer.render(inline(#"\frac{1}{k}"#), fontSize: 16))
        XCTAssertEqual(attribute("style", in: tags[1]),
                       "vertical-align:\(MarkdownMathRenderer.cssLength(-plain.baseline));max-width:none")
        // 数式ブロックは縮めてよい（`max-width:none` を付けない）。
        XCTAssertEqual(attribute("style", in: blockTag), "display:block;margin:1em auto")
    }

    func testHTMLKeepsBlockAndInlineDisplaySizeFormulasApart() throws {
        // 同じ式・同じ大きさでも、数式ブロックとインライン数式は置き方（`style`）が異なる。
        let latex = #"\displaystyle\frac{1}{k}"#
        let source = "$$\(latex)$$\n\n確率 $\(latex)$ で当選する。\n\n脚注[^1]\n\n[^1]: 脚注の $\(latex)$"
        let html = MarkdownHTMLExporter.render(source)
        let tags = imageTags(in: html)
        XCTAssertEqual(tags.count, 3)
        XCTAssertEqual(tags.filter { attribute("style", in: $0)?.hasPrefix("display:block") == true }.count, 1)
        XCTAssertEqual(tags.filter { attribute("style", in: $0)?.hasPrefix("vertical-align:-") == true }.count, 2)
        // 脚注のインライン数式も数式ブロックと同じ大きさで描く。
        XCTAssertEqual(Set(tags.compactMap { attribute("height", in: $0) }).count, 1)
    }

    func testHTMLAsyncMatchesSyncForInlineDisplayStyle() async throws {
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
                                                                fontSize: MarkdownMathRenderer.displayFontSize))
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
        let rendered = try XCTUnwrap(MarkdownMathRenderer.render(inline(latex), fontSize: 16))
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

    func testStandardPresetKeepsBodyMathSizes() throws {
        let html = MarkdownHTMLExporter.render("本文 $x^2+1$ と $\\displaystyle\\frac{1}{k}$\n\n$$\\frac{1}{k}$$")
        XCTAssertEqual(sizes(of: imageTags(in: html)), [
            try expectedSize(inline("x^2+1"), fontSize: 16),
            try expectedSize(inline(#"\displaystyle\frac{1}{k}"#), fontSize: 21),
            try expectedSize(block(#"\frac{1}{k}"#), fontSize: 21)
        ])
    }

    func testLargerPresetScalesInlineAndBlockMath() async throws {
        let source = "本文 $x^2+1$ と $\\displaystyle\\frac{1}{k}$\n\n$$\\frac{1}{k}$$"
        let large = preset(fontSize: 24)
        let expected = [
            try expectedSize(inline("x^2+1"), fontSize: 24),
            // 数式ブロックは 21 × 24 / 16 = 31.5（丸めない）。
            try expectedSize(inline(#"\displaystyle\frac{1}{k}"#), fontSize: 31.5),
            try expectedSize(block(#"\frac{1}{k}"#), fontSize: 31.5)
        ]
        let sync = sizes(of: imageTags(in: MarkdownHTMLExporter.render(source, preset: large)))
        XCTAssertEqual(sync, expected)
        // 先頭の `\displaystyle` は、どの本文の大きさでも数式ブロックと同じ大きさになる。
        XCTAssertEqual(sync[1], sync[2])
        let async = try await MarkdownHTMLExporter.renderAsync(source, preset: large)
        XCTAssertEqual(sizes(of: imageTags(in: async)), expected)
        XCTAssertEqual(MarkdownMathRenderer.fontSize(for: inline(#"\displaystyle x"#), inlineSize: 24,
                                                     displaySize: 31.5), 31.5)
    }

    func testHeadingAndParagraphGetSeparateImagesForSameFormula() throws {
        let latex = #"\displaystyle x"#
        let html = MarkdownHTMLExporter.render("# 見出し $\(latex)$\n\n本文 $\(latex)$")
        let found = sizes(of: imageTags(in: html))
        XCTAssertEqual(found.count, 2)
        // 見出し1は本文の2倍（32px）で、数式ブロックの大きさ（21）より大きい。本文は21。
        XCTAssertEqual(found[0], try expectedSize(inline(latex), fontSize: 32))
        XCTAssertEqual(found[1], try expectedSize(inline(latex), fontSize: 21))
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
                let expected = try expectedSize(formula, fontSize: CGFloat(bodySize) * scale)
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
