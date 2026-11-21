import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

/// 不具合: 構造化プレビュー（分割表示・テーマ・本文幅の指定時など）で、入れ子の箇条書きがすべて同じ深さで表示されていた。
/// 解析と描画は深さを段落スタイルの字下げとして持っていたが、SwiftUI の `Text` は段落スタイルの字下げを無視する。
/// プレビューは字下げを `PreviewIndentedText` で取り出し、行の余白（`PreviewIndentedLayout`）で表す。
final class PreviewListIndentTests: XCTestCase {
    private static let indentUnits: [(name: String, unit: String)] = [
        ("2 spaces", "  "), ("4 spaces", "    "), ("tab", "\t")
    ]

    private func listBlocks(_ analysis: MarkdownAnalysis) -> [MarkdownBlock] {
        analysis.blocks.filter {
            switch $0.kind {
            case .unorderedList, .orderedList: true
            default: false
            }
        }
    }

    @MainActor
    private func layout(_ block: MarkdownBlock, in analysis: MarkdownAnalysis,
                        showTaskPrefix: Bool = true) -> PreviewIndentedText {
        PreviewIndentedText.make(MarkdownRenderer.renderLeaf(block, in: analysis, showTaskPrefix: showTaskPrefix))
    }

    private func hasIndent(_ text: NSAttributedString) -> Bool {
        var found = false
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if let style = value as? NSParagraphStyle, style.firstLineHeadIndent != 0 || style.headIndent != 0 {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// 報告された文書と同じ形（見出し、`#` だけの行、段落、3階層の箇条書き）を、字下げの単位ごとに確かめる。
    @MainActor
    func testReportedOutlineKeepsNestingForEveryIndentUnit() {
        for (name, unit) in Self.indentUnits {
            let source = """
            # サンプルの見出し
            #
            段落の1行目。
            段落の2行目。

            - 親の項目:
            \(unit)- 1階層目の項目A
            \(unit)- 1階層目の項目B
            \(unit)\(unit)- 2階層目の項目
            \(unit)\(unit)\(unit)- 3階層目の項目
            \(unit)- 1階層目の項目C
            """
            let analysis = MarkdownAnalysis(source)
            // `#` だけの行は CommonMark では空の見出し（<h1></h1>）で、段落の一部ではない。
            XCTAssertEqual(analysis.blocks[0].kind, .heading(level: 1), name)
            XCTAssertEqual(analysis.blocks[1].kind, .heading(level: 1), name)
            XCTAssertEqual(analysis.blocks[1].content, "", name)
            XCTAssertEqual(analysis.blocks[2].kind, .paragraph, name)

            let items = listBlocks(analysis)
            XCTAssertEqual(items.map(\.nestingDepth), [0, 1, 1, 2, 3, 1], name)
            let layouts = items.map { layout($0, in: analysis) }
            XCTAssertEqual(layouts.map { $0.marker?.string }, Array(repeating: "•  ", count: 6), name)
            XCTAssertEqual(layouts.map(\.body.string).first, "親の項目:", name)
            for (item, value) in zip(items, layouts) {
                XCTAssertFalse(hasIndent(value.body), "\(name): \(value.body.string)")
                XCTAssertGreaterThan(value.markerWidth, 0, name)
                let sameDepth = zip(items, layouts).filter { $0.0.nestingDepth == item.nestingDepth }
                XCTAssertTrue(sameDepth.allSatisfy { $0.1.markerIndent == value.markerIndent }, name)
            }
            let indentByDepth = (0...3).map { depth in
                zip(items, layouts).first { $0.0.nestingDepth == depth }!.1.markerIndent
            }
            XCTAssertEqual(indentByDepth, indentByDepth.sorted(), name)
            XCTAssertEqual(Set(indentByDepth).count, 4, name)
        }
    }

    /// 2スペースの字下げで、親より2段深く書いた子も1段下の項目になる（コードブロックにならない）。
    @MainActor
    func testOverIndentedChildIsNestedOneLevelBelowItsParent() {
        let analysis = MarkdownAnalysis("- a\n  - b\n      - c")
        let items = listBlocks(analysis)
        XCTAssertEqual(items.map(\.content), ["a", "b", "c"])
        XCTAssertEqual(items.map(\.nestingDepth), [0, 1, 2])
        XCTAssertFalse(analysis.blocks.contains { $0.kind == .codeBlock })
        let indents = items.map { layout($0, in: analysis).markerIndent }
        XCTAssertLessThan(indents[0], indents[1])
        XCTAssertLessThan(indents[1], indents[2])
    }

    @MainActor
    func testOrderedAndUnorderedListsMixedAcrossFourLevels() {
        // 番号付きリストの本文は「1. 」の後ろ（3桁目）から始まるため、子はその位置以上に字下げする。
        // 2スペースでは CommonMark 上も入れ子にならないため、最小の字下げ・4スペース・タブで確かめる。
        let variants: [(name: String, levels: [String])] = [
            ("content column", ["", "   ", "     ", "        "]),
            ("4 spaces", ["", "    ", "        ", "            "]),
            ("tab", ["", "\t", "\t\t", "\t\t\t"])
        ]
        for (name, levels) in variants {
            let source = "1. one\n\(levels[1])- two\n\(levels[2])1. three\n\(levels[3])- four\n2. five"
            let analysis = MarkdownAnalysis(source)
            let items = listBlocks(analysis)
            XCTAssertEqual(items.map(\.nestingDepth), [0, 1, 2, 3, 0], name)
            let layouts = items.map { layout($0, in: analysis) }
            XCTAssertEqual(layouts.map { $0.marker?.string }, ["1.  ", "•  ", "1.  ", "•  ", "2.  "], name)
            XCTAssertEqual(layouts.map(\.body.string), ["one", "two", "three", "four", "five"], name)
            let indents = layouts.map(\.markerIndent)
            XCTAssertLessThan(indents[0], indents[1], name)
            XCTAssertLessThan(indents[1], indents[2], name)
            XCTAssertLessThan(indents[2], indents[3], name)
            XCTAssertEqual(indents[0], indents[4], name)
        }
    }

    /// タスクはチェックボックスを行頭記号の位置に置くため、記号を持たず深さだけを持つ。
    @MainActor
    func testTaskItemsKeepNestingWithoutTextPrefix() {
        let analysis = MarkdownAnalysis("- [ ] parent\n  - [x] child\n    1. [ ] numbered")
        let items = listBlocks(analysis)
        let layouts = items.map { layout($0, in: analysis, showTaskPrefix: false) }
        XCTAssertEqual(layouts.map { $0.marker?.string }, [nil, nil, "1.  "])
        XCTAssertEqual(layouts.map(\.body.string), ["parent", "child", "numbered"])
        XCTAssertLessThan(layouts[0].markerIndent, layouts[1].markerIndent)
        XCTAssertLessThan(layouts[1].markerIndent, layouts[2].markerIndent)
        XCTAssertFalse(layouts.contains { hasIndent($0.body) })
    }

    /// 明示的な改行の後の行と、項目の続きの段落は、行頭記号ではなく項目の本文の位置にそろう。
    @MainActor
    func testHardBreakAndContinuationParagraphAlignWithItemText() throws {
        let analysis = MarkdownAnalysis("- item  \n  second line\n\n  continuation")
        let itemLayout = layout(analysis.blocks[0], in: analysis)
        XCTAssertEqual(itemLayout.marker?.string, "•  ")
        XCTAssertEqual(itemLayout.body.string, "item\nsecond line")

        let continuation = try XCTUnwrap(analysis.blocks.first { $0.content == "continuation" })
        let continuationLayout = layout(continuation, in: analysis)
        XCTAssertNil(continuationLayout.marker)
        XCTAssertEqual(continuationLayout.bodyIndent, itemLayout.bodyIndent)
        XCTAssertFalse(hasIndent(continuationLayout.body))
    }

    /// リンクを含む項目は AppKit の `NSTextView` で描く。字下げを本文に残すと余白と二重になる。
    @MainActor
    func testLinkedItemKeepsLinkAndDropsParagraphIndent() {
        let analysis = MarkdownAnalysis("- parent\n  - [site](https://example.com)")
        let items = listBlocks(analysis)
        let child = layout(items[1], in: analysis)
        XCTAssertEqual(child.body.string, "site")
        XCTAssertNotNil(child.body.attribute(.link, at: 0, effectiveRange: nil))
        XCTAssertFalse(hasIndent(child.body))
        XCTAssertGreaterThan(child.markerIndent, layout(items[0], in: analysis).markerIndent)
    }

    /// プレビューの描画キャッシュは拡大とテーマを当てる。その後も行頭記号を見分けられる。
    @MainActor
    func testRenderCacheOutputKeepsMarkerWithZoomAndTheme() {
        let analysis = MarkdownAnalysis("- parent\n  - child")
        let cache = PreviewRenderCache()
        let layouts = listBlocks(analysis).map { block in
            PreviewIndentedText.make(cache.render(block, in: analysis, context: DocumentContext(fileURL: nil),
                                                  zoom: 1.5, theme: .preset(.githubDark)))
        }
        XCTAssertEqual(layouts.map { $0.marker?.string }, ["•  ", "•  "])
        XCTAssertLessThan(layouts[0].markerIndent, layouts[1].markerIndent)
    }

    // MARK: - SwiftUI の配置

    /// 白地に描いた画像で、指定した行の範囲にある最も左の濃い画素の位置を返す。
    @MainActor
    private func leftmostInk(_ view: some View, width: CGFloat, rows: ClosedRange<Int>? = nil) -> Int? {
        let renderer = ImageRenderer(content: view
            .frame(width: width, alignment: .leading)
            .background(Color.white)
            .environment(\.colorScheme, .light))
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: image)
        let range = rows ?? 0...(bitmap.pixelsHigh - 1)
        for x in 0..<bitmap.pixelsWide {
            for y in range where y < bitmap.pixelsHigh {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                   color.brightnessComponent < 0.5 { return x }
            }
        }
        return nil
    }

    @MainActor
    private func blackLayout(_ block: MarkdownBlock, in analysis: MarkdownAnalysis) -> PreviewIndentedText {
        let rendered = NSMutableAttributedString(attributedString:
            MarkdownRenderer.renderLeaf(block, in: analysis))
        rendered.addAttribute(.foregroundColor, value: NSColor.black,
                              range: NSRange(location: 0, length: rendered.length))
        return PreviewIndentedText.make(rendered)
    }

    @MainActor
    private func indentedView(_ layout: PreviewIndentedText) -> some View {
        PreviewIndentedLayout(layout: layout,
                              marker: { Text(AttributedString($0)) },
                              content: { Text(AttributedString($0)) })
    }

    /// 修正前は `Text(AttributedString(rendered))` で描き、深さに関係なく同じ位置から始まっていた。
    @MainActor
    func testIndentedLayoutDrawsDeeperItemsFurtherRight() throws {
        let analysis = MarkdownAnalysis("- parent\n  - child\n    - grandchild")
        let positions = try listBlocks(analysis).map { block in
            try XCTUnwrap(leftmostInk(indentedView(blackLayout(block, in: analysis)), width: 400))
        }
        XCTAssertEqual(positions.count, 3)
        XCTAssertGreaterThan(positions[1], positions[0] + 16)
        XCTAssertGreaterThan(positions[2], positions[1] + 16)
    }

    /// 実際の `MarkdownPreview`（見出しを含むため構造化プレビュー）で、リンクを含む項目の `NSTextView` の位置を比べる。
    /// 修正前はすべての項目が同じ位置に置かれ、字下げは `NSTextView` の中の段落スタイルだけで表していた。
    @MainActor
    func testHostedStructuredPreviewPlacesNestedItemsFurtherRight() throws {
        let source = """
        # 見出し

        - [a](https://example.com/a)
          - [b](https://example.com/b)
            1. [c](https://example.com/c)
        - [ ] [t](https://example.com/t)
          - [ ] [u](https://example.com/u)
        """
        let host = NSHostingView(rootView: MarkdownPreview(markdown: source,
                                                           documentContext: DocumentContext(fileURL: nil)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = window.contentView?.bounds ?? .zero
        host.layoutSubtreeIfNeeded()
        defer { window.contentView = nil }

        func textViews(in view: NSView) -> [NSTextView] {
            (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
        }
        let views = textViews(in: host)
        func originX(_ text: String) throws -> CGFloat {
            let view = try XCTUnwrap(views.first { $0.string == text }, "Missing text view for \(text)")
            // 余白と二重にならないよう、本文に段落スタイルの字下げを残さない。
            XCTAssertFalse(hasIndent(view.attributedString()), text)
            return view.convert(NSPoint.zero, to: host).x
        }
        let a = try originX("a"), b = try originX("b"), c = try originX("c")
        XCTAssertGreaterThan(b, a + 16)
        XCTAssertGreaterThan(c, b + 16)
        let t = try originX("t"), u = try originX("u")
        XCTAssertGreaterThan(u, t + 16)
    }

    /// 折り返した行は行頭記号の下ではなく、本文の左端から始まる。
    @MainActor
    func testWrappedLinesHangAtBodyIndent() throws {
        let analysis = MarkdownAnalysis("- " + Array(repeating: "wrap", count: 30).joined(separator: " "))
        let layout = blackLayout(analysis.blocks[0], in: analysis)
        let view = indentedView(layout)
        let firstLine = try XCTUnwrap(leftmostInk(view, width: 200, rows: 0...12))
        let laterLines = try XCTUnwrap(leftmostInk(view, width: 200, rows: 30...400))
        XCTAssertLessThanOrEqual(firstLine, Int(layout.markerIndent) + 6)
        XCTAssertGreaterThanOrEqual(laterLines, Int(layout.bodyIndent) - 2)
    }
}
