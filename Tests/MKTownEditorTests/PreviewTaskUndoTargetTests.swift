import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

@MainActor
final class PreviewTaskUndoTargetTests: XCTestCase {
    private final class TextBox {
        var value = "- [ ] item"
    }

    func testPreviewOnlyTaskChangeSupportsUndoAndRedo() {
        let box = TextBox()
        let binding = Binding<String>(get: { box.value }, set: { box.value = $0 })
        let manager = UndoManager()
        manager.groupsByEvent = false
        let target = PreviewTaskUndoTarget()

        manager.beginUndoGrouping()
        target.replaceText("- [x] item", in: binding, undoManager: manager)
        manager.endUndoGrouping()
        XCTAssertEqual(box.value, "- [x] item")
        manager.undo()
        XCTAssertEqual(box.value, "- [ ] item")
        manager.redo()
        XCTAssertEqual(box.value, "- [x] item")
    }
}
