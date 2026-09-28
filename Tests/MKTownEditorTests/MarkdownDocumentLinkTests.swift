import Foundation
import XCTest
@testable import MKTownEditor

final class MarkdownDocumentLinkTests: XCTestCase {
    func testRelativeMarkdownLinkResolvesAgainstCurrentDocument() {
        let context = DocumentContext(fileURL: URL(fileURLWithPath: "/tmp/book/chapters/current.md"))
        let link = MarkdownDocumentLink(url: URL(string: "../intro/first%20draft.md#%E6%A6%82%E8%A6%81")!,
                                        context: context)
        XCTAssertEqual(link?.fileURL.path, "/tmp/book/intro/first draft.md")
        XCTAssertEqual(link?.fragment, "概要")
    }

    func testOnlyRelativeMarkdownDocumentsAreHandled() {
        let context = DocumentContext(fileURL: URL(fileURLWithPath: "/tmp/current.md"))
        for value in ["https://example.com/doc.md", "#heading", "image.png", "/tmp/doc.md",
                      "file:///tmp/doc.md"] {
            XCTAssertNil(MarkdownDocumentLink(url: URL(string: value)!, context: context), value)
        }
        XCTAssertEqual(MarkdownDocumentLink(url: URL(string: "README.MARKDOWN")!, context: context)?
            .fileURL.path, "/tmp/README.MARKDOWN")
        XCTAssertNil(MarkdownDocumentLink(url: URL(string: "README.md")!,
                                          context: DocumentContext(fileURL: nil)))
    }

    @MainActor
    func testRenderedRelativeLinkCanBeResolved() {
        let rendered = MarkdownRenderer.render("[next](next.md#section)")
        let url = rendered.attribute(.link, at: 0, effectiveRange: nil) as? URL
        let context = DocumentContext(fileURL: URL(fileURLWithPath: "/tmp/current.md"))
        XCTAssertEqual(url.flatMap { MarkdownDocumentLink(url: $0, context: context) }?.fileURL.path,
                       "/tmp/next.md")
    }
}

@MainActor
final class DocumentLinkNavigationTests: XCTestCase {
    func testPendingFragmentIsConsumedOnlyByTargetDocument() {
        let context = DocumentContext(fileURL: URL(fileURLWithPath: "/tmp/source.md"))
        let link = MarkdownDocumentLink(url: URL(string: "target.md#heading")!, context: context)!
        let navigation = DocumentLinkNavigation()
        navigation.request(link)

        XCTAssertNil(navigation.take(for: URL(fileURLWithPath: "/tmp/source.md")))
        XCTAssertEqual(navigation.take(for: link.fileURL), "heading")
        XCTAssertNil(navigation.pending)
        XCTAssertNil(navigation.take(for: link.fileURL))
    }

    func testFailedOpenCancelsOnlyMatchingRequest() {
        let context = DocumentContext(fileURL: URL(fileURLWithPath: "/tmp/source.md"))
        let link = MarkdownDocumentLink(url: URL(string: "target.md#heading")!, context: context)!
        let navigation = DocumentLinkNavigation()
        navigation.request(link)
        navigation.cancel(for: URL(fileURLWithPath: "/tmp/other.md"))
        XCTAssertNotNil(navigation.pending)
        navigation.cancel(for: link.fileURL)
        XCTAssertNil(navigation.pending)
    }
}
