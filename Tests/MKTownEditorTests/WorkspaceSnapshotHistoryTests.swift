import Foundation
import XCTest
@testable import MKTownEditor

final class WorkspaceSnapshotHistoryTests: XCTestCase {
    func testExplicitSnapshotsRemainSeparateForDifferentDocuments() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceSnapshotStore(directory: root)
        let firstURL = root.appendingPathComponent("first.md")
        let secondURL = root.appendingPathComponent("second.md")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("# Old\n".utf8).write(to: firstURL)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("first-alias.md"),
            withDestinationURL: firstURL)
        let first = try store.save("# Old\n", title: "  draft  ", for: firstURL,
                                   now: Date(timeIntervalSince1970: 100))
        let second = try store.save("# New\n", title: "revision", for: firstURL,
                                    now: Date(timeIntervalSince1970: 200))
        _ = try store.save("Other", title: "other", for: secondURL)

        XCTAssertEqual(try store.entries(for: firstURL), [second, first])
        XCTAssertEqual(try store.entries(for: root.appendingPathComponent("first-alias.md")),
                       [second, first])
        XCTAssertEqual(first.title, "draft")
        XCTAssertEqual(try store.text(for: first, documentURL: firstURL), "# Old\n")
        XCTAssertEqual(try store.entries(for: secondURL).count, 1)
        XCTAssertThrowsError(try store.text(for: first, documentURL: secondURL))
        try store.delete(first, documentURL: firstURL)
        XCTAssertEqual(try store.entries(for: firstURL), [second])
        XCTAssertThrowsError(try store.text(for: first, documentURL: firstURL))
    }

    func testSeparateChangedLineHunksCanBeRestoredIndependently() {
        let saved = "A\nold one\nC\nold two\nE\n"
        let current = "A\nnew one\nC\nnew two\nE\n"
        let hunks = WorkspaceSnapshotDiff.hunks(snapshot: saved, current: current)
        XCTAssertEqual(hunks.count, 2)
        XCTAssertEqual(WorkspaceSnapshotDiff.restoring(hunks[0], snapshot: saved,
                                                      current: current),
                       "A\nold one\nC\nnew two\nE\n")
        XCTAssertEqual(WorkspaceSnapshotDiff.restoring(hunks[1], snapshot: saved,
                                                      current: current),
                       "A\nnew one\nC\nold two\nE\n")
    }

    func testAddedAndRemovedLinesIncludingFinalNewlineRestoreExactly() {
        let cases = [
            ("A\nB", "A\nX\nB"),
            ("A\nB\n", "A\n"),
            ("A\n", "A"),
            ("", "one\ntwo")
        ]
        for (saved, current) in cases {
            let hunks = WorkspaceSnapshotDiff.hunks(snapshot: saved, current: current)
            XCTAssertFalse(hunks.isEmpty)
            var restored = current
            for hunk in hunks.reversed() {
                restored = WorkspaceSnapshotDiff.restoring(hunk,
                    snapshot: saved, current: restored)
            }
            XCTAssertEqual(restored, saved)
        }
    }

    func testEverySmallRepeatedLineCombinationRestoresFromAllHunks() {
        let values = ["", "a", "b", "a\na", "a\nb", "b\na", "a\nb\na", "a\na\nb"]
        for saved in values {
            for current in values {
                let hunks = WorkspaceSnapshotDiff.hunks(snapshot: saved, current: current)
                var restored = current
                for hunk in hunks.reversed() {
                    restored = WorkspaceSnapshotDiff.restoring(hunk,
                        snapshot: saved, current: restored)
                }
                XCTAssertEqual(restored, saved, "snapshot=\(saved), current=\(current)")
            }
        }
    }
}
