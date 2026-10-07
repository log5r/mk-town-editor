import AppKit
import PDFKit
import XCTest
@testable import MKTownEditor

@MainActor
final class DocumentWorkTests: XCTestCase {
    func testPureWorkRunsOffMainThreadAndCancellationReachesWorker() async throws {
        let isMain = try await DocumentWork.perform { Thread.isMainThread }
        XCTAssertFalse(isMain)
        let task = Task {
            try await DocumentWork.perform {
                while !Task<Never, Never>.isCancelled { Thread.sleep(forTimeInterval: 0.001) }
                try Task.checkCancellation()
                return true
            }
        }
        await Task.yield()
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled work must not publish a result") }
        catch is CancellationError { }
    }

    func testAsyncHTMLKeepsMathTablesAndEmbeddedImages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([137, 80, 78, 71]).write(to: root.appendingPathComponent("image.png"))
        let source = "# Async\n\n$x^2$\n\n$$y^2$$\n\n| A | B |\n| --- | --- |\n| $z$ | **bold** |\n\n![image](image.png)"
        let url = root.appendingPathComponent("note.md")
        let expected = MarkdownHTMLExporter.render(source, documentURL: url)
        let actual = try await MarkdownHTMLExporter.renderAsync(source, documentURL: url)
        XCTAssertEqual(actual, expected)
        XCTAssertTrue(actual.contains("data:image/png;base64,"))
        XCTAssertTrue(actual.contains("math-block"))
        XCTAssertTrue(actual.contains("<strong>bold</strong>"))
        let references = try await MarkdownHTMLExporter.renderAsync("![image](image.png)", documentURL: url, images: .fileReferences)
        XCTAssertTrue(references.contains(root.appendingPathComponent("image.png").absoluteString))
        XCTAssertFalse(references.contains("data:image/png"))
    }

    func testAsyncImportAndClipboardUseRenderedAttributes() async throws {
        let html = "<h1>Title</h1><p>Hello <b>bold</b> and <a href=\"https://example.com\">link</a>.</p>"
        let imported = try await RichTextMarkdownImporter.convertAsync(Data(html.utf8), format: .html)
        XCTAssertTrue(imported.markdown.contains("# Title"), imported.markdown)
        XCTAssertTrue(imported.markdown.contains("**bold**"), imported.markdown)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try await MarkdownRichClipboard.copyAsync("**bold** [link](https://example.com)", documentURL: nil, to: board)
        XCTAssertTrue(board.string(forType: .html)?.contains("<strong>bold</strong>") == true)
        XCTAssertTrue(board.string(forType: .string)?.contains("bold link") == true)
        XCTAssertNotNil(board.data(forType: .rtf))
    }

    func testAsyncPDFProducesReadableOutputAndCancelledExportPreservesDestination() async throws {
        _ = NSApplication.shared
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("async-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: destination) }
        try await MarkdownPDFExporter.exportAsync("# Async PDF\n\nHello **world**.", documentURL: nil, to: destination)
        XCTAssertTrue(PDFDocument(url: destination)?.string?.contains("Hello world") == true)
        let original = try Data(contentsOf: destination)
        let cancelled = Task {
            try await MarkdownPDFExporter.exportAsync(String(repeating: "text\n\n", count: 1000), documentURL: nil, to: destination)
        }
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testRelatedExportCallersUseAsyncPipeline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("note.md")
        try Data("# Slide\n\nHello **world**.".utf8).write(to: source)
        let html = root.appendingPathComponent("note.html")
        try await AutomationDocumentWriter.exportHTMLAsync(source: source, to: html)
        XCTAssertTrue(try String(contentsOf: html, encoding: .utf8).contains("<strong>world</strong>"))
        let pdf = root.appendingPathComponent("slides.pdf")
        try await MarkdownSlidePDFExporter.exportAsync(MarkdownSlideDeck("# One\n\nHello\n\n---\n\n# Two"), documentURL: source, to: pdf)
        XCTAssertEqual(PDFDocument(url: pdf)?.pageCount, 2)
        let config = PublicationConfiguration(provider: .wordpress, endpoint: "https://example.com", account: "user", title: "Title", slug: "title", mode: .draft)
        let plan = try await PublicationPlan.makeAsync(config, markdown: "**body**", documentURL: source, credential: "test-placeholder")
        XCTAssertEqual(plan.preview, "<p><strong>body</strong></p>")
    }

    func testAsyncPortablePlanningPreservesResources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("image.png"))
        let plan = try await PortablePackagePlanner.planAsync(source: "![image](image.png)", documentURL: root.appendingPathComponent("note.md"))
        XCTAssertEqual(plan.assets.map(\.relativePath), ["assets/image.png"])
        XCTAssertTrue(plan.markdown.contains("assets/image.png"))
    }
}
