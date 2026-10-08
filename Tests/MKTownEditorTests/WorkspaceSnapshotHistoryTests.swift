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

    func testHistoryFollowsRenamedDocumentAndLeavesNoOldFolder() throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        // 一時フォルダは /private/var へのリンクの下にあり、移動後の旧パスは解決結果が変わる。
        let old = URL(fileURLWithPath: "/private" + workspace.appendingPathComponent("old.md").path)
        let new = workspace.appendingPathComponent("new.md")
        try Data("# Draft\n".utf8).write(to: old)
        let entry = try store.save("# Draft\n", title: "draft", for: old)
        try FileManager.default.moveItem(at: old, to: new)

        try store.remap(from: old, to: new)

        XCTAssertEqual(try store.entries(for: new), [entry])
        XCTAssertEqual(try store.text(for: entry, documentURL: new), "# Draft\n")
        XCTAssertEqual(try store.entries(for: old), [])
        XCTAssertEqual(try historyFolders(in: store).count, 1)
        XCTAssertEqual(store.orphans(), [])
    }

    func testFolderMoveRemapsDescendantsIncludingLegacyIndexes() throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let folder = workspace.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("archive"),
                                                withIntermediateDirectories: true)
        let first = folder.appendingPathComponent("first.md")
        let nested = folder.appendingPathComponent("sub/nested.md")
        let gone = folder.appendingPathComponent("gone.md")
        let outside = workspace.appendingPathComponent("notes-outside.md")
        for url in [first, nested, outside] { try Data("text".utf8).write(to: url) }
        let firstEntry = try store.save("first", title: "first", for: first)
        let nestedEntry = try store.save("nested", title: "nested", for: nested)
        // 書類が既に削除された履歴も、記録したパスでフォルダと一緒に移す。
        let goneEntry = try store.save("gone", title: "gone", for: gone)
        let outsideEntry = try store.save("outside", title: "outside", for: outside)
        try writeLegacyIndex([nestedEntry], in: store, containing: nestedEntry)

        let moved = workspace.appendingPathComponent("archive/notes", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: moved)
        try store.remap(from: folder, to: moved)

        XCTAssertEqual(try store.entries(for: moved.appendingPathComponent("first.md")), [firstEntry])
        XCTAssertEqual(try store.entries(for: moved.appendingPathComponent("sub/nested.md")), [nestedEntry])
        XCTAssertEqual(try store.text(for: nestedEntry,
                                      documentURL: moved.appendingPathComponent("sub/nested.md")), "nested")
        XCTAssertEqual(try store.entries(for: moved.appendingPathComponent("gone.md")), [goneEntry])
        XCTAssertEqual(try store.entries(for: outside), [outsideEntry])
        XCTAssertEqual(try store.entries(for: first), [])
        XCTAssertEqual(try historyFolders(in: store).count, 4)
        // 以前の形式の索引にも移動先のパスが記録され、書類のある履歴として扱われる。
        XCTAssertEqual(store.orphans().map(\.documentPath),
                       [WorkspaceSnapshotStore.documentPath(for: moved.appendingPathComponent("gone.md"))])
    }

    func testDocumentWindowMoveRemapsOnlyWhenOldDocumentIsGone() async throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.md")
        let copy = root.appendingPathComponent("copy.md")
        let renamed = root.appendingPathComponent("renamed.md")
        try Data("text".utf8).write(to: original)
        let entry = try store.save("text", title: "kept", for: original)

        // 別名で保存した場合は元の書類が残るので、履歴は元の書類に残す。
        try FileManager.default.copyItem(at: original, to: copy)
        await store.remapMovedDocument(from: original, to: copy).value
        XCTAssertEqual(try store.entries(for: original), [entry])
        XCTAssertEqual(try store.entries(for: copy), [])

        try FileManager.default.moveItem(at: original, to: renamed)
        await store.remapMovedDocument(from: original, to: renamed).value
        XCTAssertEqual(try store.entries(for: renamed), [entry])
        XCTAssertEqual(try store.entries(for: original), [])
    }

    func testRemapMergesWithHistoryAlreadyAtDestination() throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old.md")
        let new = root.appendingPathComponent("new.md")
        let earlier = try store.save("earlier", title: "earlier", for: new,
                                     now: Date(timeIntervalSince1970: 100))
        try Data("text".utf8).write(to: old)
        let later = try store.save("later", title: "later", for: old,
                                   now: Date(timeIntervalSince1970: 200))
        try FileManager.default.moveItem(at: old, to: new)

        try store.remap(from: old, to: new)

        XCTAssertEqual(try store.entries(for: new), [later, earlier])
        XCTAssertEqual(try store.text(for: later, documentURL: new), "later")
        XCTAssertEqual(try store.text(for: earlier, documentURL: new), "earlier")
        XCTAssertEqual(try historyFolders(in: store).count, 1)
    }

    func testLegacyIndexIsReadAndUpgradedWhenHistoryOpens() throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = root.appendingPathComponent("legacy.md")
        try Data("text".utf8).write(to: document)
        let entry = try store.save("text", title: "legacy", for: document)
        try writeLegacyIndex([entry], in: store, containing: entry)

        XCTAssertEqual(try store.entries(for: document), [entry])
        XCTAssertEqual(store.orphans().map(\.documentPath), [nil])
        try store.recordDocumentPath(for: document)
        XCTAssertEqual(try store.entries(for: document), [entry])
        XCTAssertEqual(store.orphans(), [])
    }

    func testOrphansListMissingDocumentsAndDeletionSkipsRestoredOnes() throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = root.appendingPathComponent("kept.md")
        let removed = root.appendingPathComponent("removed.md")
        let restored = root.appendingPathComponent("restored.md")
        for url in [kept, removed, restored] { try Data("text".utf8).write(to: url) }
        try store.save("kept", title: "kept", for: kept)
        let removedEntry = try store.save("removed", title: "removed", for: removed)
        try store.save("restored", title: "restored", for: restored)
        try FileManager.default.removeItem(at: removed)
        try FileManager.default.removeItem(at: restored)

        let orphans = store.orphans()
        XCTAssertEqual(orphans.map(\.documentPath), [removed, restored].map {
            WorkspaceSnapshotStore.documentPath(for: $0)
        })
        XCTAssertEqual(orphans[0].entries, [removedEntry])

        // 一覧を作った後に書類が戻った履歴は削除しない。
        try Data("text".utf8).write(to: restored)
        XCTAssertTrue(try store.deleteOrphan(orphans[0]))
        XCTAssertFalse(try store.deleteOrphan(orphans[1]))
        XCTAssertEqual(try store.entries(for: removed), [])
        XCTAssertEqual(try store.entries(for: restored).count, 1)
        XCTAssertEqual(try store.entries(for: kept).count, 1)
        XCTAssertEqual(store.orphans(), [])
        XCTAssertThrowsError(try store.deleteOrphan(WorkspaceSnapshotOrphan(
            id: "../outside", documentPath: nil, entries: [])))
    }

    func testBackgroundDeleteRemovesOnlyThatSnapshotAndEmptyFolder() async throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = root.appendingPathComponent("document.md")
        try Data("text".utf8).write(to: document)
        let first = try store.save("first", title: "first", for: document,
                                   now: Date(timeIntervalSince1970: 100))
        let second = try store.save("second", title: "second", for: document,
                                    now: Date(timeIntervalSince1970: 200))
        let folder = try XCTUnwrap(historyFolders(in: store).first)

        // 履歴シートは削除を背景で実行する。
        try await Task.detached { try store.delete(first, documentURL: document) }.value
        XCTAssertEqual(try store.entries(for: document), [second])
        XCTAssertEqual(try store.text(for: second, documentURL: document), "second")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent(first.id.uuidString + ".md").path))
        // 索引から外れた項目の再削除と、内容ファイルを失った項目の削除は失敗にしない。
        try await Task.detached { try store.delete(first, documentURL: document) }.value
        try FileManager.default.removeItem(at: folder.appendingPathComponent(second.id.uuidString + ".md"))
        try await Task.detached { try store.delete(second, documentURL: document) }.value
        XCTAssertEqual(try store.entries(for: document), [])
        XCTAssertEqual(try historyFolders(in: store), [])
    }

    private func makeStore() throws -> (URL, WorkspaceSnapshotStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, WorkspaceSnapshotStore(directory: root.appendingPathComponent("store")))
    }

    private func historyFolders(in store: WorkspaceSnapshotStore) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
    }

    /// 書類のパスを持たない以前の形式（項目の配列だけ）で索引を書き直す。
    private func writeLegacyIndex(_ entries: [WorkspaceSnapshotEntry], in store: WorkspaceSnapshotStore,
                                  containing entry: WorkspaceSnapshotEntry) throws {
        let folder = try XCTUnwrap(historyFolders(in: store).first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent(entry.id.uuidString + ".md").path)
        })
        try JSONEncoder().encode(entries).write(to: folder.appendingPathComponent("index.json"))
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

    func testRowsSplitLinesOnceAndMatchHunkExcerpts() {
        let saved = (0..<200).map { "line \($0)" }.joined(separator: "\n")
        var lines = saved.components(separatedBy: "\n")
        lines[10] = "changed 10"
        lines.insert("inserted", at: 120)
        lines.remove(at: 190)
        let current = lines.joined(separator: "\n")
        let rows = WorkspaceSnapshotDiff.rows(snapshot: saved, current: current)
        XCTAssertEqual(rows.map(\.hunk), WorkspaceSnapshotDiff.hunks(snapshot: saved, current: current))
        let first = rows[0]
        XCTAssertEqual(first.currentExcerpt, "changed 10")
        XCTAssertEqual(first.snapshotExcerpt, "line 10")
        XCTAssertTrue(rows.contains { $0.snapshotExcerpt == "（なし）" && $0.currentExcerpt == "inserted" })
    }

    func testCancelledComparisonStopsWithoutBuildingRows() async {
        let saved = (0..<50_000).map { "line \($0)" }.joined(separator: "\n")
        let current = (0..<50_000).map { $0.isMultiple(of: 7) ? "changed \($0)" : "line \($0)" }
            .joined(separator: "\n")
        let worker = Task.detached { () -> Int in
            while !Task.isCancelled { await Task.yield() }
            return WorkspaceSnapshotDiff.rows(snapshot: saved, current: current).count
        }
        worker.cancel()
        let count = await worker.value
        XCTAssertEqual(count, 0)
        XCTAssertFalse(WorkspaceSnapshotDiff.rows(snapshot: "a\nb", current: "a\nc").isEmpty)
    }
}
