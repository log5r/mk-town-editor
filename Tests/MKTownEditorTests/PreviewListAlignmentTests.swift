import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

/// 入れ子のリストの字下げの修正に対するレビュー指摘の再現テスト。
/// 埋め込み文書のコピー、コールアウト、本文が空のタスク、幅の広い行頭記号、引用の中のリストを確かめる。
final class PreviewListAlignmentTests: XCTestCase {
    // MARK: - 補助

    @MainActor
    private func textView(_ text: NSAttributedString, width: CGFloat = 480) -> NSTextView {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 2000))
        view.textStorage?.setAttributedString(text)
        return view
    }

    /// `needle` が現れるたびに、その先頭の文字の左端の位置を返す。
    @MainActor
    private func positions(of needle: String, in view: NSTextView) throws -> [CGFloat] {
        let manager = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        manager.ensureLayout(for: container)
        let source = view.string as NSString
        var result: [CGFloat] = []
        var location = 0
        while location < source.length {
            let range = source.range(of: needle, range: NSRange(location: location, length: source.length - location))
            guard range.location != NSNotFound else { break }
            let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: range.location, length: 1),
                                            actualCharacterRange: nil)
            result.append(manager.boundingRect(forGlyphRange: glyphs, in: container).minX)
            location = NSMaxRange(range)
        }
        return result
    }

    @MainActor
    private func position(of needle: String, in view: NSTextView) throws -> CGFloat {
        try XCTUnwrap(positions(of: needle, in: view).first, needle)
    }

    @MainActor
    private func hosted<Content: View>(_ view: Content, width: CGFloat = 600,
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

    @MainActor
    private func textViews(in view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
    }

    private func assertStrictlyIncreasing(_ values: [CGFloat], by step: CGFloat,
                                          file: StaticString = #filePath, line: UInt = #line) {
        for (previous, next) in zip(values, values.dropFirst()) {
            XCTAssertGreaterThan(next, previous + step, "\(values)", file: file, line: line)
        }
    }

    private func assertAllEqual(_ values: [CGFloat], accuracy: CGFloat = 0.5,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(values.isEmpty, file: file, line: line)
        for value in values {
            XCTAssertEqual(value, values[0], accuracy: accuracy, "\(values)", file: file, line: line)
        }
    }

    @MainActor
    private func embeddedText(_ source: String) throws -> NSAttributedString {
        let segments = WorkspaceEmbedSegment.render(MarkdownAnalysis(source),
                                                    documentContext: DocumentContext(fileURL: nil))
        XCTAssertEqual(segments.count, 1)
        guard case let .text(text) = segments.first else {
            XCTFail("Missing text segment: \(segments)")
            return NSAttributedString()
        }
        return text
    }

    // MARK: - 1. 埋め込み文書の範囲選択とコピー

    /// 不具合: 項目ごとに別の `Text` に分けたため、項目をまたいで選択できず、記号側は選択できなかった。
    /// チェックリストをコピーすると完了・未完了が落ちた。
    @MainActor
    func testEmbeddedTextSegmentIsOneStringWithMarkersAndTaskState() throws {
        let text = try embeddedText("- [ ] alpha task\n- [x] bravo task\n  - charlie\n\nAfter the list")
        XCTAssertEqual(text.string, "☐ 未完了  alpha task\n☑ 完了  bravo task\n•  charlie\n\nAfter the list")
    }

    @MainActor
    func testEmbeddedTextCopiesAcrossItemsIncludingMarkers() throws {
        let text = try embeddedText("- [ ] alpha task\n- [x] bravo task\n  - charlie")
        try hosted(WorkspaceEmbedText(text: text, source: "", context: DocumentContext(fileURL: nil))) { host in
            let views = textViews(in: host)
            XCTAssertEqual(views.count, 1, "区間全体が1つの選択面になる")
            let view = try XCTUnwrap(views.first)
            XCTAssertTrue(view.isSelectable)
            view.selectAll(nil)
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("PreviewListAlignmentTests-\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            // NSTextView は文字列を旧来の種類（NSStringPboardType）で書き出し、`.string` として読める。
            XCTAssertTrue(view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes))
            XCTAssertEqual(pasteboard.string(forType: .string),
                           "☐ 未完了  alpha task\n☑ 完了  bravo task\n•  charlie")
            // 引用の中のコードブロックの縦線と左端をそろえるため、行の余白を持たない。
            XCTAssertEqual(try position(of: "☐", in: view), 0, accuracy: 0.5)
            // 字下げは表示だけに効かせ、入れ子の項目は右にずれる。
            let bullets = try [position(of: "☐", in: view), position(of: "•", in: view)]
            assertStrictlyIncreasing(bullets, by: 16)
        }
    }

    // MARK: - 2. コールアウトの中の入れ子のリスト

    /// 不具合: コールアウトはまとめた文字列を `Text` で描き、入れ子のリストが平坦になっていた。
    @MainActor
    func testCalloutNestedListWithoutLinksIsIndented() throws {
        let source = "# Heading\n\n> [!NOTE]\n> - outer\n>   - inner\n>     - innermost"
        try hosted(MarkdownPreview(markdown: source, documentContext: DocumentContext(fileURL: nil))) { host in
            let view = try XCTUnwrap(textViews(in: host).first { $0.string.contains("innermost") },
                                     "コールアウトの入れ子のリストは NSTextView で描く")
            let bullets = try positions(of: "•", in: view)
            XCTAssertEqual(bullets.count, 3)
            assertStrictlyIncreasing(bullets, by: 16)
            // 見出しの行を含め、引用記号は字下げの影響を受けない。
            let bars = try positions(of: "│", in: view)
            XCTAssertEqual(bars.count, 4)
            assertAllEqual(bars)
        }
    }

    /// 入れ子のリストを含まないコールアウトは、これまでどおり `Text` で描く。
    func testCalloutWithoutListKeepsSwiftUIText() {
        let plain = NSAttributedString(string: "│  note", attributes: [.previewQuotePrefix: true])
        XCTAssertFalse(PreviewAppKitIndent.containsListIndent(plain))
    }

    // MARK: - 3. 本文が空のタスク

    /// 不具合: `- [ ]` だけの子タスクは記号を隠すと描画結果が空になり、チェックボックスが左端に置かれていた。
    @MainActor
    func testEmptyNestedTaskCheckboxAlignsWithLabeledSibling() {
        let analysis = MarkdownAnalysis("- [ ] top\n  - [ ]\n  - [ ] labeled")
        let tasks = analysis.blocks.filter { $0.task != nil }
        XCTAssertEqual(tasks.map(\.nestingDepth), [0, 1, 1])
        XCTAssertEqual(MarkdownRenderer.renderLeaf(tasks[1], in: analysis, showTaskPrefix: false).length, 0,
                       "空のタスクの描画結果からは字下げを読み取れない")
        let indents = tasks.map(PreviewIndentedText.taskCheckboxIndent(for:))
        XCTAssertEqual(indents[1], indents[2])
        XCTAssertGreaterThan(indents[1], indents[0])
        // チェックボックスは同じ深さの箇条書きの記号と同じ位置に置く。
        let labeled = PreviewIndentedText.make(
            MarkdownRenderer.renderLeaf(tasks[2], in: analysis, showTaskPrefix: false))
        XCTAssertEqual(indents[2], labeled.markerIndent)
    }

    // MARK: - 4. 幅の広い行頭記号

    func testMarkerColumnOverflowsLeftInsteadOfPushingBody() {
        XCTAssertEqual(PreviewMarkerColumn.markerOffset(markerWidth: 14, columnWidth: 20), 0)
        XCTAssertEqual(PreviewMarkerColumn.markerOffset(markerWidth: 20, columnWidth: 20), 0)
        XCTAssertEqual(PreviewMarkerColumn.markerOffset(markerWidth: 57, columnWidth: 20), -37)
    }

    /// 白地に描いた画像で、指定した行の範囲にある最も左の濃い画素の位置を返す。
    @MainActor
    private func leftmostInk(_ view: some View, rows: ClosedRange<Int>? = nil) -> Int? {
        let renderer = ImageRenderer(content: view
            .frame(width: 260, alignment: .leading)
            .padding(.leading, 60)
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

    /// 記号を白で描き、本文の左端だけを測る。
    @MainActor
    private func bodyOnlyView(_ block: MarkdownBlock, in analysis: MarkdownAnalysis) -> some View {
        let layout = PreviewIndentedText.make(MarkdownRenderer.renderLeaf(block, in: analysis))
        func colored(_ text: NSAttributedString, _ color: NSColor) -> NSAttributedString {
            let result = NSMutableAttributedString(attributedString: text)
            result.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: result.length))
            return result
        }
        return PreviewIndentedLayout(
            layout: PreviewIndentedText(markerIndent: layout.markerIndent, bodyIndent: layout.bodyIndent,
                                        marker: layout.marker.map { colored($0, .white) },
                                        body: colored(layout.body, .black)),
            marker: { Text(AttributedString($0)) }, content: { Text(AttributedString($0)) })
    }

    /// 不具合: 記号が列（20pt）より広いと本文が右へ押され、同じ項目の続きの段落とずれていた。
    @MainActor
    func testWideOrderedMarkerKeepsBodyAlignedWithContinuationInStructuredPreview() throws {
        let long = Array(repeating: "delta", count: 12).joined(separator: " ")
        let analysis = MarkdownAnalysis("9. alpha\n10. bravo\n12345. \(long)\n\n       continuation")
        let items = analysis.blocks.filter { if case .orderedList = $0.kind { true } else { false } }
        let continuation = try XCTUnwrap(analysis.blocks.first { $0.content == "continuation" })
        XCTAssertEqual(continuation.nestingDepth, 1)
        var edges = try items.map { try XCTUnwrap(leftmostInk(bodyOnlyView($0, in: analysis))) }
        edges.append(try XCTUnwrap(leftmostInk(bodyOnlyView(continuation, in: analysis))))
        for edge in edges {
            XCTAssertEqual(Double(edge), Double(edges[0]), accuracy: 2, "\(edges)")
        }
        // 幅の広い記号の項目の折り返した行も、1行目の本文と同じ位置から始まる。
        let wrapped = try XCTUnwrap(leftmostInk(bodyOnlyView(items[2], in: analysis), rows: 24...200))
        XCTAssertEqual(Double(wrapped), Double(edges[2]), accuracy: 2)
    }

    /// AppKit で描く箇所（全体を1つで描くプレビュー・コールアウト・埋め込み文書）も、本文の左端をそろえる。
    @MainActor
    func testWideOrderedMarkerKeepsBodyAlignedInAppKitText() throws {
        let rendered = MarkdownRenderer.render("9. alpha\n10. bravo\n\n    after bravo\n12345. charlie\n\n       after charlie")
        let view = textView(PreviewAppKitIndent.aligned(rendered))
        let alpha = try position(of: "alpha", in: view)
        // 列に収まる記号の項目と、その続きの段落は名目上の本文の位置にそろう。
        XCTAssertEqual(try position(of: "bravo", in: view), alpha, accuracy: 0.5)
        XCTAssertEqual(try position(of: "after bravo", in: view), alpha, accuracy: 0.5)
        // 行頭より左へはみ出せない記号では本文を右へずらし、続きの段落も同じ位置にそろえる。
        let charlie = try position(of: "charlie", in: view)
        XCTAssertEqual(try position(of: "after charlie", in: view), charlie, accuracy: 0.5)
        // 描画結果の文字列は変えない。
        XCTAssertEqual(view.string, rendered.string)
    }

    /// 埋め込み文書で、タスクの中の明示的な改行の後の行も、1行目の本文とそろう。
    @MainActor
    func testHardBreakInsideTaskAlignsWithItemTextInEmbeddedDocument() throws {
        // タスクの状態（`☐ 未完了  `）は記号の列より広く、最上位では本文を右へずらす。改行の後の行も同じ位置にそろえる。
        let view = textView(try embeddedText("- [ ] first line  \n  second line\n  - [x] nested  \n    next"))
        XCTAssertEqual(try position(of: "second line", in: view), try position(of: "first line", in: view),
                       accuracy: 0.5)
        XCTAssertEqual(try position(of: "next", in: view), try position(of: "nested", in: view), accuracy: 0.5)
        XCTAssertGreaterThan(try position(of: "☑", in: view), try position(of: "☐", in: view) + 16)
    }

    // MARK: - 5. 引用の中のリスト

    /// 不具合: 引用記号が行頭記号に含まれ、入れ子の項目では引用の縦線ごと右へずれていた。
    @MainActor
    func testQuotedNestedListKeepsQuoteBarsFixedInEmbeddedDocument() throws {
        let view = textView(try embeddedText("> - parent\n>   - child\n>     - grandchild\n>\n> plain"))
        assertAllEqual(try positions(of: "│", in: view))
        assertStrictlyIncreasing(try positions(of: "•", in: view), by: 16)
    }

    /// 全体を1つの `NSTextView` で描くプレビューでも同じ。修正前は段落スタイルを引用記号から取り、
    /// 引用の中の入れ子のリストがすべて同じ位置に並んでいた。
    @MainActor
    func testQuotedNestedListInWholeDocumentPreview() throws {
        let source = "> - parent\n>   - child\n>     - grandchild"
        try hosted(MarkdownPreview(markdown: source, documentContext: DocumentContext(fileURL: nil))) { host in
            let view = try XCTUnwrap(textViews(in: host).first { $0.string.contains("grandchild") })
            assertAllEqual(try positions(of: "│", in: view))
            assertStrictlyIncreasing(try positions(of: "•", in: view), by: 16)
        }
    }

    /// 構造化プレビューでは引用の縦線を行のビューが描き、リストの字下げはブロックの内側に置く。
    @MainActor
    func testStructuredPreviewDrawsQuoteBarsOutsideTheListIndent() throws {
        let source = "# Heading\n\n> - [parent](https://example.com/p)\n>   - [child](https://example.com/c)"
        let analysis = MarkdownAnalysis(source)
        let items = analysis.blocks.filter { $0.kind == .unorderedList }
        let index = PreviewLayoutIndex(analysis)
        XCTAssertEqual(items.map { index.quoteDepth(for: $0.id) }, [1, 1])
        for item in items {
            XCTAssertFalse(MarkdownRenderer.renderLeaf(item, in: analysis).string.contains("│"))
        }
        try hosted(MarkdownPreview(markdown: source, documentContext: DocumentContext(fileURL: nil))) { host in
            let views = textViews(in: host)
            let parent = try XCTUnwrap(views.first { $0.string == "parent" })
            let child = try XCTUnwrap(views.first { $0.string == "child" })
            XCTAssertGreaterThan(child.convert(NSPoint.zero, to: host).x,
                                 parent.convert(NSPoint.zero, to: host).x + 16)
        }
    }

    /// 引用の直下の段落は、リストの続きの段落と違って字下げしない。
    @MainActor
    func testParagraphDirectlyInsideQuoteHasNoContinuationIndent() throws {
        let analysis = MarkdownAnalysis("> quoted paragraph")
        let paragraph = try XCTUnwrap(analysis.blocks.first { $0.kind == .paragraph })
        XCTAssertFalse(PreviewAppKitIndent.containsListIndent(MarkdownRenderer.renderLeaf(paragraph, in: analysis)))
    }
}
