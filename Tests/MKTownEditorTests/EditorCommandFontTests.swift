import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

/// 編集コマンドが挿入した記号が、日本語の代替フォント（ヒラギノ）を引き継がないことを確かめる。
/// 日本語の直後で Return を押して続けたリストのハイフンが、本文フォントの約半分の幅で描かれた不具合の回帰テスト。
@MainActor
final class EditorCommandFontTests: XCTestCase {
    private var window: NSWindow?
    /// `EditorTextView.commandModel` は弱参照のため、テスト中はここで保持する。
    private var model: MarkdownEditorModel?

    override func tearDown() {
        window = nil
        model = nil
        super.tearDown()
    }

    func testListContinuationAfterJapaneseKeepsEditorFont() throws {
        let (view, _) = makeEditor()
        type("- 1", into: view)
        view.insertNewline(nil)
        compose("あ", into: view)
        try assertJapaneseUsesFallbackFont(in: view, at: 6)

        view.insertNewline(nil)
        compose("い", into: view)
        view.insertNewline(nil)

        XCTAssertEqual(view.string, "- 1\n- あ\n- い\n- ")
        layOut(view)
        // 3行目と4行目の記号は、日本語の行の後で Return を押して挿入された。
        for location in [0, 4, 8, 12] {
            assertEditorFont(in: view, range: NSRange(location: location, length: 2))
        }
        XCTAssertEqual(markerWidth(in: view, at: 12), markerWidth(in: view, at: 0), accuracy: 0.01)
    }

    func testFormattingJapaneseSelectionKeepsEditorFontForMarkers() throws {
        let (view, model) = makeEditor()
        type("- ", into: view)
        compose("あ", into: view)
        try assertJapaneseUsesFallbackFont(in: view, at: 2)
        view.setSelectedRange(NSRange(location: 2, length: 1))

        model.apply(.bold)

        XCTAssertEqual(view.string, "- **あ**")
        layOut(view)
        assertEditorFont(in: view, range: NSRange(location: 2, length: 2))
        assertEditorFont(in: view, range: NSRange(location: 5, length: 2))
        // 日本語は引き続き代替フォントで描かれる。
        try assertJapaneseUsesFallbackFont(in: view, at: 4)
    }

    func testMultipleSelectionFormattingKeepsEditorFontForMarkers() throws {
        let (view, model) = makeEditor()
        compose("あ", into: view)
        type(" ", into: view)
        compose("い", into: view)
        try assertJapaneseUsesFallbackFont(in: view, at: 0)
        view.setSelectedRanges([NSValue(range: NSRange(location: 0, length: 1)),
                                NSValue(range: NSRange(location: 2, length: 1))],
                               affinity: .downstream, stillSelecting: false)

        model.apply(.bold)

        XCTAssertEqual(view.string, "**あ** **い**")
        layOut(view)
        for location in [0, 3, 6, 9] {
            assertEditorFont(in: view, range: NSRange(location: location, length: 2))
        }
    }

    /// ファイルの再読み込みなど、編集画面の外で変わった本文を反映する経路（`updateNSView`）。
    /// 先頭が日本語の文書では、置き換えた全文が先頭の文字の代替フォントを引き継いでいた。
    func testExternalTextChangeKeepsEditorFontWhenDocumentStartsWithJapanese() async throws {
        let box = TextBox(text: "あいう")
        let host = NSHostingView(rootView: Host(box: box, model: MarkdownEditorModel()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        let view = try XCTUnwrap(findEditor(in: host))
        layOut(view)
        try assertJapaneseUsesFallbackFont(in: view, at: 0)

        box.text = "あ\n- 1"
        for _ in 0..<5 where view.string != box.text {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(view.string, "あ\n- 1")
        layOut(view)
        assertEditorFont(in: view, range: NSRange(location: 1, length: 4))
        try assertJapaneseUsesFallbackFont(in: view, at: 0)
        window.contentView = nil
    }

    // MARK: - Helpers

    private final class TextBox: ObservableObject {
        @Published var text: String
        init(text: String) { self.text = text }
    }

    private struct Host: View {
        @ObservedObject var box: TextBox
        let model: MarkdownEditorModel

        var body: some View {
            MarkdownTextEditor(text: $box.text, model: model)
        }
    }

    private func findEditor(in view: NSView) -> EditorTextView? {
        if let editor = view as? EditorTextView { return editor }
        return view.subviews.lazy.compactMap { self.findEditor(in: $0) }.first
    }

    /// 編集画面（`MarkdownTextEditor`）と同じく、プレーンテキストで本文フォントを設定した編集ビュー。
    private func makeEditor() -> (EditorTextView, MarkdownEditorModel) {
        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.layoutManager?.delegate = view
        view.isRichText = false
        view.allowsUndo = true
        EditorTextStyle().apply(to: view)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        self.window = window
        let model = MarkdownEditorModel()
        self.model = model
        model.connect(view)
        view.commandModel = model
        return (view, model)
    }

    private var editorFont: NSFont { EditorTextStyle().font.font(size: CGFloat(EditorTextStyle().fontSize)) }

    private func type(_ text: String, into view: NSTextView) {
        view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// IME と同じく、マーク付きテキストで変換してから確定する。確定後に表示されたものとしてレイアウトする。
    private func compose(_ text: String, into view: NSTextView) {
        view.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        layOut(view)
    }

    /// レイアウトで `NSTextStorage` の属性補正（本文フォントにない文字への代替フォントの割り当て）を確定させる。
    private func layOut(_ view: NSTextView) {
        guard let layoutManager = view.layoutManager, let container = view.textContainer else { return }
        layoutManager.ensureLayout(for: container)
    }

    /// 前提の確認。日本語に代替フォントが付いていなければ、このテストは不具合を再現できない。
    private func assertJapaneseUsesFallbackFont(in view: NSTextView, at location: Int,
                                                file: StaticString = #filePath, line: UInt = #line) throws {
        let font = try XCTUnwrap(view.textStorage?.attribute(.font, at: location, effectiveRange: nil) as? NSFont,
                                 file: file, line: line)
        XCTAssertNotEqual(font.fontName, editorFont.fontName, file: file, line: line)
    }

    private func assertEditorFont(in view: NSTextView, range: NSRange,
                                  file: StaticString = #filePath, line: UInt = #line) {
        guard let storage = view.textStorage else { return XCTFail("No text storage", file: file, line: line) }
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            XCTAssertEqual((value as? NSFont)?.fontName, editorFont.fontName,
                           "\(storage.attributedSubstring(from: subrange).string.debugDescription) at \(subrange)",
                           file: file, line: line)
        }
    }

    /// 行頭のリスト記号（`- `）の描画幅。
    private func markerWidth(in view: NSTextView, at location: Int) -> CGFloat {
        guard let layoutManager = view.layoutManager, let container = view.textContainer else { return 0 }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: location, length: 2),
                                              actualCharacterRange: nil)
        return layoutManager.boundingRect(forGlyphRange: glyphs, in: container).width
    }
}
