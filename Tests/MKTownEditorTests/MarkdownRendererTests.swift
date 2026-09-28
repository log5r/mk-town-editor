import AppKit
import XCTest
@testable import MKTownEditor

final class MarkdownRendererTests: XCTestCase {
    func testParserRecognizesCommonBlockTypes() {
        let blocks = MarkdownBlockParser.parse("# Title\n> Quote\n- Item\n2. Second\n---")

        XCTAssertEqual(blocks.map(\.kind), [
            .heading(level: 1),
            .quote,
            .unorderedList,
            .orderedList(number: 2),
            .horizontalRule
        ])
    }

    func testParserKeepsFencedCodeTogether() {
        let blocks = MarkdownBlockParser.parse("```swift\nlet value = 1\nprint(value)\n```")

        XCTAssertEqual(blocks, [
            MarkdownBlock(kind: .codeBlock, content: "let value = 1\nprint(value)")
        ])
    }

    @MainActor
    func testRendererRemovesMarkdownMarkersAndKeepsStructure() {
        let rendered = MarkdownRenderer.render("# **Title**\n\n- Item")

        XCTAssertEqual(rendered.string, "Title\n\n•  Item")
        XCTAssertNotNil(rendered.attribute(.font, at: 0, effectiveRange: nil))
    }
}
