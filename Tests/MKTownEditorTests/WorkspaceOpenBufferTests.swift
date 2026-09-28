import Foundation
import XCTest
@testable import MKTownEditor

@MainActor
final class WorkspaceOpenBufferTests: XCTestCase {
    func testOpenBufferIsValidatedAndUpdatedAfterMove() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.md")
        let reference = root.appendingPathComponent("reference.md")
        try "source".write(to: source, atomically: true, encoding: .utf8)
        try "[link](source.md)".write(to: reference, atomically: true, encoding: .utf8)
        var open = MarkdownDocument(text: "unsaved\n[link](source.md)")
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let id = UUID()
        store.registerOpenBuffer(id: id, url: reference,
                                 encodedData: { open.encodedData() },
                                 updateText: { open.text = $0 })
        let plan = try WorkspaceFileOperations.planMove(
            source: source, destination: root.appendingPathComponent("renamed.md"), root: root,
            openDocuments: store.openBufferSnapshots())
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
                                 encodedData: { Data(first.utf8) }, updateText: { first = $0 })
        store.registerOpenBuffer(id: secondID, url: reference,
                                 encodedData: { Data(second.utf8) }, updateText: { second = $0 })
        let plan = try WorkspaceFileOperations.planMove(
            source: source, destination: root.appendingPathComponent("renamed.md"), root: root,
            openDocuments: store.openBufferSnapshots())
        second = "another unsaved edit"
        XCTAssertThrowsError(try store.openBufferSnapshots())
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside.md")
        store.registerOpenBuffer(id: UUID(), url: outside,
                                 encodedData: { Data("outside".utf8) }, updateText: { _ in })
        store.registerOpenBuffer(id: UUID(), url: outside,
                                 encodedData: { Data("different".utf8) }, updateText: { _ in })
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
                                 encodedData: { Data(text.utf8) }, updateText: { text = $0 })
        let plan = try WorkspaceFileOperations.planMove(
            source: source, destination: root.appendingPathComponent("renamed.md"), root: root,
            openDocuments: store.openBufferSnapshots())
        try plan.apply()
        text = "unsaved\n[link](renamed.md)"
        try store.applyOpenBufferChanges(in: plan)
        XCTAssertEqual(text, "unsaved\n[link](renamed.md)")
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
                                 encodedData: { Data(text.utf8) }, updateText: { text = $0 })
        let plan = try WorkspaceFileOperations.planMove(
            source: source, destination: root.appendingPathComponent("renamed.md"), root: root,
            openDocuments: store.openBufferSnapshots())
        XCTAssertEqual(plan.inspectedOpenDocuments.count, 1)
        text = "[new](source.md)"
        XCTAssertThrowsError(try store.validateOpenBuffers(in: plan))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
}
