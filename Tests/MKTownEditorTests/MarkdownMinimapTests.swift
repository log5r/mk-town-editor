import AppKit
import Foundation
import XCTest
@testable import MKTownEditor

final class MarkdownMinimapTests: XCTestCase {
    func testLineSamplingAndNavigationHandleCRLFUnicodeAndFinalLine() throws {
        let source = "前\r\n🙂🙂\r\n\n最後"
        let plan = try XCTUnwrap(MarkdownMinimapPlan.make(source: source, maximumBars: 10))
        XCTAssertEqual(plan.lineCount, 4)
        XCTAssertEqual(plan.bars.count, 4)
        XCTAssertEqual(plan.location(at: 0), 0)
        XCTAssertEqual(plan.location(at: 0.5), (source as NSString).range(of: "\n最後").location)
        XCTAssertEqual(plan.location(at: 0.75), (source as NSString).range(of: "最後").location)
        XCTAssertEqual(plan.location(at: 1), (source as NSString).range(of: "最後").location)
        XCTAssertEqual(plan.location(at: -1), 0)
    }

    func testManyLinesRemainWithinBarLimit() throws {
        let source = Array(repeating: "short\nlonger line\n", count: 1000).joined()
        let plan = try XCTUnwrap(MarkdownMinimapPlan.make(source: source))
        XCTAssertEqual(plan.lineCount, 2001)
        XCTAssertEqual(plan.bars.count, 600)
        XCTAssertTrue(plan.bars.allSatisfy { (0...1).contains($0) })
        XCTAssertEqual(plan.sourceLength, (source as NSString).length)
    }

    func testLargeDocumentPlanningCostWithoutSecondTextLayout() throws {
        for (label, lines) in [("100 KB", 2_500), ("1 MB", 25_000), ("10 MB", 250_000)] {
            let source = String(repeating: "0123456789012345678901234567890123456789\n", count: lines)
            let started = ProcessInfo.processInfo.systemUptime
            let plan = try XCTUnwrap(MarkdownMinimapPlan.make(source: source))
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            XCTAssertEqual(plan.lineCount, lines + 1)
            XCTAssertEqual(plan.bars.count, 600)
            print("MarkdownMinimapPlan \(label): \(String(format: "%.3f", elapsed)) s")
        }
    }
}

@MainActor
final class MarkdownMinimapViewportTests: XCTestCase {
    func testViewportReflectsScrollPositionAndVisibleHeight() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 1000))
        let model = MarkdownEditorModel()
        model.scrollDidChange(NSPoint(x: 0, y: 200), in: scrollView)
        XCTAssertEqual(model.viewport.topFraction, 0.2, accuracy: 0.02)
        XCTAssertEqual(model.viewport.visibleFraction, 0.2, accuracy: 0.02)
    }
}
