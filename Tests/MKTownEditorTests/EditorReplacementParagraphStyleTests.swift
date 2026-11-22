import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

/// 編集コマンドと外部変更の反映が、入力属性（`typingAttributes`）の段落スタイルと文字方向を置換文字に広げないことを確かめる。
///
/// プレーンテキストの `NSTextView` で段落の書字方向を変える（⌃⌘← の `makeBaseWritingDirectionRightToLeft:`）と、
/// キャレットのある段落だけが右から左・右揃えになり、入力属性も右から左になる。入力属性はキャレットを別の段落へ
/// 動かしても戻らない。置換文字に入力属性をそのまま付けると、書き換えた段落や再読み込みした全文が右から左になった。
@MainActor
final class EditorReplacementParagraphStyleTests: XCTestCase {
    private var window: NSWindow?
    /// `EditorTextView.commandModel` は弱参照のため、テスト中はここで保持する。
    private var model: MarkdownEditorModel?

    override func tearDown() {
        window?.contentView = nil
        window = nil
        model = nil
        super.tearDown()
    }

    /// 別の段落の先頭から始まる選択範囲を書式変更しても、その段落の方向と揃えは変わらない。
    func testFormattingSelectionAtParagraphStartKeepsItsParagraphStyle() throws {
        let (view, model) = makeEditor()
        type("abc\ndef\nghi", into: view)
        try makeParagraphRightToLeft(in: view, at: 5)
        let original = paragraphStyle(in: view, at: 8)
        XCTAssertNotEqual(original?.baseWritingDirection, .rightToLeft)

        view.setSelectedRange(NSRange(location: 8, length: 3))
        model.apply(.bold)

        XCTAssertEqual(view.string, "abc\ndef\n**ghi**")
        layOut(view)
        XCTAssertEqual(paragraphStyle(in: view, at: 8), original)
        XCTAssertEqual(paragraphStyle(in: view, at: 4)?.baseWritingDirection, .rightToLeft)
    }

    /// 段落の先頭に空の範囲で挿入した文字は、直前の段落ではなく挿入先の段落の段落スタイルを持つ。
    /// 画像のドロップや記号の補完は、キャレット位置に空の範囲で挿入する。
    func testInsertionAtParagraphStartKeepsDestinationParagraphStyle() throws {
        let (view, _) = makeEditor()
        type("abc\ndef\nghi", into: view)
        try makeParagraphRightToLeft(in: view, at: 5)
        let original = paragraphStyle(in: view, at: 8)

        view.replaceEditorCharacters(in: NSRange(location: 8, length: 0), with: "# ")

        XCTAssertEqual(view.string, "abc\ndef\n# ghi")
        layOut(view)
        XCTAssertEqual(paragraphStyle(in: view, at: 8), original)
        XCTAssertEqual(paragraphStyle(in: view, at: 4)?.baseWritingDirection, .rightToLeft)
        assertEditorFont(in: view, range: NSRange(location: 8, length: 2))
    }

    /// 外部変更の反映は、入力属性の段落スタイルを全文に広げず、開いたときと同じ方向と行の高さにする。
    func testExternalTextChangeKeepsDefaultDirectionAndLineHeight() async throws {
        let (view, box, host) = try makeHostedEditor(text: "abc\ndef\nghi")
        let openedLineHeight = lineHeight(in: view)
        try makeParagraphRightToLeft(in: view, at: 5)

        box.text = "abc\ndef\nghi\njkl"
        try await waitForText(box.text, in: view, host: host)

        layOut(view)
        for location in [0, 4, 8, 12] {
            let style = paragraphStyle(in: view, at: location)
            XCTAssertEqual(style?.baseWritingDirection ?? .natural, .natural, "paragraph at \(location)")
            XCTAssertEqual(style?.alignment ?? .natural, .natural, "paragraph at \(location)")
        }
        XCTAssertEqual(lineHeight(in: view), openedLineHeight)
        assertEditorFont(in: view, range: NSRange(location: 0, length: (view.string as NSString).length))
    }

