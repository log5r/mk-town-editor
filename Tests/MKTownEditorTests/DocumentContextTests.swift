import Foundation
import XCTest
@testable import MKTownEditor

final class DocumentContextTests: XCTestCase {
    func testUnsavedDocumentHasNoRelativeResourceBase() {
        let context = DocumentContext(fileURL: nil)

        XCTAssertNil(context.directoryURL)
        XCTAssertNil(context.resolveLocalResource("images/figure.png"))
    }

    func testRelativeResourceFollowsSaveMoveAndSaveAsURL() {
        let first = DocumentContext(fileURL: URL(fileURLWithPath: "/tmp/draft/README.md"))
        let moved = DocumentContext(fileURL: URL(fileURLWithPath: "/tmp/project/README.md"))
        let renamed = DocumentContext(fileURL: URL(fileURLWithPath: "/tmp/project/notes.md"))

        XCTAssertEqual(first.resolveLocalResource("images/figure.png")?.path, "/tmp/draft/images/figure.png")
        XCTAssertEqual(moved.resolveLocalResource("images/figure.png")?.path, "/tmp/project/images/figure.png")
        XCTAssertEqual(renamed.resolveLocalResource("../shared/図%20A.png")?.path, "/tmp/shared/図 A.png")
    }

    func testRemoteAndAbsolutePathsAreNotTreatedAsLocalRelativeResources() {
        let context = DocumentContext(fileURL: URL(fileURLWithPath: "/tmp/README.md"))

        XCTAssertNil(context.resolveLocalResource("https://example.com/a.png"))
        XCTAssertNil(context.resolveLocalResource("/tmp/absolute.png"))
        XCTAssertNil(context.resolveLocalResource(""))
    }
}
