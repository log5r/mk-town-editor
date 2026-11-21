import AppKit
import SwiftUI
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

    /// The bar is hidden while previews update automatically and never shows revision numbers (#24).
    func testPreviewUpdateStatusIsHiddenWhileLiveAndDescribesPausedStateWithoutRevisions() throws {
        var state = PreviewUpdateState()
        XCTAssertNil(PreviewUpdateControls.statusText(for: state))
        state.sourceChanged()
        XCTAssertNil(PreviewUpdateControls.statusText(for: state))

        state.pause(at: "a")
        let upToDate = try XCTUnwrap(PreviewUpdateControls.statusText(for: state))
        state.sourceChanged()
        let stale = try XCTUnwrap(PreviewUpdateControls.statusText(for: state))
        XCTAssertNotEqual(upToDate, stale)
        for text in [upToDate, stale] {
            XCTAssertFalse(text.contains("世代"))
            XCTAssertNil(text.rangeOfCharacter(from: .decimalDigits), text)
        }
    }

    func testTogglePauseFreezesThenResumesPreview() {
        let updates = PreviewUpdateController()
        updates.togglePause(source: "# A", preferredSnapshot: DocumentSnapshot(source: "# A"))
        XCTAssertTrue(updates.state.isPaused)
        XCTAssertEqual(updates.state.displayedSource, "# A")
        updates.togglePause(source: "# B")
        XCTAssertFalse(updates.state.isPaused)
        XCTAssertNil(updates.snapshot)
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

    /// 一時停止中の帯は、「システム」のプレビューの白い背景（GitHub風）に置いても境目が見えること。
    /// 以前は帯の背景が `controlBackgroundColor`（ライト外観では白）で、白いプレビューと同化した。
    func testPausedBarStaysDistinctOnWhiteSystemPreviewBackground() throws {
        let updates = PreviewUpdateController()
        updates.pause(source: "# a")
        let height: CGFloat = 40
        let root = PreviewUpdateControls(updates: updates, source: "# a")
            .frame(width: 400, height: height, alignment: .top)
            .background(Color(nsColor: try XCTUnwrap(PreviewTheme.system.previewBackground)))
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 400, height: height)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        // 文字は幅の一部にしかないため、幅いっぱいに白でない行（区切り線や帯の面）があるかで境目を判定する。
        // 帯の背景が白い `controlBackgroundColor` で区切り線もなかった以前の版では、そのような行はない。
        func isWhite(_ x: Int, _ y: Int) -> Bool {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return true }
            return 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent > 0.985
        }
        let columns = Array(stride(from: 0, to: bitmap.pixelsWide, by: 4))
        let distinctRows = (0..<bitmap.pixelsHigh).filter { y in
            columns.filter { !isWhite($0, y) }.count > columns.count * 9 / 10
        }
        XCTAssertFalse(distinctRows.isEmpty, "一時停止中の帯が白いプレビューと同化している")
        // 帯の下のプレビューの背景は白のまま。
        XCTAssertTrue(isWhite(bitmap.pixelsWide / 2, bitmap.pixelsHigh - 1))
    }
}
