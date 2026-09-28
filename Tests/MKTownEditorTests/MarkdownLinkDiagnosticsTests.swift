import Foundation
import XCTest
@testable import MKTownEditor

final class MarkdownLinkDiagnosticsTests: XCTestCase {
    func testReportsMissingLocalResourcesHeadingsAndReferenceDefinitions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("# Known".utf8).write(to: root.appendingPathComponent("target.md"))
        let source = """
        # Present
        [ok](#present) [heading](#absent)
        ![image](missing.png)
        [file](missing.md) [target](target.md#absent)
        [reference][lost] [valid][id]
        `[code](ghost.md)`
        ```md
        [fence](ghost.md)
        ```
        [id]: https://example.com
        """
        let context = DocumentContext(fileURL: root.appendingPathComponent("source.md"))
        let diagnostics = MarkdownLinkDiagnostics.inspect(source, analysis: MarkdownAnalysis(source),
                                                          context: context)
        XCTAssertEqual(diagnostics.map(\.kind), [.missingHeading, .missingImage, .missingFile,
                                                 .missingHeading, .missingReference])
        XCTAssertEqual(diagnostics.map(\.detail), ["#absent", "missing.png", "missing.md",
                                                   "target.md#absent", "lost"])
        let text = source as NSString
        XCTAssertEqual(text.substring(with: diagnostics[0].sourceRange), "[heading](#absent)")
    }

    func testCurrentDocumentUsesUnsavedSourceForHeadingCheck() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source.md")
        try Data("# Old".utf8).write(to: file)
        let source = "# New\n[local](source.md#new)"
        XCTAssertTrue(MarkdownLinkDiagnostics.inspect(source, analysis: MarkdownAnalysis(source),
                                                      context: DocumentContext(fileURL: file)).isEmpty)
    }

    func testInlineLinkScannerRetainsImageFlagAndEscapedParentheses() {
        let links = MarkdownLinkSyntax.inlineLinks(in: "![a](image.png) [b](folder/a\\(1\\).md)")
        XCTAssertEqual(links.map(\.destination), ["image.png", "folder/a(1).md"])
        XCTAssertEqual(links.map(\.isImage), [true, false])
    }
}
