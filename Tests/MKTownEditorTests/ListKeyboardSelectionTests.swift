import AppKit
import XCTest
@testable import MKTownEditor

private final class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// Sidebar lists and palettes select with the arrow keys and activate with Return (#26).
@MainActor
final class ListKeyboardSelectionTests: XCTestCase {
    func testResolvedSelectionFallsBackToFirstRow() {
        XCTAssertEqual(ListKeyboardSelection.resolved(nil, in: ["a", "b"]), "a")
        XCTAssertEqual(ListKeyboardSelection.resolved("b", in: ["a", "b"]), "b")
        XCTAssertEqual(ListKeyboardSelection.resolved("gone", in: ["a", "b"]), "a")
        XCTAssertNil(ListKeyboardSelection.resolved("a", in: [String]()))
    }

    func testMovingClampsToTheList() {
        let ids = [1, 2, 3]
        XCTAssertEqual(ListKeyboardSelection.moved(nil, in: ids, by: 1), 2)
        XCTAssertEqual(ListKeyboardSelection.moved(2, in: ids, by: 1), 3)
        XCTAssertEqual(ListKeyboardSelection.moved(3, in: ids, by: 1), 3)
        XCTAssertEqual(ListKeyboardSelection.moved(1, in: ids, by: -1), 1)
        XCTAssertEqual(ListKeyboardSelection.moved(9, in: ids, by: -1), 1)
        XCTAssertNil(ListKeyboardSelection.moved(nil, in: [Int](), by: 1))
    }

    /// A list that shows nothing selected starts at its first row, not the second (#60).
    func testMovingFromNoSelectionStartsAtTheEnds() {
        let ids = [1, 2, 3]
        XCTAssertEqual(ListKeyboardSelection.moved(nil, in: ids, by: 1, startsUnselected: true), 1)
        XCTAssertEqual(ListKeyboardSelection.moved(nil, in: ids, by: -1, startsUnselected: true), 3)
        XCTAssertEqual(ListKeyboardSelection.moved(9, in: ids, by: 1, startsUnselected: true), 1)
        XCTAssertEqual(ListKeyboardSelection.moved(1, in: ids, by: 1, startsUnselected: true), 2)
        XCTAssertNil(ListKeyboardSelection.moved(nil, in: [Int](), by: 1, startsUnselected: true))
    }

