import AppKit
import Foundation
import XCTest
@testable import MKTownEditor

final class WorkspaceDocumentEmbedTests: XCTestCase {
    @MainActor
    func testLoaderDiscoversUnsavedNestedDependenciesWithoutEncodingUnrelatedBuffers() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/embed-dependencies-\(UUID().uuidString)")
        let host = root.appendingPathComponent("host.md")
        let parent = root.appendingPathComponent("parent.md")
        let child = root.appendingPathComponent("child.md")
        let other = root.appendingPathComponent("other.md")
        let documents = [host, parent, child, other]
        let store = WorkspaceStore(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)))
        var encodes: [URL: Int] = [:]
        var parentText = "Parent\n![[child]]"
        for url in [parent, child, other] {
            store.registerOpenBuffer(id: UUID(), url: url, encodedData: {
                encodes[url, default: 0] += 1
                return Data((url == parent ? parentText : url.lastPathComponent).utf8)
            }, updateText: { _ in })
        }
        let reference = WorkspaceEmbedReference(target: "parent", section: nil)
        let loaded = try await WorkspaceEmbedLoader.load(reference, from: host, documents: documents,
            loadOpenBuffers: { try store.openBufferSnapshots(including: $0) })
        XCTAssertEqual(loaded.dependencies, [parent, child])
        XCTAssertTrue(loaded.expansion.text.contains("child.md"))
        XCTAssertTrue(loaded.expansion.issues.isEmpty)
        XCTAssertEqual(encodes[parent], 1)
        XCTAssertEqual(encodes[child], 1)
        XCTAssertNil(encodes[other])
        parentText = "Parent\n![[other]]"
        store.openBufferDidChange(for: parent)
        let changed = try await WorkspaceEmbedLoader.load(reference, from: host, documents: documents,
            index: loaded.index, dependencies: loaded.dependencies, cache: loaded.cache,
            previous: loaded.expansion, previousTarget: loaded.target,
            loadOpenBuffers: { try store.openBufferSnapshots(including: $0) })
        XCTAssertEqual(changed.dependencies, [parent, other])
        XCTAssertTrue(changed.expansion.text.contains("other.md"))
        XCTAssertFalse(changed.expansion.text.contains("child.md"))
    }

    @MainActor
    func testLoaderTracksUnreadableDependencyAndRevertsToDiskAfterBufferCloses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = root.appendingPathComponent("host.md"), target = root.appendingPathComponent("note.md")
        let store = WorkspaceStore(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)))
        let id = UUID(), reference = WorkspaceEmbedReference(target: "note", section: nil)
        let missing = try await WorkspaceEmbedLoader.load(reference, from: host, documents: [host, target],
            loadOpenBuffers: { try store.openBufferSnapshots(including: $0) })
        XCTAssertEqual(missing.dependencies, [target])
        XCTAssertFalse(missing.expansion.issues.isEmpty)
        try Data("disk".utf8).write(to: target)
        store.registerOpenBuffer(id: id, url: target, encodedData: { Data("unsaved".utf8) }, updateText: { _ in })
        let open = try await WorkspaceEmbedLoader.load(reference, from: host, documents: [host, target],
            dependencies: missing.dependencies, loadOpenBuffers: { try store.openBufferSnapshots(including: $0) })
        XCTAssertEqual(open.expansion.text, "unsaved")
        store.unregisterOpenBuffer(id: id, url: target)
        let closed = try await WorkspaceEmbedLoader.load(reference, from: host, documents: [host, target],
            dependencies: open.dependencies, cache: open.cache,
            loadOpenBuffers: { try store.openBufferSnapshots(including: $0) })
        XCTAssertEqual(closed.expansion.text, "disk")
    }

    @MainActor
    func testCancelledDependencyLoadDoesNotEncodeBuffers() async throws {
        let document = URL(fileURLWithPath: "/private/tmp/cancelled-embed.md")
        var encodes = 0
        let task = Task {
            try await WorkspaceEmbedLoader.load(WorkspaceEmbedReference(target: "cancelled-embed", section: nil),
                from: URL(fileURLWithPath: "/private/tmp/host.md"), documents: [document],
                index: WorkspaceDocumentIndex(documents: [document]), dependencies: [document],
                loadOpenBuffers: { _ in encodes += 1; return [document: Data("body".utf8)] })
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertEqual(encodes, 0)
    }

    func testEmbedCacheAvoidsRepeatedReadsAndReflectsDiskAndOpenChanges() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: url) }
        try "first".write(to: url, atomically: true, encoding: .utf8)
        var cache = WorkspaceEmbedFileCache()
        for _ in 0..<10 { XCTAssertEqual(cache.load(url, openBuffers: [:]), "first") }
        XCTAssertEqual(cache.readCount, 1)
        XCTAssertEqual(cache.load(url, openBuffers: [url: Data("unsaved".utf8)]), "unsaved")
        try "second version".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(cache.load(url, openBuffers: [:]), "second version")
        XCTAssertEqual(cache.readCount, 2)
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(cache.load(url, openBuffers: [:]))
    }

    func testEmbedCacheRereadsSameSizeSameDateEditsWithAndWithoutGenerationIdentifiers() throws {
        let pinnedDate = Date(timeIntervalSince1970: 1_700_000_000)
        func overwritePreservingMetadata(_ url: URL, with text: String) throws {
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
            try FileManager.default.setAttributes([.modificationDate: pinnedDate], ofItemAtPath: url.path)
        }
        let withoutGeneration: WorkspaceFileMetadata.Reader = {
            let metadata = try WorkspaceFileMetadata(url: $0)
            return WorkspaceFileMetadata(modified: metadata.modified, size: metadata.size, generation: nil)
        }
        for (reader, rereadsUnchangedFiles) in [(WorkspaceFileMetadata.read, false), (withoutGeneration, true)] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
            defer { try? FileManager.default.removeItem(at: url) }
            try "".write(to: url, atomically: true, encoding: .utf8)
            try overwritePreservingMetadata(url, with: "first")
            var cache = WorkspaceEmbedFileCache(readMetadata: reader)
            XCTAssertEqual(cache.load(url, openBuffers: [:]), "first")
            XCTAssertEqual(cache.load(url, openBuffers: [:]), "first")
            XCTAssertEqual(cache.readCount, rereadsUnchangedFiles ? 2 : 1)
            try overwritePreservingMetadata(url, with: "FIRST")
            XCTAssertEqual(try reader(url).size, 5)
            XCTAssertEqual(try reader(url).modified, pinnedDate)
            XCTAssertEqual(cache.load(url, openBuffers: [:]), "FIRST")
            XCTAssertEqual(cache.readCount, rereadsUnchangedFiles ? 3 : 2)
        }
    }

    private let root = URL(fileURLWithPath: "/tmp/mktown-embed-tests")

    func testStandaloneSyntaxAndSectionExtraction() throws {
        let block = try XCTUnwrap(MarkdownAnalysis("![[notes#topic]]").blocks.first)
        XCTAssertEqual(block.kind, .paragraph)
        XCTAssertNotNil(WorkspaceDocumentEmbed.reference(in: block.content))
        XCTAssertNil(WorkspaceDocumentEmbed.reference(in: "before ![[notes]]"))
        XCTAssertNil(WorkspaceDocumentEmbed.reference(in: "![[notes]] after"))
        let reference = try XCTUnwrap(WorkspaceDocumentEmbed.reference(in: "![[notes#topic]]"))
        let index = root.appendingPathComponent("index.md")
        let notes = root.appendingPathComponent("notes.md")
        let expansion = WorkspaceDocumentEmbed.expand(reference, from: index,
            documents: [index, notes]) { _ in
                "# Intro\nfirst\n## Topic\nbody\n### Child\nchild\n## Next\nother"
            }
        XCTAssertTrue(expansion.issues.isEmpty)
        XCTAssertEqual(expansion.text, "## Topic\nbody\n### Child\nchild\n")
    }

    func testNestedEmbedTracksCyclesAndDepth() throws {
        let a = root.appendingPathComponent("a.md")
        let b = root.appendingPathComponent("b.md")
        let c = root.appendingPathComponent("c.md")
        let docs = [a, b, c]
        let content = [b: "B\n![[c]]", c: "C\n![[a]]"]
        let reference = try XCTUnwrap(WorkspaceDocumentEmbed.reference(in: "![[b]]"))
        let expansion = WorkspaceDocumentEmbed.expand(reference, from: a,
            documents: docs) { content[$0] }
        XCTAssertTrue(expansion.text.contains("B"))
        XCTAssertTrue(expansion.text.contains("C"))
        XCTAssertEqual(expansion.issues.count, 1)
        XCTAssertTrue(expansion.issues[0].contains("循環"))

        let chain = (0...5).map { root.appendingPathComponent("\($0).md") }
        let limited = WorkspaceDocumentEmbed.expand(
            try XCTUnwrap(WorkspaceDocumentEmbed.reference(in: "![[1]]")),
            from: chain[0], documents: chain) { url in
                guard let number = Int(url.deletingPathExtension().lastPathComponent) else { return nil }
                return "![[\(number + 1)]]"
            }
        XCTAssertTrue(limited.issues.contains { $0.contains("展開深度") })
    }

    func testMissingDocumentAndSectionProduceIssues() throws {
        let index = root.appendingPathComponent("index.md")
        let notes = root.appendingPathComponent("notes.md")
        let missing = WorkspaceDocumentEmbed.expand(
            try XCTUnwrap(WorkspaceDocumentEmbed.reference(in: "![[missing]]")),
            from: index, documents: [index, notes]) { _ in "" }
        XCTAssertEqual(missing.issues.count, 1)
        let section = WorkspaceDocumentEmbed.expand(
            try XCTUnwrap(WorkspaceDocumentEmbed.reference(in: "![[notes#absent]]")),
            from: index, documents: [index, notes]) { _ in "# Present" }
        XCTAssertEqual(section.issues.count, 1)
        XCTAssertTrue(section.issues[0].contains("見出し"))
    }

    func testCodeBlockDoesNotExpandNestedSyntax() throws {
        let index = root.appendingPathComponent("index.md")
        let notes = root.appendingPathComponent("notes.md")
        let nested = root.appendingPathComponent("nested.md")
        let reference = try XCTUnwrap(WorkspaceDocumentEmbed.reference(in: "![[notes]]"))
        let expansion = WorkspaceDocumentEmbed.expand(reference, from: index,
            documents: [index, notes, nested]) { url in
                url == notes ? "```\n![[nested]]\n```" : "expanded"
            }
        XCTAssertEqual(expansion.text, "```\n![[nested]]\n```")
    }

    func testReloadUsesUpdatedDependencyText() throws {
        let index = root.appendingPathComponent("index.md")
        let notes = root.appendingPathComponent("notes.md")
        let reference = try XCTUnwrap(WorkspaceDocumentEmbed.reference(in: "![[notes]]"))
        var current = "first"
        func render() -> WorkspaceEmbedExpansion {
            WorkspaceDocumentEmbed.expand(reference, from: index,
                documents: [index, notes]) { _ in current }
        }
        XCTAssertEqual(render().text, "first")
        current = "second"
        XCTAssertEqual(render().text, "second")
    }

    func testNestedRelativeLinkUsesContainingDocumentLocation() throws {
        let index = root.appendingPathComponent("index.md")
        let parent = root.appendingPathComponent("parent.md")
        let child = root.appendingPathComponent("sub/child.md")
        let reference = try XCTUnwrap(WorkspaceDocumentEmbed.reference(in: "![[parent]]"))
        let expanded = WorkspaceDocumentEmbed.expand(reference, from: index,
            documents: [index, parent, child]) { url in
                url == parent ? "![[sub/child]]" : "[asset](image.png)"
            }
        XCTAssertEqual(expanded.text, "[asset](sub/image.png)")
    }

    func testRenameUpdatesEmbedTargetAndKeepsSection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let old = root.appendingPathComponent("old.md")
        let new = root.appendingPathComponent("new.md")
        let referring = root.appendingPathComponent("index.md")
        try "# Section".write(to: old, atomically: true, encoding: .utf8)
        try "![[old#section]]\n```\n![[old]]\n```".write(to: referring,
            atomically: true, encoding: .utf8)
        let plan = try WorkspaceFileOperations.planMove(source: old,
            destination: new, root: root)
        XCTAssertEqual(plan.changedLinks, 1)
        try plan.apply()
        XCTAssertEqual(try String(contentsOf: referring, encoding: .utf8),
            "![[new#section]]\n```\n![[old]]\n```")
    }

    /// 不具合: 埋め込み文書のコードブロックは文字ごとの背景のままで、行の長さに沿った白い帯として表示されていた。
    @MainActor
    func testEmbeddedCodeBlockIsFramedWithoutPerCharacterBackground() throws {
        let analysis = MarkdownAnalysis("Use `inline` here.\n\n```swift\nlet x = 1\n\nprint(x)\n```\n\n> ```\n> quoted\n> ```",
                                        dialect: .extended)
        let segments = WorkspaceEmbedSegment.render(analysis, documentContext: DocumentContext(fileURL: nil))
        let codeBlocks = segments.compactMap { segment -> (AttributedString, Int)? in
            guard case let .codeBlock(block, code, quoteDepth) = segment else { return nil }
            // コピーボタンが写す元のブロックを持つ。
            XCTAssertEqual(block.kind, .codeBlock)
            XCTAssertEqual(block.content, String(code.characters))
            return (code, quoteDepth)
        }
        XCTAssertEqual(codeBlocks.map { String($0.0.characters) }, ["let x = 1\n\nprint(x)", "quoted"])
        XCTAssertEqual(codeBlocks.map(\.1), [0, 1])
        for (code, _) in codeBlocks {
            let rendered = try NSAttributedString(code, including: \.appKit)
            var backgrounds = 0
            rendered.enumerateAttribute(.backgroundColor,
                                        in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
                if value != nil { backgrounds += 1 }
            }
            XCTAssertEqual(backgrounds, 0)
        }

        guard case let .text(text) = segments.first else { return XCTFail("\(segments)") }
        let inline = try NSAttributedString(text, including: \.appKit)
        let location = (inline.string as NSString).range(of: "inline").location
        XCTAssertNotNil(inline.attribute(.backgroundColor, at: location, effectiveRange: nil))
    }
}
