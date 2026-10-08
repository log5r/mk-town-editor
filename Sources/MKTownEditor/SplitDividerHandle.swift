import AppKit
import SwiftUI

/// The divider between the editor and the preview. It is an AppKit view so it gets what
/// `NSSplitView` dividers offer: the resize cursor, a highlighted line while dragging,
/// double-click to restore an even split, and the splitter accessibility role (#25).
///
/// The split ratio stays in SwiftUI state because it is saved per document and in named
/// layouts, which `HSplitView` cannot restore.
struct SplitDividerHandle: NSViewRepresentable {
    /// True when the panes sit side by side, so the divider line is vertical.
    let isVertical: Bool
    let valueDescription: String
    /// Translation along the split axis since the drag began, positive toward the trailing or bottom pane.
    let onDrag: (CGFloat) -> Void
    let onDragEnded: () -> Void
    let onReset: () -> Void
    let onAdjust: (_ increment: Bool) -> Void

    nonisolated static let thickness: CGFloat = 8

    func makeNSView(context: Context) -> SplitDividerHandleView {
        let view = SplitDividerHandleView()
        update(view)
        return view
    }

    func updateNSView(_ view: SplitDividerHandleView, context: Context) {
        update(view)
    }

    private func update(_ view: SplitDividerHandleView) {
        if view.isVertical != isVertical {
            view.isVertical = isVertical
            view.window?.invalidateCursorRects(for: view)
            view.needsDisplay = true
        }
        view.setAccessibilityValue(valueDescription)
        view.onDrag = onDrag
        view.onDragEnded = onDragEnded
        view.onReset = onReset
        view.onAdjust = onAdjust
    }
}

final class SplitDividerHandleView: NSView {
    var isVertical = true
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    var onReset: (() -> Void)?
    var onAdjust: ((Bool) -> Void)?
    private var dragOrigin: NSPoint?
    private(set) var isDragging = false {
        didSet { if isDragging != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel(String(localized: "編集とプレビューの分割位置"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var cursor: NSCursor { isVertical ? .resizeLeftRight : .resizeUpDown }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            dragOrigin = nil
            isDragging = false
            onReset?()
            return
        }
        dragOrigin = event.locationInWindow
        isDragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin else { return }
        let location = event.locationInWindow
        // Window coordinates grow upward; SwiftUI's vertical layout grows downward.
        onDrag?(isVertical ? location.x - dragOrigin.x : dragOrigin.y - location.y)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragOrigin != nil else { return }
        dragOrigin = nil
        isDragging = false
        onDragEnded?()
    }

    override func draw(_ dirtyRect: NSRect) {
        (isDragging ? NSColor.controlAccentColor : NSColor.separatorColor).setFill()
        let width: CGFloat = isDragging ? 2 : 1
        let line = isVertical
            ? NSRect(x: (bounds.width - width) / 2, y: 0, width: width, height: bounds.height)
            : NSRect(x: 0, y: (bounds.height - width) / 2, width: bounds.width, height: width)
        line.fill()
    }

    override func accessibilityPerformIncrement() -> Bool {
        onAdjust?(true)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        onAdjust?(false)
        return true
    }
}
