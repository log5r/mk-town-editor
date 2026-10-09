import XCTest
@testable import MKTownEditor

final class TreeSitterSyntaxParserTests: XCTestCase {
    private func tokens(_ source: String, _ grammar: TreeSitterGrammar, file: StaticString = #filePath, line: UInt = #line) -> [(String, CodeSyntaxToken)] {
        let text = source as NSString
        guard let result = TreeSitterSyntaxParser.tokens(in: source, grammar: grammar) else {
            XCTFail("解析できない: \(source)", file: file, line: line)
            return []
        }
        return result.map { (text.substring(with: $0.range), $0.token) }
    }

    private func assertWellFormed(_ source: String, _ grammar: TreeSitterGrammar, file: StaticString = #filePath, line: UInt = #line) {
        guard let result = TreeSitterSyntaxParser.tokens(in: source, grammar: grammar) else {
            return XCTFail("解析できない: \(source)", file: file, line: line)
        }
        XCTAssertTrue(TreeSitterSyntaxParser.isValid(result, length: (source as NSString).length), source, file: file, line: line)
    }

    private func range(_ lo: Int, _ len: Int) -> NSRange { NSRange(location: lo, length: len) }

    // MARK: クエリ

    func testEveryGrammarQueryCompiles() {
        for grammar in TreeSitterGrammar.allCases {
            XCTAssertNil(TreeSitterSyntaxParser.queryCompileError(for: grammar), grammar.rawValue)
        }
    }

    func testCacheVersionContainsEngineVersionAndQueryRevision() {
        for grammar in TreeSitterGrammar.allCases {
            XCTAssertTrue(grammar.cacheVersion.contains("tree-sitter"))
            XCTAssertTrue(grammar.cacheVersion.contains(grammar.packageVersion))
            XCTAssertTrue(grammar.cacheVersion.contains("q\(TreeSitterGrammar.queryRevision)"))
        }
        XCTAssertNotEqual(TreeSitterGrammar.javascript.cacheVersion, TreeSitterGrammar.typescript.cacheVersion)
    }

    // MARK: 正規化

    func testNormalizeSplitsOuterRangeAroundNestedRange() {
        let result = TreeSitterSyntaxParser.normalize([(range(0, 10), .string, 0), (range(3, 2), .number, 1)], length: 10)
        XCTAssertEqual(result, [
            CodeSyntaxTokenRange(range: range(0, 3), token: .string),
            CodeSyntaxTokenRange(range: range(3, 2), token: .number),
            CodeSyntaxTokenRange(range: range(5, 5), token: .string)
        ])
    }

    func testNormalizeNestedAtEdgesAndDeeperNesting() {
        // 内側が外側の先頭・末尾に接する場合、空の断片は作らない。
        let edges = TreeSitterSyntaxParser.normalize([(range(0, 6), .string, 0), (range(0, 2), .number, 1), (range(4, 2), .keyword, 2)], length: 6)
        XCTAssertEqual(edges, [
            CodeSyntaxTokenRange(range: range(0, 2), token: .number),
            CodeSyntaxTokenRange(range: range(2, 2), token: .string),
            CodeSyntaxTokenRange(range: range(4, 2), token: .keyword)
        ])
        let deep = TreeSitterSyntaxParser.normalize([(range(0, 9), .string, 0), (range(2, 5), .variable, 1), (range(3, 1), .number, 2)], length: 9)
        XCTAssertEqual(deep, [
            CodeSyntaxTokenRange(range: range(0, 2), token: .string),
            CodeSyntaxTokenRange(range: range(2, 1), token: .variable),
            CodeSyntaxTokenRange(range: range(3, 1), token: .number),
            CodeSyntaxTokenRange(range: range(4, 3), token: .variable),
            CodeSyntaxTokenRange(range: range(7, 2), token: .string)
        ])
    }

    func testNormalizeEqualRangeKeepsLowerPatternIndex() {
        let result = TreeSitterSyntaxParser.normalize([(range(0, 3), .type, 5), (range(0, 3), .keyword, 2), (range(0, 3), .string, 9)], length: 3)
        XCTAssertEqual(result, [CodeSyntaxTokenRange(range: range(0, 3), token: .keyword)])
    }

