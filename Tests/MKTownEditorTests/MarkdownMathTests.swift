import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

@MainActor
final class MarkdownMathTests: XCTestCase {
    func testInlineMathSurvivesActualPreviewLayoutInEveryTextContainer() throws {
        for source in [
            "本文中に $E = mc^2$ のように書けます。",
            "# 見出し $E = mc^2$",
            "- [ ] タスク $E = mc^2$",
            "| 式 |\n| --- |\n| $E = mc^2$ |",
            "> 引用 $E = mc^2$",
            "> [!NOTE]\n> 注記 $E = mc^2$",
            "脚注[^1]\n\n[^1]: $E = mc^2$",
            "[リンク](https://example.com) $E = mc^2$"
        ] {
            let host = NSHostingView(rootView: MarkdownPreview(
                markdown: source, documentContext: DocumentContext(fileURL: nil)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            host.frame = window.contentView?.bounds ?? .zero
            host.layoutSubtreeIfNeeded()
            defer { window.contentView = nil }

            func textViews(in view: NSView) -> [NSTextView] {
                (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
            }
            let views = textViews(in: host).filter { $0.string.contains("\u{FFFC}") }
            XCTAssertFalse(views.isEmpty, source)
            for view in views {
                let location = (view.string as NSString).range(of: "\u{FFFC}").location
                let attachment = try XCTUnwrap(view.attributedString().attribute(
                    .attachment, at: location, effectiveRange: nil) as? NSTextAttachment, source)
                let image = try XCTUnwrap(attachment.image, source)
                let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
                XCTAssertTrue((0..<bitmap.pixelsHigh).contains { y in
                    (0..<bitmap.pixelsWide).contains { x in
                        (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1
                    }
                }, "Formula bitmap must contain visible pixels: \(source)")
                let manager = try XCTUnwrap(view.layoutManager)
                let container = try XCTUnwrap(view.textContainer)
                manager.ensureLayout(for: container)
                let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: location, length: 1),
                                               actualCharacterRange: nil)
                let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
                XCTAssertGreaterThan(rect.width, 20, source)
                XCTAssertGreaterThan(rect.height, 5, source)
                XCTAssertGreaterThan(view.frame.height, 0, source)
            }
        }
    }

    func testInlineMathAvoidsCurrencyEscapesAndCode() {
        let source = #"Price $5 and $6; $x^2+1$; \$literal$; `code $y$`"#
        let formulas = MarkdownMath.segments(source).compactMap { segment -> String? in
            if case let .formula(formula) = segment { return formula.latex }
            return nil
        }
        XCTAssertEqual(formulas, ["x^2+1"])
        XCTAssertEqual(MarkdownMath.segments("$5$"), [
            .formula(.init(source: "$5$", latex: "5", display: false))
        ])
    }

    func testDisplayMathSupportsSingleAndMultipleLines() {
        XCTAssertEqual(MarkdownMath.displayFormula("$$\nx = \\frac{1}{2}\n$$")?.latex,
                       "x = \\frac{1}{2}")
        XCTAssertEqual(MarkdownMath.displayFormula("$$x^2$$")?.latex, "x^2")
        XCTAssertEqual(MarkdownMath.displayFormula("$$ x^2\n+ y^2 $$")?.latex, "x^2\n+ y^2")
        XCTAssertNil(MarkdownMath.displayFormula("$$x$$ $$y$$"))
        XCTAssertNil(MarkdownMath.displayFormula("before $$x$$ after"))
        XCTAssertNil(MarkdownMath.displayFormula("$$\n \n$$"))
    }

    func testPreviewAndHTMLRenderMathAndPreserveMalformedFormula() {
        let inline = MarkdownRenderer.render("Value $x^2+1$ end")
        XCTAssertNotNil(inline.attribute(.attachment,
            at: (inline.string as NSString).range(of: "\u{FFFC}").location,
            effectiveRange: nil))
        let html = MarkdownHTMLExporter.render("Value $x^2+1$ end")
        XCTAssertTrue(html.contains("data:image/png;base64,"))
        XCTAssertTrue(html.contains("alt=\"x^2+1\""))

        let malformed = MarkdownRenderer.render("$\\unknowncommand$")
        XCTAssertTrue(malformed.string.contains("$\\unknowncommand$"))
        let malformedHTML = MarkdownHTMLExporter.render("$\\unknowncommand$")
        XCTAssertTrue(malformedHTML.contains("$\\unknowncommand$"))
    }

    func testBlockMathRendersInPreviewAndHTML() {
        let source = "$$\nx^2 + y^2 = z^2\n$$"
        let analysis = MarkdownAnalysis(source)
        XCTAssertNotNil(analysis.blocks.first.flatMap { MarkdownMath.displayFormula($0.content) })
        XCTAssertTrue(MarkdownRenderer.render(source).string.contains("\u{FFFC}"))
        XCTAssertTrue(MarkdownHTMLExporter.render(source).contains("class=\"math-block\""))
    }

    func testDisplayBlocksDoNotNeedSurroundingBlankLines() {
        for newline in ["\n", "\r\n", "\r"] {
            let source = ["Before", "$$x^2$$", "$$", #"\frac{1}{2}"#, "", "+ y", "$$", "After"]
                .joined(separator: newline)
            let blocks = MarkdownAnalysis(source).blocks
            XCTAssertEqual(blocks.count, 4)
            XCTAssertEqual(blocks.first?.content, "Before")
            XCTAssertEqual(blocks.last?.content, "After")
            let formulas = blocks.compactMap { MarkdownMath.displayFormula($0.content) }
            XCTAssertEqual(formulas.count, 2)
            for block in blocks.dropFirst().dropLast() {
                let original = (source as NSString).substring(with: block.sourceRange)
                XCTAssertNotNil(MarkdownMath.displayFormula(original))
            }
            let rendered = MarkdownRenderer.render(source)
            XCTAssertEqual(rendered.string.filter { $0 == "\u{FFFC}" }.count, 2)
            XCTAssertEqual(MarkdownHTMLExporter.render(source)
                .components(separatedBy: "class=\"math-block\"").count - 1, 2)
        }
    }

    func testMathKeepsCodeEscapesAndUnclosedDelimitersLiteral() {
        for source in ["```tex\n$$x^2$$\n```", "    $$x^2$$", #"\$x^2$"#,
                       "`$x^2$`", "$$x^2", "$ x $", "$5 and $6"] {
            XCTAssertFalse(MarkdownRenderer.render(source).string.contains("\u{FFFC}"), source)
            XCTAssertFalse(MarkdownHTMLExporter.render(source).contains("class=\"math\""), source)
        }
        for newline in ["\n", "\r", "\r\n"] {
            XCTAssertEqual(MarkdownMath.segments("$x" + newline + "y$"),
                           [.text("$x" + newline + "y$")])
        }
    }

    func testDisplayMathAfterListAndTable() {
        for source in ["- Item\n  $$x^2$$\nAfter", "| A |\n| --- |\n| B |\n$$x^2$$"] {
            let blocks = MarkdownAnalysis(source).blocks
            XCTAssertEqual(blocks.compactMap { MarkdownMath.displayFormula($0.content) }.count, 1)
            XCTAssertTrue(MarkdownRenderer.render(source).string.contains("\u{FFFC}"))
        }
        let source = "$$\n" + #"\text{price: \$$}"# + "\n$$"
        XCTAssertEqual(MarkdownAnalysis(source).blocks.count, 1)
        XCTAssertNotNil(MarkdownMath.displayFormula(source))
    }

    func testQuotedDisplayMathAndEquationReferences() {
        let quote = MarkdownAnalysis("> Before\n> $$x^2$$\n> After")
        XCTAssertEqual(quote.blocks.compactMap { MarkdownMath.displayFormula($0.content) }.count, 1)
        let source = "$$x^2$$\n{#eq:square}\n\nSee @eq:square"
        let analysis = MarkdownAnalysis(source)
        XCTAssertEqual(analysis.crossReferences.targets.first?.key, "eq:square")
        XCTAssertTrue(MarkdownHTMLExporter.render(source).contains("math-block"))
    }

    func testBasicDialectLeavesDisplayMathLiteral() {
        let context = DocumentContext(fileURL: nil, markdownDialect: .basic)
        for source in ["$$x^2$$", "$$\nx^2\n$$"] {
            XCTAssertFalse(MarkdownRenderer.render(source, documentContext: context)
                .string.contains("\u{FFFC}"))
            XCTAssertFalse(MarkdownHTMLExporter.render(source, dialect: .basic)
                .contains("class=\"math\""))
        }
    }

    func testPDFPrintViewContainsRenderedEquation() throws {
        let info = MarkdownPDFExporter.printInfo(destination:
            URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("math.pdf"))
        let view = try MarkdownPDFExporter.printableView("Equation $x^2+1$ end\n$$x^2$$", documentURL: nil,
                                                         printInfo: info)
        let text = try XCTUnwrap(view.textStorage)
        let range = (text.string as NSString).range(of: "\u{FFFC}")
        XCTAssertNotEqual(range.location, NSNotFound)
        XCTAssertNotNil(text.attribute(.attachment, at: range.location, effectiveRange: nil))
        XCTAssertEqual(text.string.filter { $0 == "\u{FFFC}" }.count, 2)
    }

    func testBasicDialectLeavesMathMarkersLiteral() {
        let context = DocumentContext(fileURL: nil, markdownDialect: .basic)
        let result = MarkdownRenderer.render("$x^2$", documentContext: context)
        XCTAssertEqual(result.string, "$x^2$")
    }
}
