import Foundation
import XCTest
@testable import MKTownEditor

@MainActor
final class MarkdownHeadingIndexTests: XCTestCase {
    func testUnicodeFormattingAndDuplicateHeadingsGenerateUniqueAnchors() {
        let source = "# Hello, _World_!\n## 日本語 Θ\n# Hello, _World_!\n# hello-world-1"
        let index = MarkdownHeadingIndex(analysis: MarkdownAnalysis(source))

        XCTAssertEqual(index.anchors.map(\.slug),
                       ["hello-world", "日本語-θ", "hello-world-1", "hello-world-1-1"])
        XCTAssertEqual(index.entry(forFragment: "hello-world-1")?.id, index.anchors[2].entry.id)
        XCTAssertEqual(index.entry(forFragment: "%E6%97%A5%E6%9C%AC%E8%AA%9E-%CE%B8")?.id,
                       index.anchors[1].entry.id)
    }

    func testOnlySameDocumentFragmentsAreHandledLocally() {
        XCTAssertEqual(MarkdownHeadingIndex.localFragment(in: URL(string: "#topic")!), "topic")
        XCTAssertNil(MarkdownHeadingIndex.localFragment(in: URL(string: "other.md#topic")!))
        XCTAssertNil(MarkdownHeadingIndex.localFragment(in: URL(string: "https://example.com/#topic")!))
        XCTAssertNil(MarkdownHeadingIndex.localFragment(in: URL(string: "#")!))
    }

    func testMarkupFreeVisibleTextAndEmptyHeadingFallback() {
        let index = MarkdownHeadingIndex(analysis: MarkdownAnalysis("# [Guide](page.md) and `code`\n# !!!"))
        XCTAssertEqual(index.anchors.map(\.slug), ["guide-and-code", "section"])
    }

    func testRenderedDocumentLinkRetainsLocalFragmentForNavigation() {
        let rendered = MarkdownRenderer.render("# Target\n\n[go](#target)")
        let range = (rendered.string as NSString).range(of: "go")
        let url = rendered.attribute(.link, at: range.location, effectiveRange: nil) as? URL
        XCTAssertEqual(url.flatMap(MarkdownHeadingIndex.localFragment(in:)), "target")
    }
}
