import AppKit
import XCTest
@testable import MKTownEditor

@MainActor
final class PreviewAccessibilityTests: XCTestCase {
    func testCodeCopyWritesOnlyCodeContentToPasteboard() throws {
        let analysis = MarkdownAnalysis("```swift\nlet value = 1\nprint(value)\n```")
        let block = try XCTUnwrap(analysis.blocks.first { $0.kind == .codeBlock })
        let board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { board.clearContents() }

        XCTAssertTrue(MarkdownCodeCopy.copy(block, to: board))
        XCTAssertEqual(board.string(forType: .string), "let value = 1\nprint(value)")
        XCTAssertFalse(board.string(forType: .string)!.contains("```"))
        let paragraph = try XCTUnwrap(MarkdownAnalysis("plain").blocks.first)
        XCTAssertFalse(MarkdownCodeCopy.copy(paragraph, to: board))
    }

    func testHeadingsUseStructuredPreviewAtEveryLevelAndKeepLinkAttribute() {
        let source = "# [案内](https://example.com)\n\n###### 詳細"
        let analysis = MarkdownAnalysis(source)
        XCTAssertTrue(PreviewAccessibility.requiresStructuredView(analysis.blocks))
        let headings = analysis.rootBlocks.filter {
            if case .heading = $0.kind { return true }
            return false
        }
        XCTAssertEqual(headings.count, 2)
        let first = MarkdownRenderer.renderLeaf(headings[0], in: analysis)
        XCTAssertEqual(PreviewAccessibility.headingLabel(level: 1, text: first.string),
                       "見出しレベル 1、案内")
        XCTAssertNotNil(first.attribute(.link, at: 0, effectiveRange: nil))
        XCTAssertEqual(PreviewAccessibility.headingLabel(level: 6, text: "詳細"),
                       "見出しレベル 6、詳細")
    }

    func testTableAndTaskLabelsExposeContextAndState() {
        let analysis = MarkdownAnalysis("| 項目 | 状態 |\n| --- | --- |\n| A | 済 |\n\n- [x] 確認")
        XCTAssertTrue(PreviewAccessibility.requiresStructuredView(analysis.blocks))
        XCTAssertEqual(PreviewAccessibility.tableCellLabel(header: "状態", value: "済", rowNumber: 1),
                       "状態 列、1 行目、済")
        XCTAssertEqual(PreviewAccessibility.tableCellLabel(header: "状態", value: "状態", rowNumber: 0),
                       "列見出し 状態")
        XCTAssertEqual(PreviewAccessibility.taskLabel("確認"), "確認 の完了")
        XCTAssertEqual(analysis.blocks.first(where: { $0.task != nil })?.task?.isChecked, true)
    }

    func testPlainDocumentKeepsNativeSelectablePreview() {
        XCTAssertFalse(PreviewAccessibility.requiresStructuredView(MarkdownAnalysis("段落\n\n次の段落").blocks))
    }
}
