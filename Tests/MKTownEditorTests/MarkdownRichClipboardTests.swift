import AppKit
import XCTest
@testable import MKTownEditor

@MainActor
final class MarkdownRichClipboardTests: XCTestCase {
    func testPayloadKeepsFormattingAndProducesReadableText() throws {
        let payload = try MarkdownRichClipboard.payload(for: "**太字**と[リンク](https://example.com)",
                                                        documentURL: nil)
        XCTAssertTrue(payload.html.contains("<strong>太字</strong>"))
        XCTAssertTrue(payload.html.contains("href=\"https://example.com\""))
        XCTAssertEqual(payload.plainText, "太字とリンク")
        XCTAssertFalse(payload.rtf.isEmpty)
        XCTAssertTrue(String(decoding: payload.rtf, as: UTF8.self).hasPrefix("{\\rtf"))
    }

    func testCopyWritesThreePasteboardFormats() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("mktown-rich-copy-test"))
        defer { pasteboard.releaseGlobally() }
        try MarkdownRichClipboard.copy("# 見出し", documentURL: nil, to: pasteboard)
        XCTAssertTrue(pasteboard.types?.contains(.html) == true)
        XCTAssertTrue(pasteboard.types?.contains(.rtf) == true)
        XCTAssertTrue(pasteboard.types?.contains(.string) == true)
        XCTAssertEqual(pasteboard.string(forType: .string), "見出し")
        XCTAssertNotNil(pasteboard.data(forType: .rtf))
    }

    func testBasicDialectClipboardLeavesTableAsText() throws {
        let payload = try MarkdownRichClipboard.payload(
            for: "| A |\n| --- |\n| B |", documentURL: nil, dialect: .basic)
        XCTAssertFalse(payload.html.contains("<table>"))
        XCTAssertTrue(payload.plainText.contains("| A |"))
    }
}
