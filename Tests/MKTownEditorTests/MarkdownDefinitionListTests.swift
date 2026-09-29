import AppKit
import XCTest
@testable import MKTownEditor

@MainActor
final class MarkdownDefinitionListTests: XCTestCase {
    func testParsesMultipleTermsDefinitionsAndContinuation() throws {
        let source = """
        API
        : **Application** programming interface
        : Public contract
          with a continuation
        SDK
        : Software development kit
        """
        let analysis = MarkdownAnalysis(source)
        let list = try XCTUnwrap(MarkdownDefinitionList(analysis.rootBlocks[0], dialect: .extended))
        XCTAssertEqual(list.entries.map(\.term), ["API", "SDK"])
        XCTAssertEqual(list.entries[0].definitions,
                       ["**Application** programming interface", "Public contract\nwith a continuation"])
        XCTAssertEqual(list.entries[1].definitions, ["Software development kit"])
        XCTAssertEqual(analysis.rootBlocks[0].sourceRange.length, (source as NSString).length)
    }

    func testNativePreviewHTMLAndPDFShareDefinitionStructure() throws {
        let source = "API\n: **Application** programming interface\n: Public contract"
        let native = MarkdownRenderer.render(source).string
        XCTAssertTrue(native.contains("API\n    Application programming interface"), native)
        XCTAssertTrue(native.contains("    Public contract"), native)
        let html = MarkdownHTMLExporter.render(source)
        XCTAssertTrue(html.contains("<dl><dt>API</dt><dd><strong>Application</strong> programming interface</dd><dd>Public contract</dd></dl>"), html)
        let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("definitions.pdf")
        let view = try MarkdownPDFExporter.printableView(source, documentURL: nil,
            printInfo: MarkdownPDFExporter.printInfo(destination: output))
        XCTAssertTrue(view.string.contains("API"))
        XCTAssertTrue(view.string.contains("Public contract"))
        XCTAssertEqual(MarkdownPlainTextExporter.render(source, options: MarkdownPlainTextOptions()),
                       "API — Application programming interface\nAPI — Public contract")
    }

    func testBasicDialectAndIncompleteSyntaxStayParagraphs() {
        let source = "API\n: Definition"
        let basic = MarkdownAnalysis(source, dialect: .basic)
        XCTAssertNil(MarkdownDefinitionList(basic.rootBlocks[0], dialect: .basic))
        XCTAssertFalse(MarkdownHTMLExporter.render(source, dialect: .basic).contains("<dl>"))
        let incomplete = MarkdownAnalysis("API\n: Definition\nstray line")
        XCTAssertNil(MarkdownDefinitionList(incomplete.rootBlocks[0], dialect: .extended))
        XCTAssertFalse(MarkdownHTMLExporter.render("API\n: Definition\nstray line").contains("<dl>"))
        let fenced = MarkdownAnalysis("```\nAPI\n: Definition\n```")
        XCTAssertNil(MarkdownDefinitionList(fenced.rootBlocks[0], dialect: .extended))
    }
}
