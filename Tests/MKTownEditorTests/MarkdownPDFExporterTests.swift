import AppKit
import PDFKit
import XCTest
@testable import MKTownEditor

@MainActor
final class MarkdownPDFExporterTests: XCTestCase {
    func testA4PrintSettingsUseReadableMargins() {
        let destination = URL(fileURLWithPath: "/private/tmp/mktown-print-settings.pdf")
        let info = MarkdownPDFExporter.printInfo(destination: destination)
        XCTAssertEqual(info.paperSize.width, 595.28, accuracy: 1)
        XCTAssertEqual(info.paperSize.height, 841.89, accuracy: 1)
        XCTAssertEqual(info.leftMargin, 48)
        XCTAssertEqual(info.rightMargin, 48)
        XCTAssertEqual(info.jobDisposition, .save)
    }

    func testPDFExportPaginatesLongDocumentAndIncludesTable() throws {
        let destination = URL(fileURLWithPath: "/private/tmp/mktown-pdf-qa.pdf")
        let paragraphs = Array(repeating: "長い文書の本文です。表と見出しを含むPDFとして読みやすく書き出します。", count: 30)
            .joined(separator: "\n\n")
        let markdown = "# PDF確認\n\n| 名前 | 点数 |\n| --- | ---: |\n| 花子 | 42 |\n\n" + paragraphs
        try MarkdownPDFExporter.export(markdown, documentURL: nil, to: destination)
        let pdf = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertGreaterThan(pdf.pageCount, 1)
        XCTAssertTrue((pdf.string ?? "").contains("PDF確認"))
        XCTAssertTrue((pdf.string ?? "").contains("花子"))
        XCTAssertEqual((pdf.string ?? "").components(separatedBy: "長い文書の本文です。").count - 1, 30)
        for pageIndex in 1..<pdf.pageCount {
            let pageText = try XCTUnwrap(pdf.page(at: pageIndex)).string ?? ""
            XCTAssertTrue(pageText.trimmingCharacters(in: .whitespacesAndNewlines)
                .hasPrefix("長い文書の本文です。"), "Page \(pageIndex + 1) begins mid-paragraph")
        }
        let bounds = try XCTUnwrap(pdf.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, 595.28, accuracy: 1)
        XCTAssertEqual(bounds.height, 841.89, accuracy: 1)
    }

    func testPrintSettingsRejectOversizedMargins() {
        let paper = NSSize(width: 300, height: 400)
        XCTAssertTrue(MarkdownPrintSettings().isValid(for: paper))
        var settings = MarkdownPrintSettings()
        settings.leftMargin = 150
        settings.rightMargin = 100
        XCTAssertFalse(settings.isValid(for: paper))
        settings.rightMargin = .nan
        XCTAssertFalse(settings.isValid(for: paper))
    }

    func testPrintLayoutIncludesSelectedHeaderAndFooter() throws {
        let destination = URL(fileURLWithPath: "/private/tmp/mktown-print-qa.pdf")
        let info = MarkdownPDFExporter.printInfo(destination: destination)
        var settings = MarkdownPrintSettings()
        settings.leftMargin = 64
        settings.header = true
        settings.footer = true
        try settings.apply(to: info)
        XCTAssertEqual(info.leftMargin, 64)
        XCTAssertEqual(info.dictionary()[NSPrintInfo.AttributeKey(rawValue: "NSPrintHeaderAndFooter")] as? Bool, true)
        let view = try MarkdownPDFExporter.printableView("# 印刷確認", documentURL: nil,
                                                         printInfo: info, title: "印刷書類",
                                                         header: settings.header, footer: settings.footer)
        XCTAssertEqual(view.pageHeader.string, "印刷書類")
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        XCTAssertTrue(operation.run())
        let pdf = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertTrue((pdf.string ?? "").contains("印刷確認"))
        XCTAssertTrue((pdf.string ?? "").contains("印刷書類"))
        XCTAssertTrue((pdf.string ?? "").contains("1 / 1"))
    }
}
