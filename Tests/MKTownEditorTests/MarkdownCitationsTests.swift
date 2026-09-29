import AppKit
import XCTest
@testable import MKTownEditor

@MainActor
final class MarkdownCitationsTests: XCTestCase {
    func testBibTeXParserKeepsNestedFieldValuesAndOrder() {
        let source = """
        @comment{Do not parse @book{fake, title={Hidden}}}
        @string{abbrev={A Journal}}
        @article{smith2020,
          author = {Smith, Jane and Doe, John},
          title = {A {Nested} Study},
          year = 2020,
          journal = "Example Journal"
        }
        @book{book1, author={Yamada, Taro}, title={Second}, year={2022}}
        """
        let entries = BibTeXParser.parse(source)
        XCTAssertEqual(entries.map(\.key), ["smith2020", "book1"])
        XCTAssertEqual(entries[0].fields["title"], "A Nested Study")
        XCTAssertEqual(entries[0].fields["journal"], "Example Journal")
        XCTAssertTrue(entries[0].bibliographyText.contains("2020"))
    }

    func testCitationNumbersAreSharedByPreviewHTMLAndConverter() throws {
        let (directory, document) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let markdown = "Cite [@book1] then [@smith2020].\n\n`[@book1]` and [@missing]"
        let context = DocumentContext(fileURL: document)
        let preview = MarkdownRenderer.render(markdown, documentContext: context).string
        XCTAssertTrue(preview.contains("Cite [2] then [1]."))
        XCTAssertTrue(preview.contains("参考文献"))
        XCTAssertTrue(preview.contains("1. Smith"))
        XCTAssertTrue(preview.contains("`[@book1]`") || preview.contains("[@book1]"))
        XCTAssertTrue(preview.contains("[@missing]"))

        let html = MarkdownHTMLExporter.render(markdown, documentURL: document)
        XCTAssertTrue(html.contains("Cite [2] then [1]."))
        XCTAssertTrue(html.contains("class=\"bibliography\""))
        XCTAssertTrue(html.contains("<li>Smith"))
        let info = MarkdownPDFExporter.printInfo(destination: directory.appendingPathComponent("out.pdf"))
        let printView = try MarkdownPDFExporter.printableView(markdown, documentURL: document,
                                                              printInfo: info)
        XCTAssertTrue(printView.string.contains("Cite [2] then [1]."))
        XCTAssertTrue(printView.string.contains("参考文献"))

        let catalog = try XCTUnwrap(MarkdownCitationCatalog.load(documentURL: document))
        let converted = catalog.materialize(markdown)
        XCTAssertTrue(converted.contains("Cite [2] then [1]."))
        XCTAssertTrue(converted.contains("## 参考文献"))
        XCTAssertTrue(converted.contains("`[@book1]`"))
    }

    func testCitationInCodeFenceDoesNotCreateBibliography() throws {
        let (directory, document) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let markdown = "```markdown\n[@book1]\n```"
        let catalog = try XCTUnwrap(MarkdownCitationCatalog.load(documentURL: document))
        XCTAssertEqual(catalog.materialize(markdown), markdown)
        XCTAssertFalse(MarkdownHTMLExporter.render(markdown, documentURL: document)
            .contains("class=\"bibliography\""))
    }

    func testBasicDialectLeavesCitationsAndMathLiteralInHTML() throws {
        let (directory, document) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let html = MarkdownHTMLExporter.render("[@book1] and $x^2$", documentURL: document,
                                               dialect: .basic)
        XCTAssertTrue(html.contains("[@book1]"))
        XCTAssertTrue(html.contains("$x^2$"))
        XCTAssertFalse(html.contains("class=\"bibliography\""))
        XCTAssertFalse(html.contains("data:image/png;base64,"))
    }

    func testBibliographyFingerprintChangesAfterExternalEdit() throws {
        let (directory, document) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = MarkdownCitationCatalog.fingerprint(documentURL: document)
        let bib = directory.appendingPathComponent("references.bib")
        try "@book{new, title={Another}, year={2024}}".write(to: bib,
            atomically: true, encoding: .utf8)
        XCTAssertNotEqual(MarkdownCitationCatalog.fingerprint(documentURL: document), previous)
        XCTAssertEqual(MarkdownCitationCatalog.load(documentURL: document)?.entries.map(\.key), ["new"])
    }

    private func fixture() throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bib = """
        @article{smith2020, author={Smith, Jane}, title={First}, year={2020}}
        @book{book1, author={Yamada, Taro}, title={Second}, year={2022}}
        """
        try bib.write(to: directory.appendingPathComponent("references.bib"),
                      atomically: true, encoding: .utf8)
        return (directory, directory.appendingPathComponent("notes.md"))
    }
}
