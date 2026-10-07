import AppKit
import XCTest
@testable import MKTownEditor

@MainActor
final class MarkdownCitationsTests: XCTestCase {
    func testBibTeXParserKeepsNestedFieldValuesAndOrder() {
        let source = """
        @comment{Do not parse @book{fake, title={Hidden}}}
        @string{abbrev={A Journal}}
        @article{smith2020,
          author = {Smith, Jane and Doe, John},
          title = {A {Nested} Study},
          year = 2020,
          journal = "Example Journal"
        }
        @book{book1, author={Yamada, Taro}, title={Second}, year={2022}}
        """
        let entries = BibTeXParser.parse(source)
        XCTAssertEqual(entries.map(\.key), ["smith2020", "book1"])
        XCTAssertEqual(entries[0].fields["title"], "A Nested Study")
        XCTAssertEqual(entries[0].fields["journal"], "Example Journal")
        XCTAssertTrue(entries[0].bibliographyText.contains("2020"))
    }

    func testCitationNumbersAreSharedByPreviewHTMLAndConverter() throws {
        let (directory, document) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let markdown = "Cite [@book1] then [@smith2020].\n\n`[@book1]` and [@missing]"
        let context = DocumentContext(fileURL: document)
        let preview = MarkdownRenderer.render(markdown, documentContext: context).string
        XCTAssertTrue(preview.contains("Cite [2] then [1]."))
        XCTAssertTrue(preview.contains("参考文献"))
        XCTAssertTrue(preview.contains("1. Smith"))
        XCTAssertTrue(preview.contains("`[@book1]`") || preview.contains("[@book1]"))
        XCTAssertTrue(preview.contains("[@missing]"))

        let html = MarkdownHTMLExporter.render(markdown, documentURL: document)
        XCTAssertTrue(html.contains("Cite [2] then [1]."))
        XCTAssertTrue(html.contains("class=\"bibliography\""))
        XCTAssertTrue(html.contains("<li>Smith"))
        let info = MarkdownPDFExporter.printInfo(destination: directory.appendingPathComponent("out.pdf"))
        let printView = try MarkdownPDFExporter.printableView(markdown, documentURL: document,
                                                              printInfo: info)
        XCTAssertTrue(printView.string.contains("Cite [2] then [1]."))
        XCTAssertTrue(printView.string.contains("参考文献"))

        let catalog = try XCTUnwrap(MarkdownCitationCatalog.load(documentURL: document))
        let converted = catalog.materialize(markdown)
        XCTAssertTrue(converted.contains("Cite [2] then [1]."))
        XCTAssertTrue(converted.contains("## 参考文献"))
        XCTAssertTrue(converted.contains("`[@book1]`"))
    }

    func testCitationInCodeFenceDoesNotCreateBibliography() throws {
        let (directory, document) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let markdown = "```markdown\n[@book1]\n```"
        let catalog = try XCTUnwrap(MarkdownCitationCatalog.load(documentURL: document))
        XCTAssertEqual(catalog.materialize(markdown), markdown)
        XCTAssertFalse(MarkdownHTMLExporter.render(markdown, documentURL: document)
            .contains("class=\"bibliography\""))
    }

    func testBasicDialectLeavesCitationsAndMathLiteralInHTML() throws {
        let (directory, document) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let html = MarkdownHTMLExporter.render("[@book1] and $x^2$", documentURL: document,
                                               dialect: .basic)
        XCTAssertTrue(html.contains("[@book1]"))
        XCTAssertTrue(html.contains("$x^2$"))
        XCTAssertFalse(html.contains("class=\"bibliography\""))
        XCTAssertFalse(html.contains("data:image/png;base64,"))
    }

    func testBibliographyFingerprintChangesAfterExternalEdit() throws {
        let (directory, document) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = MarkdownCitationCatalog.fingerprint(documentURL: document)
        let bib = directory.appendingPathComponent("references.bib")
        try "@book{new, title={Another}, year={2024}}".write(to: bib,
            atomically: true, encoding: .utf8)
        XCTAssertNotEqual(MarkdownCitationCatalog.fingerprint(documentURL: document), previous)
        XCTAssertEqual(MarkdownCitationCatalog.load(documentURL: document)?.entries.map(\.key), ["new"])
    }

