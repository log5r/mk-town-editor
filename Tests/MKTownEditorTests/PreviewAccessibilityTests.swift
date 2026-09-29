import AppKit
import XCTest
@testable import MKTownEditor

@MainActor
final class PreviewAccessibilityTests: XCTestCase {
    func testPreviewUpdateStateTracksDisplayedAndCurrentRevisions() {
        var state = PreviewUpdateState()
        XCTAssertFalse(state.isPaused)
        XCTAssertEqual(state.currentRevision, 1)

        state.pause(at: "old")
        state.sourceChanged()
        state.sourceChanged()
        XCTAssertTrue(state.isStale)
        XCTAssertEqual(state.displayedSource, "old")
        XCTAssertEqual(state.displayedRevision, 1)
        XCTAssertEqual(state.currentRevision, 3)

        state.refresh(to: "new")
        XCTAssertFalse(state.isStale)
        XCTAssertEqual(state.displayedSource, "new")
        XCTAssertEqual(state.displayedRevision, 3)
        state.resume()
        XCTAssertNil(state.displayedSource)
        XCTAssertNil(state.displayedRevision)
    }

    func testPreviewUpdateControllerFreezesAndRefreshesMatchingAnalysis() async {
        let updates = PreviewUpdateController()
        updates.pause(source: "# Frozen", preferredSnapshot: DocumentSnapshot(source: "# Frozen"))
        updates.sourceChanged()
        XCTAssertEqual(updates.snapshot?.source, "# Frozen")
        XCTAssertTrue(updates.state.isStale)

        updates.refresh(source: "# Current", preferredSnapshot: DocumentSnapshot(source: "# Other"))
        XCTAssertEqual(updates.snapshot?.source, "# Frozen")
        for _ in 0..<100 where updates.snapshot?.source != "# Current" {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(updates.snapshot?.source, "# Current")
        updates.resume()
        XCTAssertNil(updates.snapshot)
    }
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
