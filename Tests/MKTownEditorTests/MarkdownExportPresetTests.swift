import AppKit
import PDFKit
import XCTest
@testable import MKTownEditor

@MainActor
final class MarkdownExportPresetTests: XCTestCase {
    func testPresetStorePersistsValidChoicesIndependently() throws {
        let name = "mktown-export-preset-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = MarkdownExportPresetStore(defaults: defaults)
        XCTAssertEqual(store.load(), [.standard])
        var preset = MarkdownExportPreset.standard
        preset.id = UUID()
        preset.name = "冊子"
        preset.bodyWidth = 620
        preset.font = .serif
        preset.margin = 64
        preset.cover = true
        preset.tableOfContents = true
        try store.save(preset)
        XCTAssertEqual(store.load(), [.standard, preset])
        let copied = try store.save(.standard)
        XCTAssertEqual(copied.name, "標準のコピー")
        XCTAssertEqual(store.load().first, .standard)
        XCTAssertNil(defaults.object(forKey: "editorFontSize"))
    }

    func testPresetValidationRejectsUnusableDimensions() {
        var preset = MarkdownExportPreset.standard
        preset.margin = 300
        XCTAssertFalse(preset.isValid)
        preset.margin = 48
        preset.bodyWidth = 0
        XCTAssertFalse(preset.isValid)
    }

    func testHTMLUsesPresetAndGeneratesCoverAndTOC() {
        var preset = MarkdownExportPreset.standard
        preset.bodyWidth = 640
        preset.fontSize = 18
        preset.font = .serif
        preset.margin = 64
        preset.cover = true
        preset.tableOfContents = true
        let html = MarkdownHTMLExporter.render("# **見出し**\n\n本文", preset: preset)
        XCTAssertTrue(html.contains("max-width: 640px"))
        XCTAssertTrue(html.contains("font: 18px/1.65"))
        XCTAssertTrue(html.contains("margin: 64pt"))
        XCTAssertTrue(html.contains("class=\"cover\""))
        XCTAssertTrue(html.contains("href=\"#見出し\""))
        XCTAssertTrue(html.contains("<h1>見出し</h1></section>"))
        XCTAssertTrue(html.contains("Hiragino Mincho"))
    }

    func testPDFUsesPresetMargins() {
        var preset = MarkdownExportPreset.standard
        preset.margin = 72
        let info = MarkdownPDFExporter.printInfo(
            destination: URL(fileURLWithPath: "/private/tmp/mktown-preset-test.pdf"),
            preset: preset
        )
        XCTAssertEqual(info.leftMargin, 72)
        XCTAssertEqual(info.rightMargin, 72)
        XCTAssertEqual(info.topMargin, 72)
        XCTAssertEqual(info.bottomMargin, 72)
        preset.bodyWidth = 400
        let view = try? MarkdownPDFExporter.printableView("本文", documentURL: nil,
                                                         printInfo: info, preset: preset)
        XCTAssertEqual(view?.bounds.width, 300)
    }

    func testPDFCoverStartsBodyOnFollowingPage() throws {
        var preset = MarkdownExportPreset.standard
        preset.cover = true
        let destination = URL(fileURLWithPath: "/private/tmp/mktown-cover-qa.pdf")
        try MarkdownPDFExporter.export("# 表紙の題名\n\n本文の段落", documentURL: nil,
                                       to: destination, preset: preset)
        let pdf = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertGreaterThanOrEqual(pdf.pageCount, 2)
        XCTAssertFalse(try XCTUnwrap(pdf.page(at: 0)).string?.contains("本文の段落") == true)
        XCTAssertTrue(try XCTUnwrap(pdf.page(at: 1)).string?.contains("本文の段落") == true)
    }
}