    func testCatalogIsParsedOnceUntilTheBibliographyChanges() throws {
        let (directory, document) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = MarkdownCitationCatalogCache.shared
        let before = cache.parseCount
        for _ in 0..<20 {
            XCTAssertEqual(MarkdownCitationCatalog.load(documentURL: document)?.entries.count, 2)
        }
        XCTAssertEqual(cache.parseCount, before + 1)

        try "@book{new, title={Another}, year={2024}}".write(
            to: directory.appendingPathComponent("references.bib"), atomically: true, encoding: .utf8)
        XCTAssertEqual(MarkdownCitationCatalog.load(documentURL: document)?.entries.map(\.key), ["new"])
        XCTAssertEqual(cache.parseCount, before + 2)
    }

    func testSameSizeReplacementWithPreservedDateIsReloaded() throws {
        let (directory, document) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bib = directory.appendingPathComponent("references.bib")
        let first = "@book{aaaa, title={First}}"
        let second = "@book{bbbb, title={Other}}"
        XCTAssertEqual(first.utf8.count, second.utf8.count)
        try first.write(to: bib, atomically: true, encoding: .utf8)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: bib.path)
        XCTAssertEqual(MarkdownCitationCatalog.load(documentURL: document)?.entries.map(\.key), ["aaaa"])

        // 復元ツールのように、同じ大きさの別内容へ置き換えて更新日時を戻す。
        try second.write(to: bib, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: bib.path)
        XCTAssertEqual(MarkdownCitationCatalog.load(documentURL: document)?.entries.map(\.key), ["bbbb"])

        // その場で上書きした場合も同様に読み直す。
        let handle = try FileHandle(forWritingTo: bib)
        try handle.write(contentsOf: Data(first.utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: bib.path)
        XCTAssertEqual(MarkdownCitationCatalog.load(documentURL: document)?.entries.map(\.key), ["aaaa"])
    }