    func testOnlyMouseEventsCountAsClicks() throws {
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 125))
        XCTAssertTrue(ListKeyboardSelection.isPointerEvent(click))
        XCTAssertFalse(ListKeyboardSelection.isPointerEvent(key))
        XCTAssertFalse(ListKeyboardSelection.isPointerEvent(nil))
    }

    func testFindsNestedWorkspaceNodeBySelectedURL() {
        let root = URL(fileURLWithPath: "/tmp/workspace")
        let nested = WorkspaceNode(url: root.appendingPathComponent("a/b.md"), name: "b.md", children: nil)
        let nodes = [
            WorkspaceNode(url: root.appendingPathComponent("top.md"), name: "top.md", children: nil),
            WorkspaceNode(url: root.appendingPathComponent("a"), name: "a", children: [nested])
        ]
        XCTAssertEqual(WorkspaceNode.first(at: URL(fileURLWithPath: "/tmp/workspace/a/./b.md"), in: nodes), nested)
        XCTAssertNil(WorkspaceNode.first(at: root.appendingPathComponent("missing.md"), in: nodes))
    }

    func testKeyboardNavigationLeavesFocusInTheList() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let list = FocusableView(frame: NSRect(x: 0, y: 0, width: 100, height: 200))
        let editor = EditorTextView(frame: NSRect(x: 100, y: 0, width: 200, height: 200))
        editor.string = "# A\n\n# B\n"
        window.contentView?.addSubview(list)
        window.contentView?.addSubview(editor)
        let model = MarkdownEditorModel()
        model.connect(editor)
        XCTAssertTrue(window.makeFirstResponder(list))

        model.navigate(to: 5, focusesEditor: false)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 5, length: 0))
        XCTAssertTrue(window.firstResponder === list)
        model.navigate(to: 0)
        XCTAssertTrue(window.firstResponder === editor)
    }

    func testPaletteFieldsMoveTheListSelection() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/MKTownEditor")
        for name in ["WorkspaceQuickOpenSheet.swift", "WorkspaceWikiLinkSheet.swift", "GoToHeadingSheet.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            XCTAssertTrue(text.contains(".movesListSelection("), name)
            XCTAssertTrue(text.contains("selection:"), name)
        }
    }
    private func source(_ name: String) throws -> String {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/MKTownEditor")
        return try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
    }

    /// The part of `text` from `start` to the next declaration at the same level.
    private func declaration(_ start: String, in text: String) throws -> String {
        let begin = try XCTUnwrap(text.range(of: start), start)
        let rest = text[begin.upperBound...]
        let next = start.hasPrefix("private struct") ? "\nprivate struct " : "\n    private var "
        return String(rest[..<(rest.range(of: next)?.lowerBound ?? rest.endIndex)])
    }

    /// The result sheets and the inspector list their rows with `List(selection:)` instead of
    /// buttons, so the arrow keys move and Return opens the selected row (#60).
    func testResultListsUseSelectionInsteadOfButtons() throws {
        let activating = ["PreviewSearchSheet.swift", "WorkspaceSearchSheet.swift",
                          "WorkspaceBacklinksSheet.swift", "WorkspaceTagsSheet.swift",
                          "WorkspaceLinkGraphSheet.swift", "WorkspaceTaskSheet.swift",
                          "WorkspaceNamedLayoutSheet.swift"]
        // These show the selected row beside the list, so selecting is all a row does.
        let browsing = ["RegexSearchSheet.swift", "GitHistorySheet.swift", "GitCommitSheet.swift",
                        "WorkspaceSnapshotHistory.swift"]
        for name in activating + browsing {
            let text = try source(name)
            XCTAssertTrue(text.contains("selection:"), name)
            XCTAssertFalse(text.contains(".buttonStyle(.plain)"), name)
        }
        for name in activating {
            let text = try source(name)
            XCTAssertTrue(text.contains(".activatesSelectionOnReturn("), name)
            XCTAssertTrue(text.contains(".activatesOnClick"), name)
        }
        XCTAssertTrue(try source("RegexSearchSheet.swift").contains("startsUnselected: true"))
        // Browsing with the arrow keys cancels the previous load instead of starting one per row.
        for name in ["GitHistorySheet.swift", "GitCommitSheet.swift", "WorkspaceSnapshotHistory.swift"] {
            XCTAssertTrue(try source(name).contains("Task.sleep(for: .milliseconds(120))"), name)
        }
        XCTAssertTrue(try source("WorkspaceSnapshotHistory.swift").contains("loadTask?.cancel()"))
        // Sheets that close when a row opens ignore a second click or Return while closing.
        for (name, guardName) in [("WorkspaceSearchSheet.swift", "didOpen"), ("WorkspaceLinkGraphSheet.swift", "didOpen"),
                                  ("WorkspaceTaskSheet.swift", "didSubmit"), ("WorkspaceNamedLayoutSheet.swift", "didApply"),
                                  ("WorkspaceBacklinksSheet.swift", "didOpen"), ("WorkspaceTagsSheet.swift", "didOpen")] {
            XCTAssertTrue(try source(name).contains("guard !\(guardName) else { return }"), name)
        }

        let workspace = try source("EditorWorkspace.swift")
        for start in ["private var contentInspectorSidebar: some View {", "private struct LinkDiagnosticsSheet: View {",
                      "private struct MarkdownLintSheet: View {", "private struct TerminologySheet: View {"] {
            let body = try declaration(start, in: workspace)
            XCTAssertTrue(body.contains("List(selection:") || body.contains(", selection:"), start)
            XCTAssertTrue(body.contains(".activatesSelectionOnReturn("), start)
            XCTAssertTrue(body.contains(".activatesOnClick"), start)
            if start.hasPrefix("private struct") {
                XCTAssertTrue(body.contains("guard !didChoose else { return }"), start)
            }
            XCTAssertFalse(body.contains(".buttonStyle(.plain)"), start)
        }
    }
}
