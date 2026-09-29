import AppKit
import XCTest
@testable import MKTownEditor

@MainActor
final class MarkdownEmojiTests: XCTestCase {
    func testShortcodesRenderOfflineInPreviewHTMLAndPDF() throws {
        let source = "Hello :smile: :rocket: :unknown: <mark>:heart:</mark>"
        let native = MarkdownRenderer.render(source).string
        XCTAssertEqual(native, "Hello 😄 🚀 :unknown: ❤️")
        let html = MarkdownHTMLExporter.render(source)
        XCTAssertTrue(html.contains("Hello 😄 🚀 :unknown: <mark>❤️</mark>"), html)
        let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("emoji.pdf")
        let view = try MarkdownPDFExporter.printableView(source, documentURL: nil,
            printInfo: MarkdownPDFExporter.printInfo(destination: output))
        XCTAssertTrue(view.string.contains("Hello 😄 🚀 :unknown: ❤️"))
        XCTAssertEqual(MarkdownPlainTextExporter.render(source, options: MarkdownPlainTextOptions()),
                       "Hello 😄 🚀 :unknown: ❤️")
    }

    func testCodeEscapesAndBasicDialectRemainLiteral() {
        XCTAssertEqual(MarkdownEmoji.replace(in: "`:smile:` \\:smile: :smile:"),
                       "`:smile:` \\:smile: 😄")
        XCTAssertEqual(MarkdownEmoji.replace(in: "![image](assets/:smile:.png) <a href='/:rocket:'>go</a>"),
                       "![image](assets/:smile:.png) <a href='/:rocket:'>go</a>")
        XCTAssertTrue(MarkdownHTMLExporter.render("```\n:smile:\n```").contains(":smile:"))
        XCTAssertTrue(MarkdownHTMLExporter.render(":smile:", dialect: .basic).contains(":smile:"))
        XCTAssertTrue(MarkdownRenderer.render(":smile:",
            documentContext: DocumentContext(fileURL: nil, markdownDialect: .basic))
            .string.contains(":smile:"))
    }

    func testCompletionsUseBundledNamesAndExcludeCode() {
        let prefix = ":smi"
        XCTAssertEqual(MarkdownEmoji.completions(in: prefix,
            range: NSRange(location: 0, length: (prefix as NSString).length)),
            [":smile:", ":smiley:"])
        XCTAssertEqual(MarkdownEmoji.completions(in: "`:smi`",
            range: NSRange(location: 1, length: 4)), [])
        XCTAssertEqual(MarkdownEmoji.completions(in: "```\n:smi\n```",
            range: NSRange(location: 4, length: 4)), [])
        XCTAssertEqual(MarkdownEmoji.completions(in: "\\:smi",
            range: NSRange(location: 1, length: 4)), [])
        let editor = EditorTextView()
        editor.string = "Look :smi"
        editor.setSelectedRange(NSRange(location: 9, length: 0))
        let range = editor.rangeForUserCompletion
        XCTAssertEqual((editor.string as NSString).substring(with: range), ":smi")
        var selected = -1
        XCTAssertEqual(editor.completions(forPartialWordRange: range,
            indexOfSelectedItem: &selected), [":smile:", ":smiley:"])
        XCTAssertEqual(selected, 0)
    }
}
