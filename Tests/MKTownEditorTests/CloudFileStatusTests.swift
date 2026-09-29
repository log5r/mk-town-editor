import Foundation
import XCTest
@testable import MKTownEditor

final class CloudFileStatusTests: XCTestCase {
    func testLocalDocumentReportsNoCloudDownloadAndReadsCoordinatedText() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = folder.appendingPathComponent("note.md")
        try "Local\n日本語".write(to: document, atomically: true, encoding: .utf8)
        let status = try CloudFileStatus.read(at: document)
        XCTAssertFalse(status.isUbiquitous)
        XCTAssertFalse(status.needsDownload)
        XCTAssertFalse(status.hasUnresolvedConflicts)
        XCTAssertNotNil(status.modificationDate)
        XCTAssertEqual(try CloudFileVersions.readCurrent(at: document), "Local\n日本語")
        XCTAssertTrue(CloudFileVersions.unresolved(at: document).isEmpty)
        XCTAssertThrowsError(try CloudFileVersions.requestDownload(at: document))
        XCTAssertThrowsError(try CloudFileVersions.resolve(at: document, selectedText: "Local\n日本語"))
    }

    func testMissingFileDoesNotReturnAUsableStatus() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        XCTAssertThrowsError(try CloudFileStatus.read(at: missing))
        XCTAssertThrowsError(try CloudFileVersions.readCurrent(at: missing))
    }
}