    func testNormalizeDropsZeroLengthAndOutOfBounds() {
        let result = TreeSitterSyntaxParser.normalize([
            (range(2, 0), .keyword, 0), (range(8, 5), .string, 1), (range(-1, 2), .number, 2), (range(0, 3), .comment, 3)
        ], length: 10)
        XCTAssertEqual(result, [CodeSyntaxTokenRange(range: range(0, 3), token: .comment)])
        XCTAssertEqual(TreeSitterSyntaxParser.normalize([], length: 0), [])
    }

    func testNormalizeDropsPartialOverlapKeepingEarlierStart() {
        let result = TreeSitterSyntaxParser.normalize([(range(5, 5), .number, 0), (range(0, 7), .string, 1)], length: 10)
        XCTAssertEqual(result, [CodeSyntaxTokenRange(range: range(0, 7), token: .string)])
    }

    func testNormalizeMergesTouchingSameTokenAndSortsOutput() {
        let result = TreeSitterSyntaxParser.normalize([(range(6, 2), .number, 0), (range(0, 1), .attribute, 0), (range(1, 4), .attribute, 1)], length: 8)
        XCTAssertEqual(result, [
            CodeSyntaxTokenRange(range: range(0, 5), token: .attribute),
            CodeSyntaxTokenRange(range: range(6, 2), token: .number)
        ])
    }

    func testNormalizeOutputInvariantOnPseudoRandomInput() {
        var seed: UInt64 = 42
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        let all: [CodeSyntaxToken] = [.keyword, .type, .string, .number]
        for _ in 0..<200 {
            let captures = (0..<30).map { _ in (range(next(60), next(20)), all[next(all.count)], next(5)) }
            guard let result = TreeSitterSyntaxParser.normalize(captures, length: 60) else { return XCTFail("不変条件を満たさない") }
            XCTAssertTrue(TreeSitterSyntaxParser.isValid(result, length: 60))
        }
    }

    func testIsValidRejectsOverlapUnsortedEmptyAndOutOfBounds() {
        let a = CodeSyntaxTokenRange(range: range(0, 3), token: .keyword)
        XCTAssertFalse(TreeSitterSyntaxParser.isValid([a, CodeSyntaxTokenRange(range: range(2, 3), token: .string)], length: 10))
        XCTAssertFalse(TreeSitterSyntaxParser.isValid([CodeSyntaxTokenRange(range: range(5, 1), token: .string), a], length: 10))
        XCTAssertFalse(TreeSitterSyntaxParser.isValid([CodeSyntaxTokenRange(range: range(1, 0), token: .string)], length: 10))
        XCTAssertFalse(TreeSitterSyntaxParser.isValid([CodeSyntaxTokenRange(range: range(8, 5), token: .string)], length: 10))
        XCTAssertTrue(TreeSitterSyntaxParser.isValid([a], length: 3))
    }

    // MARK: キャプチャ名

    func testCapitalizedRuleMatchesScannerRule() {
        func kind(_ word: String) -> CodeSyntaxToken? {
            TreeSitterSyntaxParser.token(forCapture: "type.capitalized", range: range(0, (word as NSString).length),
                                         text: word as NSString, grammar: .javascript)
        }
        XCTAssertEqual(kind("Foo"), .type)
        XCTAssertEqual(kind("HTTPServer"), .type)
        XCTAssertNil(kind("MAX_SIZE"))
        XCTAssertNil(kind("foo"))
        XCTAssertNil(kind("X"))
        XCTAssertNil(kind("_Foo"))
        XCTAssertNil(TreeSitterSyntaxParser.token(forCapture: "unknown", range: range(0, 1), text: "a", grammar: .ruby))
    }

    func testBuiltinKeywordsAreRubyOnly() {
        XCTAssertEqual(tokens("private\nattr_reader :a\nfoo", .ruby).filter { $0.1 == .keyword }.map(\.0), ["private", "attr_reader"])
        XCTAssertTrue(tokens("private; require(x)", .javascript).filter { $0.1 == .keyword }.isEmpty)
    }

    // MARK: JavaScript / TypeScript

    func testJavaScriptBasics() {
        let values = tokens("const slash = /[//]/g; // note\nlet r = a / b / c;", .javascript)
        XCTAssertTrue(values.contains { $0 == ("/[//]/g", .string) })
        XCTAssertTrue(values.contains { $0 == ("// note", .comment) })
        XCTAssertTrue(values.contains { $0 == ("const", .keyword) })
        XCTAssertEqual(values.filter { $0.1 == .string }.count, 1)
    }

