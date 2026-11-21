import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

/// 構造化プレビューの表の罫線、コールアウトの縦線、リスト項目の間隔を、実際に描いた結果で確かめる。
@MainActor
final class PreviewBlockStyleTests: XCTestCase {
    private func structuredPreview(_ source: String) -> MarkdownPreview {
        PreviewLayoutTestSupport.preview(source, onRevealSource: { _ in })
    }

    /// `host` を描いた画像と、1ptあたりのピクセル数。
    private func bitmap(of host: NSView) throws -> (NSBitmapImageRep, CGFloat) {
        host.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return (rep, CGFloat(rep.pixelsWide) / host.bounds.width)
    }

    /// 画像は窓の背景を含まず、何も描いていないピクセルは透明になる。明るい背景（白）に重ねた色で比べる。
    private func onWhite(_ color: NSColor) -> NSColor {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        return NSColor.white.blended(withFraction: rgb.alphaComponent, of: rgb.withAlphaComponent(1)) ?? rgb
    }

    private func contrast(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int, against background: NSColor) -> Double {
        guard let color = rep.colorAt(x: x, y: y) else { return 1 }
        return PreviewTypography.contrastRatio(onWhite(color), onWhite(background))
    }

    /// 背景と見分けられるピクセルが縦に `minimumRun` 以上続く列（隣り合う列は1本と数える）。
    private func verticalLines(in rep: NSBitmapImageRep, minimumRun: Int, minimumContrast: Double) -> [Int] {
        let background = rep.colorAt(x: 1, y: 1) ?? .white
        var lines: [Int] = []
        for x in 0..<rep.pixelsWide {
            var run = 0, longest = 0
            for y in 0..<rep.pixelsHigh {
                run = contrast(rep, x, y, against: background) >= minimumContrast ? run + 1 : 0
                longest = max(longest, run)
            }
            if longest >= minimumRun, lines.last.map({ x - $0 > 2 }) ?? true { lines.append(x) }
            else if longest >= minimumRun { lines[lines.count - 1] = x }
        }
        return lines
    }

    func testTableBordersAreVisibleAgainstTheBackground() throws {
        let source = "| A | B |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |\n"
        try PreviewLayoutTestSupport.hosted(structuredPreview(source)) { host in
            let (rep, scale) = try bitmap(of: host)
            // 3行の表（1行34pt以上）の縦線は、左端・列の間・右端の3本。以前の罫線（文字色の20%の半分の太さ）は
            // 背景とのコントラストが足りず、1本も数えられない。
            let lines = verticalLines(in: rep, minimumRun: Int(90 * scale), minimumContrast: 1.5)
            XCTAssertEqual(lines.count, 3, "\(lines)")
        }
    }

    func testCalloutBarIsOneContinuousLine() throws {
        let source = "> [!note]\n> - あああ\n> - いいい\n> - ううう\n"
        try PreviewLayoutTestSupport.hosted(structuredPreview(source)) { host in
            let text = try PreviewLayoutTestSupport.textView(
                "\(MarkdownCalloutKind.note.title)\n•  あああ\n•  いいい\n•  ううう", in: host)
            XCTAssertFalse(text.string.contains("│"), "縦線は文字ではなく図形で引く")
            let frame = text.convert(text.bounds, to: host)
            let (rep, scale) = try bitmap(of: host)
            let top = host.isFlipped ? frame.minY : host.bounds.height - frame.maxY
            let rows = Int((top + 1) * scale)..<Int((top + frame.height - 1) * scale)
            // 本文の左（縦線の位置）と、縦線と本文の間（コールアウトの背景）。
            let barX = Int((frame.minX - PreviewQuoteBar.trailing - PreviewQuoteBar.lineWidth / 2) * scale)
            let fillX = Int((frame.minX - PreviewQuoteBar.trailing / 2) * scale)
            XCTAssertGreaterThan(rows.count, Int(60 * scale))
            for y in rows {
                let fill = try XCTUnwrap(rep.colorAt(x: fillX, y: y))
                XCTAssertGreaterThan(contrast(rep, barX, y, against: fill), 1.15, "縦線が y=\(y) で途切れている")
            }
        }
    }

