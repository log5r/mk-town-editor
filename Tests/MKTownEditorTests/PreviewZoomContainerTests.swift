import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

/// 不具合 #101: 構造化プレビューのコールアウト・脚注・埋め込み文書が、プレビューの表示倍率（`MarkdownPreview.zoom`）に
/// 追従しなかった。文字と数式（周りの文字の1.2倍）と字下げが、本文と同じ倍率で拡大・縮小することを確かめる。
/// docs/math-font-size-and-baseline.md の「コールアウト・脚注・埋め込み文書を表示倍率に合わせる」
@MainActor
final class PreviewZoomContainerTests: XCTestCase {
    /// 1つの `NSTextView` で測った値。
    private struct Measured {
        var fontSize: CGFloat = 0
        var math: NSRect = .zero
        /// 入れ子のリスト項目の本文と、1段浅い項目の本文の左端の差。
        var nestedIndent: CGFloat?
        /// 測った文字の左端（`host` の座標系）。
        var x: CGFloat = 0
    }

    private func textView(containing needle: String, in host: NSView,
                          file: StaticString = #filePath, line: UInt = #line) throws -> NSTextView {
        try XCTUnwrap(PreviewLayoutTestSupport.textViews(in: host).first { $0.string.contains(needle) },
                      "Missing text view containing \(needle)", file: file, line: line)
    }

