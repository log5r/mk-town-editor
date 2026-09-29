import Foundation
import XCTest
@testable import MKTownEditor

final class AutomationDocumentWriterTests: XCTestCase {
    func testSaveCreatesUTF8DocumentWithoutOverwriting() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try AutomationDocumentWriter.destination(folderPath: folder.path,
            fileName: "日本語.md", extension: "md")
        try AutomationDocumentWriter.save("# 見出し\n本文", at: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# 見出し\n本文")
        XCTAssertThrowsError(try AutomationDocumentWriter.save("変更", at: url)) { error in
            XCTAssertEqual(error as? AutomationDocumentWriter.WriterError, .destinationExists)
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# 見出し\n本文")
    }

    func testRejectsTraversalEmptyNamesAndMissingFolders() throws {
        let folder = FileManager.default.temporaryDirectory
        for name in ["", ".", "..", "../outside", "sub/file", "a:b"] {
            XCTAssertThrowsError(try AutomationDocumentWriter.destination(folderPath: folder.path,
                fileName: name, extension: "md"), "\(name)")
        }
        XCTAssertThrowsError(try AutomationDocumentWriter.destination(
            folderPath: folder.appendingPathComponent(UUID().uuidString).path,
            fileName: "note", extension: "md"))
    }

    @MainActor
    func testHTMLExportUsesExistingRendererWithoutOverwriting() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.md")
        try "# Hello\n\n**World**".write(to: source, atomically: true, encoding: .utf8)
        let output = try AutomationDocumentWriter.destination(folderPath: folder.path,
            fileName: "page", extension: "html")
        try AutomationDocumentWriter.exportHTML(source: source, to: output)
        let html = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(html.contains("<h1"))
        XCTAssertTrue(html.contains("World"))
        XCTAssertThrowsError(try AutomationDocumentWriter.exportHTML(source: source, to: output))
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), html)
    }
}
