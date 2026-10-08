import Foundation
import XCTest
@testable import MKTownEditor

final class WorkspaceDocumentTemplateTests: XCTestCase {
    /// A new document starts empty; guidance is a placeholder, not saved text (#28).
    func testTemplatesHaveDistinctBodiesAndNewDocumentIsEmpty() {
        XCTAssertEqual(WorkspaceDocumentTemplate.blank.text, "")
        XCTAssertEqual(MarkdownDocument().text, "")
        XCTAssertEqual(MarkdownDocument().encodedData(), Data())
        XCTAssertFalse(WorkspaceDocumentTemplate.starter.text.isEmpty)
        XCTAssertTrue(WorkspaceDocumentTemplate.meetingNotes.text.contains("## 決定事項"))
        XCTAssertTrue(WorkspaceDocumentTemplate.article.text.contains("## 本文"))
    }

    func testTemplateBodyIsWrittenAtChosenLocationWithoutReplacingExistingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let body = WorkspaceDocumentTemplate.meetingNotes.text
        let file = try WorkspaceFileOperations.create(name: "記録", in: folder, root: root,
                                                      folder: false, contents: body)
        XCTAssertEqual(file.deletingLastPathComponent().standardizedFileURL.path,
                       folder.standardizedFileURL.path)
        XCTAssertEqual(file.pathExtension, "md")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), body)
        XCTAssertThrowsError(try WorkspaceFileOperations.create(name: "記録.md", in: folder,
                                                                 root: root, folder: false,
                                                                 contents: "replacement"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), body)
        let blank = try WorkspaceFileOperations.create(name: "空白.md", in: root, root: root,
                                                       folder: false,
                                                       contents: WorkspaceDocumentTemplate.blank.text)
        XCTAssertEqual(try Data(contentsOf: blank), Data())
    }
}