    func testTemplateSubstitutionSplitsString() {
        let source = "const s = `a ${a + 1} b`;"
        let values = tokens(source, .javascript)
        XCTAssertTrue(values.contains { $0 == ("1", .number) })
        XCTAssertTrue(values.contains { $0 == ("`a ${a + ", .string) })
        XCTAssertTrue(values.contains { $0 == ("} b`", .string) })
    }

    func testMultilineTemplateStringRanges() {
        let source = "x = `line1\n日本語\n😀 end`; y = 1"
        let expected = (source as NSString).range(of: "`line1\n日本語\n😀 end`")
        XCTAssertTrue(TreeSitterSyntaxParser.tokens(in: source, grammar: .javascript)!
            .contains { $0.token == .string && NSEqualRanges($0.range, expected) })
    }

    func testJSXAndTSX() {
        let source = "const el = <Button>{x / y}</Button>; /re/.test(x)"
        for grammar in [TreeSitterGrammar.tsx, .javascript] {
            let values = tokens(source, grammar)
            XCTAssertEqual(values.filter { $0.1 == .string }.map(\.0), ["/re/"], grammar.rawValue)
            XCTAssertTrue(values.contains { $0 == ("Button", .type) }, grammar.rawValue)
        }
    }

    func testTypeScriptNonNullAssertionIsDivision() {
        let values = tokens("const r = x! / c / g", .typescript)
        XCTAssertFalse(values.contains { $0.1 == .string })
    }

    func testTypeScriptTypesAndKeywords() {
        let values = tokens("interface User { name: string; age?: number }\nlet u: Foo<Bar> = null as unknown as Foo", .typescript)
        XCTAssertTrue(values.contains { $0 == ("interface", .keyword) })
        XCTAssertTrue(values.contains { $0 == ("string", .type) })
        XCTAssertTrue(values.contains { $0 == ("number", .type) })
        XCTAssertTrue(values.contains { $0 == ("Bar", .type) })
        XCTAssertTrue(values.contains { $0 == ("null", .keyword) })
        XCTAssertTrue(values.contains { $0 == ("as", .keyword) })
    }

    func testDecorators() {
        let values = tokens("@Component({ selector: 'a' })\nclass A { @Input() x = 1; @a.b c = 2 }", .typescript)
        XCTAssertTrue(values.contains { $0 == ("@Component", .attribute) })
        XCTAssertTrue(values.contains { $0 == ("@Input", .attribute) })
        XCTAssertTrue(values.contains { $0 == ("@a", .attribute) })
    }

    func testShebangAndSetOfStrings() {
        let values = tokens("#!/usr/bin/env node\nconsole.log('a', \"b\")", .javascript)
        XCTAssertTrue(values.contains { $0 == ("#!/usr/bin/env node", .comment) })
        XCTAssertEqual(values.filter { $0.1 == .string }.map(\.0), ["'a'", "\"b\""])
    }

    // MARK: Ruby

    func testRubyBasics() {
        let source = "puts /a#b/\nclass Foo < Bar\n  attr_reader :name, @x\n  def hi = \"v #{1} w\" # note\nend"
        let values = tokens(source, .ruby)
        XCTAssertTrue(values.contains { $0 == ("/a#b/", .string) })
        XCTAssertTrue(values.contains { $0 == ("Foo", .type) })
        XCTAssertTrue(values.contains { $0 == ("attr_reader", .keyword) })
        XCTAssertTrue(values.contains { $0 == (":name", .variable) })
        XCTAssertTrue(values.contains { $0 == ("@x", .variable) })
        XCTAssertTrue(values.contains { $0 == ("# note", .comment) })
        XCTAssertFalse(values.contains { $0 == ("puts", .keyword) })
    }

    func testRubyInterpolationSplitsString() {
        let values = tokens("x = \"a#{1}b\"", .ruby)
        XCTAssertTrue(values.contains { $0 == ("1", .number) })
        XCTAssertTrue(values.contains { $0 == ("\"a#{", .string) })
        XCTAssertTrue(values.contains { $0 == ("}b\"", .string) })
    }

