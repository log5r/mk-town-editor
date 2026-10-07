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

        let small = LocalImageCache(costLimit: 4, protectionInterval: 0)
        XCTAssertNotNil(small.image(at: first))
        XCTAssertNotNil(small.image(at: second))
        let key = try XCTUnwrap(LocalImageCache.key(for: first))
        XCTAssertFalse(small.contains(key), "The least recently used image is evicted")

        // 直近に使った画像は上限を超えても追い出さず、しばらく使われなくなってから追い出す。
        let clock = TestClock()
        let protected = LocalImageCache(costLimit: 4, protectionInterval: 5, now: { clock.now })
        XCTAssertNotNil(protected.image(at: first))
        XCTAssertNotNil(protected.image(at: second))
        XCTAssertTrue(protected.contains(key), "An image used moments ago is not evicted")
        clock.advance(by: 10)
        let third = root.appendingPathComponent("third.png")
        try png.write(to: third)
        XCTAssertNotNil(protected.image(at: third))
        XCTAssertFalse(protected.contains(key), "Images unused beyond the protection interval are evicted")
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
        let requester = LocalImageRequester()

        let pending = MarkdownRenderer.$localImageRequester.withValue(requester) {
            MarkdownRenderer.render("![写真](photo.png)", documentContext: context)
        }
        XCTAssertEqual(pending.string, "画像を読み込み中: 写真")

        let deadline = Date().addingTimeInterval(5)
        while store.revision == revision, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotEqual(store.revision, revision)
        let loaded = MarkdownRenderer.$localImageRequester.withValue(requester) {
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

    func testImagesBeyondTheLimitStayCachedWhileInUseWithoutMainThreadDecoding() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let urls = (0..<12).map { root.appendingPathComponent("photo\($0).png") }
        for url in urls { try png.write(to: url) }
        // 1枚分の上限で、1回の描画が上限を超える画像を使う状況を作る。
        let store = LocalImageStore(cache: LocalImageCache(costLimit: 4))
        for url in urls { guard case .loading = store.lookup(url) else { return XCTFail("expected loading") } }
        let deadline = Date().addingTimeInterval(5)
        while store.hasPendingDecodes, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(20))
        let revision = store.revision
        let decodes = store.cache.decodeCount
        XCTAssertEqual(decodes, urls.count)
        for _ in 0..<3 {
            for url in urls {
                guard case .image = store.lookup(url) else { return XCTFail("images in use must stay cached") }
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(store.cache.decodeCount, decodes, "No image is decoded again on the render path")
        XCTAssertEqual(store.revision, revision)
        let maximumRunning = await ImageDecodeLimiter.local.maximumRunning
        XCTAssertLessThanOrEqual(maximumRunning, 4, "Local decodes are bounded")
    }

    func testReloadedImagesPublishSoPlaceholdersAreReplaced() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("photo.png")
        try png.write(to: image)
        let clock = TestClock()
        let store = LocalImageStore(cache: LocalImageCache(costLimit: 4, protectionInterval: 5,
                                                           now: { clock.now }))
        _ = store.lookup(image)
        let deadline = Date().addingTimeInterval(5)
        while store.hasPendingDecodes, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(20))
        // 長く使われず追い出された画像も、読み直しが終われば再描画を通知して表示を置き換える。
        clock.advance(by: 10)
        let other = root.appendingPathComponent("other.png")
        try png.write(to: other)
        _ = store.cache.image(at: other)
        XCTAssertFalse(store.cache.contains(try XCTUnwrap(LocalImageCache.key(for: image))))
        let revision = store.revision
        guard case .loading = store.lookup(image) else { return XCTFail("the evicted image reloads in background") }
        while store.hasPendingDecodes, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<50 where store.revision == revision { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotEqual(store.revision, revision)
        guard case .image = store.lookup(image) else { return XCTFail("the reloaded image is displayed") }
    }

    func testStaleDecodeFinishingLastDoesNotEvictTheNewerVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("photo.png")
        try png.write(to: url)
        let path = url.standardizedFileURL.path
        let old = LocalImageCache.Key(path: path, modified: Date(timeIntervalSince1970: 100), size: 1)
        let new = LocalImageCache.Key(path: path, modified: Date(timeIntervalSince1970: 200), size: 2)

        let image = NSImage(size: NSSize(width: 1, height: 1))

        // 古い版のデコードを先に始め、後から始めた新しい版のデコードが先に終わる。
        let outOfOrder = LocalImageCache()
        let oldGeneration = outOfOrder.reserveGeneration()
        let newGeneration = outOfOrder.reserveGeneration()
        outOfOrder.insert(image, for: new, generation: newGeneration)
        outOfOrder.insert(image, for: old, generation: oldGeneration)
        XCTAssertTrue(outOfOrder.contains(new), "A late stale decode must not remove the newer version")
        XCTAssertFalse(outOfOrder.contains(old))

        // 古い日付のファイルに戻した場合も、後から始めたデコードの結果を新しい版として保持する。
        let restored = LocalImageCache()
        restored.insert(image, for: new, generation: restored.reserveGeneration())
        restored.insert(image, for: old, generation: restored.reserveGeneration())
        XCTAssertTrue(restored.contains(old), "An older-dated file restored later is the current version")
        XCTAssertFalse(restored.contains(new))

        // 実際のデコードでも、古い日付に戻したファイルはキャッシュされる。
        let past = Date(timeIntervalSinceNow: -86_400)
        let cache = LocalImageCache()
        XCTAssertNotNil(cache.image(at: url))
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
        let restoredKey = try XCTUnwrap(LocalImageCache.key(for: url))
        XCTAssertNotNil(cache.image(at: url))
        XCTAssertTrue(cache.contains(restoredKey))
    }

    func testClosingThePreviewCancelsDecodesOnlyItWasWaitingFor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let urls = (0..<3).map { root.appendingPathComponent("photo\($0).png") }
        for url in urls { try png.write(to: url) }
        let limiter = ImageDecodeLimiter(limit: 1)
        let store = LocalImageStore(cache: LocalImageCache(), limiter: limiter)
        let closing = LocalImageRequester()
        let staying = LocalImageRequester()
        // 枠を先に埋め、要求を順番待ちにする。
        await limiter.acquire()
        for url in urls { _ = store.lookup(url, requester: closing) }
        _ = store.lookup(urls[2], requester: staying)
        store.cancelRequests(from: closing)
        await limiter.release()
        let deadline = Date().addingTimeInterval(5)
        while store.hasPendingDecodes, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.cache.decodeCount, 1, "Only the image another preview still waits for is decoded")
        XCTAssertTrue(store.cache.contains(try XCTUnwrap(LocalImageCache.key(for: urls[2]))))
        XCTAssertFalse(store.cache.contains(try XCTUnwrap(LocalImageCache.key(for: urls[0]))))
    }

    func testReferencedPathsMatchTheImagesTheRendererRequests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = root.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        for name in ["plain.png", "with space.png", "図.png", "ref.png", "titled.png", "sized.png"] {
            try png.write(to: assets.appendingPathComponent(name))
        }
        let markdown = """
        ![a](assets/plain.png) ![b](assets/with%20space.png) ![c](<assets/with space.png>)
        ![d](assets/%E5%9B%B3.png) ![e][ref] ![f](assets/titled.png "title")
        ![g](assets/sized.png){width=120} ![h](https://example.com/remote.png)
        `![code](assets/code.png)`

        [ref]: assets/ref.png
        """
        let context = DocumentContext(fileURL: root.appendingPathComponent("doc.md"))
        let snapshot = DocumentSnapshot(source: markdown)
        let expected = LocalImageStore.localImagePaths(destinations: snapshot.imageDestinations, context: context)
        let requester = LocalImageRequester()
        // 共有の同時実行枠を埋め、描画が要求したデコードを待機させたまま調べる。
        for _ in 0..<4 { await ImageDecodeLimiter.local.acquire() }
        _ = MarkdownRenderer.$localImageRequester.withValue(requester) {
            MarkdownRenderer.render(snapshot.analysis, documentContext: context)
        }
        let requested = LocalImageStore.shared.pendingPaths(for: requester)
        LocalImageStore.shared.cancelRequests(from: requester)
        for _ in 0..<4 { await ImageDecodeLimiter.local.release() }
        XCTAssertEqual(expected.count, 6)
        // 描画が実際に要求した画像と、取り下げの判定に使う参照先が一致する。
        XCTAssertEqual(requested, expected)
        XCTAssertFalse(expected.contains { $0.hasSuffix("code.png") })
    }

    func testChangedContentWithdrawsOnlyImagesNoLongerReferenced() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let urls = (0..<3).map { root.appendingPathComponent("photo\($0).png") }
        for url in urls { try png.write(to: url) }
        let limiter = ImageDecodeLimiter(limit: 1)
        let store = LocalImageStore(cache: LocalImageCache(), limiter: limiter)
        let requester = LocalImageRequester()
        await limiter.acquire()
        for url in urls { _ = store.lookup(url, requester: requester) }
        // 編集で photo0 と photo1 の参照が消え、photo2 だけが残った。
        store.reconcileRequests(from: requester, keepingPaths: [urls[2].standardizedFileURL.path])
        XCTAssertEqual(store.pendingPaths(for: requester), [urls[2].standardizedFileURL.path])
        await limiter.release()
        let deadline = Date().addingTimeInterval(5)
        while store.hasPendingDecodes, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.cache.decodeCount, 1)
        XCTAssertTrue(store.cache.contains(try XCTUnwrap(LocalImageCache.key(for: urls[2]))))
    }

    func testGenerationsFollowLookupOrderEvenIfWorkersStartOutOfOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("photo.png")
        try png.write(to: url)
        let path = url.standardizedFileURL.path
        let old = LocalImageCache.Key(path: path, modified: Date(timeIntervalSince1970: 100), size: 1)
        let new = LocalImageCache.Key(path: path, modified: Date(timeIntervalSince1970: 200), size: 2)
        let cache = LocalImageCache()
        // 問い合わせの順に番号を確保し、処理は新しい版から実行される。
        let oldGeneration = cache.reserveGeneration()
        let newGeneration = cache.reserveGeneration()
        cache.decode(key: new, fileURL: url, generation: newGeneration)
        cache.decode(key: old, fileURL: url, generation: oldGeneration)
        XCTAssertTrue(cache.contains(new))
        XCTAssertFalse(cache.contains(old))
    }

    func testRemoteImageDecodesAreBoundedAndCancelledLoadsStoreNothing() async throws {
        let limiter = ImageDecodeLimiter(limit: 4)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await limiter.acquire()
                    try? await Task.sleep(for: .milliseconds(5))
                    await limiter.release()
                }
            }
        }
        let maximumRunning = await limiter.maximumRunning
        let running = await limiter.running
        XCTAssertLessThanOrEqual(maximumRunning, 4)
        XCTAssertEqual(running, 0)

        let imageData = png
        let store = RemoteImageStore(fetch: { _ in
            try await Task.sleep(for: .milliseconds(200))
            return imageData
        })
        store.setEnabled(true)
        let url = URL(string: "https://example.com/cancelled.png")!
        let load = Task { await store.load(url) }
        try await Task.sleep(for: .milliseconds(20))
        load.cancel()
        await load.value
        XCTAssertNil(store.image(for: url))
        XCTAssertFalse(store.hasFailed(url), "A cancelled load is not a failure")
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

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000_000)

    var now: Date { lock.withLock { value } }

    func advance(by seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}
