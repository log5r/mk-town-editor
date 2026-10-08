import Foundation
import XCTest
@testable import MKTownEditor

@MainActor
final class WorkspaceFileIndexTests: XCTestCase {
    func testMonitorCreationAndStartupFailuresFallBackToPollingAndStopCleanly() async throws {
        for creationFails in [true, false] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let document = root.appendingPathComponent("external.md")
            var scannedNames: [String] = []
            var callbacks = 0
            let monitor = WorkspaceDirectoryMonitor(root: root, fallbackInterval: 0.02,
                createStream: { root, context in
                    creationFails ? nil : WorkspaceDirectoryMonitor.createStream(root, &context)
                }, startStream: { _ in false }, changed: {
                    callbacks += 1
                    scannedNames = (try? WorkspaceFileIndex.scan(root: root))?.nodes.map(\.name) ?? []
                })
            defer { monitor.stop() }
            try "external edit".write(to: document, atomically: true, encoding: .utf8)
            for _ in 0..<200 where !scannedNames.contains("external.md") {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertEqual(scannedNames, ["external.md"], "fallback must detect external additions")
            try FileManager.default.removeItem(at: document)
            for _ in 0..<200 where !scannedNames.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(scannedNames.isEmpty, "fallback must detect external deletions")
            monitor.stop()
            // Allow an already queued callback to drain before checking timer teardown.
            try await Task.sleep(for: .milliseconds(30))
            let afterStop = callbacks
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertEqual(callbacks, afterStop, "stopping must cancel the fallback timer")
        }
    }