    func testRenderingResolvesTheCatalogOnceAndPrefersTheProvidedCatalog() throws {
        let (directory, document) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let markdown = (0..<200).map { "段落 \($0) [@book1] と [@smith2020]" }.joined(separator: "\n\n")
        let cache = MarkdownCitationCatalogCache.shared
        _ = MarkdownCitationCatalog.load(documentURL: document)
        let parses = cache.parseCount

        let html = MarkdownHTMLExporter.render(markdown, documentURL: document)
        XCTAssertTrue(html.contains("段落 199 [2] と [1]"))
        let rendered = MarkdownRenderer.render(markdown, documentContext: DocumentContext(fileURL: document))
        XCTAssertTrue(rendered.string.contains("段落 199 [2] と [1]"))
        XCTAssertEqual(cache.parseCount, parses)

        let provided = try XCTUnwrap(MarkdownCitationCatalog.load(documentURL: document))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("references.bib"))
        var context = DocumentContext(fileURL: document)
        context.citationCatalog = provided
        let analysis = MarkdownAnalysis(markdown)
        let leaf = MarkdownRenderer.renderLeaf(analysis.blocks[0], in: analysis, documentContext: context)
        XCTAssertEqual(leaf.string.trimmingCharacters(in: .whitespacesAndNewlines), "段落 0 [2] と [1]")
        context.citationCatalog = .empty
        XCTAssertTrue(MarkdownRenderer.render(analysis, documentContext: context).string
            .contains("段落 0 [@book1]"))
    }

    func testAnalysisRecordsWhetherCitationSyntaxIsPresent() throws {
        XCTAssertTrue(MarkdownAnalysis("本文 [@a]").containsCitationSyntax)
        XCTAssertTrue(MarkdownAnalysis("本文[^1]\n\n[^1]: 注 [@a]").containsCitationSyntax)
        XCTAssertFalse(MarkdownAnalysis("```\n[@a]\n```").containsCitationSyntax)
        XCTAssertFalse(MarkdownAnalysis("本文 [@a]", dialect: .basic).containsCitationSyntax)
        let catalog = MarkdownCitationCatalog(entries: [BibTeXEntry(key: "a", fields: [:])])
        XCTAssertFalse(catalog.hasCitation(in: MarkdownAnalysis("引用なし")))
        XCTAssertTrue(catalog.hasCitation(in: MarkdownAnalysis("本文 [@a]")))
    }

    func testCitationsInsideTableCellsAreResolvedAndListed() throws {
        let (directory, document) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let markdown = "| 出典 | 年 |\n|---|---|\n| [@book1] | 2022 |"
        let analysis = MarkdownAnalysis(markdown)
        XCTAssertTrue(analysis.containsCitationSyntax, "Table blocks keep their text in cells, not content")
        let catalog = try XCTUnwrap(MarkdownCitationCatalog.load(documentURL: document))
        XCTAssertTrue(catalog.hasCitation(in: analysis))

        // プレビューは引用記法がある時だけ参考文献を読み込み、セルの描画に渡す。
        var context = DocumentContext(fileURL: document)
        context.citationCatalog = analysis.containsCitationSyntax ? catalog : .empty
        let cell = MarkdownRenderer.renderTableCell("[@book1]", in: analysis, documentContext: context)
        XCTAssertEqual(cell.string, "[2]")
        // 全文描画は表を素のテキストで出力する（変更前から同じ）が、参考文献の一覧は表の引用でも出す。
        let rendered = MarkdownRenderer.render(markdown, documentContext: DocumentContext(fileURL: document))
        XCTAssertTrue(rendered.string.contains("参考文献"))
        let html = MarkdownHTMLExporter.render(markdown, documentURL: document)
        XCTAssertFalse(html.contains("[@book1]"))
        XCTAssertTrue(html.contains("class=\"bibliography\""))
        XCTAssertFalse(MarkdownAnalysis("| a |\n|---|\n| b |").containsCitationSyntax)
    }

    func testFileMonitorReportsInPlaceAndAtomicBibliographyChanges() async throws {
        let (directory, document) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bib = directory.appendingPathComponent("references.bib")
        let counter = ChangeCounter()
        let consumer = Task {
            for await _ in MarkdownCitationFileMonitor.changes(documentURL: document) {
                await counter.increment()
            }
        }
        defer { consumer.cancel() }
        try await Task.sleep(for: .milliseconds(100))

        let handle = try FileHandle(forWritingTo: bib)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n@misc{later, title={Later}}".utf8))
        try handle.close()
        let afterAppend = try await counter.wait(above: 0)

        try "@book{replaced, title={Replaced}}".write(to: bib, atomically: true, encoding: .utf8)
        _ = try await counter.wait(above: afterAppend)
        XCTAssertEqual(MarkdownCitationCatalog.load(documentURL: document)?.entries.map(\.key), ["replaced"])

        // 置き換え後のファイルも監視が張り直されている。
        let afterReplace = await counter.value
        let replacedHandle = try FileHandle(forWritingTo: bib)
        try replacedHandle.seekToEnd()
        try replacedHandle.write(contentsOf: Data("\n".utf8))
        try replacedHandle.close()
        _ = try await counter.wait(above: afterReplace)
    }

    func testChangesDuringTheInitialLoadAreDeliveredOnceIterationStarts() async throws {
        let (directory, document) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bib = directory.appendingPathComponent("references.bib")
        // プレビューと同じく、監視を始めてから読み込み、その後で変更を受け取り始める。
        let changes = MarkdownCitationFileMonitor.changes(documentURL: document)
        XCTAssertEqual(MarkdownCitationCatalog.load(documentURL: document)?.entries.count, 2)
        try "@book{saved, title={Saved during load}}".write(to: bib, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(300))
        let received = Task { () -> Bool in
            for await _ in changes { return true }
            return false
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(5))
            received.cancel()
        }
        let delivered = await received.value
        timeout.cancel()
        XCTAssertTrue(delivered, "A save made while the catalog was loading must not be missed")
        XCTAssertEqual(MarkdownCitationCatalog.load(documentURL: document)?.entries.map(\.key), ["saved"])
    }

    private func fixture() throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bib = """
        @article{smith2020, author={Smith, Jane}, title={First}, year={2020}}
        @book{book1, author={Yamada, Taro}, title={Second}, year={2022}}
        """
        try bib.write(to: directory.appendingPathComponent("references.bib"),
                      atomically: true, encoding: .utf8)
        return (directory, directory.appendingPathComponent("notes.md"))
    }
}

private actor ChangeCounter {
    private(set) var value = 0

    func increment() { value += 1 }

    func wait(above previous: Int, timeout: Duration = .seconds(5)) async throws -> Int {
        let deadline = ContinuousClock.now + timeout
        while value <= previous {
            guard ContinuousClock.now < deadline else {
                XCTFail("No file change was reported")
                return value
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return value
    }
}
