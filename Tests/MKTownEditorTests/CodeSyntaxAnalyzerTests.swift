import XCTest
@testable import MKTownEditor

final class CodeSyntaxAnalyzerTests: XCTestCase {
    private func grammar(_ name: String) -> TreeSitterGrammar? {
        if case .treeSitter(let grammar)? = CodeSyntaxAnalyzer.language(named: name)?.engine { return grammar }
        return nil
    }

    func testAliasesResolveToEngines() {
        XCTAssertEqual(grammar("ts"), .typescript)
        XCTAssertEqual(grammar("mts"), .typescript)
        XCTAssertEqual(grammar("tsx"), .tsx)
        XCTAssertEqual(grammar("jsx"), .javascript)
        XCTAssertEqual(grammar("JS"), .javascript)
        XCTAssertEqual(grammar("rb"), .ruby)
        XCTAssertEqual(grammar("ruby:app.rb"), .ruby)
        XCTAssertEqual(grammar("{.ruby}"), .ruby)
        XCTAssertEqual(grammar("language-typescript"), .typescript)
        XCTAssertEqual(grammar("app.tsx"), .tsx)
        XCTAssertEqual(CodeSyntaxAnalyzer.language(named: "ts")?.name, "typescript")
        XCTAssertEqual(CodeSyntaxAnalyzer.language(named: "jsx")?.name, "javascript")
        guard case .scanner(let language)? = CodeSyntaxAnalyzer.language(named: "c")?.engine else { return XCTFail("c は走査器") }
        XCTAssertEqual(language.name, "c")
        XCTAssertEqual(CodeSyntaxAnalyzer.language(named: "main.cpp")?.name, "cpp")
    }

    func testPlainTextAndUnknownLanguagesAreNil() {
        for name in ["text", "txt", "plaintext", "", "  ", "unknown-lang", "notes.txt"] {
            XCTAssertNil(CodeSyntaxAnalyzer.language(named: name), name)
        }
        XCTAssertNil(CodeSyntaxAnalyzer.language(named: nil))
        XCTAssertEqual(CodeSyntaxAnalyzer.tokens(in: "const a = 1", language: "text"), [])
    }

    func testAnalyzerUsesTreeSitterForMigratedLanguages() {
        // 旧走査器は行頭の `/` を正規表現と読んだが、JavaScript には改行での文の終端がなく、Tree-sitter は除算と読む。
        let tokens = CodeSyntaxAnalyzer.tokens(in: "y = a\n/ 2 / 3", language: "js", cache: CodeSyntaxTokenCache())
        XCTAssertFalse(tokens.contains { $0.token == .string })
        let swift = CodeSyntaxAnalyzer.tokens(in: "let x = 1", language: "swift", cache: CodeSyntaxTokenCache())
        XCTAssertFalse(swift.isEmpty)
    }

    // MARK: キャッシュ

    func testCacheHitsOnIdenticalContent() {
        let cache = CodeSyntaxTokenCache()
        let source = "const a = 'x'"
        let first = CodeSyntaxAnalyzer.tokens(in: source, language: "js", cache: cache)
        XCTAssertEqual(cache.hits, 0)
        XCTAssertEqual(cache.misses, 1)
        let second = CodeSyntaxAnalyzer.tokens(in: source, language: "javascript", cache: cache)
        XCTAssertEqual(cache.hits, 1, "別名でも正規名が同じなら共有する")
        XCTAssertEqual(first, second)
        XCTAssertEqual(cache.count, 1)
    }

    func testCacheMissesOnDifferentLanguageOrContent() {
        let cache = CodeSyntaxTokenCache()
        _ = CodeSyntaxAnalyzer.tokens(in: "const a = 1", language: "js", cache: cache)
        _ = CodeSyntaxAnalyzer.tokens(in: "const a = 1", language: "ts", cache: cache)
        _ = CodeSyntaxAnalyzer.tokens(in: "const a = 2", language: "js", cache: cache)
        XCTAssertEqual(cache.hits, 0)
        XCTAssertEqual(cache.misses, 3)
        XCTAssertEqual(cache.count, 3)
    }

    func testEmptyResultsAreCachedToo() {
        let cache = CodeSyntaxTokenCache()
        XCTAssertEqual(CodeSyntaxAnalyzer.tokens(in: "a b", language: "ruby", cache: cache), [])
        XCTAssertEqual(CodeSyntaxAnalyzer.tokens(in: "a b", language: "ruby", cache: cache), [])
        XCTAssertEqual(cache.hits, 1)
    }

    func testHashCollisionDoesNotReturnWrongTokens() {
        let cache = CodeSyntaxTokenCache(hash: { _ in 7 })
        let a = CodeSyntaxAnalyzer.tokens(in: "const a = 1", language: "js", cache: cache)
        let b = CodeSyntaxAnalyzer.tokens(in: "// hello", language: "js", cache: cache)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(b.map(\.token), [.comment])
        XCTAssertEqual(cache.hits, 0)
        // 衝突した鍵は後の本文に置き換わるが、結果は常に本文に対して正しい。
        XCTAssertEqual(CodeSyntaxAnalyzer.tokens(in: "const a = 1", language: "js", cache: cache), a)
        XCTAssertEqual(CodeSyntaxAnalyzer.tokens(in: "// hello", language: "js", cache: cache), b)
    }

