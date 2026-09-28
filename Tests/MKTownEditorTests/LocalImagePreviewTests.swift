import AppKit
import XCTest
@testable import MKTownEditor

@MainActor
final class LocalImagePreviewTests: XCTestCase {
    private let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lGQAAAAASUVORK5CYII=")!

    func testInlineRelativeImageLoadsAsAttachmentWithAltDescription() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = root.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try png.write(to: assets.appendingPathComponent("図 one.png"))
        let context = DocumentContext(fileURL: root.appendingPathComponent("README.md"))

        let rendered = MarkdownRenderer.render("before ![説明](assets/%E5%9B%B3%20one.png) after",
                                               documentContext: context)
        let location = (rendered.string as NSString).range(of: "\u{FFFC}").location

        XCTAssertNotEqual(location, NSNotFound)
        let attachment = try XCTUnwrap(rendered.attribute(.attachment, at: location,
                                                           effectiveRange: nil) as? NSTextAttachment)
        XCTAssertNotNil(attachment.image)
        XCTAssertEqual(attachment.image?.accessibilityDescription, "説明")
        XCTAssertEqual(rendered.attribute(.alternateDescription, at: location,
                                          effectiveRange: nil) as? String, "説明")
    }

    func testReferenceImagesAlsoLoadAndMissingResourcesShowAlt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try png.write(to: root.appendingPathComponent("photo.png"))
        let context = DocumentContext(fileURL: root.appendingPathComponent("README.md"))
        let markdown = "![photo][image]\n\n[image]: photo.png"

        let loaded = MarkdownRenderer.render(markdown, documentContext: context)
        XCTAssertTrue(loaded.string.contains("\u{FFFC}"))

        let missing = MarkdownRenderer.render("![missing](absent.png)", documentContext: context)
        XCTAssertEqual(missing.string, "画像: missing")
        XCTAssertNotNil(missing.attribute(.link, at: 0, effectiveRange: nil))
        XCTAssertEqual(MarkdownRenderer.render("![remote](https://example.com/a.png)").string,
                       "外部画像の読込オフ: remote")
    }

    func testRemoteImageStoreRequiresOptInCachesAndClearsOnDisable() async {
        let imageData = png
        let store = RemoteImageStore(fetch: { _ in imageData })
        let url = URL(string: "https://example.com/figure.png")!
        await store.load(url)
        XCTAssertNil(store.image(for: url))
        store.setEnabled(true)
        await store.load(url)
        XCTAssertNotNil(store.image(for: url))
        let revision = store.revision
        await store.load(url)
        XCTAssertEqual(store.revision, revision)
        store.setEnabled(false)
        XCTAssertNil(store.image(for: url))
    }

    func testRemoteImageStoreReportsDecodeFailureAndSkipsUnsupportedScheme() async {
        let store = RemoteImageStore(fetch: { _ in Data("invalid".utf8) })
        store.setEnabled(true)
        let url = URL(string: "https://example.com/broken.png")!
        await store.load(url)
        XCTAssertTrue(store.hasFailed(url))
        let revision = store.revision
        await store.load(url)
        XCTAssertEqual(store.revision, revision)
        await store.load(URL(fileURLWithPath: "/tmp/image.png"))
        XCTAssertEqual(store.revision, revision)
    }

    func testRemoteImageReferencesExcludeCodeAndIncludeReferenceStyle() {
        let markdown = "![shown][pic]\n\n[pic]: https://example.com/a.png\n\n" +
            "`![inline](https://example.com/no.png)`\n\n```md\n" +
            "![code](https://example.com/code.png)\n```"
        XCTAssertEqual(RemoteImageStore.referencedURLs(in: markdown),
            [URL(string: "https://example.com/a.png")!])
    }

    func testImagePreviewIsBoundedWithoutEnlargingSmallImages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("small.png")
        try png.write(to: image)

        let preview = try XCTUnwrap(ImageResourceManager().previewImage(at: image, alt: "small"))

        XCTAssertLessThanOrEqual(preview.size.width, 480)
        XCTAssertLessThanOrEqual(preview.size.height, 320)
        XCTAssertEqual(preview.accessibilityDescription, "small")
    }

    func testAttachmentShrinksToAvailableTextLineWidth() {
        let attachment = MarkdownImageAttachment()
        attachment.image = NSImage(size: NSSize(width: 480, height: 240))

        let bounds = attachment.attachmentBounds(for: nil,
                                                  proposedLineFragment: CGRect(x: 0, y: 0,
                                                                               width: 220, height: 20),
                                                  glyphPosition: .zero, characterIndex: 0)

        XCTAssertLessThanOrEqual(bounds.width, 220)
        XCTAssertEqual(bounds.width / bounds.height, 2, accuracy: 0.001)
    }

    func testTableCellAndTaskLeafUseDocumentContext() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try png.write(to: root.appendingPathComponent("photo.png"))
        let context = DocumentContext(fileURL: root.appendingPathComponent("README.md"))
        let task = MarkdownAnalysis("- [ ] ![task](photo.png)")
        let block = try XCTUnwrap(task.rootBlocks.first)
        let taskText = MarkdownRenderer.renderLeaf(block, in: task, showTaskPrefix: false,
                                                   documentContext: context)
        let cellText = MarkdownRenderer.renderTableCell("![cell](photo.png)", in: task,
                                                         documentContext: context)

        XCTAssertTrue(taskText.string.contains("\u{FFFC}"))
        XCTAssertEqual(cellText.string, "\u{FFFC}")
    }
}
