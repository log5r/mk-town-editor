import XCTest
@testable import MKTownEditor

/// コードブロックの字句を版ごとに1度だけ求め、エディタ・プレビュー・書き出しで共有することの検証。
@MainActor
final class CodeSyntaxSharingTests: XCTestCase {
    private let jsSample = "const re = /[//]/g; // note\nlet n = 42;"

    private func codeBlocks(_ snapshot: DocumentSnapshot) -> [MarkdownBlock] {
        snapshot.analysis.blocks.filter { $0.kind == .codeBlock }
    }

    private func codeTokenTexts(_ snapshot: DocumentSnapshot) -> [(CodeSyntaxToken, String)] {
        let text = snapshot.source as NSString
        return snapshot.syntaxSpans.compactMap { span in
            guard case .codeToken(let kind) = span.role else { return nil }
            XCTAssertLessThanOrEqual(NSMaxRange(span.range), text.length)
            return (kind, text.substring(with: span.range))
        }
    }

    // MARK: スナップショットとエディタ

    func testSnapshotHoldsTokensForEveryHighlightableBlockAndSpansMapToSource() {
        let source = """
        日本語の前置き 😀 です。

        ```js
        \(jsSample)
        ```

        > ```ruby
        > x = 1 # note
        > ```

        - 項目

          ```js
          let a = /[//]/g;
          ```
        """
        let snapshot = DocumentSnapshot(source: source)
        let blocks = codeBlocks(snapshot)
        XCTAssertEqual(blocks.count, 3)
        for block in blocks {
            XCTAssertNotNil(snapshot.codeSyntaxTokens[block.id], "\(block.codeLanguage ?? "nil"): \(block.content)")
        }
        let texts = codeTokenTexts(snapshot)
        XCTAssertTrue(texts.contains { $0.0 == .string && $0.1 == "/[//]/g" })
        XCTAssertTrue(texts.contains { $0.0 == .comment && $0.1 == "// note" })
        XCTAssertTrue(texts.contains { $0.0 == .comment && $0.1 == "# note" })
        XCTAssertTrue(texts.contains { $0.0 == .number && $0.1 == "42" })
        XCTAssertEqual(texts.filter { $0.1 == "/[//]/g" }.count, 2, "リスト内のブロックでも原文の位置に対応する")
    }

    func testUnsupportedLanguageHasNoEntryAndEmptyResultStillHasOne() {
        let snapshot = DocumentSnapshot(source: "```text\nabc\n```\n\n```js\n\n```\n\n```js\nx\n```\n")
        let blocks = codeBlocks(snapshot)
        XCTAssertNil(snapshot.codeSyntaxTokens[blocks[0].id])
        XCTAssertEqual(snapshot.codeSyntaxTokens[blocks[2].id], [])
    }

    func testCRLFDocumentKeepsRangesInsideSourceWithoutCarriageReturns() {
        let source = "# 見出し\r\n\r\n```js\r\nconst re = /[//]/g; // note\r\nlet n = 1;\r\n```\r\n"
        let snapshot = DocumentSnapshot(source: source)
        let texts = codeTokenTexts(snapshot)
        XCTAssertFalse(texts.isEmpty)
        for (_, text) in texts { XCTAssertFalse(text.contains("\r"), text) }
        XCTAssertTrue(texts.contains { $0.0 == .comment && $0.1 == "// note" })
        XCTAssertTrue(texts.contains { $0.0 == .number && $0.1 == "1" })
    }

    func testUnclosedStringOnLastLineKeepsEarlierTokens() {
        let snapshot = DocumentSnapshot(source: "```js\nconst a = 1;\nconst s = \"abc\n```\n")
        let texts = codeTokenTexts(snapshot)
        XCTAssertTrue(texts.contains { $0.0 == .keyword && $0.1 == "const" })
        XCTAssertTrue(texts.contains { $0.0 == .number && $0.1 == "1" })
    }

    func testExplicitTokensDriveEditorSpans() {
        let source = "```js\nlet a = 1;\n```\n"
        let analysis = MarkdownAnalysis(source)
        let block = analysis.blocks.first { $0.kind == .codeBlock }!
        let injected = [CodeSyntaxTokenRange(range: NSRange(location: 0, length: 3), token: .type)]
        let spans = MarkdownSyntaxHighlighter.spans(in: source, analysis: analysis,
                                                    codeSyntaxTokens: [block.id: injected])
        let kinds = spans.compactMap { span -> CodeSyntaxToken? in
            if case .codeToken(let kind) = span.role { return kind } else { return nil }
        }
        XCTAssertEqual(kinds, [.type], "渡した字句だけが使われ、再解析されない")
    }

    // MARK: プレビュー

    func testPreviewRenderingWithSnapshotTokensDoesNotAnalyzeAgain() {
        let big = (0..<400).map { "const value\($0) = /[//]/g; // line \($0)" }.joined(separator: "\n")
        let snapshot = DocumentSnapshot(source: "```js\n\(big)\n```\n")
        let cache = CodeSyntaxAnalyzer.sharedCache
        var context = DocumentContext(fileURL: nil)
        context.codeSyntaxTokens = snapshot.codeSyntaxTokens
        cache.removeAll()
        cache.resetCounters()
        let withTokens = MarkdownRenderer.render(snapshot.analysis, documentContext: context)
        XCTAssertEqual(cache.misses, 0)
        XCTAssertEqual(cache.hits, 0)
        let renderCache = PreviewRenderCache()
        let block = codeBlocks(snapshot)[0]
        _ = renderCache.render(block, in: snapshot.analysis, context: context, zoom: 1)
        XCTAssertEqual(cache.misses, 0)

        // トークンなしでも結果は同じ（キャッシュに載っているので再解析もしない）。
        let without = MarkdownRenderer.render(snapshot.analysis, documentContext: DocumentContext(fileURL: nil))
        XCTAssertTrue(withTokens.isEqual(to: without))
    }

