import AppKit
import XCTest
@testable import MKTownEditor

final class MarkdownRendererTests: XCTestCase {
    func testParserRecognizesCommonBlockTypes() {
        let blocks = MarkdownAnalysis("# Title\n> Quote\n- Item\n2. Second\n---").blocks

        XCTAssertEqual(blocks.map(\.kind), [
            .heading(level: 1),
            .quote,
            .unorderedList,
            .orderedList(number: 2),
            .horizontalRule
        ])
    }

    func testParserKeepsFencedCodeTogether() {
        let source = "```swift\nlet value = 1\nprint(value)\n```"
        let blocks = MarkdownAnalysis(source).blocks

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .codeBlock)
        XCTAssertEqual(blocks[0].content, "let value = 1\nprint(value)")
        XCTAssertEqual(blocks[0].codeLanguage, "swift")
        XCTAssertEqual(blocks[0].sourceRange, NSRange(location: 0, length: (source as NSString).length))
    }

    @MainActor
    func testRendererRemovesMarkdownMarkersAndKeepsStructure() {
        let rendered = MarkdownRenderer.render("# **Title**\n\n- Item")

        XCTAssertEqual(rendered.string, "Title\n\n•  Item")
        XCTAssertNotNil(rendered.attribute(.font, at: 0, effectiveRange: nil))
    }

    @MainActor
    func testRendererDistinguishesSoftAndHardParagraphBreaks() {
        let rendered = MarkdownRenderer.render("first\nsecond  \nthird\\\nfourth\n\nnext")

        XCTAssertEqual(rendered.string, "first second\nthird\nfourth\n\nnext")
    }
}
