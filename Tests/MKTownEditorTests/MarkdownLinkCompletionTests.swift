import Foundation
import XCTest
@testable import MKTownEditor

final class MarkdownLinkCompletionTests: XCTestCase {
    func testCurrentDocumentHeadingsIncludeDuplicateAnchors() {
        let analysis = MarkdownAnalysis("# Guide\n# Guide\n## 日本語")
        let context = DocumentContext(fileURL: nil)
        XCTAssertEqual(MarkdownLinkCompletion.headings(for: "#guide", current: analysis,
                                                       context: context).map(\.destination),
                       ["#guide", "#guide-1"])
        XCTAssertEqual(MarkdownLinkCompletion.headings(for: "#日本", current: analysis,
                                                       context: context).map(\.destination),
                       ["#日本語"])
    }

    func testOnlyNamedTargetDocumentIsParsed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("# Target\n# More".utf8).write(to: root.appendingPathComponent("target.md"))
        let context = DocumentContext(fileURL: root.appendingPathComponent("source.md"))
        let analysis = MarkdownAnalysis("# Current")

        XCTAssertEqual(MarkdownLinkCompletion.headings(for: "target.md#", current: analysis,
                                                       context: context).map(\.destination),
                       ["target.md#target", "target.md#more"])
        XCTAssertTrue(MarkdownLinkCompletion.headings(for: "missing.md#", current: analysis,
                                                    context: context).isEmpty)
    }

    func testReferenceIDsAndInsertion() throws {
        let source = "Example\n\n[Beta]: /b\n[Alpha]: /a"
        let analysis = MarkdownAnalysis(source)
        XCTAssertEqual(MarkdownLinkCompletion.referenceIDs(in: analysis), ["alpha", "beta"])
        let draft = MarkdownLinkSyntax.draft(in: source, selection: NSRange(location: 0, length: 7))
        let edit = try XCTUnwrap(MarkdownLinkSyntax.referenceEdit(in: source, draft: draft,
                                                                label: "Example", referenceID: "alpha"))
        XCTAssertEqual(edit.applying(to: source), "[Example][alpha]\n\n[Beta]: /b\n[Alpha]: /a")
        XCTAssertNil(MarkdownLinkSyntax.referenceEdit(in: "changed", draft: draft,
                                                     label: "Example", referenceID: "alpha"))
    }

    @MainActor
    func testInsertedReferenceLinkRendersUsingExistingDefinition() throws {
        let source = "Example\n\n[alpha]: https://example.com"
        let draft = MarkdownLinkSyntax.draft(in: source, selection: NSRange(location: 0, length: 7))
        let edit = try XCTUnwrap(MarkdownLinkSyntax.referenceEdit(in: source, draft: draft,
                                                                label: "Example", referenceID: "alpha"))
        let rendered = MarkdownRenderer.render(edit.applying(to: source))
        XCTAssertEqual(rendered.attribute(.link, at: 0, effectiveRange: nil) as? URL,
                       URL(string: "https://example.com"))
    }
}
