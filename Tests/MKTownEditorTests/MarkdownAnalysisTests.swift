import Foundation
import XCTest
@testable import MKTownEditor

final class MarkdownAnalysisTests: XCTestCase {
    func testEveryBlockRangePointsIntoOriginalUnicodeSource() {
        let source = "# 題🙂\r\n\r\n- 一\r\n  - 二\r\n"
        let analysis = MarkdownAnalysis(source)
        let original = source as NSString

        XCTAssertEqual(analysis.blocks.map(\.kind), [
            .heading(level: 1), .blank, .unorderedList, .unorderedList, .blank
        ])
        XCTAssertEqual(analysis.blocks.map { original.substring(with: $0.sourceRange) }, [
            "# 題🙂\r\n", "\r\n", "- 一\r\n", "  - 二\r\n", ""
        ])
        for block in analysis.blocks {
            XCTAssertNotNil(analysis.positionMap.positions(for: block.sourceRange))
        }
    }

    func testNestedListsAndQuotesExposeParentChildRelationships() {
        let analysis = MarkdownAnalysis("- parent\n  1. child\n  - sibling\n- next\n> quote\n>> nested")

        XCTAssertEqual(analysis.rootBlocks.map(\.id), [0, 3, 4])
        XCTAssertEqual(analysis.children(of: analysis.blocks[0]).map(\.id), [1, 2])
        XCTAssertEqual(analysis.children(of: analysis.blocks[4]).map(\.id), [5])
        XCTAssertEqual(analysis.blocks[1].kind, .orderedList(number: 1))
        XCTAssertEqual(analysis.blocks[1].sourceIndent, "  ")
        XCTAssertEqual(analysis.blocks[1].nestingDepth, 1)
        XCTAssertEqual(analysis.blocks[3].nestingDepth, 0)
    }

    func testLongerClosingFenceAndUnclosedFenceKeepSourceRange() {
        let source = "~~~~rust\nlet x = 1\n~~~~~\n```swift\nunfinished"
        let blocks = MarkdownAnalysis(source).blocks

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.map(\.codeLanguage), ["rust", "swift"])
        XCTAssertEqual(blocks[1].content, "unfinished")
        XCTAssertEqual(NSMaxRange(blocks[1].sourceRange), (source as NSString).length)
    }

    func testParagraphGroupsLinesAndClassifiesBreaks() {
        let source = "first\nsecond  \nthird\\\nfourth\n\nnext"
        let analysis = MarkdownAnalysis(source)

        XCTAssertEqual(analysis.blocks.map(\.kind), [.paragraph, .blank, .paragraph])
        XCTAssertEqual(analysis.blocks[0].lineBreaks, [.soft, .hard, .hard])
        XCTAssertEqual((source as NSString).substring(with: analysis.blocks[0].sourceRange),
                       "first\nsecond  \nthird\\\nfourth\n")
    }

    func testEvenBackslashesRemainASoftBreak() {
        let analysis = MarkdownAnalysis("escaped\\\\\nnext")

        XCTAssertEqual(analysis.blocks[0].lineBreaks, [.soft])
    }

    func testListItemCanContainMultipleParagraphsAndMixedNestedMarkers() {
        let source = "- parent\n\n  second paragraph\n  continues  \n  here\n  1. ordered child\n  - bullet child\n- next"
        let analysis = MarkdownAnalysis(source)
        let parent = analysis.blocks[0]

        XCTAssertEqual(analysis.children(of: parent).map(\.kind), [
            .blank, .paragraph, .orderedList(number: 1), .unorderedList
        ])
        XCTAssertEqual(analysis.blocks[2].content, "second paragraph\ncontinues  \nhere")
        XCTAssertEqual(analysis.blocks[2].lineBreaks, [.soft, .hard])
        XCTAssertEqual(analysis.blocks.last?.parentID, nil)
    }

    func testImmediateContinuationStaysInFirstListParagraph() {
        let source = "- parent\n  continued\n  - child"
        let analysis = MarkdownAnalysis(source)

        XCTAssertEqual(analysis.blocks.count, 2)
        XCTAssertEqual(analysis.blocks[0].content, "parent\ncontinued")
        XCTAssertEqual(analysis.blocks[0].lineBreaks, [.soft])
        XCTAssertEqual(analysis.blocks[1].parentID, analysis.blocks[0].id)
    }
}
