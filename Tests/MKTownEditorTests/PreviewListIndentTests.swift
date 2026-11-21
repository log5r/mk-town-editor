import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

/// 不具合: 構造化プレビュー（分割表示・テーマ・本文幅の指定時など）で、入れ子の箇条書きがすべて同じ深さで表示されていた。
/// 解析と描画は深さを段落スタイルの字下げとして持っていたが、SwiftUI の `Text` は段落スタイルの字下げを無視する。
/// プレビューはリスト項目を `PreviewAppKitIndent.aligned` で整えて `NSTextView` で描き、続きの段落は行の余白で字下げする。
@MainActor
final class PreviewListIndentTests: XCTestCase {
    private typealias Support = PreviewLayoutTestSupport

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

    private func hasIndent(_ text: NSAttributedString) -> Bool {
        PreviewAppKitIndent.containsListIndent(text)
    }

    /// 構造化プレビューに載せ、各項目の行頭記号の位置を返す。項目は `記号 + 本文` の文字列で探す。
    private func markerPositions(_ source: String, items: [String], zoom: Double = 1) throws -> [CGFloat] {
        var result: [CGFloat] = []
        try Support.hosted(Support.preview(source, zoom: zoom)) { host in
            for item in items {
                let view = try Support.textView(item, in: host)
                result.append(try Support.position(of: String(item.prefix(1)), in: view, relativeTo: host))
            }
        }
        return result
    }

    private func assertIncreasing(_ values: [CGFloat], by step: CGFloat = 16,
                                  file: StaticString = #filePath, line: UInt = #line) {
        for (previous, next) in zip(values, values.dropFirst()) {
            XCTAssertGreaterThan(next, previous + step, "\(values)", file: file, line: line)
        }
    }

