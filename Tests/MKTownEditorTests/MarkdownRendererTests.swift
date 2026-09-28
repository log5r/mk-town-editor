import AppKit
import XCTest
@testable import MKTownEditor

final class MarkdownRendererTests: XCTestCase {
    func testParserRecognizesCommonBlockTypes() {
        let blocks = MarkdownAnalysis("# Title\n> Quote\n- Item\n2. Second\n---").rootBlocks

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

    @MainActor
    func testNestedListAndContinuationAreVisuallyIndented() {
        let rendered = MarkdownRenderer.render("- parent\n  - child\n\n    continuation")
        let source = rendered.string as NSString
        let parent = rendered.attribute(.paragraphStyle, at: source.range(of: "parent").location,
                                        effectiveRange: nil) as? NSParagraphStyle
        let child = rendered.attribute(.paragraphStyle, at: source.range(of: "child").location,
                                       effectiveRange: nil) as? NSParagraphStyle
        let continuation = rendered.attribute(.paragraphStyle, at: source.range(of: "continuation").location,
                                              effectiveRange: nil) as? NSParagraphStyle

        XCTAssertEqual(rendered.string, "•  parent\n•  child\n\ncontinuation")
        XCTAssertGreaterThan(child?.firstLineHeadIndent ?? 0, parent?.firstLineHeadIndent ?? 0)
        XCTAssertGreaterThan(continuation?.firstLineHeadIndent ?? 0, child?.firstLineHeadIndent ?? 0)
    }

    @MainActor
    func testListParagraphContinuesOnNextLineWithoutExtraBullet() {
        let rendered = MarkdownRenderer.render("- parent\n  continued\n  - child")

        XCTAssertEqual(rendered.string, "•  parent continued\n•  child")
    }

    @MainActor
    func testQuoteRendersMultipleParagraphsListsCodeAndNestedQuote() {
        let markdown = "> first\n> second\n>\n> - item\n>   - child\n>\n> ```swift\n> let x = 1\n> ```\n>> nested"

        XCTAssertEqual(MarkdownRenderer.render(markdown).string,
                       "│  first second\n│  \n│  •  item\n│  •  child\n│  \n│  let x = 1\n│  │  nested")
    }

    @MainActor
    func testQuoteLazyContinuationAndOutsideParagraph() {
        XCTAssertEqual(MarkdownRenderer.render("> first\nsecond\n>\noutside").string,
                       "│  first second\n│  \noutside")
    }

    @MainActor
    func testIndentedAndFencedCodeRenderLiteralMarkdown() {
        let output = MarkdownRenderer.render("    **literal**\n\n    _again_\n\n~~~~python\n# text\n~~~~~")

        XCTAssertEqual(output.string, "**literal**\n\n_again_\n\n# text")
    }

    @MainActor
    func testIndentedCodeInsideListKeepsLiteralContent() {
        XCTAssertEqual(MarkdownRenderer.render("- item\n      **code**\n- next").string,
                       "•  item\n**code**\n•  next")
    }
}
