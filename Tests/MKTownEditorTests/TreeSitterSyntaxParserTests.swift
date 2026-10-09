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

    // MARK: 依存の版

    /// `packageVersion` はキャッシュ鍵に入る。依存を更新したのに値を上げ忘れると、古い解析結果を返し続ける。
    func testPackageVersionsMatchPackageResolved() throws {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
            let parent = directory.deletingLastPathComponent()
            try XCTSkipIf(parent == directory, "Package.swift が見つからない")
            directory = parent
        }
        let data = try Data(contentsOf: directory.appendingPathComponent("Package.resolved"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let pins = try XCTUnwrap(json["pins"] as? [[String: Any]])
        var versions: [String: String] = [:]
        for pin in pins {
            if let identity = pin["identity"] as? String,
               let state = pin["state"] as? [String: Any],
               let version = state["version"] as? String {
                versions[identity] = version
            }
        }
        let packages: [TreeSitterGrammar: String] = [
            .javascript: "tree-sitter-javascript",
            .typescript: "tree-sitter-typescript",
            .tsx: "tree-sitter-typescript",
            .ruby: "tree-sitter-ruby",
        ]
        XCTAssertEqual(Set(packages.keys), Set(TreeSitterGrammar.allCases), "文法を追加したらここにも加える")
        for (grammar, package) in packages {
            XCTAssertEqual(grammar.packageVersion, versions[package], "\(grammar.rawValue): Package.resolved の \(package)")
        }
    }

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

    func testOversizeSourceIsUnsupportedAndCached() {
        let source = String(repeating: "a", count: TreeSitterSyntaxParser.maximumSourceLength + 1)
        XCTAssertEqual(TreeSitterSyntaxParser.parse(source, grammar: .javascript), .unsupported)
        let cache = CodeSyntaxTokenCache()
        XCTAssertEqual(CodeSyntaxAnalyzer.tokens(in: source, language: "js", cache: cache), [])
        XCTAssertEqual(cache.count, 1)
    }

    func testTimeoutIsInterruptedAndNotCached() {
        let line = "const v = foo(1, 'a') + `t${x}`; // c\n"
        let source = String(repeating: line, count: 20_000)
        XCTAssertEqual(TreeSitterSyntaxParser.parse(source, grammar: .javascript, timeout: 0.000_001), .interrupted)
        let cache = CodeSyntaxTokenCache()
        let selection = CodeSyntaxAnalyzer.language(named: "js")!
        XCTAssertEqual(CodeSyntaxAnalyzer.tokens(in: source, language: selection, cache: cache, parseTimeout: 0.000_001), [])
        XCTAssertEqual(cache.count, 0)
        // 通常の上限なら解析できる（タイムアウトは一時的な失敗で、入力のせいではない）。
        if case .tokens = TreeSitterSyntaxParser.parse(source, grammar: .javascript, timeout: 30) {} else {
            XCTFail("十分な時間があれば解析できる")
        }
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

/// JavaScript・TypeScript・Ruby の正規表現リテラルと除算の判別。旧走査器の規則を Tree-sitter の文法に置き換えた後も、
/// 同じ入力で結果が変わらないこと（変わる場合は理由）を確かめる。
final class TreeSitterRegexLiteralTests: XCTestCase {
    private func tokens(_ source: String, _ language: String) -> [(String, CodeSyntaxToken)] {
        let text = source as NSString
        return CodeSyntaxAnalyzer.tokens(in: source, language: language, cache: CodeSyntaxTokenCache()).map {
            (text.substring(with: $0.range), $0.token)
        }
    }

    func testRegexLiteralsAreNotCommentsAndDivisionStaysCode() {
        for name in ["js", "ts"] {
            let values = tokens("const slash = /[//]/g; return 1;\nlet r = a / b / c; // note\nif (/\\/\\*/.test(x)) {}", name)
            XCTAssertTrue(values.contains { $0 == ("/[//]/g", .string) }, name)
            XCTAssertTrue(values.contains { $0 == ("return", .keyword) }, name)
            XCTAssertTrue(values.contains { $0 == ("// note", .comment) }, name)
            XCTAssertEqual(values.filter { $0.1 == .comment }.count, 1, name)
            XCTAssertTrue(values.contains { $0 == ("/\\/\\*/", .string) }, name)
            XCTAssertFalse(values.contains { $0.0.hasPrefix("/ b") }, name)
        }
        for name in ["js", "ts"] {
            // コメントの後ろ、`default` の後ろ、前置 `++` の後ろは正規表現。
            let regex = tokens("const r = /* note */ /[//]/g; return 1\nexport default /[//]/g; const x = 1\ny = ++/a/.lastIndex", name)
            XCTAssertEqual(regex.filter { $0 == ("/[//]/g", .string) }.count, 2, name)
            XCTAssertTrue(regex.contains { $0 == ("/* note */", .comment) }, name)
            XCTAssertTrue(regex.contains { $0 == ("return", .keyword) }, name)
            XCTAssertTrue(regex.contains { $0 == ("const", .keyword) }, name)
            XCTAssertEqual(regex.filter { $0.1 == .comment }.count, 1, name)
            // 後置 `++`・`--`、メンバー名 `obj.in` の後ろは除算。
            let division = tokens("a = x++ / b/g\nc = y-- / d/g\nconst q = obj.in / b/g", name)
            XCTAssertFalse(division.contains { $0.1 == .string }, name)
        }
        for name in ["js", "ts"] {
            // 制御文の条件の後ろは文の始まりなので正規表現。ただの括弧の後ろは除算。
            let control = tokens("if (ok) /[//]/.test(x); return 1\nwhile (a) /b/g.exec(s)\nfor (;;) /c/.test(t)\nz = (a) / b / c\nif /* note */ (ok) /d/.test(x)\nif (ok) {} /e/.test(x)\nfunction f() {} /f/.test(x)\nelse {} /g/.test(x)\nv = {a: 1} / h / i\nw = f({}) / j / k", name)
            for regex in ["/[//]/", "/b/g", "/c/", "/d/", "/e/", "/f/", "/g/"] {
                XCTAssertTrue(control.contains { $0 == (regex, .string) }, "\(name) \(regex)")
            }
            XCTAssertTrue(control.contains { $0 == ("return", .keyword) }, name)
            // 式の中の関数本体・クラス本体の後ろは値なので除算。宣言の後ろは文の始まり。
            let bodies = tokens("const p = function() {} / b / g\nconst q = () => {} / c / g\nconst r = (class {}) / d / g\nfunction s() {} /re/.test(x)", name)
            XCTAssertEqual(bodies.filter { $0.1 == .string }.map(\.0), ["/re/"], name)
            // `async function` の式も同じ。ラベルと `case` のコロンの後ろのブロックは文。
            let more = tokens("const f = async function() {} / b / g\nasync function h() {} /e/.test(x)\nlabel: {} /[//]/.test(x); return 1\nswitch (v) { case 1: {} /c/.test(x); default: {} /d/.test(x) }\nconst o = {a: {}} / i / j\nconst t = c ? {} : {} / k / l", name)
            XCTAssertEqual(more.filter { $0.1 == .string }.map(\.0), ["/e/", "/[//]/", "/c/", "/d/"], name)
            XCTAssertTrue(more.contains { $0 == ("return", .keyword) }, name)
            // 引数に `{}` を含む関数式も値として閉じる。`export default` の宣言は文として閉じる。
            // Tree-sitter 版：名前のない `export default function() {}` / `class {}` は文法が式として読み、直後の行頭の `/` を
            // 正規表現にできない（ES 仕様では宣言）。名前付きの宣言なら文として閉じる。
            let declarations = tokens("const f = function(a = {}) {} / b / g\nconst h = ({x}) => {} / c / g\nexport default function k() {}\n/[//]/.test(x)\nexport default class K {}\n/e/.test(x)", name)
            XCTAssertEqual(declarations.filter { $0.1 == .string }.map(\.0), ["/[//]/", "/e/"], name)
            let anonymous = tokens("export default function() {}\n/[//]/.test(x)", name)
            XCTAssertFalse(anonymous.contains { $0 == ("/[//]/", .string) }, name)
            // セミコロンのない `import` は改行で終わる。`async` と `function` の間の改行は別の文。
            let lines = tokens("import fs from \"node:fs\"\n/[//]/.test(x)\nimport {\n  a,\n  b\n} from \"y\"\n/c/.test(x)\nconst async = 1; const z = async\nfunction f() {}\n/d/.test(x)", name)
            XCTAssertEqual(lines.filter { $0.1 == .string && $0.0.hasPrefix("/") }.map(\.0), ["/[//]/", "/c/", "/d/"], name)
            // 変数名の `of`、非 null アサーション `x!` の後ろは除算。`for (x of /re/)` と前置の `!` の後ろは正規表現。
            let contextual = tokens("const of = 12; const q = of / b / g\nconst r = x! / c / g\nfor (const m of /[ab]/.exec(s)) {}\nconst n = !/d/.test(s)", name)
            // 非 null アサーションは TypeScript だけ。JavaScript の `x!` は構文エラーなので、Tree-sitter 版は除算と同じに扱う
            // （旧走査器は `!` の後ろを正規表現とみなして `/ c /` を文字列にしていた）。
            XCTAssertEqual(contextual.filter { $0.1 == .string }.map(\.0), ["/[ab]/", "/d/"], name)
            // `break`・`continue` は改行で文が終わる。
            let jumps = tokens("while (x) { break\n/[//]/.test(x) }\nouter: for (;;) { continue outer\n/e/.test(x) }\ny = a\n/ 2 / 3", name)
            XCTAssertEqual(jumps.filter { $0.1 == .string }.map(\.0), ["/[//]/", "/e/"], name)
            // `for await (…)` の後ろも文の始まり。
            XCTAssertTrue(tokens("async function f(xs) { for await (const x of xs) /[//]/.test(x) }", name)
                .contains { $0 == ("/[//]/", .string) }, name)
            // オブジェクトリテラルや呼び出しの閉じ括弧の後ろは除算。
            XCTAssertFalse(control.contains { $0.0.hasPrefix("/ b") || $0.0.hasPrefix("/ h") || $0.0.hasPrefix("/ j") }, name)
            XCTAssertEqual(control.filter { $0.1 == .comment }.map(\.0), ["/* note */"], name)
        }
        // Ruby のコマンド呼び出しの引数。`a / b`、`@n /2` は除算。
        let command = tokens("puts /a#b/\nx = a / b / c\ny = @n /2 # note", "ruby")
        XCTAssertTrue(command.contains { $0 == ("/a#b/", .string) })
        XCTAssertEqual(command.filter { $0.1 == .string }.count, 1)
        XCTAssertTrue(command.contains { $0 == ("# note", .comment) })
        // Ruby の正規表現の中の `#` はコメントではない。
        // 代入済みのローカル変数、ブロック・メソッドの引数の後ろは除算。
        let locals = tokens("a = 12; x = a /2/3\nitems.each { |n| y = n /2/1 }\ndef f(k) k /2/1 end\ndef g k; k /2/1 end\nputs /a#b/", "ruby")
        // Tree-sitter 版：tree-sitter-ruby はローカル変数を追跡しないため、`a /2/3` は `a(/2/3)` と読まれる（既知の制約）。
        // 最後の本物の正規表現は見つかる。
        XCTAssertEqual(locals.filter { $0.1 == .string }.last?.0, "/a#b/")
        // 複合代入の左辺もローカル変数。`!` で終わるメソッドは呼び出し。ブロックの引数はブロックの中だけ。
        let more = tokens("a ||= 12; x = a /2/3\nb += 1; y = b /2/1\nfoo! /a#b/; z = 1\n1.times { |puts| }\nputs /c#d/\n[1].each do |puts| end\nputs /e#f/\nc <= 2; puts c /g#h/", "ruby")
        // 変数の後ろの `/2/` を正規表現と読む制約は上と同じ。本物の正規表現が順に見つかる。
        XCTAssertEqual(more.filter { $0.1 == .string && $0.0.contains("#") }.map(\.0), ["/a#b/", "/c#d/", "/e#f/", "/g#h/"])
        // 多重代入の左辺はすべて変数。ハッシュの `{}` はスコープを作らない。
        let assignments = tokens("a, b = 12, 3; y = a /2/3\nc, *d = 1, 2\nz = c /2/1\nh = { x: (e = 12) }; w = e /2/3\nputs /f#g/", "ruby")
        XCTAssertEqual(assignments.filter { $0.1 == .string && $0.0.contains("#") }.map(\.0), ["/f#g/"])
        // メソッドの中のローカル変数は、外側の同じ名前のメソッド呼び出しに影響しない。
        let scopes = tokens("def f\n  puts = 1\n  if puts > 0\n    x = puts /2/1\n  end\n  y = 3 if puts\nend\nputs /a#b/\nclass C\n  def g; puts = 2; end\nend\nputs /c#d/", "ruby")
        XCTAssertEqual(scopes.filter { $0.1 == .string && $0.0.contains("#") }.map(\.0), ["/a#b/", "/c#d/"])
        // Ruby は改行で文が終わる。括弧の中や行末の `\` は継続。
        // Tree-sitter 版：括弧の中でも改行で文が終わるので、行頭の `/` は正規表現（Ruby の構文どおり。旧走査器は継続とみなしていた）。
        // 行末の `\` は継続なので、次の行頭の `/` は除算。
        let lines = tokens("x = 1\n/a#b/.match(s)\nz = 4 \\\n/ 5 # note", "ruby")
        XCTAssertEqual(lines.filter { $0.1 == .string }.map(\.0), ["/a#b/"])
        XCTAssertEqual(tokens("y = (2\n/ 3)\nz = 4", "ruby").filter { $0.1 == .string }.count, 0)
        XCTAssertTrue(lines.contains { $0 == ("# note", .comment) })
        let ruby = tokens("if cond then /a#b/ else nil end", "ruby")
        XCTAssertTrue(ruby.contains { $0 == ("/a#b/", .string) })
        XCTAssertTrue(ruby.contains { $0 == ("end", .keyword) })
        XCTAssertTrue(tokens("x =~ /a#b/ if y", "ruby").contains { $0 == ("/a#b/", .string) })
        XCTAssertTrue(tokens("x =~ /a#b/ if y", "ruby").contains { $0 == ("if", .keyword) })
    
    }

    func testRubyBlockCommentsOnlyAtColumnZero() {
        let values = tokens("x =begin\n  1\nend\nputs x\n=begin\nif\n  =end\n=end\nreturn", "ruby")
        XCTAssertTrue(values.contains { $0 == ("end", .keyword) })
        // Tree-sitter 版：tree-sitter-ruby は字下げした `  =end` でもブロックコメントを閉じる（Ruby 本体は0桁目だけ。既知の制約）。
        // 行頭の `=begin` から始まるコメントは見つかる。
        XCTAssertTrue(values.contains { $0.1 == .comment && $0.0.hasPrefix("=begin\nif") })
        XCTAssertTrue(values.contains { $0 == ("return", .keyword) })
        XCTAssertEqual(values.filter { $0.1 == .comment }.count, 1)
    }
}