    func testSwitchingRootClearsPublishedTreeAndDocumentIndexImmediately() async throws {
        let base = URL(fileURLWithPath: "/private/tmp/workspace-root-switch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let first = base.appendingPathComponent("first"), second = base.appendingPathComponent("second")
        for root in [first, second] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try "body".write(to: root.appendingPathComponent(root.lastPathComponent + ".md"),
                             atomically: true, encoding: .utf8)
        }
        let store = WorkspaceStore(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)))
        store.setRoot(first)
        for _ in 0..<200 where store.documentURLs.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.visibleNodes.first?.name, "first.md")
        XCTAssertEqual(store.documentIndex.canonical.count, 1)
        store.setRoot(second)
        // Inspect before the main actor yields to any background result.
        XCTAssertTrue(store.nodes.isEmpty)
        XCTAssertTrue(store.visibleNodes.isEmpty)
        XCTAssertTrue(store.documentURLs.isEmpty)
        XCTAssertTrue(store.documentIndex.canonical.isEmpty)
        for _ in 0..<200 where store.documentURLs.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.visibleNodes.first?.name, "second.md")
        XCTAssertEqual(store.documentURLs.map { $0.resolvingSymlinksInPath().standardizedFileURL },
                       [second.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent("second.md")])
        XCTAssertEqual(store.documentIndex.canonical,
                       Set(store.documentURLs.map { $0.resolvingSymlinksInPath().standardizedFileURL }))
    }

    func testOpenBufferRevisionsAndSnapshotsAreScopedToRequestedDocuments() throws {
        let store = WorkspaceStore(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)))
        let root = URL(fileURLWithPath: "/private/tmp/buffer-scope-\(UUID().uuidString)")
        let a = root.appendingPathComponent("a.md"), b = root.appendingPathComponent("b.md")
        let conflict = root.appendingPathComponent("conflict.md")
        let aID = UUID(), bID = UUID()
        var aEncodes = 0, bEncodes = 0, conflictEncodes = 0
        store.registerOpenBuffer(id: aID, url: a, encodedData: {
            aEncodes += 1; return Data("A".utf8)
        }, updateText: { _ in })
        store.registerOpenBuffer(id: bID, url: b, encodedData: {
            bEncodes += 1; return Data("B".utf8)
        }, updateText: { _ in })
        for text in ["first", "second"] {
            store.registerOpenBuffer(id: UUID(), url: conflict, encodedData: {
                conflictEncodes += 1; return Data(text.utf8)
            }, updateText: { _ in })
        }
        let before = store.openBufferRevisions
        store.openBufferDidChange(for: a)
        XCTAssertEqual(store.openBufferRevisions[a], before[a]! + 1)
        XCTAssertEqual(store.openBufferRevisions[b], before[b])
        XCTAssertEqual(aEncodes + bEncodes + conflictEncodes, 0)
        XCTAssertEqual(try store.openBufferSnapshots(under: root, including: [a]), [a: Data("A".utf8)])
        XCTAssertEqual(aEncodes, 1)
        XCTAssertEqual(bEncodes, 0)
        XCTAssertEqual(conflictEncodes, 0)
        XCTAssertThrowsError(try store.openBufferSnapshots(under: root, including: [conflict]))
        let revision = store.openBufferRevisions[a]!
        store.unregisterOpenBuffer(id: aID, url: a)
        XCTAssertEqual(store.openBufferRevisions[a], revision + 1)
        XCTAssertTrue(try store.openBufferSnapshots(including: [a]).isEmpty)
        XCTAssertEqual(store.openBufferRevisions[b], before[b])
    }

    func testUnchangedRefreshDoesNotPublishAndNestedChangesAreObserved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let store = WorkspaceStore(defaults: defaults)
        store.setRoot(root)
        for _ in 0..<200 where store.nodes.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        // 表示ツリー・書類索引の作成と、テスト用フォルダ作成のファイル監視の通知（遅延0.5秒）は
        // 非同期に届く。遅い環境でも初期化の通知を計測に含めないよう、通知が1秒途絶えるまで待つ。
        var lastSetupChange = Date()
        let setupObservation = store.objectWillChange.sink { lastSetupChange = Date() }
        let deadline = Date().addingTimeInterval(8)
        while Date().timeIntervalSince(lastSetupChange) < 1, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        setupObservation.cancel()
        var changes = 0
        let observation = store.objectWillChange.sink { changes += 1 }
        store.refresh(force: true)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(changes, 0)
        let previousRevision = store.fileSystemRevision
        try "new".write(to: sub.appendingPathComponent("new.md"), atomically: true, encoding: .utf8)
        for _ in 0..<300 where store.nodes.first?.children?.isEmpty != false {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.nodes.first?.children?.first?.name, "new.md")
        for _ in 0..<100 where store.documentURLs.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.documentIndex.canonical, Set(store.documentURLs.map { $0.resolvingSymlinksInPath().standardizedFileURL }))
        XCTAssertGreaterThan(store.fileSystemRevision, previousRevision)
        let reference = WorkspaceEmbedReference(target: "new", section: nil)
        let expansion = WorkspaceDocumentEmbed.expand(reference, from: root.appendingPathComponent("host.md"), index: store.documentIndex) { _ in "embedded" }
        XCTAssertEqual(expansion.text, "embedded")
        withExtendedLifetime(observation) {}
    }

    func testScanBuildsTreeAndSkipsHiddenAndSymbolicLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = root.appendingPathComponent("章")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "本文".write(to: folder.appendingPathComponent("日本語.md"), atomically: true, encoding: .utf8)
        try Data([0]).write(to: root.appendingPathComponent("figure.png"))
        try "hidden".write(to: root.appendingPathComponent(".secret.md"), atomically: true, encoding: .utf8)
        try "other".write(to: root.appendingPathComponent("ignored.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"),
                                                    withDestinationURL: root)
        let result = try WorkspaceFileIndex.scan(root: root)
        XCTAssertFalse(result.isTruncated)
        XCTAssertEqual(result.nodes.map(\.name), ["章", "figure.png"])
        XCTAssertEqual(result.nodes[0].children?.map(\.name), ["日本語.md"])
        XCTAssertTrue(result.nodes[0].children?[0].isEditableDocument == true)
        XCTAssertFalse(result.nodes[1].isEditableDocument)
    }

    // Issue #36: ルートを読めないときは空の一覧ではなくエラーにする。
    func testScanThrowsWhenRootCannotBeListedButSkipsUnreadableSubfolders() throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        let locked = base.appendingPathComponent("locked")
        let readable = base.appendingPathComponent("readable")
        let hidden = readable.appendingPathComponent("hidden")
        defer {
            for folder in [locked, hidden] {
                try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            }
            try? manager.removeItem(at: base)
        }
        func reason(of root: URL) -> WorkspaceRootUnavailableError.Reason? {
            do { _ = try WorkspaceFileIndex.scan(root: root); return nil }
            catch {
                XCTAssertEqual(error.rootURL, root)
                return error.reason
            }
        }
        XCTAssertEqual(reason(of: base.appendingPathComponent("missing")), .missing)
        let file = base.appendingPathComponent("file.md")
        try "body".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(reason(of: file), .notDirectory)
        try manager.createDirectory(at: locked, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        XCTAssertEqual(reason(of: locked), .permissionDenied)

        try manager.createDirectory(at: hidden, withIntermediateDirectories: true)
        try "body".write(to: readable.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: hidden.path)
        let result = try WorkspaceFileIndex.scan(root: readable)
        XCTAssertEqual(result.nodes.map(\.name), ["hidden", "note.md"])
        XCTAssertEqual(result.nodes[0].children, [])
        XCTAssertEqual(result.skippedDirectories, 1)
    }

    func testWorkspaceWideScansReportUnreadableRootInsteadOfEmptyResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try WorkspaceSearch.report(root: root,
                                                        options: WorkspaceSearchOptions(query: "word"))) {
            XCTAssertEqual(($0 as? WorkspaceRootUnavailableError)?.reason, .missing)
        }
        do {
            _ = try await WorkspaceAttachmentAudit.scan(root: root)
            XCTFail("an unreadable root must not look like a workspace without attachments")
        } catch {
            XCTAssertEqual((error as? WorkspaceRootUnavailableError)?.reason, .missing)
        }
    }

    func testStorePublishesUnavailableRootAndRecoversWhenFolderIsReadableAgain() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? manager.removeItem(at: root)
        }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try "a".write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        let store = WorkspaceStore(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)))
        store.setRoot(root)
        let expectedRoot = try XCTUnwrap(store.rootURL)
        for _ in 0..<200 where store.nodes.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.nodes.map(\.name), ["a.md"])
        XCTAssertFalse(store.isRootUnavailable)

        // 権限を失ったルート: 空の一覧ではなく利用不可の状態になり、ルートは保持する。
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        store.refresh(force: true)
        for _ in 0..<300 where !store.isRootUnavailable { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.rootUnavailableError?.reason, .permissionDenied)
        XCTAssertEqual(store.rootURL, expectedRoot)
        XCTAssertTrue(store.nodes.isEmpty)
        for _ in 0..<200 where !store.visibleNodes.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(store.visibleNodes.isEmpty)

        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        store.refreshIfRootUnavailable()
        for _ in 0..<300 where store.isRootUnavailable { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(store.rootUnavailableError)
        XCTAssertEqual(store.nodes.map(\.name), ["a.md"])

        // 削除されたルート（取り外したボリュームと同じく存在しない）も、戻れば一覧に戻る。
        try manager.removeItem(at: root)
        store.refresh(force: true)
        for _ in 0..<300 where !store.isRootUnavailable { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.rootUnavailableError?.reason, .missing)
        XCTAssertEqual(store.rootURL, expectedRoot)
        XCTAssertTrue(store.nodes.isEmpty)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try "b".write(to: root.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        store.refreshIfRootUnavailable()
        for _ in 0..<300 where store.nodes.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(store.rootUnavailableError)
        XCTAssertEqual(store.nodes.map(\.name), ["b.md"])
    }

    func testStaleBookmarkOfMovedFolderOpensItAndIsSavedAgain() async throws {
        let manager = FileManager.default
        let base = URL(fileURLWithPath: "/private/tmp/workspace-bookmark-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: base) }
        let original = base.appendingPathComponent("original")
        let moved = base.appendingPathComponent("moved")
        try manager.createDirectory(at: original, withIntermediateDirectories: true)
        try "body".write(to: original.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        let bookmark = try original.bookmarkData(options: [], includingResourceValuesForKeys: nil,
                                                 relativeTo: nil)
        try manager.moveItem(at: original, to: moved)
        let restored = try XCTUnwrap(WorkspaceStore.restoreBookmark(bookmark))
        XCTAssertTrue(restored.isStale, "moving the folder must make the bookmark stale")

        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        defaults.set(bookmark, forKey: "workspaceFolderBookmark")
        let store = WorkspaceStore(defaults: defaults)
        XCTAssertEqual(store.rootURL?.path, moved.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertNil(store.errorMessage)
        let saved = try XCTUnwrap(defaults.data(forKey: "workspaceFolderBookmark"))
        XCTAssertNotEqual(saved, bookmark)
        let refreshed = try XCTUnwrap(WorkspaceStore.restoreBookmark(saved))
        XCTAssertFalse(refreshed.isStale)
        XCTAssertEqual(refreshed.url.resolvingSymlinksInPath().standardizedFileURL.path,
                       moved.resolvingSymlinksInPath().standardizedFileURL.path)
        for _ in 0..<200 where store.nodes.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.nodes.map(\.name), ["note.md"])
    }

    func testBookmarkOfDeletedFolderShowsUnavailableRootInsteadOfDiscardingIt() async throws {
        let manager = FileManager.default
        let base = URL(fileURLWithPath: "/private/tmp/workspace-bookmark-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: base) }
        let folder = base.appendingPathComponent("removed")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let bookmark = try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil,
                                               relativeTo: nil)
        try manager.removeItem(at: folder)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        defaults.set(bookmark, forKey: "workspaceFolderBookmark")

        let store = WorkspaceStore(defaults: defaults)
        XCTAssertEqual(store.rootURL?.lastPathComponent, "removed")
        XCTAssertEqual(store.rootURL?.deletingLastPathComponent().resolvingSymlinksInPath().path,
                       base.resolvingSymlinksInPath().path)
        for _ in 0..<300 where !store.isRootUnavailable { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.rootUnavailableError?.reason, .missing)
        XCTAssertTrue(store.nodes.isEmpty)
        XCTAssertEqual(defaults.data(forKey: "workspaceFolderBookmark"), bookmark,
                       "the bookmark is kept so the folder can be restored when it comes back")

        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try "body".write(to: folder.appendingPathComponent("back.md"), atomically: true, encoding: .utf8)
        store.refreshIfRootUnavailable()
        for _ in 0..<300 where store.nodes.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(store.rootUnavailableError)
        XCTAssertEqual(store.nodes.map(\.name), ["back.md"])
    }

    func testScanContinuesPastFormerTenThousandEntryLimit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<10_001 { try Data().write(to: root.appendingPathComponent("\(index).png")) }
        let result = try WorkspaceFileIndex.scan(root: root)
        XCTAssertFalse(result.isTruncated)
        XCTAssertEqual(result.nodes.count, 10_001)
        XCTAssertTrue(try WorkspaceFileIndex.scan(root: root, maximumEntries: 2).isTruncated)
    }

    func testRescanDetectsExternalFileChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertTrue(try WorkspaceFileIndex.scan(root: root).nodes.isEmpty)
        let file = root.appendingPathComponent("new.markdown")
        try "new".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try WorkspaceFileIndex.scan(root: root).nodes.map(\.name), ["new.markdown"])
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(try WorkspaceFileIndex.scan(root: root).nodes.isEmpty)
    }

    func testOpenDocumentRegistryCountsMultipleWindows() throws {
        let suite = "mktown-workspace-registry-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspaceStore(defaults: defaults)
        let document = URL(fileURLWithPath: "/private/tmp/shared.md")
        store.registerOpenDocument(document)
        store.registerOpenDocument(document)
        XCTAssertEqual(store.openDocumentURLs.count, 1)
        store.unregisterOpenDocument(document)
        XCTAssertEqual(store.openDocumentURLs.count, 1)
        store.unregisterOpenDocument(document)
        XCTAssertTrue(store.openDocumentURLs.isEmpty)
    }

    func testAttachmentAuditFindsMissingAndUnusedAcrossDocuments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = root.appendingPathComponent("assets")
        let images = root.appendingPathComponent("images")
        let chapter = root.appendingPathComponent("chapter")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chapter, withIntermediateDirectories: true)
        let used = assets.appendingPathComponent("図 one.png")
        let unused = assets.appendingPathComponent("old.heic")
        let unusedInImages = images.appendingPathComponent("old.png")
        try Data([1]).write(to: used)
        try Data([2]).write(to: unused)
        try Data([3]).write(to: unusedInImages)
        let first = root.appendingPathComponent("index.md")
        let second = chapter.appendingPathComponent("note.md")
        try "![used](assets/%E5%9B%B3%20one.png)\n![missing](assets/lost.png)\n`![code](assets/old.heic)`".write(
            to: first, atomically: true, encoding: .utf8)
        try "![reference][figure]\n\n[figure]: ../assets/%E5%9B%B3%20one.png".write(
            to: second, atomically: true, encoding: .utf8)

        let result = try await WorkspaceAttachmentAudit.scan(root: root)

        XCTAssertEqual(result.missing.map { $0.url.lastPathComponent }, ["lost.png"])
        XCTAssertEqual(result.missing[0].sources, [first])
        XCTAssertEqual(Set(result.unused.map { $0.url.lastPathComponent }), ["old.heic", "old.png"])
        XCTAssertEqual(result.used.map { $0.url.lastPathComponent }, ["図 one.png"])
        XCTAssertEqual(Set(result.used[0].sources), Set([first, second]))
        XCTAssertEqual(result.missing.map(\.exists), [false])
        XCTAssertTrue((result.used + result.unused).allSatisfy(\.exists),
                      "Existence is recorded during the scan instead of being checked by each row")

        let changed = try await WorkspaceAttachmentAudit.scan(root: root,
            openDocuments: [first: Data("![now used](assets/old.heic)".utf8)])
        XCTAssertEqual(changed.unused.map { $0.url.lastPathComponent }, ["old.png"])
        XCTAssertEqual(changed.used.first(where: { $0.url == unused })?.sources, [first])
    }
}
