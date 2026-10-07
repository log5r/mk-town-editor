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
        let inspectionLink = try XCTUnwrap(rendered.attribute(.link, at: location,
            effectiveRange: nil) as? URL)
        XCTAssertEqual(MarkdownImageInspectionLink.destination(inspectionLink),
            assets.appendingPathComponent("図 one.png"))
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
        XCTAssertNotNil(store.fullImage(for: url))
        let revision = store.revision
        await store.load(url)
        XCTAssertEqual(store.revision, revision)
        store.setEnabled(false)
        XCTAssertNil(store.image(for: url))
        XCTAssertNil(store.fullImage(for: url))
    }

    func testDetachedPreviewWindowFollowsDocumentURLAndClosesWithOwner() throws {
        let suite = "mktown-detached-preview-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = DetachedPreviewWindowManager()
        let settings = EditorSettingsStore(defaults: defaults)
        manager.show(document: .constant(MarkdownDocument(text: "# Preview")),
            documentURL: nil, settingsStore: settings,
            workspaceStore: WorkspaceStore(defaults: defaults),
            updates: PreviewUpdateController())
        XCTAssertTrue(manager.isOpen)
        let saved = URL(fileURLWithPath: "/tmp/preview.md")
        manager.updateDocumentURL(saved)
        XCTAssertEqual(manager.documentURL, saved)
        manager.close()
        XCTAssertFalse(manager.isOpen)
    }

    func testImageInspectionLinkRejectsUnsupportedSchemes() {
        let remote = URL(string: "https://example.com/a%20b.png")!
        XCTAssertEqual(MarkdownImageInspectionLink.destination(
            MarkdownImageInspectionLink.make(remote)!), remote)
        XCTAssertNil(MarkdownImageInspectionLink.destination(
            URL(string: "mktown-image:/inspect?url=javascript%3Aalert%281%29")!))
        XCTAssertNil(MarkdownImageInspectionLink.make(URL(string: "javascript:alert(1)")!))
        XCTAssertNil(MarkdownImageInspectionLink.destination(
            URL(string: "mktown-image:/other?url=https%3A%2F%2Fexample.com%2Fa.png")!))
    }

    func testLocalAttachmentLinkOpensQuickLookOnlyForExistingNonDocumentFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pdf = root.appendingPathComponent("仕様 one.pdf")
        let markdown = root.appendingPathComponent("other.md")
        try Data("pdf".utf8).write(to: pdf)
        try Data("text".utf8).write(to: markdown)
        let context = DocumentContext(fileURL: root.appendingPathComponent("note.md"))
        XCTAssertEqual(MarkdownAttachmentInspectionLink.localFile(
            URL(string: "%E4%BB%95%E6%A7%98%20one.pdf")!, context: context), pdf)
        XCTAssertNil(MarkdownAttachmentInspectionLink.localFile(
            URL(string: "other.md")!, context: context))
        XCTAssertNil(MarkdownAttachmentInspectionLink.localFile(
            URL(string: "missing.pdf")!, context: context))
        XCTAssertNil(MarkdownAttachmentInspectionLink.localFile(
            URL(string: "https://example.com/file.pdf")!, context: context))
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

    func testImageWidthDialectLeavesCodeUntouchedAndCaptionsStandaloneImage() {
        let source = "`![code](a.png){width=99}` ![図](b.png){width=320px}"
        let layout = MarkdownImageLayout.parse(source)
        XCTAssertEqual(layout.markdown, "`![code](a.png){width=99}` ![図](b.png)")
        XCTAssertEqual(layout.widths, [320])
        XCTAssertNil(layout.standaloneCaption)
        XCTAssertEqual(MarkdownImageLayout.parse("![説明](b.png){width=320}").standaloneCaption,
                       "説明")
    }

    func testStandaloneImageUsesRequestedWidthAndShowsCaption() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try png.write(to: root.appendingPathComponent("photo.png"))
        let document = root.appendingPathComponent("note.md")
        let source = "![説明](photo.png){width=240}"
        let rendered = MarkdownRenderer.render(source,
            documentContext: DocumentContext(fileURL: document))
        let location = (rendered.string as NSString).range(of: "\u{FFFC}").location
        let attachment = try XCTUnwrap(rendered.attribute(.attachment, at: location,
            effectiveRange: nil) as? MarkdownImageAttachment)
        XCTAssertEqual(attachment.bounds.width, 240)
        XCTAssertTrue(rendered.string.hasSuffix("\n説明"))
        let html = MarkdownHTMLExporter.render(source, documentURL: document)
        XCTAssertTrue(html.contains("width=\"240\""))
        XCTAssertTrue(html.contains("<figcaption>説明</figcaption>"))
        XCTAssertFalse(html.contains("{width=240}"))
    }

    func testRemoteImageReferencesExcludeCodeAndIncludeReferenceStyle() {
        let markdown = "![shown][pic]\n\n[pic]: https://example.com/a.png\n\n" +
            "`![inline](https://example.com/no.png)`\n\n```md\n" +
            "![code](https://example.com/code.png)\n```"
        XCTAssertEqual(RemoteImageStore.referencedURLs(in: markdown),
            [URL(string: "https://example.com/a.png")!])
    }

    func testRemoteImageReferencesReuseProvidedAnalysisAndSnapshot() {
        let markdown = "![shown][pic]\n\n[pic]: https://example.com/a.png\n\n![inline](https://example.com/b.png)"
        let expected: Set<URL> = [URL(string: "https://example.com/a.png")!,
                                  URL(string: "https://example.com/b.png")!]
        XCTAssertEqual(DocumentSnapshot(source: markdown).remoteImageURLs, expected)
        XCTAssertEqual(DocumentSnapshot(source: "![local](a.png)").remoteImageURLs, [])

        // 渡した解析結果の参照定義を使うことで、本文を再解析していないことを確かめる。
        let definitions = MarkdownAnalysis("[pic]: https://example.com/from-analysis.png")
        XCTAssertEqual(RemoteImageStore.referencedURLs(in: "![x][pic] http", analysis: definitions),
                       [URL(string: "https://example.com/from-analysis.png")!])
        XCTAssertEqual(RemoteImageStore.referencedURLs(in: "![x][pic] http"), [])
    }

    func testLocalImageCacheDecodesOncePerFileVersionAndEvictsOldestBeyondLimit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("first.png")
        let second = root.appendingPathComponent("second.png")
        try png.write(to: first)
        try png.write(to: second)
        let cache = LocalImageCache()

        for _ in 0..<10 { XCTAssertNotNil(cache.image(at: first)) }
        XCTAssertEqual(cache.decodeCount, 1)
        XCTAssertNil(cache.image(at: root.appendingPathComponent("missing.png")))

        let larger = try XCTUnwrap(NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }.tiffRepresentation)
        try larger.write(to: first)
        XCTAssertNotNil(cache.image(at: first))
        XCTAssertEqual(cache.decodeCount, 2, "A changed file must be decoded again")

        let small = LocalImageCache(costLimit: 4)
        XCTAssertNotNil(small.image(at: first))
        XCTAssertNotNil(small.image(at: second))
        let key = try XCTUnwrap(LocalImageCache.key(for: first))
        XCTAssertNil(small.cachedImage(for: key), "The least recently used image is evicted")
    }

    func testPreviewDecodesLocalImagesInBackgroundAndRendersAfterRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try png.write(to: root.appendingPathComponent("photo.png"))
        let context = DocumentContext(fileURL: root.appendingPathComponent("README.md"))
        let store = LocalImageStore.shared
        let revision = store.revision
        let decodes = store.cache.decodeCount

        let pending = MarkdownRenderer.$decodesLocalImagesInBackground.withValue(true) {
            MarkdownRenderer.render("![写真](photo.png)", documentContext: context)
        }
        XCTAssertEqual(pending.string, "画像を読み込み中: 写真")

        let deadline = Date().addingTimeInterval(5)
        while store.revision == revision, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotEqual(store.revision, revision)
        let loaded = MarkdownRenderer.$decodesLocalImagesInBackground.withValue(true) {
            MarkdownRenderer.render("![写真](photo.png)", documentContext: context)
        }
        let location = (loaded.string as NSString).range(of: "\u{FFFC}").location
        XCTAssertNotEqual(location, NSNotFound)
        let attachment = try XCTUnwrap(loaded.attribute(.attachment, at: location,
                                                         effectiveRange: nil) as? NSTextAttachment)
        XCTAssertEqual(attachment.image?.accessibilityDescription, "写真")
        _ = MarkdownRenderer.render("![別名](photo.png)", documentContext: context)
        XCTAssertEqual(store.cache.decodeCount, decodes + 1)
    }

    func testEvictedPreviewImagesAreReloadedSynchronouslyInsteadOfLooping() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let urls = (0..<3).map { root.appendingPathComponent("photo\($0).png") }
        for url in urls { try png.write(to: url) }
        // 1枚分しか保持できない上限で、表示中の画像が互いを追い出す状況を作る。
        let store = LocalImageStore(cache: LocalImageCache(costLimit: 4))
        for url in urls { guard case .loading = store.lookup(url) else { return XCTFail("expected loading") } }
        let deadline = Date().addingTimeInterval(5)
        while store.hasPendingDecodes, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(20))
        let revision = store.revision
        let decodes = store.cache.decodeCount
        for _ in 0..<3 {
            for url in urls {
                guard case .image = store.lookup(url) else { return XCTFail("evicted image must render") }
            }
        }
        XCTAssertFalse(store.hasPendingDecodes)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(store.revision, revision, "Re-reading evicted images must not trigger another render pass")
        XCTAssertGreaterThan(store.cache.decodeCount, decodes)
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
