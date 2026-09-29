import AppKit
import PDFKit
import XCTest
@testable import MKTownEditor

@MainActor
final class MarkdownSlideDeckTests: XCTestCase {
    func testHorizontalRulesBecomeBoundariesOnlyInSlideDeck() {
        let source = "# First\n\nText\n\n---\n\n# Second\n\nMore"
        let deck = MarkdownSlideDeck(source)
        XCTAssertEqual(deck.slides, ["# First\n\nText", "# Second\n\nMore"])
        XCTAssertTrue(MarkdownHTMLExporter.render(source).contains("<hr>"))
        XCTAssertEqual(MarkdownSlideDeck("# Single").slides, ["# Single"])
        XCTAssertEqual(MarkdownSlideDeck("---\n\n# One\n\n---\n").slides, ["# One"])
    }

    func testFrontMatterAndSetextDoNotCreateExtraSlides() {
        let source = "---\ntitle: Demo\n---\n\nHeading\n---\n\nBody\n\n---\n\nEnd"
        let deck = MarkdownSlideDeck(source)
        XCTAssertEqual(deck.slides.count, 2)
        XCTAssertTrue(deck.slides[0].contains("Heading\n---"))
        XCTAssertFalse(deck.slides[0].contains("title: Demo"))
    }

    func testSlidePDFHasOneLandscapePagePerSlide() throws {
        let deck = MarkdownSlideDeck("# First\n\nHello\n\n---\n\n# Second\n\nWorld")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        try MarkdownSlidePDFExporter.export(deck, documentURL: nil, to: output)
        let pdf = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(pdf.pageCount, 2)
        XCTAssertGreaterThan(try XCTUnwrap(pdf.page(at: 0)).bounds(for: .mediaBox).width,
                             try XCTUnwrap(pdf.page(at: 0)).bounds(for: .mediaBox).height)
        XCTAssertTrue(pdf.string?.contains("First") == true)
        XCTAssertTrue(pdf.string?.contains("World") == true)
    }
}