    /// 文字方向の入力属性（⌥⌃⌘← の `makeTextWritingDirectionRightToLeft:`）を、書式変更の記号にも再読み込みした全文にも付けない。
    func testReplacementsDoNotApplyTypingWritingDirection() async throws {
        let (view, box, host) = try makeHostedEditor(text: "abc\ndef")
        let model = try XCTUnwrap(view.commandModel)
        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.doCommand(by: #selector(NSTextView.makeTextWritingDirectionRightToLeft(_:)))
        XCTAssertNotNil(view.typingAttributes[.writingDirection], "前提: 入力属性に文字方向が入る")

        view.setSelectedRange(NSRange(location: 4, length: 3))
        model.apply(.bold)
        XCTAssertEqual(view.string, "abc\n**def**")
        assertNoWritingDirection(in: view)

        box.text = "xyz\nuvw"
        try await waitForText(box.text, in: view, host: host)
        assertNoWritingDirection(in: view)
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

    /// `NSHostingView` に載せた実際の編集画面。本文は開いたときの経路（`makeNSView`）で入る。
    private func makeHostedEditor(text: String) throws -> (EditorTextView, TextBox, NSHostingView<Host>) {
        let box = TextBox(text: text)
        let model = MarkdownEditorModel()
        self.model = model
        let host = NSHostingView(rootView: Host(box: box, model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        let view = try XCTUnwrap(findEditor(in: host))
        layOut(view)
        return (view, box, host)
    }

    private func findEditor(in view: NSView) -> EditorTextView? {
        if let editor = view as? EditorTextView { return editor }
        return view.subviews.lazy.compactMap { self.findEditor(in: $0) }.first
    }

    private func waitForText(_ text: String, in view: NSTextView, host: NSView) async throws {
        for _ in 0..<5 where view.string != text {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(view.string, text)
    }

    private func type(_ text: String, into view: NSTextView) {
        view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// ⌃⌘← と同じ操作で、`location` の段落を右から左にする。入力属性も右から左になったことを前提として確かめる。
    private func makeParagraphRightToLeft(in view: NSTextView, at location: Int,
                                          file: StaticString = #filePath, line: UInt = #line) throws {
        view.setSelectedRange(NSRange(location: location, length: 0))
        view.doCommand(by: #selector(NSTextView.makeBaseWritingDirectionRightToLeft(_:)))
        XCTAssertEqual(paragraphStyle(in: view, at: location)?.baseWritingDirection, .rightToLeft,
                       "前提: 段落が右から左になる", file: file, line: line)
        let typing = try XCTUnwrap(view.typingAttributes[.paragraphStyle] as? NSParagraphStyle, file: file, line: line)
        XCTAssertEqual(typing.baseWritingDirection, .rightToLeft, "前提: 入力属性が右から左になる", file: file, line: line)
    }

    private func layOut(_ view: NSTextView) {
        guard let layoutManager = view.layoutManager, let container = view.textContainer else { return }
        layoutManager.ensureLayout(for: container)
    }

    private func paragraphStyle(in view: NSTextView, at location: Int) -> NSParagraphStyle? {
        view.textStorage?.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
    }

    private func lineHeight(in view: NSTextView) -> CGFloat {
        guard let layoutManager = view.layoutManager else { return 0 }
        layOut(view)
        return layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).height
    }

    private var editorFont: NSFont { EditorTextStyle().font.font(size: CGFloat(EditorTextStyle().fontSize)) }

    private func assertEditorFont(in view: NSTextView, range: NSRange,
                                  file: StaticString = #filePath, line: UInt = #line) {
        guard let storage = view.textStorage else { return XCTFail("No text storage", file: file, line: line) }
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            XCTAssertEqual((value as? NSFont)?.fontName, editorFont.fontName,
                           "\(storage.attributedSubstring(from: subrange).string.debugDescription) at \(subrange)",
                           file: file, line: line)
        }
    }

    private func assertNoWritingDirection(in view: NSTextView, file: StaticString = #filePath, line: UInt = #line) {
        guard let storage = view.textStorage else { return XCTFail("No text storage", file: file, line: line) }
        storage.enumerateAttribute(.writingDirection, in: NSRange(location: 0, length: storage.length)) { value, subrange, _ in
            XCTAssertNil(value, "\(storage.attributedSubstring(from: subrange).string.debugDescription) at \(subrange)",
                         file: file, line: line)
        }
    }
}
