import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

/// 構造化プレビューの文字列は、すべて `NSTextView`（`HoverLinkText`）で描く。
/// SwiftUI の `Text` は段落スタイルの字下げと行間、添付画像、リンクの文字色を無視するため使わない。
@MainActor
final class PreviewInlineTextTests: XCTestCase {
    private typealias Support = PreviewLayoutTestSupport

    private func structuredPreview(_ source: String) -> MarkdownPreview {
        Support.preview(source, onRevealSource: { _ in })
    }

    func testPlainParagraphsAndHeadingsAreDrawnInTextViews() {
        Support.hosted(structuredPreview("# 見出し\n\n最初の段落です。\n\n二番目の段落です。\n")) { host in
            XCTAssertEqual(Support.textViews(in: host).map(\.string), ["見出し", "最初の段落です。", "二番目の段落です。"])
        }
    }

    /// 短い文字列は文字の幅に合わせる。行の幅いっぱいに広げると、後ろに置くボタンや表のセルの寄せが効かなくなる。
    func testShortParagraphHugsItsText() throws {
        try Support.hosted(structuredPreview("短い段落。\n"), width: 600) { host in
            let view = try Support.textView("短い段落。", in: host)
            XCTAssertGreaterThan(view.frame.width, 20)
            XCTAssertLessThan(view.frame.width, 200)
        }
    }

    /// 長い段落は行の幅で折り返し、ウインドウの外へはみ出さない。
    func testLongParagraphWrapsWithinTheAvailableWidth() throws {
        let text = String(repeating: "折り返しを確かめるための長い段落。", count: 12)
        try Support.hosted(structuredPreview(text + "\n"), width: 600) { host in
            let view = try Support.textView(text, in: host)
            XCTAssertLessThanOrEqual(view.convert(view.bounds, to: host).maxX, host.bounds.maxX)
            XCTAssertGreaterThan(try Support.lineStarts(in: view).count, 1)
            XCTAssertGreaterThan(view.frame.height, 30)
        }
    }

    /// 表のセルの寄せは SwiftUI の枠で決める。セルの文字列が列の幅いっぱいに広がると、右寄せ・中央寄せが効かない。
    func testTableCellsFollowTheColumnAlignment() throws {
        let source = "| 左の列の見出し | 中央の列の見出し | 右の列の見出し |\n|:---|:---:|---:|\n| 左 | 中 | 右 |\n"
        try Support.hosted(structuredPreview(source), width: 700) { host in
            @MainActor func frame(_ text: String) throws -> NSRect {
                let view = try Support.textView(text, in: host)
                return view.convert(view.bounds, to: host)
            }
            let (leftHeader, centerHeader, rightHeader) =
                (try frame("左の列の見出し"), try frame("中央の列の見出し"), try frame("右の列の見出し"))
            let (left, center, right) = (try frame("左"), try frame("中"), try frame("右"))
            XCTAssertEqual(left.minX, leftHeader.minX, accuracy: 1)
            XCTAssertEqual(center.midX, centerHeader.midX, accuracy: 1)
            XCTAssertEqual(right.maxX, rightHeader.maxX, accuracy: 1)
            XCTAssertGreaterThan(right.minX, rightHeader.minX + 20)
        }
    }

    /// 不具合: `NSTextStorage` が日本語のフォントを置き換えるため、渡した文字列で測った幅が表示より狭くなり、
    /// 行の幅に余裕があっても、狭い幅に置かれたビューの中で折り返していた。
    func testHuggedWidthIsMeasuredWithTheDisplayedFonts() throws {
        let cases = [(source: "**太字の日本語の短い段落**\n", text: "太字の日本語の短い段落"),
                     (source: "**強調**と`コード`の混ざった段落 and English\n", text: "強調とコードの混ざった段落 and English")]
        for (source, text) in cases {
            try Support.hosted(structuredPreview(source), width: 600) { host in
                let view = try Support.textView(text, in: host)
                XCTAssertEqual(try Support.lineStarts(in: view).count, 1, text)
            }
        }
    }

    /// 内容が変わらない更新では、文字列を入れ直さない。入れ直すとレイアウトとリンクのホバー表示をやり直す。
    /// `NSTextStorage` がフォントを置き換えるため、ビューの文字列と渡した文字列をそのまま比べると常に異なる。
    func testUnchangedUpdateDoesNotResetTheText() throws {
        let source = "**太字の日本語**の段落。\n"
        let host = NSHostingView(rootView: structuredPreview(source))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        let view = try Support.textView("太字の日本語の段落。", in: host)
        var edits = 0
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: view.textStorage, queue: nil) { _ in edits += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        host.rootView = structuredPreview(source)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(try Support.textView("太字の日本語の段落。", in: host) === view)
        XCTAssertEqual(edits, 0)

        // 表示が変わる更新（拡大率の変更）では、同じビューに入れ直す。
        // 上の確認が、更新が届かなかっただけではないことを確かめる。
        let width = view.frame.width
        host.rootView = Support.preview(source, zoom: 1.5, onRevealSource: { _ in })
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(try Support.textView("太字の日本語の段落。", in: host) === view)
        XCTAssertGreaterThan(edits, 0)
        // 覚えていた大きさも捨て、拡大した文字で測り直す。
        XCTAssertGreaterThan(view.frame.width, width * 1.2)
    }

