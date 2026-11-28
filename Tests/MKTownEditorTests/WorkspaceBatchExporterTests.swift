import Foundation
import XCTest
@testable import MKTownEditor

@MainActor
final class WorkspaceBatchExporterTests: XCTestCase {
    func testExportsNestedDocumentsAndUsesOpenBufferSnapshot() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("nested"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let first = source.appendingPathComponent("first.md")
        try Data("# Saved".utf8).write(to: first)
        try Data("# Nested".utf8).write(to: source.appendingPathComponent("nested/second.markdown"))
        let files = try WorkspaceBatchExporter.documents(in: source, excluding: destination)
        XCTAssertEqual(files.map(\.relativePath), ["first.md", "nested/second.markdown"])
        var updates: [Int] = []
        let report = try await WorkspaceBatchExporter.export(documents: files, to: destination,
            format: .html, openBuffers: [first.standardizedFileURL: MarkdownDocument(text: "# Draft")],
            progress: { done, _ in updates.append(done) })
        XCTAssertEqual(report.exported, 2)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(updates, [1, 2])
        let html = try String(contentsOf: destination.appendingPathComponent("first.html"),
                              encoding: .utf8)
        XCTAssertTrue(html.contains("Draft"))
        XCTAssertFalse(html.contains("Saved"))
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            destination.appendingPathComponent("nested/second.html").path))
    }

    func testExistingOutputAndInvalidDocumentAreReportedWithoutStoppingOthers() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("saved".utf8).write(to: source.appendingPathComponent("a.md"))
        try Data([0xFF]).write(to: source.appendingPathComponent("b.md"))
        try Data("fine".utf8).write(to: source.appendingPathComponent("c.md"))
        let existing = destination.appendingPathComponent("a.txt")
        try Data("existing".utf8).write(to: existing)
        let report = try await WorkspaceBatchExporter.export(
            documents: WorkspaceBatchExporter.documents(in: source), to: destination,
            format: .plainText)
        XCTAssertEqual(report.exported, 1)
        XCTAssertEqual(report.failures.map(\.source), ["a.md", "b.md"])
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "existing")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("c.txt"),
                                  encoding: .utf8), "fine")
    }

    func testMarkdownExportPreservesLegacyEncodingAndTextExportIncludesUnsavableEdits() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("note.md")
        let destination = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let original = try XCTUnwrap("日本語\r\n".data(using: .shiftJIS))
        try original.write(to: source)
        var buffer = try MarkdownDocument(data: original)
        buffer.text += "追記"
        let files = [BatchExportDocument(sourceURL: source, relativePath: "note.md")]
        let key = source.resolvingSymlinksInPath().standardizedFileURL
        let copy = try await WorkspaceBatchExporter.export(documents: files, to: destination,
            format: .markdown, openBuffers: [key: buffer])
        XCTAssertEqual(copy.exported, 1)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("note.md")),
                       try XCTUnwrap("日本語\r\n追記".data(using: .shiftJIS)))
        buffer.text += "😀"
        let text = try await WorkspaceBatchExporter.export(documents: files, to: destination,
            format: .plainText, openBuffers: [key: buffer])
        XCTAssertEqual(text.exported, 1)
        XCTAssertTrue(try String(contentsOf: destination.appendingPathComponent("note.txt"),
                                 encoding: .utf8).contains("追記😀"))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testCancellationStopsBeforeNextDocument() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: source.appendingPathComponent("a.md"))
        try Data("two".utf8).write(to: source.appendingPathComponent("b.md"))
        let report = try await WorkspaceBatchExporter.export(
            documents: WorkspaceBatchExporter.documents(in: source), to: destination,
            format: .markdown, progress: { done, _ in
                if done == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            })
        XCTAssertTrue(report.cancelled)
        XCTAssertEqual(report.exported, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            destination.appendingPathComponent("b.md").path))
    }

    func testTwoSourceExtensionsWithSameStemDoNotOverwrite() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: source.appendingPathComponent("same.md"))
        try Data("second".utf8).write(to: source.appendingPathComponent("same.markdown"))
        let report = try await WorkspaceBatchExporter.export(
            documents: WorkspaceBatchExporter.documents(in: source), to: destination,
            format: .html)
        XCTAssertEqual(report.exported, 1)
        XCTAssertEqual(report.failures.count, 1)
        let html = try String(contentsOf: destination.appendingPathComponent("same.html"),
                              encoding: .utf8)
        XCTAssertTrue(html.contains("first") != html.contains("second"))
    }

    private func temporaryFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch-export-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
