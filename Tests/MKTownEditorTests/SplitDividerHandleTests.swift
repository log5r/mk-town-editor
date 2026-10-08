import AppKit
import XCTest
@testable import MKTownEditor

/// The split divider behaves like an `NSSplitView` divider (#25).
@MainActor
final class SplitDividerHandleTests: XCTestCase {
    private func event(_ type: NSEvent.EventType, at point: NSPoint, clicks: Int = 1,
                       in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                           clickCount: clicks, pressure: 1)!
    }

    private func hostedHandle() -> (SplitDividerHandleView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let view = SplitDividerHandleView(frame: NSRect(x: 96, y: 0, width: 8, height: 200))
        window.contentView?.addSubview(view)
        return (view, window)
    }

    func testDragReportsTranslationAlongTheSplitAxisAndHighlights() {
        let (view, window) = hostedHandle()
        var deltas: [CGFloat] = []
        var ended = 0
        view.onDrag = { deltas.append($0) }
        view.onDragEnded = { ended += 1 }

        view.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 100, y: 100), in: window))
        XCTAssertTrue(view.isDragging)
        view.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: 130, y: 90), in: window))
        view.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 130, y: 90), in: window))
        XCTAssertEqual(deltas, [30])
        XCTAssertEqual(ended, 1)
        XCTAssertFalse(view.isDragging)

        // Stacked panes: dragging down (window y decreases) grows the top pane.
        view.isVertical = false
        view.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 100, y: 100), in: window))
        view.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: 100, y: 80), in: window))
        XCTAssertEqual(deltas.last, 20)
    }

    func testDoubleClickResetsWithoutStartingADrag() {
        let (view, window) = hostedHandle()
        var resets = 0
        var drags = 0
        view.onReset = { resets += 1 }
        view.onDrag = { _ in drags += 1 }
        view.onDragEnded = { XCTFail("A double-click is not a drag") }
        view.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 100, y: 100), clicks: 2, in: window))
        view.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: 140, y: 100), in: window))
        view.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 140, y: 100), in: window))
        XCTAssertEqual(resets, 1)
        XCTAssertEqual(drags, 0)
    }

    func testUsesResizeCursorAndSplitterRoleWithAdjustments() {
        let view = SplitDividerHandleView(frame: .zero)
        XCTAssertEqual(view.cursor, .resizeLeftRight)
        view.isVertical = false
        XCTAssertEqual(view.cursor, .resizeUpDown)
        XCTAssertEqual(view.accessibilityRole(), .splitter)
        XCTAssertFalse(view.mouseDownCanMoveWindow)
        var adjustments: [Bool] = []
        view.onAdjust = { adjustments.append($0) }
        XCTAssertTrue(view.accessibilityPerformIncrement())
        XCTAssertTrue(view.accessibilityPerformDecrement())
        XCTAssertEqual(adjustments, [true, false])
    }

    func testDraggedRatioRespectsMinimumAndEditorPosition() {
        // 1008 points minus the 8-point divider leaves 1000.
        XCTAssertEqual(EditorSplitSizing.draggedRatio(from: 0.5, delta: 100, total: 1008,
                                                      minimum: 280, editorTrailing: false), 0.6, accuracy: 1e-9)
        XCTAssertEqual(EditorSplitSizing.draggedRatio(from: 0.5, delta: 100, total: 1008,
                                                      minimum: 280, editorTrailing: true), 0.4, accuracy: 1e-9)
        XCTAssertEqual(EditorSplitSizing.draggedRatio(from: 0.5, delta: 900, total: 1008,
                                                      minimum: 280, editorTrailing: false), 0.72, accuracy: 1e-9)
        XCTAssertEqual(EditorSplitSizing.draggedRatio(from: 0.5, delta: -900, total: 1008,
                                                      minimum: 280, editorTrailing: false), 0.28, accuracy: 1e-9)
        XCTAssertEqual(EditorSplitSizing.adjustedRatio(0.78, increment: true), 0.8)
        XCTAssertEqual(EditorSplitSizing.adjustedRatio(0.5, increment: false), 0.45, accuracy: 1e-9)
    }
}