    /// `view` の中の `needle` の左にある縦線の列が、`view` の高さの範囲で途切れないことを確かめる。
    private func assertContinuousBar(leftOf needle: String, in view: NSTextView, host: NSView,
                                     minimumHeight: CGFloat, file: StaticString = #filePath,
                                     line: UInt = #line) throws {
        let manager = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        let storage = try XCTUnwrap(view.textStorage)
        let (rep, scale) = try bitmap(of: host)
        let bars = PreviewQuoteBars.bars(in: storage, layoutManager: manager, container: container,
                                         characterRange: NSRange(location: 0, length: storage.length))
        XCTAssertFalse(bars.isEmpty, file: file, line: line)
        let textX = try PreviewLayoutTestSupport.position(of: needle, in: view)
        // 本文にいちばん近い（最も深い）縦線。
        let x = try XCTUnwrap(bars.map(\.rect.minX).filter { $0 < textX }.max(), file: file, line: line)
        let column = bars.filter { $0.rect.minX == x }
        let top = try XCTUnwrap(column.map(\.rect.minY).min()), bottom = try XCTUnwrap(column.map(\.rect.maxY).max())
        XCTAssertGreaterThanOrEqual(bottom - top, minimumHeight, file: file, line: line)
        let origin = view.textContainerOrigin
        var checked = 0
        var y = top + 1
        while y < bottom - 1 {
            let point = view.convert(NSPoint(x: origin.x + x + 0.5, y: origin.y + y), to: host)
            let px = Int(point.x * scale)
            let py = Int((host.isFlipped ? point.y : host.bounds.height - point.y) * scale)
            let fill = try XCTUnwrap(rep.colorAt(x: px + Int(4 * scale), y: py))
            XCTAssertGreaterThan(contrast(rep, px, py, against: fill), 1.15, "縦線が y=\(y) で途切れている",
                                 file: file, line: line)
            checked += 1
            y += 0.5
        }
        XCTAssertGreaterThan(checked, 20, file: file, line: line)
    }

