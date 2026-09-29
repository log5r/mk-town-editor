import AppKit
import XCTest
@testable import MKTownEditor

@MainActor
final class MarkdownInlineExtensionsTests: XCTestCase {
    func testMarkupRendersInNativeHTMLAndPDF() throws {
        let source = "See <mark>important</mark> x<sup>2</sup> H<sub>2</sub>O."
        let native = MarkdownRenderer.render(source)
        XCTAssertEqual(native.string, "See important x2 H2O.")
        let mark = (native.string as NSString).range(of: "important")
        XCTAssertNotNil(native.attribute(.backgroundColor, at: mark.location, effectiveRange: nil))
        let raised = (native.string as NSString).range(of: "x2")
        XCTAssertGreaterThan(native.attribute(.baselineOffset, at: raised.location + 1,
                                             effectiveRange: nil) as? CGFloat ?? 0, 0)
        let lowered = (native.string as NSString).range(of: "H2")
        XCTAssertLessThan(native.attribute(.baselineOffset, at: lowered.location + 1,
                                          effectiveRange: nil) as? CGFloat ?? 0, 0)
        let html = MarkdownHTMLExporter.render(source)
        XCTAssertTrue(html.contains("<mark>important</mark>"))
        XCTAssertTrue(html.contains("<sup>2</sup>"))
        XCTAssertTrue(html.contains("<sub>2</sub>"))
        let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inline-extensions.pdf")
        let view = try MarkdownPDFExporter.printableView(source, documentURL: nil,
            printInfo: MarkdownPDFExporter.printInfo(destination: output))
        XCTAssertTrue(view.string.contains("See important x2 H2O."))
    }

    func testCodeEscapesBasicDialectAndUnsupportedAttributesRemainLiteral() {
        let source = "`<mark>code</mark>` \\<mark>escaped</mark> <mark class='x'>attribute</mark>"
        let parsed = MarkdownInlineExtensions.placeholders(in: source)
        XCTAssertTrue(parsed.items.isEmpty)
        let basic = MarkdownHTMLExporter.render("<mark>text</mark>", dialect: .basic)
        XCTAssertFalse(basic.contains("<mark>text</mark>"))
        XCTAssertTrue(basic.contains("未対応HTML要素"))
        let fenced = MarkdownHTMLExporter.render("```\n<sup>2</sup>\n```")
        XCTAssertTrue(fenced.contains("&lt;sup&gt;2&lt;/sup&gt;"))
    }

    func testCommandsWrapAndUnwrapSelection() {
        for (style, tag) in [(MarkdownFormattingStyle.highlight, "mark"),
                             (.superscript, "sup"), (.subscriptText, "sub")] {
            let edit = MarkdownFormatter.apply(style, to: "abc", selection: NSRange(location: 1, length: 1))
            let wrapped = "a<\(tag)>b</\(tag)>c"
            XCTAssertEqual(edit.applying(to: "abc"), wrapped)
            XCTAssertEqual(edit.selection.length, 1)
            let undo = MarkdownFormatter.apply(style, to: wrapped, selection: edit.selection)
            XCTAssertEqual(undo.applying(to: wrapped), "abc")
        }
        XCTAssertTrue(EditorCommand.palette.contains(.highlight))
        XCTAssertTrue(EditorCommand.context.contains(.superscript))
    }

    func testOuterEmphasisIsRetained() {
        let rendered = MarkdownRenderer.render("**<mark>important</mark>**")
        XCTAssertEqual(rendered.string, "important")
        let font = rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false)
    }
}
