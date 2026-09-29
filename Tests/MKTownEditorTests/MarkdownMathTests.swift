import AppKit
import XCTest
@testable import MKTownEditor

@MainActor
final class MarkdownMathTests: XCTestCase {
    func testInlineMathAvoidsCurrencyEscapesAndCode() {
        let source = #"Price $5 and $6; $x^2+1$; \$literal$; `code $y$`"#
        let formulas = MarkdownMath.segments(source).compactMap { segment -> String? in
            if case let .formula(formula) = segment { return formula.latex }
            return nil
        }
        XCTAssertEqual(formulas, ["x^2+1"])
        XCTAssertTrue(MarkdownMath.segments("$5$").allSatisfy {
            if case .text = $0 { return true }
            return false
        })
    }

    func testDisplayMathRequiresOwnFenceLines() {
        XCTAssertEqual(MarkdownMath.displayFormula("$$\nx = \\frac{1}{2}\n$$")?.latex,
                       "x = \\frac{1}{2}")
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

    func testPDFPrintViewContainsRenderedEquation() throws {
        let info = MarkdownPDFExporter.printInfo(destination:
            URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("math.pdf"))
        let view = try MarkdownPDFExporter.printableView("Equation $x^2+1$ end", documentURL: nil,
                                                         printInfo: info)
        let text = try XCTUnwrap(view.textStorage)
        let range = (text.string as NSString).range(of: "\u{FFFC}")
        XCTAssertNotEqual(range.location, NSNotFound)
        XCTAssertNotNil(text.attribute(.attachment, at: range.location, effectiveRange: nil))
    }

    func testBasicDialectLeavesMathMarkersLiteral() {
        let context = DocumentContext(fileURL: nil, markdownDialect: .basic)
        let result = MarkdownRenderer.render("$x^2$", documentContext: context)
        XCTAssertEqual(result.string, "$x^2$")
    }
}
