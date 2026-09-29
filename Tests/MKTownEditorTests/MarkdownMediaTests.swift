import AppKit
import XCTest
@testable import MKTownEditor

@MainActor
final class MarkdownMediaTests: XCTestCase {
    func testStandaloneLocalAudioAndVideoAreEligible() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("voice note.m4a")
        let video = folder.appendingPathComponent("demo.mp4")
        try Data([0]).write(to: audio)
        try Data([0]).write(to: video)
        let context = DocumentContext(fileURL: folder.appendingPathComponent("note.md"))
        let source = "!audio[Voice](voice%20note.m4a)\n\n!video[Demo](demo.mp4)"
        let blocks = MarkdownAnalysis(source).rootBlocks.filter { $0.kind == .paragraph }
        let first = try XCTUnwrap(MarkdownMedia(blocks[0], dialect: .extended))
        let second = try XCTUnwrap(MarkdownMedia(blocks[1], dialect: .extended))
        XCTAssertEqual(first.kind, .audio)
        XCTAssertEqual(first.localURL(in: context), audio)
        XCTAssertEqual(second.localURL(in: context), video)
        let html = MarkdownHTMLExporter.render(source, documentURL: context.fileURL)
        XCTAssertTrue(html.contains("<a href=\"file:"))
        XCTAssertTrue(html.contains("音声: Voice"))
        XCTAssertTrue(html.contains("動画: Demo"))
        XCTAssertFalse(html.contains("<audio"))
        let output = folder.appendingPathComponent("media.pdf")
        let view = try MarkdownPDFExporter.printableView(source, documentURL: context.fileURL,
            printInfo: MarkdownPDFExporter.printInfo(destination: output))
        XCTAssertTrue(view.string.contains("音声: Voice"))
        XCTAssertTrue(view.string.contains("動画: Demo"))
    }

    func testUnsupportedRemoteMissingAndBasicMediaUseFallback() throws {
        let source = "!audio[Song](https://example.com/song.mp3)"
        let remote = try XCTUnwrap(MarkdownMedia(MarkdownAnalysis(source).rootBlocks[0],
                                                 dialect: .extended))
        XCTAssertNil(remote.localURL(in: DocumentContext(fileURL: URL(fileURLWithPath: "/tmp/note.md"))))
        XCTAssertTrue(MarkdownHTMLExporter.render(source).contains("再生不可"))
        let unsupported = try XCTUnwrap(MarkdownMedia(
            MarkdownAnalysis("!video[Test](test.avi)").rootBlocks[0], dialect: .extended))
        XCTAssertNil(unsupported.localURL(in: DocumentContext(fileURL: URL(fileURLWithPath: "/tmp/note.md"))))
        XCTAssertNil(MarkdownMedia(MarkdownAnalysis(source, dialect: .basic).rootBlocks[0],
                                   dialect: .basic))
        XCTAssertNil(MarkdownMedia(MarkdownAnalysis("Text !audio[Song](song.mp3)").rootBlocks[0],
                                   dialect: .extended))
    }
}
