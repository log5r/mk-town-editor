import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

@MainActor
final class PreviewTaskUndoTargetTests: XCTestCase {
    private final class TextBox {
        var value = "- [ ] item"
        var isReadOnly = false
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

    func testReadOnlyPreviewRejectsTaskChangesAndPreservesEarlierUndo() {
        let box = TextBox()
        let binding = Binding<String>(get: { box.value }, set: { box.value = $0 })
        let canEdit = { !box.isReadOnly }
        let manager = UndoManager()
        manager.groupsByEvent = false
        let target = PreviewTaskUndoTarget()

        box.isReadOnly = true
        target.replaceText("- [x] item", in: binding, undoManager: manager, canEdit: canEdit)
        XCTAssertEqual(box.value, "- [ ] item")
        XCTAssertFalse(manager.canUndo)

        box.isReadOnly = false
        manager.beginUndoGrouping()
        target.replaceText("- [x] item", in: binding, undoManager: manager, canEdit: canEdit)
        manager.endUndoGrouping()
        XCTAssertTrue(manager.canUndo)

        box.isReadOnly = true
        target.replaceText("- [ ] item", in: binding, undoManager: manager, canEdit: canEdit)
        XCTAssertEqual(box.value, "- [x] item")

        box.isReadOnly = false
        manager.undo()
        XCTAssertEqual(box.value, "- [ ] item")
        XCTAssertFalse(manager.canUndo)
        manager.redo()
        XCTAssertEqual(box.value, "- [x] item")
    }
}