    func testQuotePrefixKeepsItsTextAndColor() throws {
        let rendered = MarkdownRenderer.render("> a\n>\n> b\n", documentContext: DocumentContext(fileURL: nil))
        let aligned = PreviewAppKitIndent.aligned(rendered)
        // 文字は残り、位置合わせとコピーで得る文字列は変わらない。
        XCTAssertEqual(aligned.string, rendered.string)
        XCTAssertTrue(aligned.string.hasPrefix("│  "))
        // 文字色は変えない。記号の文字は表示のときだけ `HoverPreviewTextView` が隠す。
        let color = try XCTUnwrap(aligned.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        XCTAssertEqual(color, rendered.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        XCTAssertNotEqual(color, .clear)
        XCTAssertTrue(PreviewQuoteBars.containsBars(aligned))
        XCTAssertFalse(PreviewQuoteBars.containsBars(NSAttributedString(string: "│  a")),
                       "引用記号の属性のない文字は縦線にしない")
    }

    /// `HoverLinkText` と同じ設定の `HoverPreviewTextView`。
    private func hoverTextView(_ text: NSAttributedString, width: CGFloat = 480) -> HoverPreviewTextView {
        let view = HoverPreviewTextView(frame: NSRect(x: 0, y: 0, width: width, height: 2000))
        view.textContainer?.lineFragmentPadding = 0
        view.isEditable = false
        view.textStorage?.setAttributedString(text)
        return view
    }

    private func temporaryColor(_ view: NSTextView, at index: Int) -> NSColor? {
        view.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: index,
                                               effectiveRange: nil) as? NSColor
    }

    /// 不具合: 記号の文字を透明にした色を文字列に書いていたため、リッチテキストでコピーすると記号が透明のまま出ていた。
    func testQuotePrefixGlyphIsHiddenOnlyOnScreenAndRichTextCopyKeepsItsColor() throws {
        let rendered = MarkdownRenderer.render("> a\n>\n> b\n", documentContext: DocumentContext(fileURL: nil))
        let view = hoverTextView(PreviewAppKitIndent.aligned(rendered))
        view.viewWillDraw()
        // 表示では記号の文字を隠す（一時属性）。文字列の文字色は変えない。
        XCTAssertEqual(temporaryColor(view, at: 0), .clear)
        XCTAssertNotEqual(view.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .clear)
        XCTAssertNil(temporaryColor(view, at: 3), "本文の文字は隠さない")

        view.selectAll(nil)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PreviewBlockStyleTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        // コピー（`copy(_:)`）と同じく、書き出せるすべての種類で書き出す。
        XCTAssertTrue(view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes))
        let legacyRTF = NSPasteboard.PasteboardType("NeXT Rich Text Format v1.0 pasteboard type")
        let data = try XCTUnwrap(pasteboard.data(forType: .rtf) ?? pasteboard.data(forType: legacyRTF),
                                 "\(pasteboard.types ?? [])")
        let copied = try XCTUnwrap(NSAttributedString(rtf: data, documentAttributes: nil))
        XCTAssertEqual(copied.string, rendered.string)
        let color = try XCTUnwrap(copied.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        XCTAssertGreaterThan(color.alphaComponent, 0, "リッチテキストの引用記号が透明になっている")
    }

    func testQuoteGlyphHidingFollowsTextChanges() throws {
        let context = DocumentContext(fileURL: nil)
        let view = hoverTextView(PreviewAppKitIndent.aligned(MarkdownRenderer.render("> a\n", documentContext: context)))
        view.viewWillDraw()
        XCTAssertEqual(temporaryColor(view, at: 0), .clear)
        // 引用の位置が変わったら付け直し、前の位置の文字は隠さない。
        let moved = PreviewAppKitIndent.aligned(MarkdownRenderer.render("x\n\n> b\n", documentContext: context))
        view.textStorage?.setAttributedString(moved)
        view.viewWillDraw()
        let bar = (moved.string as NSString).range(of: "│").location
        XCTAssertNil(temporaryColor(view, at: 0))
        XCTAssertEqual(temporaryColor(view, at: bar), .clear)
        // 引用がなくなったら外す。
        view.textStorage?.setAttributedString(NSAttributedString(string: "plain text"))
        view.viewWillDraw()
        for index in 0..<view.string.count { XCTAssertNil(temporaryColor(view, at: index)) }
    }

    /// 引用の線を含まない文字列では `layoutManager` に触れず、TextKit 2 のまま描く。
    func testTextViewWithoutQuoteBarsKeepsTextKit2() throws {
        let view = hoverTextView(NSAttributedString(string: "plain text"))
        // 不具合: `draw(_:)` を上書きしていたため、作った時点で TextKit 1 になっていた。
        XCTAssertNotNil(view.textLayoutManager, "HoverPreviewTextView は TextKit 2 で始まる")
        view.viewWillDraw()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        XCTAssertNotNil(view.textLayoutManager)
    }

    func testQuoteBarsSpanWrappedLinesAndStopAtTheLastLineOfTheQuote() throws {
        let long = String(repeating: "あいうえお", count: 30)
        let rendered = MarkdownRenderer.render("> \(long)\n>\n> 次\n\n後ろの段落\n",
                                               documentContext: DocumentContext(fileURL: nil))
        let view = PreviewLayoutTestSupport.standaloneTextView(PreviewAppKitIndent.aligned(rendered), width: 300)
        let manager = try XCTUnwrap(view.layoutManager), container = try XCTUnwrap(view.textContainer)
        manager.ensureLayout(for: container)
        let storage = try XCTUnwrap(view.textStorage)
        let bars = PreviewQuoteBars.bars(in: storage, layoutManager: manager, container: container,
                                         characterRange: NSRange(location: 0, length: storage.length))
            .sorted { $0.rect.minY < $1.rect.minY }
        XCTAssertEqual(bars.count, 3)
        XCTAssertEqual(Set(bars.map(\.rect.minX)).count, 1)
        // 折り返した段落の線は1行より高く、次の段落の線と隙間なくつながる。
        XCTAssertGreaterThan(bars[0].rect.height, 40)
        XCTAssertEqual(bars[0].rect.maxY, bars[1].rect.minY, accuracy: 0.01)
        XCTAssertEqual(bars[1].rect.maxY, bars[2].rect.minY, accuracy: 0.01)
        // 引用の最後の行では、後ろの段落の間隔へはみ出さない。
        let lastLine = manager.lineFragmentRect(
            forGlyphAt: manager.glyphIndexForCharacter(at: (storage.string as NSString).range(of: "次").location),
            effectiveRange: nil)
        XCTAssertLessThan(bars[2].rect.maxY, lastLine.maxY)
    }

    /// 不具合: 右から左の文字で始まる引用は段落の向きが右から左になり、引用記号が右へ動いていた。線は1行目の記号の
    /// 位置から段落の全行へ伸ばすため、折り返した行の本文に重なり、同じ深さの隣の段落とも位置がずれていた。
    func testRightToLeftQuoteBarsStayContinuousAndDoNotOverlapText() throws {
        let hebrew = String(repeating: "שלום עולם ", count: 20)
        let rendered = MarkdownRenderer.render("> \(hebrew)\n>\n> English\n>\n> > \(hebrew)\n",
                                               documentContext: DocumentContext(fileURL: nil))
        let aligned = PreviewAppKitIndent.aligned(rendered)
        let view = PreviewLayoutTestSupport.standaloneTextView(aligned, width: 300)
        let manager = try XCTUnwrap(view.layoutManager), container = try XCTUnwrap(view.textContainer)
        manager.ensureLayout(for: container)
        let storage = try XCTUnwrap(view.textStorage)
        let bars = PreviewQuoteBars.bars(in: storage, layoutManager: manager, container: container,
                                         characterRange: NSRange(location: 0, length: storage.length))
        // 深さごとに1つの位置に並ぶ。浅い線は左、深い線は右。
        let columns = Set(bars.map(\.rect.minX)).sorted()
        XCTAssertEqual(columns.count, 2, "\(bars.map(\.rect))")
        XCTAssertLessThan(try XCTUnwrap(columns.last), 30, "引用記号は左に置く")
        // 浅い線は引用の全体を途切れずに通る。
        let outer = bars.filter { $0.rect.minX == columns[0] }.sorted { $0.rect.minY < $1.rect.minY }
        XCTAssertEqual(outer.count, 5)
        for (upper, lower) in zip(outer, outer.dropFirst()) {
            XCTAssertEqual(upper.rect.maxY, lower.rect.minY, accuracy: 0.01)
        }
        XCTAssertGreaterThan(outer[0].rect.height, 40, "折り返した段落")
        // 本文のどの文字とも重ならない。
        let source = storage.string as NSString
        var checked = 0
        for index in 0..<source.length where storage.attribute(.previewQuotePrefix, at: index, effectiveRange: nil) == nil {
            guard let scalar = UnicodeScalar(source.character(at: index)),
                  !CharacterSet.whitespacesAndNewlines.contains(scalar) else { continue }
            let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: index, length: 1),
                                            actualCharacterRange: nil)
            let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
            for bar in bars where bar.rect.intersects(rect) {
                XCTFail("縦線 \(bar.rect) が文字 \(index) \(rect) と重なる")
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 100)
    }

