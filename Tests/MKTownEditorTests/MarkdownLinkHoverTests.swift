import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import MKTownEditor

final class MarkdownLinkHoverTests: XCTestCase {
    @MainActor
    func testStructuredPreviewKeepsLinkTextInSelectableView() {
        let source = "# [Example](https://example.com)\n\nBody"
        let preview = MarkdownPreview(markdown: source, documentContext: DocumentContext(fileURL: nil))
        let host = NSHostingView(rootView: preview)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = window.contentView?.bounds ?? .zero
        host.layoutSubtreeIfNeeded()
        func allSubviews(of view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + allSubviews(of: $0) }
        }
        let linked = allSubviews(of: host).compactMap { $0 as? HoverPreviewTextView }
        XCTAssertFalse(linked.isEmpty)
        XCTAssertTrue(linked.contains { $0.frame.height > 0 })
        XCTAssertTrue(linked.contains { view in
            let text = view.attributedString()
            return (0..<text.length).contains {
                text.attribute(.link, at: $0, effectiveRange: nil) != nil
            }
        })
    }

    func testFindsInlineAndReferenceLinksButNotCodeOrImages() {
        let source = """
        [one](other.md) [two][ref] ![image](photo.png)
        \\[escaped][ref]
        \u{60}[code](hidden.md)\u{60}
        ~~~md
        [fence](hidden.md)
        ~~~
        [ref]: https://example.com
        """
        let links = MarkdownLinkHover.links(in: source)
        XCTAssertEqual(links.map(\.url.relativeString), ["other.md", "https://example.com"])
        let text = source as NSString
        XCTAssertEqual(text.substring(with: links[1].sourceRange), "[two][ref]")
    }

    func testLocalPreviewUsesTargetSectionAndCurrentUnsavedDocument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.md")
        let targetURL = root.appendingPathComponent("target.md")
        try Data("# Old\nDisk content".utf8).write(to: sourceURL)
        try Data("# One\nFirst section\n# Two\nSecond section\n# Three\nThird section".utf8)
            .write(to: targetURL)
        let context = DocumentContext(fileURL: sourceURL)
        let local = await MarkdownLinkHoverContentLoader.preview(
            for: URL(string: "target.md#two")!, context: context,
            currentSource: "# Current\nUnsaved text", loadsExternalPages: false)
        XCTAssertEqual(local.title, "Two")
        XCTAssertEqual(local.excerpt, "Second section")
        let current = await MarkdownLinkHoverContentLoader.preview(
            for: URL(string: "#current")!, context: context,
            currentSource: "# Current\nUnsaved text", loadsExternalPages: false)
        XCTAssertEqual(current.title, "Current")
        XCTAssertEqual(current.excerpt, "Unsaved text")
        let missing = await MarkdownLinkHoverContentLoader.preview(
            for: URL(string: "target.md#missing")!, context: context,
            currentSource: "", loadsExternalPages: false)
        XCTAssertEqual(missing.excerpt, String(localized: "見出しが見つかりません"))
    }

    func testExternalFetchRequiresExplicitSetting() async {
        actor Counter {
            var value = 0
            func hit() { value += 1 }
        }
        let counter = Counter()
        let url = URL(string: "https://example.com/page")!
        let context = DocumentContext(fileURL: nil)
        let disabled = await MarkdownLinkHoverContentLoader.preview(
            for: url, context: context, currentSource: "", loadsExternalPages: false) { _ in
                await counter.hit()
                return "Fetched Title"
            }
        XCTAssertEqual(disabled.title, "example.com")
        let enabled = await MarkdownLinkHoverContentLoader.preview(
            for: url, context: context, currentSource: "", loadsExternalPages: true) { _ in
                await counter.hit()
                return "Fetched Title"
            }
        let count = await counter.value
        XCTAssertEqual(count, 1)
        XCTAssertEqual(enabled.title, "Fetched Title")
        XCTAssertEqual(enabled.destination, url.absoluteString)
    }
}
