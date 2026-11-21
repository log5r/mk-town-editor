import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

/// 入れ子のリストの字下げの修正に対するレビュー指摘の再現テスト。
/// 埋め込み文書のコピー、コールアウト、本文が空のタスク、幅の広い行頭記号、引用の中のリスト、
/// 構造化プレビューのリスト項目全体の選択とコピーを確かめる。
final class PreviewListAlignmentTests: XCTestCase {
    // MARK: - 補助

    private typealias Support = PreviewLayoutTestSupport

    @MainActor
    private func textView(_ text: NSAttributedString) -> NSTextView { Support.standaloneTextView(text) }

    @MainActor
    private func positions(of needle: String, in view: NSTextView) throws -> [CGFloat] {
        try Support.positions(of: needle, in: view)
    }

    @MainActor
    private func position(of needle: String, in view: NSTextView) throws -> CGFloat {
        try Support.position(of: needle, in: view)
    }

    @MainActor
    private func hosted<Content: View>(_ view: Content,
                                       body: (NSHostingView<Content>) throws -> Void) rethrows {
        try Support.hosted(view, body: body)
    }

    @MainActor
    private func textViews(in view: NSView) -> [NSTextView] { Support.textViews(in: view) }

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
            XCTAssertEqual(Support.copiedString(view), "☐ 未完了  alpha task\n☑ 完了  bravo task\n•  charlie")
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
            // 縦線は図形で引くため、文字列に引用記号を含めない（`PreviewBlockStyleTests`）。
            XCTAssertFalse(view.string.contains("│"))
        }
    }

    /// 入れ子のリストを含まないコールアウトは、リストの字下げを位置に直す対象にしない。
    func testCalloutWithoutListHasNoListIndent() {
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
        let indents = tasks.map(PreviewListIndent.taskCheckboxIndent(for:))
        XCTAssertEqual(indents[1], indents[2])
        XCTAssertGreaterThan(indents[1], indents[0])
        // チェックボックスは同じ深さの箇条書きの記号と同じ位置に置く。
        XCTAssertEqual(indents[2], MarkdownRenderer.listMarkerIndent(depth: 1))
    }

    // MARK: - 4. 幅の広い行頭記号

    /// 不具合: 記号が列（20pt）より広いと本文が右へ押され、同じ項目の続きの段落とずれていた。
    /// 構造化プレビューでは項目と続きの段落を別の行で描くため、続きの段落は親の項目の本文の位置を求めてそろえる。
    /// 続きの段落はリンクを含めて `NSTextView` で描き、位置を測る。表示倍率を変えても同じ。
    @MainActor
    func testWideOrderedMarkerKeepsBodyAlignedWithContinuationInStructuredPreview() throws {
        let source = """
        # Heading

        9. alpha
        10. bravo

            [after bravo](https://example.com/b)
        12345. charlie

               [after charlie](https://example.com/c)
        """
        for zoom in [1.0, 1.5] {
            try hosted(Support.preview(source, zoom: zoom)) { host in
                @MainActor func body(_ text: String, _ needle: String) throws -> CGFloat {
                    try Support.position(of: needle, in: Support.textView(text, in: host), relativeTo: host)
                }
                let alpha = try body("9.  alpha", "alpha")
                XCTAssertEqual(try body("10.  bravo", "bravo"), alpha, accuracy: 0.5, "zoom \(zoom)")
                XCTAssertEqual(try body("after bravo", "after"), alpha, accuracy: 0.5, "zoom \(zoom)")
                XCTAssertEqual(try body("after charlie", "after"), try body("12345.  charlie", "charlie"),
                               accuracy: 0.5, "zoom \(zoom)")
            }
        }
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
            let parent = try Support.textView("•  parent", in: host)
            let child = try Support.textView("•  child", in: host)
            XCTAssertFalse(parent.string.contains("│") || child.string.contains("│"))
            XCTAssertGreaterThan(try Support.position(of: "•", in: child, relativeTo: host),
                                 try Support.position(of: "•", in: parent, relativeTo: host) + 16)
        }
    }

    /// 引用の直下の段落は、リストの続きの段落と違って字下げしない。
    @MainActor
    func testParagraphDirectlyInsideQuoteHasNoContinuationIndent() throws {
        let analysis = MarkdownAnalysis("> quoted paragraph")
        let paragraph = try XCTUnwrap(analysis.blocks.first { $0.kind == .paragraph })
        XCTAssertFalse(PreviewAppKitIndent.containsListIndent(MarkdownRenderer.renderLeaf(paragraph, in: analysis)))
    }

    // MARK: - 6. 構造化プレビューのリスト項目全体の選択とコピー

    /// 不具合: 行頭記号を `Text`、本文を別のビュー（リンクがあれば `NSTextView`）で描いたため、
    /// 番号や記号を含めて項目全体を選択・コピーできなかった。修正前（字下げの修正の前）は1つのビューで描いていた。
    @MainActor
    func testListItemIsOneSelectionSurfaceIncludingMarker() throws {
        let source = "# Heading\n\n1. [alpha](https://example.com/a)\n2. bravo plain\n- charlie plain\n  - delta"
        try hosted(Support.preview(source)) { host in
            for item in ["1.  alpha", "2.  bravo plain", "•  charlie plain", "•  delta"] {
                let view = try Support.textView(item, in: host)
                XCTAssertTrue(view.isSelectable, item)
                XCTAssertEqual(Support.copiedString(view), item)
            }
        }
    }

    /// 番号付きのタスクも、番号と本文を1つの選択面に置く（チェックボックスは操作部品のため別）。
    @MainActor
    func testNumberedTaskKeepsNumberAndTextInOneSurface() throws {
        try hosted(Support.preview("# Heading\n\n1. [ ] [alpha](https://example.com/a)\n- [x] [bravo](https://example.com/b)")) { host in
            XCTAssertEqual(Support.copiedString(try Support.textView("1.  alpha", in: host)), "1.  alpha")
            XCTAssertEqual(Support.copiedString(try Support.textView("bravo", in: host)), "bravo")
        }
    }

    /// `NSTextView` は右クリックを受け取り、行に付けた SwiftUI の文脈メニューを出さない。
    /// リスト項目の `NSTextView` の文脈メニューに「原文へ移動」を加える。
    @MainActor
    func testListItemContextMenuOffersRevealSource() throws {
        let source = "# Heading\n\n- alpha\n  - bravo"
        let analysis = MarkdownAnalysis(source)
        let bravo = try XCTUnwrap(analysis.blocks.first { $0.content == "bravo" })
        var revealed: [NSRange] = []
        try hosted(Support.preview(source, onRevealSource: { revealed.append($0) })) { host in
            let view = try Support.textView("•  bravo", in: host)
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))
            let menu = try XCTUnwrap(view.menu(for: event))
            XCTAssertEqual(menu.items.first?.title, String(localized: "原文へ移動"))
            menu.performActionForItem(at: 0)
            XCTAssertEqual(revealed, [bravo.sourceRange])
        }
        // 「原文へ移動」を渡さないプレビューでは加えない。
        try hosted(Support.preview(source)) { host in
            let view = try Support.textView("•  bravo", in: host)
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))
            XCTAssertNotEqual(view.menu(for: event)?.items.first?.title, String(localized: "原文へ移動"))
        }
    }

    /// `view` の文脈メニューの先頭の「原文へ移動」を実行する。項目がなければ失敗にする。
    @MainActor
    private func performRevealSource(in view: NSTextView, file: StaticString = #filePath,
                                     line: UInt = #line) throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1), file: file, line: line)
        let menu = try XCTUnwrap(view.menu(for: event), file: file, line: line)
        XCTAssertEqual(menu.items.first?.title, String(localized: "原文へ移動"), file: file, line: line)
        guard menu.items.first?.title == String(localized: "原文へ移動") else { return }
        menu.performActionForItem(at: 0)
    }

    /// 不具合: 入れ子のリストや引用を含むコールアウトは `NSTextView` で描くが、「原文へ移動」を渡しておらず、
    /// 右クリックで出なかった。コールアウトのブロックの範囲を示す。
    @MainActor
    func testCalloutTextViewContextMenuOffersRevealSource() throws {
        let title = MarkdownCalloutKind.note.title
        for (source, needle) in [("> [!note]\n> - alpha\n> - bravo\n", "\(title)\n•  alpha\n•  bravo"),
                                 ("> [!note]\n> body\n>\n> > nested\n", "nested")] {
            let analysis = MarkdownAnalysis(source)
            let callout = try XCTUnwrap(analysis.blocks.first { $0.calloutKind != nil })
            var revealed: [NSRange] = []
            try hosted(Support.preview(source, onRevealSource: { revealed.append($0) })) { host in
                let view = try XCTUnwrap(textViews(in: host).first { $0.string.contains(needle) }, source)
                try performRevealSource(in: view)
            }
            XCTAssertEqual(revealed, [callout.sourceRange], source)
        }
    }

    /// 同じ原因: リンクを含む見出し・段落・表のセルも `NSTextView` で描き、「原文へ移動」が出なかった。
    @MainActor
    func testLinkedTextViewsContextMenuOfferRevealSource() throws {
        let source = "# [Head](https://example.com/h)\n\n[Para](https://example.com/p)\n\n| A |\n| --- |\n| [Cell](https://example.com/c) |\n"
        let analysis = MarkdownAnalysis(source)
        for needle in ["Head", "Para", "Cell"] {
            let block = try XCTUnwrap(analysis.blocks.first {
                needle == "Cell" ? $0.table != nil : $0.content.contains(needle)
            }, needle)
            var revealed: [NSRange] = []
            try hosted(Support.preview(source, onRevealSource: { revealed.append($0) })) { host in
                try performRevealSource(in: Support.textView(needle, in: host))
            }
            XCTAssertEqual(revealed, [block.sourceRange], needle)
        }
    }
}