    /// 線が次の段落へ続くかは次の段落の引用の深さだけで決まる。対象の段落より後ろはレイアウトしない。
    func testQuoteBarsDoNotLayOutTheFollowingParagraph() throws {
        let long = String(repeating: "あいうえお", count: 2000)
        // 引用の中のリストの項目は、それぞれ引用記号を持つ段落になる。2つ目の項目は画面外まで続く長い段落。
        let rendered = MarkdownRenderer.render("> - 一\n> - \(long)\n", documentContext: DocumentContext(fileURL: nil))
        let storage = NSTextStorage(attributedString: PreviewAppKitIndent.aligned(rendered))
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        let source = storage.string as NSString
        let first = source.paragraphRange(for: NSRange(location: 0, length: 0))
        let bars = PreviewQuoteBars.bars(in: storage, layoutManager: manager, container: container,
                                         characterRange: NSRange(location: first.location, length: 1))
        XCTAssertEqual(bars.count, 1)
        // 次の段落に線が続くため、段落の高さいっぱいに伸ばす。
        let line = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        XCTAssertEqual(try XCTUnwrap(bars.first).rect.maxY, line.maxY, accuracy: 0.01)
        let longStart = source.range(of: "あいうえお").location
        XCTAssertLessThan(manager.firstUnlaidCharacterIndex(), longStart + 1000,
                          "画面外の長い段落までレイアウトしている")
    }

    func testNestedQuoteInsideCalloutDrawsContinuousBar() throws {
        let source = "> [!note]\n> 本文\n>\n> > 入れ子1\n> >\n> > 入れ子2\n> >\n> > 入れ子3\n"
        try PreviewLayoutTestSupport.hosted(structuredPreview(source)) { host in
            let view = try XCTUnwrap(PreviewLayoutTestSupport.textViews(in: host)
                .first { $0.string.contains("入れ子3") }, "入れ子の引用を含むコールアウトは NSTextView で描く")
            try assertContinuousBar(leftOf: "入れ子1", in: view, host: host, minimumHeight: 60)
        }
    }

