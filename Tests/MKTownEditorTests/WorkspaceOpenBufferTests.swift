import Foundation
import XCTest
@testable import MKTownEditor

@MainActor
final class WorkspaceOpenBufferTests: XCTestCase {
    func testUnsavableBufferCanBeIndexedAndManuallySelectedEncodingSurvivesLinkUpdate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.md")
        let reference = root.appendingPathComponent("reference.md")
        let original = Data("charset=utf-8\r\n[link](source.md)".utf8)
        try Data("source".utf8).write(to: source)
        try original.write(to: reference)
        var open = try MarkdownDocument(data: original, encoding: .shiftJIS)
        let store = WorkspaceStore(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)))
        store.registerOpenBuffer(id: UUID(), url: reference, document: { open }, updateText: { open.text = $0 })
        open.text += "😀"
        let snapshots = try store.openBufferSnapshots()
        XCTAssertEqual(try MarkdownDocument.decode(XCTUnwrap(snapshots[reference.resolvingSymlinksInPath()])), open.text)
        let destination = root.appendingPathComponent("renamed.md")
        XCTAssertThrowsError(try WorkspaceFileOperations.planMove(source: source, destination: destination,
            root: root, openDocuments: store.openBufferDocuments()))
        XCTAssertEqual(try Data(contentsOf: reference), original)

        open.text.removeLast()
        open.text += "日本語"
        let plan = try WorkspaceFileOperations.planMove(source: source, destination: destination,
            root: root, openDocuments: store.openBufferDocuments())
        try plan.apply()
        let expected = "charset=utf-8\r\n[link](renamed.md)日本語"
        XCTAssertEqual(try Data(contentsOf: reference), try XCTUnwrap(expected.data(using: .shiftJIS)))
        try plan.rollback()
        XCTAssertEqual(try Data(contentsOf: reference), original)
    }

    func testOpenBufferIsValidatedAndUpdatedAfterMove() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.md")
        let reference = root.appendingPathComponent("reference.md")
        let unrelated = root.appendingPathComponent("unrelated.md")
        try "source".write(to: source, atomically: true, encoding: .utf8)
        try "[link](source.md)".write(to: reference, atomically: true, encoding: .utf8)
        try "unrelated".write(to: unrelated, atomically: true, encoding: .utf8)
        var open = MarkdownDocument(text: "unsaved\n[link](source.md)")
        var openUnrelated = MarkdownDocument(text: "unrelated")
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let id = UUID()
        store.registerOpenBuffer(id: id, url: reference,
                                 document: { open },
                                 updateText: { open.text = $0 })
        store.registerOpenBuffer(id: UUID(), url: unrelated, document: { openUnrelated },
                                 isReadOnly: { true }, updateText: { openUnrelated.text = $0 })
        let plan = try WorkspaceFileOperations.planMove(
            source: source, destination: root.appendingPathComponent("renamed.md"), root: root,
            openDocuments: store.openBufferDocuments())
        try store.validateOpenBuffers(in: plan)
        let lockID = store.lockOpenDocuments(in: plan)
        let secondLockID = store.lockOpenDocuments(in: plan)
        XCTAssertTrue(store.isDocumentLocked(reference))
        try plan.apply()
        try store.applyOpenBufferChanges(in: plan)
        store.unlockOpenDocuments(lockID)
        XCTAssertTrue(store.isDocumentLocked(reference))
        store.unlockOpenDocuments(secondLockID)
        XCTAssertEqual(open.text, "unsaved\n[link](renamed.md)")
        XCTAssertEqual(openUnrelated.text, "unrelated")
        XCTAssertFalse(store.isDocumentLocked(reference))
        store.unregisterOpenBuffer(id: id, url: reference)
    }

    func testChangedOrDivergentOpenBuffersAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.md")
        let reference = root.appendingPathComponent("reference.md")
        try "source".write(to: source, atomically: true, encoding: .utf8)
        try "[link](source.md)".write(to: reference, atomically: true, encoding: .utf8)
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        var first = "[link](source.md)"
        var second = first
        let firstID = UUID()
        let secondID = UUID()
        store.registerOpenBuffer(id: firstID, url: reference,
                                 document: { MarkdownDocument(text: first) }, updateText: { first = $0 })
        store.registerOpenBuffer(id: secondID, url: reference,
                                 document: { MarkdownDocument(text: second) }, updateText: { second = $0 })
        let plan = try WorkspaceFileOperations.planMove(
            source: source, destination: root.appendingPathComponent("renamed.md"), root: root,
            openDocuments: store.openBufferDocuments())
        second = "another unsaved edit"
        XCTAssertThrowsError(try store.openBufferSnapshots())
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside.md")
        store.registerOpenBuffer(id: UUID(), url: outside,
                                 document: { MarkdownDocument(text: "outside") }, updateText: { _ in })
        store.registerOpenBuffer(id: UUID(), url: outside,
                                 document: { MarkdownDocument(text: "different") }, updateText: { _ in })
        XCTAssertThrowsError(try store.openBufferSnapshots(under: root))
        XCTAssertThrowsError(try store.validateOpenBuffers(in: plan))
        second = first
        XCTAssertEqual(try store.openBufferSnapshots(under: root).count, 1)
        first = "edited after preview"
        XCTAssertThrowsError(try store.validateOpenBuffers(in: plan))
    }

    func testExternalFilePresenterRefreshToAppliedTextIsAccepted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.md")
        let reference = root.appendingPathComponent("reference.md")
        try "source".write(to: source, atomically: true, encoding: .utf8)
        try "[link](source.md)".write(to: reference, atomically: true, encoding: .utf8)
        var text = "unsaved\n[link](source.md)"
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.registerOpenBuffer(id: UUID(), url: reference,
                                 document: { MarkdownDocument(text: text) }, updateText: { text = $0 })
        let plan = try WorkspaceFileOperations.planMove(
            source: source, destination: root.appendingPathComponent("renamed.md"), root: root,
            openDocuments: store.openBufferDocuments())
        try plan.apply()
        text = "unsaved\n[link](renamed.md)"
        try store.applyOpenBufferChanges(in: plan)
        XCTAssertEqual(text, "unsaved\n[link](renamed.md)")
    }

    func testReadOnlyWindowPreventsLinkRewriteBeforeAndAfterDiskCommit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.md")
        let reference = root.appendingPathComponent("reference.md")
        let destination = root.appendingPathComponent("renamed.md")
        let original = "[link](source.md)"
        try "source".write(to: source, atomically: true, encoding: .utf8)
        try original.write(to: reference, atomically: true, encoding: .utf8)
        var firstText = original
        var secondText = original
        var secondIsReadOnly = true
        let store = WorkspaceStore(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)))
        let secondID = UUID()
        store.registerOpenBuffer(id: UUID(), url: reference,
                                 document: { MarkdownDocument(text: firstText) }, updateText: { firstText = $0 })
        store.registerOpenBuffer(id: secondID, url: reference,
                                 document: { MarkdownDocument(text: secondText) },
                                 isReadOnly: { secondIsReadOnly }, updateText: { secondText = $0 })
        let plan = try WorkspaceFileOperations.planMove(
            source: source, destination: destination, root: root, openDocuments: store.openBufferDocuments())

        XCTAssertTrue(store.isDocumentReadOnly(reference))
        XCTAssertThrowsError(try store.validateOpenBuffers(in: plan)) { error in
            guard case let WorkspaceOpenBufferError.readOnly(url) = error else {
                return XCTFail("Expected a read-only buffer error, received \(error)")
            }
            XCTAssertEqual(url, reference.resolvingSymlinksInPath().standardizedFileURL)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))

        secondIsReadOnly = false
        XCTAssertFalse(store.isDocumentReadOnly(reference))
        try store.validateOpenBuffers(in: plan)
        try plan.apply()
        secondIsReadOnly = true
        XCTAssertThrowsError(try store.applyOpenBufferChanges(in: plan)) { error in
            guard case WorkspaceOpenBufferError.readOnly = error else {
                return XCTFail("Expected a read-only buffer error, received \(error)")
            }
        }
        XCTAssertEqual(firstText, original)
        XCTAssertEqual(secondText, original)
        try plan.rollback()
        XCTAssertEqual(try String(contentsOf: reference, encoding: .utf8), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        store.unregisterOpenBuffer(id: secondID, url: reference)
        XCTAssertFalse(store.isDocumentReadOnly(reference))
    }

    func testNewLinkInPreviouslyUnrelatedOpenDocumentStopsMove() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.md")
        let unrelated = root.appendingPathComponent("unrelated.md")
        try "source".write(to: source, atomically: true, encoding: .utf8)
        try "plain".write(to: unrelated, atomically: true, encoding: .utf8)
        var text = "plain"
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.registerOpenBuffer(id: UUID(), url: unrelated,
                                 document: { MarkdownDocument(text: text) }, updateText: { text = $0 })
        let plan = try WorkspaceFileOperations.planMove(
            source: source, destination: root.appendingPathComponent("renamed.md"), root: root,
            openDocuments: store.openBufferDocuments())
        XCTAssertEqual(plan.inspectedOpenDocuments.count, 1)
        text = "[new](source.md)"
        XCTAssertThrowsError(try store.validateOpenBuffers(in: plan))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
}