    /// 報告された文書と同じ形（見出し、`#` だけの行、段落、3階層の箇条書き）を、字下げの単位ごとに確かめる。
    func testReportedOutlineKeepsNestingForEveryIndentUnit() throws {
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
            let positions = try markerPositions(source, items: items.map { "•  " + $0.content })
            let byDepth = Dictionary(grouping: zip(items.map(\.nestingDepth), positions), by: \.0)
            for (depth, entries) in byDepth {
                XCTAssertTrue(entries.allSatisfy { abs($0.1 - entries[0].1) < 0.5 }, "\(name) depth \(depth)")
            }
            assertIncreasing((0...3).map { byDepth[$0]![0].1 })
        }
    }

    /// 2スペースの字下げで、親より2段深く書いた子も1段下の項目になる（コードブロックにならない）。
    func testOverIndentedChildIsNestedOneLevelBelowItsParent() throws {
        let source = "# Heading\n\n- a\n  - b\n      - c"
        let analysis = MarkdownAnalysis(source)
        let items = listBlocks(analysis)
        XCTAssertEqual(items.map(\.content), ["a", "b", "c"])
        XCTAssertEqual(items.map(\.nestingDepth), [0, 1, 2])
        XCTAssertFalse(analysis.blocks.contains { $0.kind == .codeBlock })
        assertIncreasing(try markerPositions(source, items: ["•  a", "•  b", "•  c"]))
    }

    func testOrderedAndUnorderedListsMixedAcrossFourLevels() throws {
        // 番号付きリストの本文は「1. 」の後ろ（3桁目）から始まるため、子はその位置以上に字下げする。
        // 2スペースでは CommonMark 上も入れ子にならないため、最小の字下げ・4スペース・タブで確かめる。
        let variants: [(name: String, levels: [String])] = [
            ("content column", ["", "   ", "     ", "        "]),
            ("4 spaces", ["", "    ", "        ", "            "]),
            ("tab", ["", "\t", "\t\t", "\t\t\t"])
        ]
        for (name, levels) in variants {
            let source = "# Heading\n\n1. one\n\(levels[1])- two\n\(levels[2])1. three\n\(levels[3])- four\n2. five"
            let items = listBlocks(MarkdownAnalysis(source))
            XCTAssertEqual(items.map(\.nestingDepth), [0, 1, 2, 3, 0], name)
            let itemTexts = ["1.  one", "•  two", "1.  three", "•  four", "2.  five"]
            assertIncreasing(Array(try markerPositions(source, items: itemTexts).prefix(4)))
            // 同じ深さの番号は幅が少し異なり、列より広い分だけ左へはみ出す。本文の左端はそろう。
            var bodies: [CGFloat] = []
            try Support.hosted(Support.preview(source)) { host in
                for (item, word) in [("1.  one", "one"), ("2.  five", "five")] {
                    bodies.append(try Support.position(of: word, in: Support.textView(item, in: host),
                                                       relativeTo: host))
                }
            }
            XCTAssertEqual(bodies[0], bodies[1], accuracy: 0.5, name)
        }
    }

    /// タスクはチェックボックスを行頭記号の位置に置く。番号付きのタスクは番号と本文を1つの文字列に保つ。
    func testTaskItemsKeepNestingAndNumberedTaskText() {
        let analysis = MarkdownAnalysis("- [ ] parent\n  - [x] child\n    1. [ ] numbered")
        let items = listBlocks(analysis)
        let indents = items.map(PreviewListIndent.taskCheckboxIndent(for:))
        XCTAssertLessThan(indents[0], indents[1])
        XCTAssertLessThan(indents[1], indents[2])
        let texts = items.map {
            PreviewListIndent.withoutIndent(MarkdownRenderer.renderLeaf($0, in: analysis, showTaskPrefix: false))
        }
        XCTAssertEqual(texts.map(\.string), ["parent", "child", "1.  numbered"])
        XCTAssertFalse(texts.contains(where: hasIndent))
    }

    /// 明示的な改行の後の行と、項目の続きの段落は、行頭記号ではなく項目の本文の位置にそろう。
    /// 続きの段落はリンクを含めて `NSTextView` で描き、位置を測る。
    func testHardBreakAndContinuationParagraphAlignWithItemText() throws {
        let source = "# Heading\n\n- item  \n  second line\n\n  [continuation](https://example.com/c)"
        try Support.hosted(Support.preview(source)) { host in
            let item = try Support.textView("•  item\nsecond line", in: host)
            let body = try Support.position(of: "item", in: item, relativeTo: host)
            XCTAssertEqual(try Support.position(of: "second", in: item, relativeTo: host), body, accuracy: 0.5)
            let continuation = try Support.textView("continuation", in: host)
            XCTAssertEqual(try Support.position(of: "continuation", in: continuation, relativeTo: host), body,
                           accuracy: 0.5)
            XCTAssertFalse(hasIndent(continuation.attributedString()))
        }
    }

    /// リンクを含む項目も、行頭記号と同じ文字列の中でリンクを保つ。
    func testLinkedItemKeepsLinkNextToMarker() throws {
        try Support.hosted(Support.preview("# Heading\n\n- parent\n  - [site](https://example.com)")) { host in
            let child = try Support.textView("•  site", in: host)
            XCTAssertNotNil(child.attributedString().attribute(.link, at: 3, effectiveRange: nil))
            let parent = try Support.textView("•  parent", in: host)
            XCTAssertGreaterThan(try Support.position(of: "•", in: child, relativeTo: host),
                                 try Support.position(of: "•", in: parent, relativeTo: host) + 16)
        }
    }

    /// プレビューの描画キャッシュは拡大とテーマを当てる。その後も行頭記号を見分け、本文の位置を求められる。
    func testRenderCacheOutputKeepsMarkerWithZoomAndTheme() throws {
        let analysis = MarkdownAnalysis("- parent\n  - child")
        let cache = PreviewRenderCache()
        let bodies = try listBlocks(analysis).map { block in
            try XCTUnwrap(PreviewAppKitIndent.itemBodyIndent(
                cache.render(block, in: analysis, context: DocumentContext(fileURL: nil),
                             zoom: 1.5, theme: .preset(.githubDark)), indentScale: 1.5))
        }
        XCTAssertEqual(bodies[0], MarkdownRenderer.listBodyIndent(depth: 0) * 1.5)
        XCTAssertEqual(bodies[1], MarkdownRenderer.listBodyIndent(depth: 1) * 1.5)
    }

    /// 表示倍率を上げると、字下げも文字と同じ割合で広がる。
    func testZoomScalesListIndent() throws {
        let source = "# Heading\n\n- parent\n  - child"
        let normal = try markerPositions(source, items: ["•  parent", "•  child"])
        let zoomed = try markerPositions(source, items: ["•  parent", "•  child"], zoom: 2)
        XCTAssertEqual(zoomed[1] - zoomed[0], (normal[1] - normal[0]) * 2, accuracy: 1)
    }

    /// 実際の `MarkdownPreview`（見出しを含むため構造化プレビュー）で、項目の位置を比べる。
    /// 修正前はすべての項目が同じ位置に置かれていた。
    func testHostedStructuredPreviewPlacesNestedItemsFurtherRight() throws {
        let source = """
        # 見出し

        - [a](https://example.com/a)
          - [b](https://example.com/b)
            1. [c](https://example.com/c)
        - [ ] [t](https://example.com/t)
          - [ ] [u](https://example.com/u)
        """
        try Support.hosted(Support.preview(source)) { host in
            @MainActor func x(_ text: String, _ needle: String) throws -> CGFloat {
                try Support.position(of: needle, in: Support.textView(text, in: host), relativeTo: host)
            }
            assertIncreasing([try x("•  a", "•"), try x("•  b", "•"), try x("1.  c", "1")])
            // タスクの本文はチェックボックスの後ろに置き、チェックボックスごと深さだけ右へずれる。
            assertIncreasing([try x("t", "t"), try x("u", "u")])
        }
    }

    /// 折り返した行は行頭記号の下ではなく、本文の左端から始まる。
    func testWrappedLinesHangAtBodyIndent() throws {
        let analysis = MarkdownAnalysis("- " + Array(repeating: "wrap", count: 30).joined(separator: " "))
        let view = Support.standaloneTextView(
            PreviewAppKitIndent.aligned(MarkdownRenderer.renderLeaf(analysis.blocks[0], in: analysis)), width: 200)
        let starts = try Support.lineStarts(in: view)
        XCTAssertGreaterThan(starts.count, 2)
        XCTAssertEqual(starts[0], MarkdownRenderer.listMarkerIndent(depth: 0), accuracy: 0.5)
        for start in starts.dropFirst() {
            XCTAssertEqual(start, MarkdownRenderer.listBodyIndent(depth: 0), accuracy: 0.5)
        }
        XCTAssertEqual(try Support.position(of: "wrap", in: view), MarkdownRenderer.listBodyIndent(depth: 0),
                       accuracy: 0.5)
    }
}
