import Foundation
import XCTest
#if canImport(MKTownMobileCore)
@testable import MKTownMobileCore
#else
@testable import MKTownEditorMobile
#endif

final class MobileMarkdownPreviewTests: XCTestCase {
    func testEmptyDocument() {
        XCTAssertTrue(MobileMarkdownPreview("").blocks.isEmpty)
    }

    func testHeadingsAndParagraphsStaySeparate() {
        let blocks = MobileMarkdownPreview("# 見出し\n\n本文🙂\n\n## 次の節").blocks
        XCTAssertEqual(blocks.map { String($0.text.characters) }, ["見出し", "本文🙂", "次の節"])
        XCTAssertEqual(blocks.map(\.headingLevel), [1, nil, 2])
        XCTAssertEqual(Set(blocks.map(\.id)).count, blocks.count)
    }

    func testInlineRunsStayInOneParagraphAndKeepAttributes() {
        let blocks = MobileMarkdownPreview("普通 **太字** と [リンク](https://example.com)").blocks
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(String(blocks[0].text.characters), "普通 太字 と リンク")
        XCTAssertTrue(blocks[0].text.runs.contains {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        })
        XCTAssertTrue(blocks[0].text.runs.contains { $0.link == URL(string: "https://example.com") })
        XCTAssertTrue(blocks[0].text.runs.allSatisfy { $0.presentationIntent == nil })
    }

    func testCodeIsLiteralAndKeepsLineBreaks() {
        let blocks = MobileMarkdownPreview("```swift\nlet x = 1\n**literal**\n```").blocks
        XCTAssertEqual(blocks.count, 1)
        XCTAssertTrue(blocks[0].isCode)
        XCTAssertTrue(String(blocks[0].text.characters).contains("let x = 1\n**literal**"))
    }

    func testListItemsAndQuote() {
        let blocks = MobileMarkdownPreview("1. First\n2. Second\n\n> Quoted").blocks
        XCTAssertEqual(blocks.map(\.listMarker), ["1.", "2.", nil])
        XCTAssertTrue(blocks[2].isQuote)
    }

    func testNestedUnorderedList() {
        let blocks = MobileMarkdownPreview("- Parent\n  - Child").blocks
        XCTAssertEqual(blocks.map(\.listMarker), ["•", "•"])
        XCTAssertEqual(blocks.map(\.indentation), [0, 1])
    }

    func testMalformedMarkdownStillDisplaysText() {
        let blocks = MobileMarkdownPreview("unclosed **bold [link").blocks
        XCTAssertEqual(String(blocks.flatMap { $0.text.characters }), "unclosed **bold [link")
    }

    func testNestedListUsesTheNearestListKind() {
        let blocks = MobileMarkdownPreview("1. Parent\n   - Child\n     1. Grandchild").blocks
        XCTAssertEqual(blocks.map(\.listMarker), ["1.", "•", "1."])
        XCTAssertEqual(blocks.map(\.indentation), [0, 1, 2])
    }

    func testImageAlternativeTextIsVisible() {
        let blocks = MobileMarkdownPreview("![風景](photo.png)").blocks
        XCTAssertEqual(String(blocks.flatMap { $0.text.characters }), "風景")
    }

    func testContinuationParagraphDoesNotRepeatTheListMarker() {
        let blocks = MobileMarkdownPreview("1. First\n\n   Continued\n\n2. Second").blocks
        XCTAssertEqual(blocks.map(\.listMarker), ["1.", nil, "2."])
        XCTAssertEqual(blocks.map { String($0.text.characters) }, ["First", "Continued", "Second"])
    }
}
