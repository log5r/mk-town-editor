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
        XCTAssertEqual(analysis.children(of: analysis.blocks[4]).map(\.id), [5, 6])
        XCTAssertEqual(analysis.blocks[6].kind, .quote)
        XCTAssertEqual(analysis.children(of: analysis.blocks[6]).map(\.id), [7])
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

    func testQuoteGroupsParagraphsNestedBlocksAndOriginalSourceRanges() {
        let source = "> first🙂\r\n> second\r\n>\r\n> - item\r\n>   - child\r\n>\r\n> ```swift\r\n> let x = 1\r\n> ```\r\n>> nested"
        let analysis = MarkdownAnalysis(source)
        let quote = analysis.rootBlocks[0]
        let children = analysis.children(of: quote)

        XCTAssertEqual(analysis.rootBlocks.map(\.kind), [.quote])
        XCTAssertEqual(children.map(\.kind), [
            .paragraph, .blank, .unorderedList, .blank, .codeBlock, .quote
        ])
        XCTAssertEqual(children[0].content, "first🙂\nsecond")
        XCTAssertEqual(children[0].lineBreaks, [.soft])
        XCTAssertEqual(analysis.children(of: children[2]).map(\.kind), [.unorderedList])
        XCTAssertEqual(children[4].codeLanguage, "swift")
        XCTAssertEqual(children[4].content, "let x = 1")
        let original = source as NSString
        XCTAssertEqual(original.substring(with: quote.sourceRange), source)
        XCTAssertEqual(original.substring(with: children[0].sourceRange), "> first🙂\r\n> second\r\n")
        XCTAssertEqual(original.substring(with: children[4].sourceRange), "> ```swift\r\n> let x = 1\r\n> ```\r\n")
        XCTAssertTrue(analysis.blocks.allSatisfy { analysis.positionMap.positions(for: $0.sourceRange) != nil })
    }

    func testLazyQuoteContinuationEndsAfterQuotedBlankLine() {
        let analysis = MarkdownAnalysis("> first\nsecond\n>\noutside")

        XCTAssertEqual(analysis.rootBlocks.map(\.kind), [.quote, .paragraph])
        XCTAssertEqual(analysis.children(of: analysis.rootBlocks[0]).map(\.kind), [.paragraph, .blank])
        XCTAssertEqual(analysis.children(of: analysis.rootBlocks[0])[0].content, "first\nsecond")
    }

    func testLazyQuoteContinuationDoesNotExtendAListOrCodeFence() {
        let list = MarkdownAnalysis("> - item\noutside")
        let code = MarkdownAnalysis("> ```\n> code\n> ```\noutside")
        let unclosedCode = MarkdownAnalysis("> ```\n> code\noutside")

        XCTAssertEqual(list.rootBlocks.map(\.kind), [.quote, .paragraph])
        XCTAssertEqual(code.rootBlocks.map(\.kind), [.quote, .paragraph])
        XCTAssertEqual(code.children(of: code.rootBlocks[0]).map(\.kind), [.codeBlock])
        XCTAssertEqual(unclosedCode.rootBlocks.map(\.kind), [.quote, .paragraph])
    }

    func testFencesKeepMarkerLengthLanguageAndLiteralContent() {
        let source = "  ~~~~swift title\n   let x = 1\n~~~\n```\n  ~~~~~ \nnext"
        let blocks = MarkdownAnalysis(source).rootBlocks

        XCTAssertEqual(blocks.map(\.kind), [.codeBlock, .paragraph])
        XCTAssertEqual(blocks[0].codeFenceMarker, "~")
        XCTAssertEqual(blocks[0].codeFenceLength, 4)
        XCTAssertEqual(blocks[0].codeLanguage, "swift")
        XCTAssertEqual(blocks[0].content, " let x = 1\n~~~\n```")
        XCTAssertEqual((source as NSString).substring(with: blocks[0].sourceRange),
                       "  ~~~~swift title\n   let x = 1\n~~~\n```\n  ~~~~~ \n")
    }

    func testIndentedCodeKeepsInteriorBlankLinesAndDoesNotInterruptParagraph() {
        let source = "    one\n\n        two\n\nplain\n    continuation\n\n\tthree"
        let blocks = MarkdownAnalysis(source).rootBlocks

        XCTAssertEqual(blocks.map(\.kind), [.codeBlock, .blank, .paragraph, .blank, .codeBlock])
        XCTAssertEqual(blocks[0].content, "one\n\n    two")
        XCTAssertEqual(blocks[0].codeFenceLength, nil)
        XCTAssertEqual(blocks[0].codeLanguage, nil)
        XCTAssertEqual(blocks[2].content, "plain\n    continuation")
        XCTAssertEqual(blocks[4].content, "three")
        XCTAssertEqual((source as NSString).substring(with: blocks[0].sourceRange), "    one\n\n        two\n")
    }

    func testFourSpaceFenceIsIndentedCodeAndBacktickInfoCannotContainBacktick() {
        let blocks = MarkdownAnalysis("    ```\n    literal\n    ```\n\n```swift`bad\ntext").rootBlocks

        XCTAssertEqual(blocks.map(\.kind), [.codeBlock, .blank, .paragraph])
        XCTAssertEqual(blocks[0].content, "```\nliteral\n```")
        XCTAssertNil(blocks[0].codeFenceLength)
        XCTAssertEqual(blocks[2].content, "```swift`bad\ntext")
    }

    func testIndentedCodeInsideQuoteDoesNotAbsorbOutsideParagraph() {
        let analysis = MarkdownAnalysis(">     code\noutside")

        XCTAssertEqual(analysis.rootBlocks.map(\.kind), [.quote, .paragraph])
        XCTAssertEqual(analysis.children(of: analysis.rootBlocks[0]).map(\.kind), [.codeBlock])
        XCTAssertEqual(analysis.children(of: analysis.rootBlocks[0])[0].content, "code")
    }

    func testIndentedCodeInsideListIsAChildRatherThanContinuationText() {
        let analysis = MarkdownAnalysis("- item\n      code\n        extra\n- next")
        let first = analysis.rootBlocks[0]
        let code = analysis.children(of: first)[0]

        XCTAssertEqual(analysis.rootBlocks.map(\.kind), [.unorderedList, .unorderedList])
        XCTAssertEqual(first.content, "item")
        XCTAssertEqual(code.kind, .codeBlock)
        XCTAssertEqual(code.content, "code\n  extra")
        XCTAssertEqual(code.nestingDepth, 1)
    }

    func testIndentedSyntaxAfterParagraphStaysInParagraph() {
        let analysis = MarkdownAnalysis("plain\n    # not a heading\n    ```\n\n    # code")

        XCTAssertEqual(analysis.rootBlocks.map(\.kind), [.paragraph, .blank, .codeBlock])
        XCTAssertEqual(analysis.rootBlocks[0].content, "plain\n    # not a heading\n    ```")
        XCTAssertEqual(analysis.rootBlocks[2].content, "# code")
    }

    func testTabIndentKeepsColumnsBeyondListCodeIndent() {
        let analysis = MarkdownAnalysis("- item\n\t\tcode")

        XCTAssertEqual(analysis.children(of: analysis.rootBlocks[0])[0].content, "  code")
    }

    func testCodeAfterQuoteIsNotConfusedWithQuoteChildParagraph() {
        let analysis = MarkdownAnalysis("> quoted\n    code")

        XCTAssertEqual(analysis.rootBlocks.map(\.kind), [.quote, .codeBlock])
        XCTAssertEqual(analysis.rootBlocks[1].content, "code")
    }

    func testSetextHeadingsCaptureMultilineSourceAndPreferParagraphOverDashRule() {
        let source = "first🙂\nsecond\n---\nnext\n===\n---"
        let blocks = MarkdownAnalysis(source).rootBlocks

        XCTAssertEqual(blocks.map(\.kind), [
            .heading(level: 2), .heading(level: 1), .horizontalRule
        ])
        XCTAssertEqual(blocks[0].content, "first🙂\nsecond")
        XCTAssertEqual(blocks[0].lineBreaks, [.soft])
        XCTAssertEqual((source as NSString).substring(with: blocks[0].sourceRange),
                       "first🙂\nsecond\n---\n")
    }

    func testATXClosingHashesAndThematicBreakSpacing() {
        let blocks = MarkdownAnalysis("  ##  title  ###  \n# no-close#\n# escaped \\###\n- - -\n *  * *\n___\n    ***").rootBlocks

        XCTAssertEqual(blocks.map(\.kind), [
            .heading(level: 2), .heading(level: 1), .heading(level: 1),
            .horizontalRule, .horizontalRule, .horizontalRule, .codeBlock
        ])
        XCTAssertEqual(blocks[0].content, "title")
        XCTAssertEqual(blocks[1].content, "no-close#")
        XCTAssertEqual(blocks[2].content, "escaped \\###")
        XCTAssertEqual(blocks[6].content, "***")
    }

    func testThematicBreakInterruptsParagraphButSetextDoesNotBecomeStandaloneHeading() {
        let blocks = MarkdownAnalysis("alpha\n* * *\n===\n\n---\n##\n####### invalid").rootBlocks

        XCTAssertEqual(blocks.map(\.kind), [
            .paragraph, .horizontalRule, .paragraph, .blank,
            .horizontalRule, .heading(level: 2), .paragraph
        ])
        XCTAssertEqual(blocks[2].content, "===")
        XCTAssertEqual(blocks[5].content, "")
    }

    func testGFMTableParsesAlignmentRowsAndOriginalRanges() {
        let source = "| Name | Score | Note |\r\n| :--- | ---: | :---: |\r\n| 🙂 | 42 | ok |\r\n| short |\r\n\r\nafter"
        let analysis = MarkdownAnalysis(source)
        let tableBlock = analysis.rootBlocks[0]
        let table = try! XCTUnwrap(tableBlock.table)

        XCTAssertEqual(analysis.rootBlocks.map(\.kind), [.table, .blank, .paragraph])
        XCTAssertEqual(table.header, ["Name", "Score", "Note"])
        XCTAssertEqual(table.alignments, [.leading, .trailing, .center])
        XCTAssertEqual(table.rows, [["🙂", "42", "ok"], ["short", "", ""]])
        XCTAssertEqual((source as NSString).substring(with: tableBlock.sourceRange),
                       "| Name | Score | Note |\r\n| :--- | ---: | :---: |\r\n| 🙂 | 42 | ok |\r\n| short |\r\n")
        XCTAssertEqual((source as NSString).substring(with: table.rowRanges[0]), "| 🙂 | 42 | ok |\r\n")
        XCTAssertTrue(analysis.positionMap.positions(for: tableBlock.sourceRange) != nil)
    }

    func testGFMTableSplitsOnlyUnescapedPipesIncludingInsideCodeSpans() {
        let source = "left|right\n---|---\n\\| escaped | `a\\|b`\n\\\\| separator | value\n`a|b` | tail"
        let table = try! XCTUnwrap(MarkdownAnalysis(source).rootBlocks[0].table)

        XCTAssertEqual(table.rows[0], ["\\| escaped", "`a\\|b`"])
        XCTAssertEqual(table.rows[1], ["\\\\", "separator"])
        XCTAssertEqual(table.rows[2], ["`a", "b`"])
    }

    func testGFMTableRequiresMatchingHeaderAndDelimiterColumns() {
        let mismatched = MarkdownAnalysis("a|b\n---|---|---")
        let setext = MarkdownAnalysis("title\n---")
        let invalidDelimiter = MarkdownAnalysis("a|b\n::---|---")
        let heading = MarkdownAnalysis("# a|b\n---|---")

        XCTAssertFalse(mismatched.blocks.contains(where: { $0.kind == .table }))
        XCTAssertFalse(setext.blocks.contains(where: { $0.kind == .table }))
        XCTAssertFalse(invalidDelimiter.blocks.contains(where: { $0.kind == .table }))
        XCTAssertFalse(heading.blocks.contains(where: { $0.kind == .table }))
    }

    func testGFMTableInsideQuoteAndListPreservesContainerRelationships() {
        let quote = MarkdownAnalysis("> a|b\n> -|-\n> 1|2")
        let list = MarkdownAnalysis("- parent\n  | a | b |\n  | - | - |\n  | 1 | 2 |\n- next")

        XCTAssertEqual(quote.children(of: quote.rootBlocks[0]).map(\.kind), [.table])
        XCTAssertEqual(quote.children(of: quote.rootBlocks[0])[0].table?.rows, [["1", "2"]])
        XCTAssertEqual(list.rootBlocks.map(\.kind), [.unorderedList, .unorderedList])
        XCTAssertEqual(list.children(of: list.rootBlocks[0]).map(\.kind), [.table])
        XCTAssertEqual(list.children(of: list.rootBlocks[0])[0].table?.rows, [["1", "2"]])
    }
}