    func testRubyHeredocRange() {
        let source = "text = <<~EOS\n  日本語 #{name}\n  😀\nEOS\nputs text"
        let values = tokens(source, .ruby)
        // 開始（`<<~EOS`）と本文は隣り合うので1つの文字列になる。
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.0, "<<~EOS\n  日本語 #{name}\n  😀\nEOS")
        XCTAssertEqual(values.first?.1, .string)
    }

    // MARK: UTF-16・改行・不完全な入力

    func testRangesUseUTF16Offsets() {
        let sources = ["const 日本 = \"😀\"; /re/.test(x)", "const e\u{301} = \"e\u{301}\"; /re/.test(x)", "// 😀👨‍👩‍👧\nconst a = 'ü';"]
        for source in sources {
            let result = TreeSitterSyntaxParser.tokens(in: source, grammar: .javascript)!
            let text = source as NSString
            for expected in ["/re/", "\"😀\"", "\"e\u{301}\"", "// 😀👨‍👩‍👧", "'ü'"] {
                let r = text.range(of: expected)
                if r.location != NSNotFound {
                    XCTAssertTrue(result.contains { NSEqualRanges($0.range, r) }, "\(expected) in \(source)")
                }
            }
        }
        let ruby = "puts '日本語😀' # メモ"
        let rubyResult = TreeSitterSyntaxParser.tokens(in: ruby, grammar: .ruby)!
        XCTAssertTrue(rubyResult.contains { NSEqualRanges($0.range, (ruby as NSString).range(of: "'日本語😀'")) })
        XCTAssertTrue(rubyResult.contains { NSEqualRanges($0.range, (ruby as NSString).range(of: "# メモ")) })
    }

    func testCRLFLineEndings() {
        let source = "let a = 1;\r\n/re/.test(x) // c\r\n"
        let result = TreeSitterSyntaxParser.tokens(in: source, grammar: .javascript)!
        let text = source as NSString
        XCTAssertTrue(result.contains { NSEqualRanges($0.range, text.range(of: "/re/")) && $0.token == .string })
        XCTAssertTrue(result.contains { NSEqualRanges($0.range, text.range(of: "// c")) && $0.token == .comment })
        let ruby = "x = 1\r\n# c\r\nputs 'a'\r\n"
        XCTAssertTrue(TreeSitterSyntaxParser.tokens(in: ruby, grammar: .ruby)!
            .contains { $0.token == .comment && NSLocationInRange((ruby as NSString).range(of: "# c").location, $0.range) })
    }

    func testIncompleteInputStillYieldsIdentifiableTokensWithinBounds() {
        let js: [String] = ["const s = \"abc", "function f( {", "if (", "/* unclosed", "x = `abc ${", "class {", "const a = 1; @", "}}}{{{", ""]
        for source in js {
            for grammar in [TreeSitterGrammar.javascript, .typescript, .tsx] { assertWellFormed(source, grammar) }
        }
        for source in ["def f(", "x = \"abc", "=begin\nabc", "puts <<~EOS\nabc", "if", "end end", "%w(a b", ""] {
            assertWellFormed(source, .ruby)
        }
        XCTAssertTrue(tokens("const s = \"abc", .javascript).contains { $0 == ("const", .keyword) })
        XCTAssertTrue(tokens("function f( {", .javascript).contains { $0 == ("function", .keyword) })
        XCTAssertTrue(tokens("if (", .javascript).contains { $0 == ("if", .keyword) })
        XCTAssertTrue(tokens("x = 1 /* unclosed", .javascript).contains { $0 == ("1", .number) })
        XCTAssertTrue(tokens("def f(", .ruby).contains { $0 == ("def", .keyword) })
    }

    func testEmptyAndPlainSourcesReturnEmptyArray() {
        XCTAssertEqual(TreeSitterSyntaxParser.tokens(in: "", grammar: .javascript), [])
        XCTAssertEqual(TreeSitterSyntaxParser.tokens(in: "a b c", grammar: .ruby), [])
    }

    func testOversizeSourceReturnsNilAndAnalyzerFallsBackToPlain() {
        let source = String(repeating: "a", count: TreeSitterSyntaxParser.maximumSourceLength + 1)
        XCTAssertNil(TreeSitterSyntaxParser.tokens(in: source, grammar: .javascript))
        let cache = CodeSyntaxTokenCache()
        XCTAssertEqual(CodeSyntaxAnalyzer.tokens(in: source, language: "js", cache: cache), [])
    }

    func testLargeSourceFinishesWithinTimeout() {
        let line = "const v = foo(1, 'a') + `t${x}`; // c\n"
        let source = String(repeating: line, count: 5_000)
        let start = Date()
        let result = TreeSitterSyntaxParser.tokens(in: source, grammar: .javascript)
        XCTAssertNotNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
}
