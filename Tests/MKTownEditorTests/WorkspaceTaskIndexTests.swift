import Foundation
import XCTest
@testable import MKTownEditor

final class WorkspaceTaskIndexTests: XCTestCase {
    func testCollectsUncheckedTasksAcrossDocumentsUsingOpenBuffer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let one = root.appendingPathComponent("one.md")
        let two = sub.appendingPathComponent("two.md")
        try "- [x] saved".write(to: one, atomically: true, encoding: .utf8)
        try "- [ ] second\n```\n- [ ] code\n```".write(to: two,
            atomically: true, encoding: .utf8)
        let nodes = WorkspaceFileIndex.scan(root: root).nodes
        let index = try WorkspaceTaskIndex.scan(root: root, nodes: nodes,
            openBuffers: [one: Data("- [ ] unsaved\n- [x] done".utf8)])
        XCTAssertEqual(index.tasks.map(\.title), ["unsaved", "second"])
        XCTAssertEqual(index.tasks.map(\.relativePath), ["one.md", "sub/two.md"])
        XCTAssertEqual(index.skippedDocuments, 0)
    }

    func testToggleEditChangesOnlyMatchingOriginalLine() throws {
        let root = URL(fileURLWithPath: "/tmp/task-index-tests")
        let source = "# Tasks\n- [ ] first\n- [ ] second\n"
        let url = root.appendingPathComponent("tasks.md")
        let item = WorkspaceTaskItem(sourceURL: url, relativePath: "tasks.md",
            line: 2, sourceLocation: 8, expectedLine: "- [ ] first\n", title: "first")
        let edit = try XCTUnwrap(WorkspaceTaskIndex.toggleEdit(for: item, in: source))
        XCTAssertEqual(edit.applying(to: source), "# Tasks\n- [x] first\n- [ ] second\n")
        XCTAssertNil(WorkspaceTaskIndex.toggleEdit(for: item,
            in: "# Tasks\n- [ ] changed\n- [ ] second\n"))
    }

    @MainActor
    func testPendingToggleMatchesOnlyItsDocument() {
        let navigation = DocumentLinkNavigation()
        let first = URL(fileURLWithPath: "/tmp/a.md")
        let second = URL(fileURLWithPath: "/tmp/b.md")
        let item = WorkspaceTaskItem(sourceURL: first, relativePath: "a.md",
            line: 1, sourceLocation: 0, expectedLine: "- [ ] work",
            title: "work")
        navigation.requestTaskToggle(item)
        XCTAssertNil(navigation.takeTaskToggle(for: second))
        XCTAssertEqual(navigation.takeTaskToggle(for: first), item)
        XCTAssertNil(navigation.pendingTaskToggle)
    }
}