    func testDocumentContextEqualityIgnoresTokens() {
        var a = DocumentContext(fileURL: nil)
        let b = a
        a.codeSyntaxTokens = [1: []]
        XCTAssertEqual(a, b)
    }

    func testHighlighterColorsExactlyTheGivenRanges() {
        let source = "let a = 1"
        let tokens = [CodeSyntaxTokenRange(range: NSRange(location: 4, length: 1), token: .variable),
                      CodeSyntaxTokenRange(range: NSRange(location: 100, length: 5), token: .keyword)]
        let result = CodeSyntaxHighlighter.render(source, language: "js", tokens: tokens)
        var colored: [NSRange] = []
        result.enumerateAttribute(.codeSyntaxToken, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            if value != nil { colored.append(range) }
        }
        XCTAssertEqual(colored, [NSRange(location: 4, length: 1)], "範囲外の字句は無視する")
    }

    func testClassificationAgreesAcrossEditorPreviewAndHTML() {
        let source = "```js\n\(jsSample)\n```\n"
        let snapshot = DocumentSnapshot(source: source)
        let block = codeBlocks(snapshot)[0]
        let expected = snapshot.codeSyntaxTokens[block.id]!.map(\.token)
        XCTAssertFalse(expected.isEmpty)

        let editor = snapshot.syntaxSpans.compactMap { span -> CodeSyntaxToken? in
            if case .codeToken(let kind) = span.role { return kind } else { return nil }
        }
        XCTAssertEqual(editor, expected)

        let attributed = CodeSyntaxHighlighter.render(block.content, language: "js",
                                                      tokens: snapshot.codeSyntaxTokens[block.id])
        var preview: [CodeSyntaxToken] = []
        attributed.enumerateAttribute(.codeSyntaxToken, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if let raw = value as? String, let kind = CodeSyntaxToken(rawValue: raw) { preview.append(kind) }
        }
        XCTAssertEqual(preview, expected)
        let unshared = CodeSyntaxHighlighter.render(block.content, language: "js")
        XCTAssertTrue(unshared.isEqual(to: attributed))

        let html = MarkdownHTMLExporter.highlightedCode(block.content, language: "js")
        let regex = try! NSRegularExpression(pattern: #"<span class="tok-([a-z]+)">"#)
        let classes = regex.matches(in: html, range: NSRange(location: 0, length: (html as NSString).length)).compactMap {
            CodeSyntaxToken(rawValue: (html as NSString).substring(with: $0.range(at: 1)))
        }
        XCTAssertEqual(classes, expected)
    }

    // MARK: HTML 書き出し

    func testHTMLExportHighlightsRepeatedBlocksIdenticallyAndRubyInList() {
        let source = """
        ```js
        \(jsSample)
        ```

        ```js
        \(jsSample)
        ```

        - item

          ```ruby
          x = 1 # note
          ```
        """
        let html = MarkdownHTMLExporter.render(source)
        let spans = try! NSRegularExpression(pattern: #"<pre><code class="language-js">.*?</code></pre>"#,
                                             options: [.dotMatchesLineSeparators])
        let blocks = spans.matches(in: html, range: NSRange(location: 0, length: (html as NSString).length))
            .map { (html as NSString).substring(with: $0.range) }
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0], blocks[1])
        XCTAssertTrue(blocks[0].contains("<span class=\"tok-string\">/[//]/g</span>"))
        XCTAssertTrue(html.contains("<span class=\"tok-comment\"># note</span>"))
    }

    // MARK: 版と取り消し

    func testCancellationInsideCodeBlockLoopAbortsSnapshot() {
        let block = "```js\nlet a = 1;\n```\n\n"
        let source = String(repeating: block, count: 5)
        var calls = 0
        struct Stop: Error {}
        do {
            _ = try DocumentSnapshot(source: source, dialect: .extended) {
                calls += 1
                if calls > 10 { throw Stop() }
            }
            XCTFail("取り消されるはず")
        } catch is Stop {
            XCTAssertEqual(calls, 11)
        } catch { XCTFail("\(error)") }
        // 全体の呼び出し回数を数え、ブロックごとの確認が増えていることを確かめる。
        var total = 0
        _ = DocumentSnapshot(source: source, dialect: .extended, checkCancellation: { total += 1 })
        var plain = 0
        _ = DocumentSnapshot(source: "text", dialect: .extended, checkCancellation: { plain += 1 })
        XCTAssertGreaterThanOrEqual(total - plain, 5)
    }

    func testStorePublishesSnapshotWhoseTokensBelongToItsOwnSource() async throws {
        let store = DocumentAnalysisStore()
        let first = "```js\nconst alpha = 1;\n```\n"
        let second = "前置き\n\n```js\nlet beta = \"two\";\n```\n"
        store.update(source: first)
        store.update(source: second)
        for _ in 0..<400 where store.snapshot?.source != second { try await Task.sleep(for: .milliseconds(5)) }
        let snapshot = try XCTUnwrap(store.snapshot)
        XCTAssertEqual(snapshot.source, second)
        let texts = codeTokenTexts(snapshot).map(\.1)
        XCTAssertTrue(texts.contains("let"))
        XCTAssertTrue(texts.contains("\"two\""))
        XCTAssertFalse(texts.contains("alpha") || texts.contains("const"))
        let block = codeBlocks(snapshot)[0]
        XCTAssertNotNil(snapshot.codeSyntaxTokens[block.id])
    }
}