    /// 文字列が変わったら、覚えていた大きさを捨てて測り直す。
    func testSizeFollowsContentChanges() throws {
        let host = NSHostingView(rootView: structuredPreview("短い。\n"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        let short = try Support.textView("短い。", in: host).frame.size

        let long = String(repeating: "書き換えたあとの長い段落。", count: 12)
        host.rootView = structuredPreview(long + "\n")
        host.layoutSubtreeIfNeeded()
        let view = try Support.textView(long, in: host)
        XCTAssertGreaterThan(view.frame.width, short.width * 3)
        XCTAssertGreaterThan(view.frame.height, short.height * 1.5)
        XCTAssertGreaterThan(try Support.lineStarts(in: view).count, 1)
    }

    /// ウインドウの幅を変えると、その幅で折り返し直し、高さも変わる。
    func testWidthChangeRewrapsTheText() throws {
        let text = String(repeating: "幅を変えて折り返しを確かめる段落。", count: 8)
        let host = NSHostingView(rootView: structuredPreview(text + "\n"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }

        func layout(width: CGFloat) throws -> (lines: Int, size: NSSize) {
            window.setContentSize(NSSize(width: width, height: 600))
            host.layoutSubtreeIfNeeded()
            let view = try Support.textView(text, in: host)
            XCTAssertLessThanOrEqual(view.convert(view.bounds, to: host).maxX, host.bounds.maxX, "\(width)")
            return (try Support.lineStarts(in: view).count, view.frame.size)
        }
        let wide = try layout(width: 700)
        let narrow = try layout(width: 350)
        XCTAssertGreaterThan(narrow.lines, wide.lines)
        XCTAssertGreaterThan(narrow.size.height, wide.size.height)
        XCTAssertLessThan(narrow.size.width, wide.size.width)
        let restored = try layout(width: 700)
        XCTAssertEqual(restored.lines, wide.lines)
        XCTAssertEqual(restored.size.height, wide.size.height, accuracy: 0.5)
    }

    /// 脚注の文字列は文字の幅に合わせ、「本文に戻る」ボタンが文字のすぐ後ろに来るようにする。
    func testFootnoteTextHugsItsText() throws {
        try Support.hosted(structuredPreview("本文[^1]。\n\n[^1]: 脚注。\n"), width: 600) { host in
            let view = try Support.textView("脚注。", in: host)
            XCTAssertLessThan(view.frame.width, 150)
        }
    }

    /// 不具合: 添付画像は行の残りの幅に合わせて大きさを決める。文字の幅に合わせたビューに置き直すと、
    /// 行の幅が画像の幅まで狭まり、画像が縮む。添付を含む文字列は行の幅いっぱいで描く。
    func testTextWithAttachmentUsesTheFullRowWidth() throws {
        try Support.hosted(structuredPreview("式 $E = mc^2$\n\n添付のない短い段落\n"), width: 600) { host in
            let attachment = try XCTUnwrap(Support.textViews(in: host).first { $0.string.contains("\u{FFFC}") })
            let plain = try Support.textView("添付のない短い段落", in: host)
            XCTAssertGreaterThan(attachment.frame.width, 400)
            XCTAssertLessThan(plain.frame.width, 250)
        }
    }

    /// 不具合（#102）: 行の幅いっぱいを使う文字列（添付を含む段落、リスト項目）が文書の先頭にあると、
    /// ウインドウに載せたときに `LazyVStack` が先頭の行を幅の指定のない提案で測り直し、`sizeThatFits` が
    /// コンテナの幅を500にしたまま残していた。ビューは置かれた幅（544pt）の高さなのに、文字は500ptで折り返し、
    /// 最後の行が次のブロックに重なった。プレビューを別ウインドウで開いたときにアプリでも起きた。
    func testFullWidthTextAtTheTopWrapsAtItsPlacedWidth() throws {
        let item = String(repeating: "リスト項目の長い本文。", count: 12)
        let formula = String(repeating: "前", count: 50) + " 確率 $\\displaystyle\\frac{1}{k}$ で当選する"
            + String(repeating: "後", count: 80)
        let cases = [(source: "- \(item)\n\n本文。\n", marker: "リスト項目"),
                     (source: formula + "\n\n- \(item)\n", marker: "\u{FFFC}")]
        for (source, marker) in cases {
            for zoom in [0.8, 1.0] {
                let label = "\(marker) zoom \(zoom)"
                try Support.hosted(Support.preview(source, zoom: zoom, onRevealSource: { _ in })) { host in
                    let view = try XCTUnwrap(Support.textViews(in: host).first { $0.string.contains(marker) }, label)
                    let manager = try XCTUnwrap(view.layoutManager)
                    let container = try XCTUnwrap(view.textContainer)
                    XCTAssertGreaterThan(view.frame.width, 520, label)
                    XCTAssertEqual(container.size.width, view.frame.width, accuracy: 0.5, label)
                    manager.ensureLayout(for: container)
                    let used = manager.usedRect(for: container)
                    XCTAssertLessThanOrEqual(used.height, view.frame.height + 0.5, label)
                    let measured = HoverLinkTextMeasurer.usedRect(of: view.attributedString(), width: view.frame.width)
                    XCTAssertEqual(used.height, measured.height, accuracy: 0.5, label)
                }
            }
        }
    }
}
