import Foundation
import XCTest
@testable import MKTownEditor

final class WorkspaceFileOperationsTests: XCTestCase {
    func testUnreadableTextDoesNotBlockMoveSearchReplaceOrAttachmentAudit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.md")
        let bad = root.appendingPathComponent("legacy.txt")
        let destination = root.appendingPathComponent("moved.md")
        try "needle".write(to: source, atomically: true, encoding: .utf8)
        try Data([0x82, 0xA0]).write(to: bad)
        let plan = try WorkspaceFileOperations.planMove(source: source, destination: destination, root: root)
        XCTAssertEqual(plan.skippedDocuments, [bad.resolvingSymlinksInPath()])
        try plan.apply()
        XCTAssertEqual(try Data(contentsOf: bad), Data([0x82, 0xA0]))
        let report = try WorkspaceSearch.report(root: root, options: WorkspaceSearchOptions(query: "needle"))
        XCTAssertEqual(report.results.count, 1)
        XCTAssertEqual(report.skippedDocuments.count, 1)
        let replacement = try WorkspaceReplace.plan(root: root, options: WorkspaceSearchOptions(query: "needle"), replacement: "new")
        XCTAssertEqual(replacement.skippedDocuments.count, 1)
        try replacement.apply(selectedURLs: [destination], openDocuments: [])
        let audit = try await WorkspaceAttachmentAudit.scan(root: root)
        XCTAssertEqual(audit.skippedDocuments.count, 1)
        XCTAssertTrue(audit.unused.isEmpty)
    }

    func testRepeatedMovePlanningReusesAnalysisAndCancellationLeavesFilesUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.md")
        let reference = root.appendingPathComponent("ref.md")
        let destination = root.appendingPathComponent("moved.md")
        try "source".write(to: source, atomically: true, encoding: .utf8)
        try "[[source]]\n![[source]]".write(to: reference, atomically: true, encoding: .utf8)
        let cache = WorkspaceLinkAnalysisCache()
        for _ in 0..<3 {
            _ = try WorkspaceFileOperations.planMove(source: source, destination: destination, root: root, cache: cache)
        }
        XCTAssertEqual(cache.analysisBuildCount, 2)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try WorkspaceFileOperations.planMove(source: source, destination: destination, root: root, cache: cache)
        }
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try "changed [[source]]".write(to: reference, atomically: true, encoding: .utf8)
        let plan = try WorkspaceFileOperations.planMove(source: source, destination: destination, root: root, cache: cache)
        XCTAssertEqual(cache.analysisBuildCount, 3)
        XCTAssertEqual(plan.changedLinks, 1)
    }

    /// Rewrites `url` in place with same-length content and pins its modification date, so the
    /// size and date match the previous version exactly.
    private func overwritePreservingMetadata(_ url: URL, with text: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: Self.pinnedDate], ofItemAtPath: url.path)
    }

    private static let pinnedDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// Simulates a volume without generation identifiers, such as exFAT or some network shares.
    private static let readMetadataWithoutGeneration: WorkspaceFileMetadata.Reader = {
        let metadata = try WorkspaceFileMetadata(url: $0)
        return WorkspaceFileMetadata(modified: metadata.modified, size: metadata.size, generation: nil)
    }

    func testApplyRejectsSameSizeSameDateEditsWithAndWithoutGenerationIdentifiers() throws {
        for reader in [WorkspaceFileMetadata.read, Self.readMetadataWithoutGeneration] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let source = root.appendingPathComponent("source.md")
            let reference = root.appendingPathComponent("reference.md")
            let destination = root.appendingPathComponent("moved.md")
            try "source".write(to: source, atomically: true, encoding: .utf8)
            try "".write(to: reference, atomically: true, encoding: .utf8)
            try overwritePreservingMetadata(reference, with: "see [[other]]!")
            let cache = WorkspaceLinkAnalysisCache(readMetadata: reader)
            let plan = try WorkspaceFileOperations.planMove(source: source, destination: destination,
                                                             root: root, cache: cache)
            XCTAssertEqual(plan.changedLinks, 0)

            let before = try reader(reference)
            try overwritePreservingMetadata(reference, with: "see [[source]]")
            let after = try reader(reference)
            XCTAssertEqual(after.size, before.size)
            XCTAssertEqual(after.modified, before.modified)
            XCTAssertEqual(after == before, !after.identifiesContent,
                           "size and date alone must only look unchanged where no generation identifier exists")

            XCTAssertThrowsError(try plan.apply()) { error in
                guard case let .documentChanged(url)? = error as? WorkspaceFileOperationError else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(url, reference.resolvingSymlinksInPath().standardizedFileURL)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertEqual(try String(contentsOf: reference, encoding: .utf8), "see [[source]]")

            let replanned = try WorkspaceFileOperations.planMove(source: source, destination: destination,
                                                                  root: root, cache: cache)
            XCTAssertEqual(replanned.changedLinks, 1)
            try replanned.apply()
            XCTAssertFalse(try String(contentsOf: reference, encoding: .utf8).contains("[[source]]"))
        }
    }

    func testAnalysisCacheDetectsSameSizeSameDateEditsAndKeepsAnalysisForUnchangedBytes() throws {
        for reader in [WorkspaceFileMetadata.read, Self.readMetadataWithoutGeneration] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("doc.md")
            try "".write(to: url, atomically: true, encoding: .utf8)
            try overwritePreservingMetadata(url, with: "alpha [[one]]")
            let cache = WorkspaceLinkAnalysisCache(readMetadata: reader)
            let first = try cache.load(url, openData: nil)
            XCTAssertEqual(first.document?.text, "alpha [[one]]")
            XCTAssertEqual(try cache.load(url, openData: nil).digest, first.digest)
            XCTAssertEqual(cache.analysisBuildCount, 1)

            try overwritePreservingMetadata(url, with: "alpha [[two]]")
            let edited = try cache.load(url, openData: nil)
            XCTAssertEqual(edited.document?.text, "alpha [[two]]")
            XCTAssertNotEqual(edited.digest, first.digest)
            XCTAssertEqual(cache.analysisBuildCount, 2)

            let touchedDate = Self.pinnedDate.addingTimeInterval(100)
            try FileManager.default.setAttributes([.modificationDate: touchedDate], ofItemAtPath: url.path)
            let touched = try cache.load(url, openData: nil)
            XCTAssertEqual(touched.digest, edited.digest)
            XCTAssertEqual(touched.metadata.modified, touchedDate)
            XCTAssertEqual(touched.document?.text, "alpha [[two]]")
            XCTAssertEqual(cache.analysisBuildCount, 2, "unchanged bytes under a new date reuse the analysis")
        }
    }

    func testFailedApplyRestoresOnlyWrittenDocumentsAndLeavesOthersUntouched() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.md")
        let destination = root.appendingPathComponent("moved.md")
        try "source".write(to: source, atomically: true, encoding: .utf8)
        let references = ["a", "b", "c", "d"].map { root.appendingPathComponent("ref-\($0).md") }
        for url in references { try "[[source]]".write(to: url, atomically: true, encoding: .utf8) }
        let plan = try WorkspaceFileOperations.planMove(source: source, destination: destination, root: root)
        let order = plan.changes.filter { $0.linkCount > 0 }.map(\.newURL)
        XCTAssertEqual(order.count, 4)
        // The second rewrite fails: one document was written before it, two were never touched.
        let failing = order[1]
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: failing.path)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: failing.path)
            try? FileManager.default.removeItem(at: root)
        }
        func identity(_ url: URL) throws -> NSObject? {
            var url = url
            url.removeAllCachedResourceValues()
            return try url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject
        }
        let before = try Dictionary(uniqueKeysWithValues: order.map { ($0, try identity($0)) })

        XCTAssertThrowsError(try plan.apply())
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        for url in order {
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "[[source]]", url.lastPathComponent)
        }
        for url in order.suffix(2) {
            XCTAssertEqual(try identity(url), before[url] ?? nil,
                           "\(url.lastPathComponent) was never written and must not be replaced by the rollback")
        }
    }

    func testApplyStopsWhenDocumentUnreadableDuringPlanningBecomesReadable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.md")
        let destination = root.appendingPathComponent("moved.md")
        let offline = root.appendingPathComponent("offline.md")
        try "source".write(to: source, atomically: true, encoding: .utf8)
        try "[[source]]".write(to: offline, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: offline.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: offline.path)
            try? FileManager.default.removeItem(at: root)
        }
        let plan = try WorkspaceFileOperations.planMove(source: source, destination: destination, root: root)
        XCTAssertEqual(plan.skippedDocuments.map(\.lastPathComponent), ["offline.md"])
        XCTAssertEqual(plan.changedLinks, 0, "its link to the moved document was never examined")

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: offline.path)
        XCTAssertThrowsError(try plan.apply()) { error in
            guard case let .documentChanged(url)? = error as? WorkspaceFileOperationError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(url.lastPathComponent, "offline.md")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let replanned = try WorkspaceFileOperations.planMove(source: source, destination: destination, root: root)
        XCTAssertEqual(replanned.changedLinks, 1)
        try replanned.apply()
        XCTAssertEqual(try String(contentsOf: offline, encoding: .utf8), "[[moved]]")
    }

    func testApplyProceedsWhileSkippedDocumentStaysUnreadable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.md")
        let offline = root.appendingPathComponent("offline.md")
        try "source".write(to: source, atomically: true, encoding: .utf8)
        try "text".write(to: offline, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: offline.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: offline.path)
            try? FileManager.default.removeItem(at: root)
        }
        let plan = try WorkspaceFileOperations.planMove(source: source,
            destination: root.appendingPathComponent("moved.md"), root: root)
        XCTAssertNoThrow(try plan.apply())
    }

    func testMovePlanRebasesIncomingAndOutgoingLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("drafts")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("source.md")
        let destination = root.appendingPathComponent("renamed.md")
        let referring = root.appendingPathComponent("index.md")
        try "# Title\n\n[other](../other.md)\n\n`[code](../other.md)`".write(
            to: source, atomically: true, encoding: .utf8)
        try "[open](drafts/source.md#title)\n\n![alt](drafts/source.md \"caption\")\n\n[id]: drafts/source.md".write(
            to: referring, atomically: true, encoding: .utf8)
        try "other".write(to: root.appendingPathComponent("other.md"),
                          atomically: true, encoding: .utf8)
        let plan = try WorkspaceFileOperations.planMove(source: source, destination: destination,
                                                         root: root)
        XCTAssertEqual(plan.changedLinks, 4)
        let previews = plan.changes.flatMap(\.linkChanges)
        XCTAssertTrue(previews.contains { $0.before == "drafts/source.md#title" &&
            $0.after == "renamed.md#title" })
        try plan.apply()
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let moved = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(moved.contains("[other](other.md)"))
        XCTAssertTrue(moved.contains("`[code](../other.md)`"))
        let updated = try String(contentsOf: referring, encoding: .utf8)
        XCTAssertTrue(updated.contains("[open](renamed.md#title)"))
        XCTAssertTrue(updated.contains("![alt](renamed.md \"caption\")"))
        XCTAssertTrue(updated.contains("[id]: renamed.md"))
    }

    func testOpenUnsavedReferenceIsIncludedAndOriginalFormatIsKept() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.md")
        let reference = root.appendingPathComponent("reference.md")
        let destination = root.appendingPathComponent("renamed.md")
        try "source".write(to: source, atomically: true, encoding: .utf8)
        try Data([0xEF, 0xBB, 0xBF] + Array("[link](source.md)\r\n".utf8)).write(to: reference)
        let openData = Data([0xEF, 0xBB, 0xBF] +
                            Array("unsaved\r\n[link](source.md)\r\n".utf8))
        let plan = try WorkspaceFileOperations.planMove(source: source, destination: destination,
                                                        root: root, openDocuments: [reference: openData])
        let change = try XCTUnwrap(plan.changes.first { $0.oldURL.lastPathComponent == "reference.md" })
        XCTAssertEqual(change.linkCount, 1)
        XCTAssertEqual(change.openOriginalData, openData)
        XCTAssertEqual(change.updatedOpenText, "unsaved\n[link](renamed.md)\n")
        try plan.apply()
        try plan.validateAppliedData()
        XCTAssertEqual(try Data(contentsOf: reference),
                       Data([0xEF, 0xBB, 0xBF] +
                            Array("unsaved\r\n[link](renamed.md)\r\n".utf8)))
        try plan.rollback()
        XCTAssertEqual(try Data(contentsOf: reference),
                       Data([0xEF, 0xBB, 0xBF] + Array("[link](source.md)\r\n".utf8)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testPlanStopsWhenDocumentChangesBeforeApply() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("before.md")
        let destination = root.appendingPathComponent("after.md")
        let ref = root.appendingPathComponent("ref.md")
        try "old".write(to: source, atomically: true, encoding: .utf8)
        try "[link](before.md)".write(to: ref, atomically: true, encoding: .utf8)
        let plan = try WorkspaceFileOperations.planMove(source: source, destination: destination,
                                                         root: root)
        try "new text".write(to: ref, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try plan.apply())
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testPlanStopsWhenPreviouslyUnrelatedDocumentAddsLink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("before.md")
        let destination = root.appendingPathComponent("after.md")
        let another = root.appendingPathComponent("another.md")
        try "source".write(to: source, atomically: true, encoding: .utf8)
        try "unrelated".write(to: another, atomically: true, encoding: .utf8)
        let plan = try WorkspaceFileOperations.planMove(source: source, destination: destination,
                                                         root: root)
        try "[new](before.md)".write(to: another, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try plan.apply())
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testCreateRejectsCollisionsAndUnsafeNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = try WorkspaceFileOperations.create(name: "drafts", in: root, root: root,
                                                         folder: true)
        let file = try WorkspaceFileOperations.create(name: "first.md", in: folder, root: root,
                                                       folder: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let implicitExtension = try WorkspaceFileOperations.create(name: "second", in: folder,
                                                                    root: root, folder: false)
        XCTAssertEqual(implicitExtension.pathExtension, "md")
        XCTAssertThrowsError(try WorkspaceFileOperations.create(name: "first.md", in: folder,
                                                                  root: root, folder: false))
        XCTAssertThrowsError(try WorkspaceFileOperations.create(name: "../bad.md", in: folder,
                                                                  root: root, folder: false))
    }

    func testCreateAndMoveRejectSymlinkedDestinationOutsideWorkspace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        XCTAssertThrowsError(try WorkspaceFileOperations.create(name: "new.md", in: alias,
            root: root, folder: false))
        let source = root.appendingPathComponent("source.md")
        try "content".write(to: source, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try WorkspaceFileOperations.planMove(source: source,
            destination: alias.appendingPathComponent("source.md"), root: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("new.md").path))
    }

    func testTrashMovesFileOutOfWorkspace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = try WorkspaceFileOperations.create(name: "discard.md", in: root, root: root,
                                                       folder: false)
        let trashed = try WorkspaceFileOperations.moveToTrash(file, root: root)
        defer { if let trashed { try? FileManager.default.removeItem(at: trashed) } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNotNil(trashed)
    }

    func testMovingFolderUpdatesIncomingLinksAndKeepsInternalRelativeLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "![img](image.png)".write(to: folder.appendingPathComponent("a.md"),
                                      atomically: true, encoding: .utf8)
        try Data([0]).write(to: folder.appendingPathComponent("image.png"))
        let index = root.appendingPathComponent("index.md")
        try "[read](folder/a.md) ![img](folder/image.png)".write(
            to: index, atomically: true, encoding: .utf8)
        let destination = root.appendingPathComponent("renamed")
        let plan = try WorkspaceFileOperations.planMove(source: folder, destination: destination,
                                                         root: root)
        XCTAssertEqual(plan.changedLinks, 2)
        try plan.apply()
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("a.md"),
                                  encoding: .utf8), "![img](image.png)")
        XCTAssertEqual(try String(contentsOf: index, encoding: .utf8),
                       "[read](renamed/a.md) ![img](renamed/image.png)")
    }

    func testPlanStopsWhenNewDocumentAppearsBeforeApply() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = try WorkspaceFileOperations.create(name: "old.md", in: root, root: root,
                                                         folder: false)
        let plan = try WorkspaceFileOperations.planMove(source: source,
            destination: root.appendingPathComponent("new.md"), root: root)
        try "[link](old.md)".write(to: root.appendingPathComponent("late.md"),
                                    atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try plan.apply())
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testMoveEscapesReservedCharactersInLinkPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("before#1.md")
        let destination = root.appendingPathComponent("after#2.md")
        try "text".write(to: source, atomically: true, encoding: .utf8)
        let ref = root.appendingPathComponent("ref.md")
        try "[read](before%231.md)".write(to: ref, atomically: true, encoding: .utf8)
        try WorkspaceFileOperations.planMove(source: source, destination: destination,
                                              root: root).apply()
        XCTAssertEqual(try String(contentsOf: ref, encoding: .utf8), "[read](after%232.md)")
    }
}