    private func measure(_ needle: String, in host: NSView, nested: (String, String)? = nil,
                         file: StaticString = #filePath, line: UInt = #line) throws -> Measured {
        let view = try textView(containing: needle, in: host, file: file, line: line)
        let storage = try XCTUnwrap(view.textStorage, file: file, line: line)
        var result = Measured()
        let location = (storage.string as NSString).range(of: needle).location
        let font = try XCTUnwrap(storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont,
                                 file: file, line: line)
        result.fontSize = font.pointSize
        var formulas: [NSTextAttachment] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let formula = value as? MarkdownMathAttachment { formulas.append(formula) }
        }
        XCTAssertEqual(formulas.count, 1, file: file, line: line)
        result.math = try XCTUnwrap(formulas.first, file: file, line: line).bounds
        if let (outer, inner) = nested {
            result.nestedIndent = try PreviewLayoutTestSupport.position(of: inner, in: view)
                - PreviewLayoutTestSupport.position(of: outer, in: view)
        }
        result.x = try PreviewLayoutTestSupport.position(of: needle, in: view, relativeTo: host)
        return result
    }

    /// 倍率 `zoom` の値が、倍率1の値の `zoom` 倍になっている。
    private func assertScaled(_ zoomed: Measured, _ base: Measured, zoom: Double, expectedFontSize: CGFloat,
                              file: StaticString = #filePath, line: UInt = #line) {
        let scale = CGFloat(zoom)
        XCTAssertEqual(base.fontSize, expectedFontSize, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(zoomed.fontSize, expectedFontSize * scale, accuracy: 0.001, "zoom \(zoom)",
                       file: file, line: line)
        // 数式は周りの文字と同じ倍率で広がり、周りの文字の1.2倍の大きさとベースラインの位置を保つ。
        XCTAssertGreaterThan(base.math.width, 0, file: file, line: line)
        XCTAssertEqual(zoomed.math.width, base.math.width * scale, accuracy: 0.001, "zoom \(zoom)",
                       file: file, line: line)
        XCTAssertEqual(zoomed.math.height, base.math.height * scale, accuracy: 0.001, "zoom \(zoom)",
                       file: file, line: line)
        XCTAssertEqual(zoomed.math.minY, base.math.minY * scale, accuracy: 0.001, "zoom \(zoom)",
                       file: file, line: line)
        if let indent = base.nestedIndent {
            XCTAssertGreaterThan(indent, 0, file: file, line: line)
            XCTAssertEqual(zoomed.nestedIndent ?? 0, indent * scale, accuracy: 0.5, "zoom \(zoom)",
                           file: file, line: line)
        }
    }

    // MARK: - コールアウト

    private let calloutSource = "本文\n\n> [!NOTE]\n> コールアウト $ax+b$ の式\n>\n> - 一\n>   - 二"

    func testCalloutFollowsZoom() throws {
        var base = Measured(), baseBody: CGFloat = 0
        try PreviewLayoutTestSupport.hosted(PreviewLayoutTestSupport.preview(calloutSource, zoom: 1)) { host in
            base = try measure("コールアウト", in: host, nested: ("一", "二"))
            baseBody = try PreviewLayoutTestSupport.position(of: "本文", in: textView(containing: "本文", in: host),
                                                             relativeTo: host)
        }
        try PreviewLayoutTestSupport.hosted(PreviewLayoutTestSupport.preview(calloutSource, zoom: 1.5)) { host in
            let zoomed = try measure("コールアウト", in: host, nested: ("一", "二"))
            assertScaled(zoomed, base, zoom: 1.5, expectedFontSize: MarkdownRenderer.bodyFontSize)
            // コールアウトの記号も文字と一緒に広がり、本文の左端からの距離が伸びる。
            let body = try PreviewLayoutTestSupport.position(of: "本文", in: textView(containing: "本文", in: host),
                                                             relativeTo: host)
            XCTAssertEqual(body, baseBody, accuracy: 0.5)
            XCTAssertGreaterThan(zoomed.x - body, base.x - baseBody + 2)
        }
    }

    // MARK: - 脚注

    private let footnoteSource = "ここ[^1]\n\n[^1]: 脚注の本文 $ax+b$"

    func testFootnoteFollowsZoom() throws {
        var base = Measured(), baseNumber: CGFloat = 0
        // 脚注の番号は本文の左端から始まり、番号と本文の間は8pt空く。
        func numberWidth(_ note: Measured, host: NSView) throws -> CGFloat {
            let body = try PreviewLayoutTestSupport.position(of: "ここ", in: textView(containing: "ここ", in: host),
                                                             relativeTo: host)
            return note.x - body - 8
        }
        try PreviewLayoutTestSupport.hosted(PreviewLayoutTestSupport.preview(footnoteSource, zoom: 1)) { host in
            base = try measure("脚注の本文", in: host)
            baseNumber = try numberWidth(base, host: host)
        }
        XCTAssertGreaterThan(baseNumber, 4)
        try PreviewLayoutTestSupport.hosted(PreviewLayoutTestSupport.preview(footnoteSource, zoom: 1.5)) { host in
            let zoomed = try measure("脚注の本文", in: host)
            // 脚注の本文は表のセルと同じく14ptで描く。
            assertScaled(zoomed, base, zoom: 1.5, expectedFontSize: 14)
            // 番号（SwiftUI の `Text`）も同じ倍率で広がる。
            XCTAssertEqual(try numberWidth(zoomed, host: host), baseNumber * 1.5, accuracy: 1)
        }
    }

    // MARK: - 埋め込み文書

    private let embeddedSource = "埋め込みの本文 $ax+b$\n\n- 一\n  - 二\n\n```\ncode\n```"

    func testEmbeddedDocumentFollowsZoom() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/embed-zoom-\(UUID().uuidString)")
        let document = root.appendingPathComponent("main.md")
        let embedded = root.appendingPathComponent("note.md")
        let reference = try XCTUnwrap(WorkspaceDocumentEmbed.reference(in: "![[note]]"))
        let source = embeddedSource
        var loads = 0
        func preview(_ zoom: Double) -> WorkspaceEmbeddedDocumentView {
            WorkspaceEmbeddedDocumentView(reference: reference, documentURL: document,
                documents: [document, embedded], diskRevision: 0, loadOpenBuffers: { _ in
                    loads += 1
                    return [embedded: Data(source.utf8)]
                }, onOpen: nil, zoom: zoom)
        }
        let host = NSHostingView(rootView: preview(1))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil }
        for _ in 0..<200 where !PreviewLayoutTestSupport.textViews(in: host).contains(where: {
            $0.string.contains("埋め込みの本文")
        }) {
            try await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
        }
        let base = try measure("埋め込みの本文", in: host, nested: ("一", "二"))
        // 表示中の埋め込み文書で倍率を変えると、読み込み直さずに描き直す。
        host.rootView = preview(1.5)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let zoomed = try measure("埋め込みの本文", in: host, nested: ("一", "二"))
        assertScaled(zoomed, base, zoom: 1.5, expectedFontSize: MarkdownRenderer.bodyFontSize)
        host.rootView = preview(1)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let restored = try measure("埋め込みの本文", in: host, nested: ("一", "二"))
        XCTAssertEqual(restored.fontSize, base.fontSize)
        XCTAssertEqual(restored.math, base.math)
        XCTAssertEqual(loads, 1, "Changing the zoom must reuse the loaded analysis")
    }

    /// 埋め込み文書のコードブロック（SwiftUI の `Text` で描く）も表示倍率で広がる。
    func testEmbeddedCodeBlockFollowsZoom() throws {
        let analysis = MarkdownAnalysis(embeddedSource)
        func codeFontSize(_ zoom: Double) throws -> CGFloat {
            let segments = WorkspaceEmbedSegment.render(analysis, documentContext: DocumentContext(fileURL: nil),
                                                        zoom: zoom)
            let code = try XCTUnwrap(segments.lazy.compactMap { segment -> AttributedString? in
                guard case let .codeBlock(_, code, _) = segment else { return nil }
                return code
            }.first)
            let rendered = try NSAttributedString(code, including: \.appKit)
            return try XCTUnwrap(rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont).pointSize
        }
        let base = try codeFontSize(1)
        XCTAssertEqual(try codeFontSize(1.5), base * 1.5, accuracy: 0.001)
    }

    /// 埋め込み文書の後ろに付く脚注の見出しと番号は、フォントと文字色を持ち、本文と同じ倍率で広がる。
    /// フォントがないと `NSTextView` の既定（Helvetica 12pt）で描かれ、倍率でも変わらなかった。
    func testEmbeddedBackMatterHasFontsThatFollowZoom() throws {
        let analysis = MarkdownAnalysis("本文[^1]\n\n[^1]: 注の本文")
        func text(_ zoom: Double) throws -> NSAttributedString {
            let segments = WorkspaceEmbedSegment.render(analysis, documentContext: DocumentContext(fileURL: nil),
                                                        zoom: zoom)
            guard case let .text(text) = segments.last else { throw XCTSkip("Missing text segment") }
            return text
        }
        let base = try text(1), zoomed = try text(1.5)
        XCTAssertEqual(base.string, zoomed.string)
        // 本文の後ろに付く部分（脚注の見出しの前の空行から最後まで）。
        let start = (base.string as NSString).range(of: "\n\n脚注").location
        XCTAssertNotEqual(start, NSNotFound)
        let backMatter = NSRange(location: start, length: base.length - start)
        base.enumerateAttributes(in: backMatter) { attributes, range, _ in
            let fragment = (base.string as NSString).substring(with: range)
            XCTAssertNotNil(attributes[.font], "No font for \(fragment.debugDescription)")
            XCTAssertNotNil(attributes[.foregroundColor], "No color for \(fragment.debugDescription)")
        }
        for needle in ["脚注", "1. ", "注の本文"] {
            let location = (base.string as NSString).range(of: needle, options: .backwards).location
            let font = try XCTUnwrap(base.attribute(.font, at: location, effectiveRange: nil) as? NSFont)
            let zoomedFont = try XCTUnwrap(zoomed.attribute(.font, at: location, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(zoomedFont.pointSize, font.pointSize * 1.5, accuracy: 0.001, needle)
        }
    }

    // MARK: - 文書全体を1つの NSTextView で描く経路

    /// 構造化しないプレビューでも、リストの字下げが文字と同じ倍率で広がる（構造化プレビューのリスト項目と同じ扱い）。
    func testPlainPreviewListIndentFollowsZoom() throws {
        let source = "- 一\n  - 二"
        func indent(_ zoom: Double) throws -> CGFloat {
            var result: CGFloat = 0
            try PreviewLayoutTestSupport.hosted(PreviewLayoutTestSupport.preview(source, zoom: zoom)) { host in
                let view = try textView(containing: "二", in: host)
                // 構造化しない経路（`MarkdownTextPreview`）で描いている。
                XCTAssertTrue(view.enclosingScrollView?.documentView === view)
                result = try PreviewLayoutTestSupport.position(of: "二", in: view)
                    - PreviewLayoutTestSupport.position(of: "一", in: view)
            }
            return result
        }
        let base = try indent(1)
        XCTAssertGreaterThan(base, 0)
        XCTAssertEqual(try indent(1.5), base * 1.5, accuracy: 0.5)
    }

    // MARK: - SwiftUI の Text で描く補助の文字

    /// 倍率1では従来の文字スタイルと同じ大きさで、倍率に比例する。
    func testSupplementaryFontsMatchTextStylesAndFollowZoom() {
        XCTAssertEqual(PreviewSupplementaryFont.bodySize, NSFont.preferredFont(forTextStyle: .body).pointSize)
        XCTAssertEqual(PreviewSupplementaryFont.bodySize, NSFont.preferredFont(forTextStyle: .headline).pointSize)
        XCTAssertEqual(PreviewSupplementaryFont.captionSize, NSFont.preferredFont(forTextStyle: .caption1).pointSize)
        XCTAssertEqual(PreviewSupplementaryFont.body(zoom: 1.5), .system(size: PreviewSupplementaryFont.bodySize * 1.5))
        XCTAssertEqual(PreviewSupplementaryFont.headline(zoom: 1.5),
                       .system(size: PreviewSupplementaryFont.bodySize * 1.5, weight: .bold))
        XCTAssertEqual(PreviewSupplementaryFont.caption(zoom: 2, weight: .semibold),
                       .system(size: PreviewSupplementaryFont.captionSize * 2, weight: .semibold))
    }
}
