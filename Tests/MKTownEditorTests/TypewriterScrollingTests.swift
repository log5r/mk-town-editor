import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

@MainActor
final class TypewriterScrollingTests: XCTestCase {
    func testKeepsLineNearCenterAndClampsAtDocumentEdges() {
        XCTAssertEqual(TypewriterScrolling.targetOrigin(lineMidY: 500,
            visibleHeight: 200, documentHeight: 1000, currentOrigin: 0,
            secondsSinceManualScroll: 10, isUserScrolling: false, isComposing: false), 400)
        XCTAssertEqual(TypewriterScrolling.targetOrigin(lineMidY: 30,
            visibleHeight: 200, documentHeight: 1000, currentOrigin: 400,
            secondsSinceManualScroll: 10, isUserScrolling: false, isComposing: false), 0)
        XCTAssertEqual(TypewriterScrolling.targetOrigin(lineMidY: 980,
            visibleHeight: 200, documentHeight: 1000, currentOrigin: 0,
            secondsSinceManualScroll: 10, isUserScrolling: false, isComposing: false), 800)
        XCTAssertNil(TypewriterScrolling.targetOrigin(lineMidY: 500,
            visibleHeight: 200, documentHeight: 1000, currentOrigin: 405,
            secondsSinceManualScroll: 10, isUserScrolling: false, isComposing: false))
    }

    func testPausesForManualScrollingAndComposition() {
        let arguments = (lineMidY: CGFloat(500), visibleHeight: CGFloat(200),
                         documentHeight: CGFloat(1000), currentOrigin: CGFloat(0))
        XCTAssertNil(TypewriterScrolling.targetOrigin(lineMidY: arguments.lineMidY,
            visibleHeight: arguments.visibleHeight, documentHeight: arguments.documentHeight,
            currentOrigin: arguments.currentOrigin, secondsSinceManualScroll: 1.4,
            isUserScrolling: false, isComposing: false))
        XCTAssertNil(TypewriterScrolling.targetOrigin(lineMidY: arguments.lineMidY,
            visibleHeight: arguments.visibleHeight, documentHeight: arguments.documentHeight,
            currentOrigin: arguments.currentOrigin, secondsSinceManualScroll: 2,
            isUserScrolling: true, isComposing: false))
        XCTAssertNil(TypewriterScrolling.targetOrigin(lineMidY: arguments.lineMidY,
            visibleHeight: arguments.visibleHeight, documentHeight: arguments.documentHeight,
            currentOrigin: arguments.currentOrigin, secondsSinceManualScroll: 2,
            isUserScrolling: false, isComposing: true))
    }

    func testTextKitLinePositionsIncreaseForUTF16CaretLocations() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.string = "😀 first\nsecond\n"
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let second = (view.string as NSString).range(of: "second").location
        let firstY = TypewriterScrolling.lineMidY(for: view, at: 0)
        let secondY = TypewriterScrolling.lineMidY(for: view, at: second)
        let finalY = TypewriterScrolling.lineMidY(for: view,
            at: (view.string as NSString).length)
        XCTAssertNotNil(firstY)
        XCTAssertGreaterThan(secondY ?? 0, firstY ?? 0)
        XCTAssertGreaterThan(finalY ?? 0, secondY ?? 0)
    }

    func testCoordinatorFollowsTypingButRespectsManualScrollPause() {
        let source = (0..<100).map { "line \($0)" }.joined(separator: "\n")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 2200))
        view.string = source
        scroll.documentView = view
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = scroll
        window.makeFirstResponder(view)
        let coordinator = MarkdownTextEditor.Coordinator(text: .constant(source),
                                                         model: MarkdownEditorModel())
        coordinator.textView = view
        coordinator.scrollView = scroll
        coordinator.usesTypewriterMode = true
        view.setSelectedRange((source as NSString).range(of: "line 90"))
        XCTAssertTrue(window.firstResponder === view)
        XCTAssertGreaterThan(scroll.documentView?.bounds.height ?? 0, scroll.contentView.bounds.height)
        XCTAssertGreaterThan(TypewriterScrolling.lineMidY(for: view,
            at: view.selectedRange().location) ?? 0, scroll.contentView.bounds.height)
        coordinator.followTypingIfAppropriate()
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 0)
        scroll.contentView.scroll(to: .zero)
        coordinator.manualScrollDidStart()
        coordinator.followTypingIfAppropriate()
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0)

        coordinator.liveScrollDidEnd(Notification(name: NSScrollView.didEndLiveScrollNotification,
                                                  object: scroll))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0)
        coordinator.cancelTypewriterFollow()
    }
}