    func testEngineVersionIsPartOfTheKey() {
        let cache = CodeSyntaxTokenCache()
        let tokens = [CodeSyntaxTokenRange(range: NSRange(location: 0, length: 1), token: .keyword)]
        cache.store(tokens, for: "x", language: "javascript", version: "tree-sitter:javascript@0.23.1:q1")
        XCTAssertNotNil(cache.tokens(for: "x", language: "javascript", version: "tree-sitter:javascript@0.23.1:q1"))
        XCTAssertNil(cache.tokens(for: "x", language: "javascript", version: "tree-sitter:javascript@0.23.1:q2"))
        XCTAssertNil(cache.tokens(for: "x", language: "javascript", version: "tree-sitter:javascript@0.24.0:q1"))
        XCTAssertNil(cache.tokens(for: "x", language: "typescript", version: "tree-sitter:javascript@0.23.1:q1"))
    }

    func testEvictionByCapacityIsLeastRecentlyUsed() {
        let cache = CodeSyntaxTokenCache(capacity: 3, lengthBudget: 1_000)
        for name in ["a", "b", "c"] { cache.store([], for: name, language: "ruby", version: "v") }
        XCTAssertNotNil(cache.tokens(for: "a", language: "ruby", version: "v"))  // a を最近使った扱いにする
        cache.store([], for: "d", language: "ruby", version: "v")                 // b が追い出される
        XCTAssertEqual(cache.count, 3)
        XCTAssertNil(cache.tokens(for: "b", language: "ruby", version: "v"))
        XCTAssertNotNil(cache.tokens(for: "a", language: "ruby", version: "v"))
        XCTAssertNotNil(cache.tokens(for: "c", language: "ruby", version: "v"))
        XCTAssertNotNil(cache.tokens(for: "d", language: "ruby", version: "v"))
    }

    func testEvictionByLengthBudget() {
        let cache = CodeSyntaxTokenCache(capacity: 100, lengthBudget: 10)
        cache.store([], for: "aaaa", language: "ruby", version: "v")
        cache.store([], for: "bbbb", language: "ruby", version: "v")
        XCTAssertEqual(cache.contentLength, 8)
        cache.store([], for: "cccc", language: "ruby", version: "v")  // 12 > 10 なので最も古い a が追い出される
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.contentLength, 8)
        XCTAssertNil(cache.tokens(for: "aaaa", language: "ruby", version: "v"))
        XCTAssertNotNil(cache.tokens(for: "cccc", language: "ruby", version: "v"))
        // 予算を超える1件は保存しない（既存の項目も追い出さない）。
        cache.store([], for: String(repeating: "x", count: 11), language: "ruby", version: "v")
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.contentLength, 8)
    }

    func testReplacingEntryAdjustsTotalLengthAndRemoveAllClears() {
        let cache = CodeSyntaxTokenCache(capacity: 10, lengthBudget: 100)
        cache.store([], for: "abc", language: "ruby", version: "v")
        cache.store([CodeSyntaxTokenRange(range: NSRange(location: 0, length: 1), token: .keyword)], for: "abc", language: "ruby", version: "v")
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.contentLength, 3)
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.contentLength, 0)
        XCTAssertNil(cache.tokens(for: "abc", language: "ruby", version: "v"))
    }

    func testUTF16LengthIsUsedForBudget() {
        let cache = CodeSyntaxTokenCache(capacity: 10, lengthBudget: 100)
        cache.store([], for: "😀", language: "ruby", version: "v")
        XCTAssertEqual(cache.contentLength, 2)
    }

    func testResultsAreIdenticalAcrossRepeatedCallsAndThreads() {
        let sources = [
            ("const a = /x/g; // c\nlet s = `t${1}`", "js"),
            ("interface A { x: string }\n@Dec() class B {}", "ts"),
            ("const el = <Button>{x / y}</Button>", "tsx"),
            ("puts /a#b/\nclass Foo; attr_reader :a; end", "rb")
        ]
        let expected = sources.map { CodeSyntaxAnalyzer.tokens(in: $0.0, language: $0.1, cache: CodeSyntaxTokenCache()) }
        XCTAssertTrue(expected.allSatisfy { !$0.isEmpty })
        let shared = CodeSyntaxTokenCache()
        let lock = NSLock()
        nonisolated(unsafe) var mismatches = 0
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            let item = index % sources.count
            let uncached = CodeSyntaxAnalyzer.tokens(in: sources[item].0, language: sources[item].1, cache: CodeSyntaxTokenCache())
            let cached = CodeSyntaxAnalyzer.tokens(in: sources[item].0, language: sources[item].1, cache: shared)
            if uncached != expected[item] || cached != expected[item] {
                lock.lock(); mismatches += 1; lock.unlock()
            }
        }
        XCTAssertEqual(mismatches, 0)
        XCTAssertEqual(shared.count, sources.count)
    }
}