    func testWholeDocumentPreviewDrawsContinuousQuoteBar() throws {
        let source = "> [!note]\n> 一\n>\n> 二\n>\n> 三\n"
        let preview = MarkdownPreview(markdown: source, documentContext: DocumentContext(fileURL: nil))
        try PreviewLayoutTestSupport.hosted(preview) { host in
            let view = try XCTUnwrap(PreviewLayoutTestSupport.textViews(in: host).first { $0.string.contains("三") })
            try assertContinuousBar(leftOf: "一", in: view, host: host, minimumHeight: 80)
        }
    }

    func testEmbeddedDocumentTextDrawsContinuousQuoteBar() throws {
        let analysis = MarkdownAnalysis("> 一\n>\n> 二\n>\n> 三\n")
        let segments = WorkspaceEmbedSegment.render(analysis, documentContext: DocumentContext(fileURL: nil))
        guard case let .text(text)? = segments.first else { return XCTFail("文章の部分がない") }
        let embedded = WorkspaceEmbedText(text: text, source: "", context: DocumentContext(fileURL: nil))
            .padding(20)
        try PreviewLayoutTestSupport.hosted(embedded) { host in
            let view = try XCTUnwrap(PreviewLayoutTestSupport.textViews(in: host).first)
            try assertContinuousBar(leftOf: "一", in: view, host: host, minimumHeight: 80)
        }
    }

    func testCalloutSegmentsCanOmitQuotePrefix() throws {
        let analysis = MarkdownAnalysis("> [!note]\n> body\n>\n> > nested\n")
        let callout = try XCTUnwrap(analysis.blocks.first { $0.calloutKind != nil })
        func text(quotesText: Bool) -> String {
            MarkdownRenderer.renderCalloutSegments(callout, in: analysis,
                documentContext: DocumentContext(fileURL: nil), quotesText: quotesText).map { segment in
                if case let .text(rendered) = segment { return rendered.string }
                return ""
            }.joined()
        }
        XCTAssertTrue(text(quotesText: true).hasPrefix("│  "))
        let plain = text(quotesText: false)
        XCTAssertFalse(plain.hasPrefix("│"))
        // 入れ子の引用の引用記号は残る。
        XCTAssertTrue(plain.contains("│  nested"), plain)
    }

    func testListItemSpacingMatchesInsideAndOutsideCallout() throws {
        let source = "> [!note]\n> - あああ\n> - いいい\n> - ううう\n\n- かかか\n- ききき\n- くくく\n"
        try PreviewLayoutTestSupport.hosted(structuredPreview(source)) { host in
            let callout = try PreviewLayoutTestSupport.textView(
                "\(MarkdownCalloutKind.note.title)\n•  あああ\n•  いいい\n•  ううう", in: host)
            let manager = try XCTUnwrap(callout.layoutManager)
            var lineTops: [CGFloat] = []
            manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) {
                rect, _, _, _, _ in lineTops.append(rect.minY)
            }
            XCTAssertEqual(lineTops.count, 4)
            let inside = lineTops[2] - lineTops[1]
            XCTAssertEqual(lineTops[3] - lineTops[2], inside, accuracy: 0.01)

            let tops = try ["•  かかか", "•  ききき", "•  くくく"].map { item -> CGFloat in
                let view = try PreviewLayoutTestSupport.textView(item, in: host)
                let frame = view.convert(view.bounds, to: host)
                return host.isFlipped ? frame.minY : -frame.maxY
            }
            XCTAssertEqual(tops[1] - tops[0], inside, accuracy: 0.5)
            XCTAssertEqual(tops[2] - tops[1], inside, accuracy: 0.5)
            // `Text` で描く段落の行の間隔（約19pt）にそろえる。
            XCTAssertEqual(inside, 19, accuracy: 1)
        }
    }

    func testWrappedListLineUsesTheSameSpacingAsTheNextItem() throws {
        let long = String(repeating: "あいうえお", count: 40)
        let rendered = MarkdownRenderer.render("- \(long)\n- 次\n", documentContext: DocumentContext(fileURL: nil))
        let view = PreviewLayoutTestSupport.standaloneTextView(PreviewAppKitIndent.aligned(rendered), width: 300)
        let manager = try XCTUnwrap(view.layoutManager)
        manager.ensureLayout(for: try XCTUnwrap(view.textContainer))
        var heights: [CGFloat] = []
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) {
            rect, _, _, _, _ in heights.append(rect.height)
        }
        XCTAssertGreaterThan(heights.count, 2)
        // 最後の行を除き、折り返した行と項目の最後の行の高さは同じになる。
        XCTAssertEqual(Set(heights.dropLast().map { ($0 * 10).rounded() }).count, 1, "\(heights)")
    }
}
