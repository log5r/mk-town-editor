import AppKit
import XCTest
@testable import MKTownEditor

/// Regressions found while reviewing the HIG fixes (#23–#29, #52).
@MainActor
final class ReviewFollowUpTests: XCTestCase {
    private func click(count: Int) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: count, pressure: 1))
    }

    /// The tap gesture fires for each click of a double-click, so only the first one activates.
    func testOnlyTheFirstClickOfADoubleClickActivatesARow() throws {
        XCTAssertTrue(ListKeyboardSelection.isSingleClick(try click(count: 1)))
        XCTAssertFalse(ListKeyboardSelection.isSingleClick(try click(count: 2)))
        XCTAssertTrue(ListKeyboardSelection.isSingleClick(nil))
    }

    /// Scanning headings with the arrow keys leaves one Back entry: where the caret was before.
    func testPreviewRunRecordsASingleBackEntry() {
        var history = NavigationHistory()
        let start = NavigationPoint(documentURL: nil, utf16Location: 0)
        let points = (1...5).map { NavigationPoint(documentURL: nil, utf16Location: $0 * 10) }
        var current = start
        for point in points {
            history.recordPreview(from: current, to: point)
            current = point
        }
        XCTAssertEqual(history.back, [start])
        XCTAssertEqual(history.goBack(from: current), start)

        // A real jump ends the run, so the next preview run records its own origin.
        history.recordJump(from: start, to: points[0])
        history.recordPreview(from: points[0], to: points[1])
        history.recordPreview(from: points[1], to: points[2])
        XCTAssertEqual(history.back, [start, points[0]])
    }

    /// Moving the caret in the editor between two preview runs starts a new run, so Back from
    /// the second run returns to where the caret was moved, not to the start of the first run.
    func testPreviewRunAfterTheCaretMovedRecordsItsOwnOrigin() {
        var history = NavigationHistory()
        let point = { NavigationPoint(documentURL: nil, utf16Location: $0) }
        history.recordPreview(from: point(0), to: point(10))
        history.recordPreview(from: point(10), to: point(20))
        // The user clicks in the editor at 50; selection changes are not recorded as jumps.
        history.recordPreview(from: point(50), to: point(30))
        history.recordPreview(from: point(30), to: point(40))
        XCTAssertEqual(history.back, [point(0), point(50)])
        XCTAssertEqual(history.goBack(from: point(40)), point(50))
    }

    /// AppKit reports arrow and function keys as private-use characters; they are not shortcuts.
    func testArrowAndFunctionKeysCannotBeAssigned() {
        for key in ["\u{F700}", "\u{F702}", "\u{F704}", "\u{F729}"] {
            XCTAssertThrowsError(try EditorShortcutRegistry.validate(ShortcutChord(key: key),
                                                                     for: .bold, overrides: [:])) { error in
                XCTAssertEqual(error as? ShortcutError, .invalidKey)
            }
        }
    }

    /// A key saved before a fixed menu item reserved it gives way to that menu item.
    func testSavedOverrideOnANewlyReservedKeyIsIgnored() {
        let reservedLater = ShortcutChord(key: "r", option: true)
        XCTAssertTrue(EditorShortcutRegistry.reserved.contains(reservedLater))
        let overrides = [EditorCommand.highlight.toolbarIdentifier: reservedLater]
        XCTAssertNil(EditorShortcutRegistry.shortcut(for: .highlight, overrides: overrides))
        // A command may still keep its own reserved default, as Find does with ⌘F.
        let find = [EditorCommand.find.toolbarIdentifier: ShortcutChord(key: "f")]
        XCTAssertEqual(EditorShortcutRegistry.shortcut(for: .find, overrides: find), ShortcutChord(key: "f"))
    }

    /// Each notice has its own identity so a repeated message restarts the banner's timer.
    func testRepeatedNoticeGetsANewIdentity() {
        let model = MarkdownEditorModel()
        model.showNotice("same")
        let first = model.notice
        model.showNotice("same")
        XCTAssertEqual(model.notice?.message, "same")
        XCTAssertNotEqual(model.notice?.id, first?.id)
    }
}
