import AppKit
import XCTest
@testable import MKTownEditor

@MainActor
final class CodeSyntaxHighlighterTests: XCTestCase {
    func testSwiftHighlightSeparatesKeywordsStringsCommentsAndNumbers() {
        let values = tokens("let count = 42\nlet text = \"if // still string\" // comment", "swift")

        XCTAssertTrue(values.contains { $0 == ("let", .keyword) })
        XCTAssertTrue(values.contains { $0 == ("42", .number) })
        XCTAssertTrue(values.contains { $0 == ("\"if // still string\"", .string) })
        XCTAssertTrue(values.contains { $0 == ("// comment", .comment) })
        XCTAssertFalse(values.contains { $0.0 == "if" })
    }

    func testAliasesAndUnsupportedLanguages() {
        XCTAssertTrue(tokens("def work(): # note", "py").contains { $0.1 == .keyword })
        XCTAssertTrue(tokens("const value = 1", "js").contains { $0.1 == .keyword })
        XCTAssertTrue(tokens("{\"ok\": true}", "json").contains { $0.1 == .keyword })
        XCTAssertTrue(tokens("int main() {}", "c++").contains { $0 == ("int", .type) })
        XCTAssertTrue(tokens("let x = 1", "unknown").isEmpty)
        XCTAssertTrue(tokens("let x = 1", nil).isEmpty)
        for plain in ["text", "txt", "plaintext", "Text"] {
            XCTAssertNil(CodeSyntaxTokenizer.language(named: plain), plain)
        }
    }

    func testFenceInfoWithFileNameAttributesOrExtensionSelectsLanguage() {
        XCTAssertEqual(CodeSyntaxTokenizer.language(named: "ruby:app.rb")?.name, "ruby")
        XCTAssertEqual(CodeSyntaxTokenizer.language(named: "{.python}")?.name, "python")
        XCTAssertEqual(CodeSyntaxTokenizer.language(named: "language-go")?.name, "go")
        XCTAssertEqual(CodeSyntaxTokenizer.language(named: "main.cpp")?.name, "cpp")
        XCTAssertEqual(CodeSyntaxTokenizer.language(named: "CPP")?.name, "cpp")
        XCTAssertNil(CodeSyntaxTokenizer.language(named: "notes.txt"))
    }

    func testEveryAliasResolvesToADefinedLanguage() {
        for (alias, canonical) in CodeSyntaxLanguages.aliases {
            XCTAssertNotNil(CodeSyntaxLanguages.all[canonical], alias)
        }
        for language in MarkdownCodeLanguage.allCases where language != .markdown {
            XCTAssertNotNil(CodeSyntaxTokenizer.language(named: language.rawValue), language.rawValue)
        }
    }

    func testCFamilyPreprocessorCharLiteralsAndBlockComments() {
        let values = tokens("#include <stdio.h>\n/* a\n b */\nint main(void) {\n  char c = 'x';\n  return 0x1F;\n}", "c")

        XCTAssertTrue(values.contains { $0 == ("#include", .attribute) })
        XCTAssertTrue(values.contains { $0 == ("<stdio.h>", .string) })
        XCTAssertTrue(values.contains { $0 == ("/* a\n b */", .comment) })
        XCTAssertTrue(values.contains { $0 == ("int", .type) })
        XCTAssertTrue(values.contains { $0 == ("'x'", .string) })
        XCTAssertTrue(values.contains { $0 == ("return", .keyword) })
        XCTAssertTrue(values.contains { $0 == ("0x1F", .number) })
        XCTAssertFalse(values.contains { $0.0 == "main" })
    }

    func testJavaAnnotationsAndCapitalizedTypes() {
        let values = tokens("@Override\npublic String name() { return MAX_SIZE; }", "java")

        XCTAssertTrue(values.contains { $0 == ("@Override", .attribute) })
        XCTAssertTrue(values.contains { $0 == ("public", .keyword) })
        XCTAssertTrue(values.contains { $0 == ("String", .type) })
        XCTAssertFalse(values.contains { $0.0 == "MAX_SIZE" })
    }

    func testRustLifetimesDoNotStartStringsAndMacrosAreMarked() {
        let values = tokens("#[derive(Debug)]\nfn get<'a>(x: &'a str) -> char { println!(\"{}\", x); 'z' }", "rust")

        XCTAssertTrue(values.contains { $0 == ("#[derive(Debug)]", .attribute) })
        XCTAssertTrue(values.contains { $0 == ("fn", .keyword) })
        XCTAssertTrue(values.contains { $0 == ("str", .type) })
        XCTAssertTrue(values.contains { $0 == ("println!", .attribute) })
        XCTAssertTrue(values.contains { $0 == ("\"{}\"", .string) })
        XCTAssertTrue(values.contains { $0 == ("'z'", .string) })
        XCTAssertFalse(values.contains { $0.0.hasPrefix("'a") })
    }

    func testPythonTripleQuotesPrefixesAndDecorators() {
        let values = tokens("@cache\ndef f():\n    \"\"\"doc\n    more\"\"\"\n    return f\"{x}\" # done", "python")

        XCTAssertTrue(values.contains { $0 == ("@cache", .attribute) })
        XCTAssertTrue(values.contains { $0 == ("\"\"\"doc\n    more\"\"\"", .string) })
        XCTAssertTrue(values.contains { $0 == ("f\"{x}\"", .string) })
        XCTAssertTrue(values.contains { $0 == ("# done", .comment) })
    }

    func testShellVariablesAndHashOnlyCommentsAtWordStart() {
        let values = tokens("for f in *.md; do\n  echo \"$f\" ${HOME} $# a#b # note\ndone", "bash")

        XCTAssertTrue(values.contains { $0 == ("for", .keyword) })
        XCTAssertTrue(values.contains { $0 == ("${HOME}", .variable) })
        XCTAssertTrue(values.contains { $0 == ("$#", .variable) })
        XCTAssertTrue(values.contains { $0 == ("# note", .comment) })
        XCTAssertFalse(values.contains { $0.1 == .comment && $0.0.contains("a#b") })
    }

    func testHashCommentsAfterIdentifiersOutsideShellStyleLanguages() {
        // Python などでは識別子や数値の直後の `#` もコメントになる。
        XCTAssertTrue(tokens("x=1#comment", "python").contains { $0 == ("#comment", .comment) })
        XCTAssertTrue(tokens("puts x#note", "ruby").contains { $0 == ("#note", .comment) })
        XCTAssertTrue(tokens("$a=1;#note", "php").contains { $0 == ("#note", .comment) })
        XCTAssertTrue(tokens("$x#note", "powershell").contains { $0 == ("#note", .comment) })
        // シェル系では単語の先頭の `#` だけをコメントにする。
        XCTAssertFalse(tokens("echo a#b", "bash").contains { $0.1 == .comment })
        XCTAssertFalse(tokens("url: a#b", "yaml").contains { $0.1 == .comment })
        XCTAssertFalse(tokens("key = a;b", "ini").contains { $0.1 == .comment })
        XCTAssertFalse(tokens("print $#array", "perl").contains { $0.1 == .comment })
    }

    func testSCSSAndLessLineCommentsKeepURLs() {
        for name in ["scss", "less"] {
            let values = tokens("// return \"x\"\n.a { background: url(http://x/y.png); }", name)
            XCTAssertTrue(values.contains { $0 == ("// return \"x\"", .comment) }, name)
            XCTAssertFalse(values.contains { $0.1 == .comment && $0.0.contains("//x") }, name)
        }
        // 素の CSS には行コメントがない。
        XCTAssertFalse(tokens("// x", "css").contains { $0.1 == .comment })
    }

    func testJavaPropertiesCommentsAndSeparators() {
        let values = tokens("! true\n# note\nname: value\nport = 8080\nkey value\npath=a\\\n  b: c\nk\\:x=1", "properties")

        XCTAssertTrue(values.contains { $0 == ("! true", .comment) })
        XCTAssertTrue(values.contains { $0 == ("# note", .comment) })
        XCTAssertTrue(values.contains { $0 == ("name", .attribute) })
        XCTAssertTrue(values.contains { $0 == ("port", .attribute) })
        XCTAssertTrue(values.contains { $0 == ("key", .attribute) })
        XCTAssertTrue(values.contains { $0 == ("k\\:x", .attribute) })
        // 継続行と値は色分けしない。
        XCTAssertFalse(values.contains { $0.0 == "b" || $0.0 == "true" || $0.0 == "8080" })
        XCTAssertEqual(CodeSyntaxTokenizer.language(named: "ini")?.name, "ini")
    }

    func testMySQLHashCommentsAreDialectSpecific() {
        XCTAssertTrue(tokens("SELECT 1 # note", "mysql").contains { $0 == ("# note", .comment) })
        XCTAssertTrue(tokens("SELECT 1#note", "mariadb").contains { $0 == ("#note", .comment) })
        XCTAssertTrue(tokens("SELECT 1 -- note", "mysql").contains { $0 == ("-- note", .comment) })
        XCTAssertFalse(tokens("SELECT a # b", "postgresql").contains { $0.1 == .comment })
    }

    func testRawStringsWithCustomDelimitersKeepEmbeddedQuotes() {
        let rust = tokens("let s = r#\"a \" if x { return } \" b\"#; let t = br##\"\"#\"##; let p = r\"C:\\\";", "rust")
        XCTAssertTrue(rust.contains { $0 == ("r#\"a \" if x { return } \" b\"#", .string) })
        XCTAssertTrue(rust.contains { $0 == ("br##\"\"#\"##", .string) })
        XCTAssertTrue(rust.contains { $0 == ("r\"C:\\\"", .string) })
        XCTAssertFalse(rust.contains { $0.0 == "if" || $0.0 == "return" })

        let swift = tokens("let s = #\"a \" if \"#\nlet m = ##\"\"\"\n\"# return\n\"\"\"##\n#if DEBUG", "swift")
        XCTAssertTrue(swift.contains { $0 == ("#\"a \" if \"#", .string) })
        XCTAssertTrue(swift.contains { $0 == ("##\"\"\"\n\"# return\n\"\"\"##", .string) })
        XCTAssertTrue(swift.contains { $0 == ("#if", .attribute) })
        XCTAssertFalse(swift.contains { $0.0 == "if" || $0.0 == "return" })

        let cpp = tokens("auto s = R\"x(a \" if )\" return)x\"; auto t = u8R\"(q)\";", "cpp")
        XCTAssertTrue(cpp.contains { $0 == ("R\"x(a \" if )\" return)x\"", .string) })
        XCTAssertTrue(cpp.contains { $0 == ("u8R\"(q)\"", .string) })
        XCTAssertFalse(cpp.contains { $0.0 == "if" || $0.0 == "return" })
    }

    func testLuaLongBracketsUseTheirLevel() {
        let values = tokens("--[==[ a ]] if ]==]\nlocal s = [=[ x ]] return ]=]\n-- [x\nlocal t = 1", "lua")
        XCTAssertTrue(values.contains { $0 == ("--[==[ a ]] if ]==]", .comment) })
        XCTAssertTrue(values.contains { $0 == ("[=[ x ]] return ]=]", .string) })
        XCTAssertTrue(values.contains { $0 == ("-- [x", .comment) })
        XCTAssertFalse(values.contains { $0.0 == "if" || $0.0 == "return" })
        XCTAssertTrue(values.contains { $0 == ("local", .keyword) })
    }

    func testDashCommentRulesPerDialect() {
        // MySQL は `--` の直後に空白が必要。
        XCTAssertFalse(tokens("SELECT 1--2 AS n", "mysql").contains { $0.1 == .comment })
        XCTAssertTrue(tokens("SELECT 1 --\tnote", "mysql").contains { $0 == ("--\tnote", .comment) })
        XCTAssertTrue(tokens("SELECT 1 --", "mysql").contains { $0 == ("--", .comment) })
        XCTAssertTrue(tokens("SELECT 1--2", "sql").contains { $0 == ("--2", .comment) })
        // Haskell の `-->` は演算子、`---` はコメント。
        XCTAssertFalse(tokens("a --> b", "haskell").contains { $0.1 == .comment })
        XCTAssertTrue(tokens("x = 1 --- note", "haskell").contains { $0 == ("--- note", .comment) })
        XCTAssertTrue(tokens("x = 1 -- | doc", "haskell").contains { $0 == ("-- | doc", .comment) })
    }

    func testJSON5SingleQuotedStringsAndUnquotedKeys() {
        let values = tokens("{'value': 'true', count: 1, \"q\": Infinity}", "json5")
        XCTAssertTrue(values.contains { $0 == ("'value'", .attribute) })
        XCTAssertTrue(values.contains { $0 == ("'true'", .string) })
        XCTAssertTrue(values.contains { $0 == ("count", .attribute) })
        XCTAssertTrue(values.contains { $0 == ("\"q\"", .attribute) })
        XCTAssertTrue(values.contains { $0 == ("Infinity", .keyword) })
        XCTAssertFalse(values.contains { $0 == ("true", .keyword) })
        // 素の JSON は従来どおり。
        XCTAssertFalse(tokens("{count: 1}", "json").contains { $0.1 == .attribute })
    }

    func testTOMLHashCommentsWithoutWhitespaceButINIKeepsValues() {
        XCTAssertTrue(tokens("key=1#comment", "toml").contains { $0 == ("#comment", .comment) })
        XCTAssertFalse(tokens("key=a;b", "toml").contains { $0.1 == .comment })
        XCTAssertFalse(tokens("key=a#b;c", "ini").contains { $0.1 == .comment })
        XCTAssertTrue(tokens("; note\nkey=1 ; tail", "ini").contains { $0 == ("; tail", .comment) })
        XCTAssertEqual(CodeSyntaxTokenizer.language(named: "cfg")?.name, "ini")
    }

    func testRawAndVerbatimStringsIgnoreBackslashEscapes() {
        let dart = tokens("var s = r\"C:\\\"; return 1;\nvar t = r'''a\\''';", "dart")
        XCTAssertTrue(dart.contains { $0 == ("r\"C:\\\"", .string) })
        XCTAssertTrue(dart.contains { $0 == ("return", .keyword) })
        XCTAssertTrue(dart.contains { $0 == ("r'''a\\'''", .string) })
        // 通常の文字列は従来どおりエスケープを扱う。
        XCTAssertTrue(tokens("var s = \"a\\\" b\";", "dart").contains { $0 == ("\"a\\\" b\"", .string) })

        let csharp = tokens("var p = @\"C:\\\"; return $@\"a \"\"q\"\" {x}\"; var e = \"\\\"\";", "cs")
        XCTAssertTrue(csharp.contains { $0 == ("@\"C:\\\"", .string) })
        XCTAssertTrue(csharp.contains { $0 == ("return", .keyword) })
        XCTAssertTrue(csharp.contains { $0 == ("$@\"a \"\"q\"\" {x}\"", .string) })
        XCTAssertTrue(csharp.contains { $0 == ("\"\\\"\"", .string) })
    }

    func testYAMLBlockScalarBodiesAreNotTokenized() {
        let yaml = """
            message: |
              true # literal
              key: value
            folded: >-
              1 # text

              - item: x
            items:
              - |
                null
            after: true # real
            """
        let values = tokens(yaml, "yaml")
        XCTAssertTrue(values.contains { $0 == ("message", .attribute) })
        XCTAssertTrue(values.contains { $0 == ("folded", .attribute) })
        XCTAssertTrue(values.contains { $0 == ("after", .attribute) })
        XCTAssertTrue(values.contains { $0 == ("true", .keyword) })
        XCTAssertTrue(values.contains { $0 == ("# real", .comment) })
        XCTAssertEqual(values.filter { $0.1 == .keyword }.count, 1)
        XCTAssertFalse(values.contains { $0.0 == "# literal" || $0.0 == "# text" || $0.0 == "key" || $0.0 == "1" })
        XCTAssertFalse(values.contains { $0.0 == "item" || $0.0 == "null" })
    }

    func testSQLQuotedIdentifiersAreNotTokenized() {
        let values = tokens("SELECT \"select\" FROM \"from\" WHERE a = 'x'", "sql")
        XCTAssertEqual(values.filter { $0.1 == .keyword }.map(\.0), ["SELECT", "FROM", "WHERE"])
        XCTAssertFalse(values.contains { $0.0.contains("\"") })
        let mysql = tokens("SELECT `select`, \"text\" FROM t", "mysql")
        XCTAssertEqual(mysql.filter { $0.1 == .keyword }.map(\.0), ["SELECT", "FROM"])
        XCTAssertTrue(mysql.contains { $0 == ("\"text\"", .string) })
    }

    func testCSharpTripleQuotedRawStringsIgnoreBackslashes() {
        let values = tokens("var path = \"\"\"C:\\\"\"\"; return 1;", "csharp")
        XCTAssertTrue(values.contains { $0 == ("\"\"\"C:\\\"\"\"", .string) })
        XCTAssertTrue(values.contains { $0 == ("return", .keyword) })
    }

    func testVariableWidthRawStringDelimiters() {
        let csharp = tokens("var a = \"\"\"\"text \"\"\" still text\"\"\"\"; return 1;\nvar b = \"\"\"\"\"\n\"\"\"\" if\n\"\"\"\"\";", "csharp")
        XCTAssertTrue(csharp.contains { $0 == ("\"\"\"\"text \"\"\" still text\"\"\"\"", .string) })
        XCTAssertTrue(csharp.contains { $0 == ("\"\"\"\"\"\n\"\"\"\" if\n\"\"\"\"\"", .string) })
        XCTAssertTrue(csharp.contains { $0 == ("return", .keyword) })
        XCTAssertFalse(csharp.contains { $0.0 == "if" })

        let swift = tokens("let s = ##\"\"\"\n  a \"## return\n  \"\"\"##\nlet e = #\"\"#; return", "swift")
        XCTAssertTrue(swift.contains { $0 == ("##\"\"\"\n  a \"## return\n  \"\"\"##", .string) })
        XCTAssertTrue(swift.contains { $0 == ("#\"\"#", .string) })
        XCTAssertEqual(swift.filter { $0.0 == "return" }.count, 1)
    }

    func testBracketsInsideQuotedArgumentsDoNotCloseAttributesOrSections() {
        let rust = tokens("#[doc = \"]\"]\nfn f() {}", "rust")
        XCTAssertTrue(rust.contains { $0 == ("#[doc = \"]\"]", .attribute) })
        XCTAssertTrue(rust.contains { $0 == ("fn", .keyword) })

        let php = tokens("#[Route(\"/a]b\")] public function f() {}\n#[Attr(\n  'x'\n)]\nclass C {}", "php")
        XCTAssertTrue(php.contains { $0 == ("#[Route(\"/a]b\")]", .attribute) })
        XCTAssertTrue(php.contains { $0 == ("#[Attr(\n  'x'\n)]", .attribute) })
        XCTAssertTrue(php.contains { $0 == ("public", .keyword) })
        XCTAssertTrue(php.contains { $0 == ("class", .keyword) })

        let toml = tokens("[\"a]b\".c]\n[[items]]\nk = 1", "toml")
        XCTAssertTrue(toml.contains { $0 == ("[\"a]b\".c]", .type) })
        XCTAssertTrue(toml.contains { $0 == ("[[items]]", .type) })
        XCTAssertTrue(toml.contains { $0 == ("k", .attribute) })
    }

    func testDockerfileCommentsOnlyAtLineStart() {
        let values = tokens("# syntax\n  # indented\nENV FOO value # literal\nCOPY source #destination", "dockerfile")
        XCTAssertTrue(values.contains { $0 == ("# syntax", .comment) })
        XCTAssertTrue(values.contains { $0 == ("# indented", .comment) })
        XCTAssertEqual(values.filter { $0.1 == .comment }.count, 2)
        XCTAssertTrue(values.contains { $0 == ("COPY", .keyword) })
    }

    func testRubyBlockCommentsOnlyAtColumnZero() {
        let values = tokens("x =begin\n  1\nend\nputs x\n=begin\nif\n  =end\n=end\nreturn", "ruby")
        XCTAssertTrue(values.contains { $0 == ("end", .keyword) })
        XCTAssertTrue(values.contains { $0 == ("=begin\nif\n  =end\n=end", .comment) })
        XCTAssertTrue(values.contains { $0 == ("return", .keyword) })
        XCTAssertEqual(values.filter { $0.1 == .comment }.count, 1)
    }

    func testProtocolRelativeURLsAreNotSCSSComments() {
        for name in ["scss", "less"] {
            let values = tokens(".a { background: url(//cdn.example/a.png); color: red; } // note", name)
            XCTAssertTrue(values.contains { $0 == ("//cdn.example/a.png", .string) }, name)
            XCTAssertTrue(values.contains { $0 == ("color", .attribute) }, name)
            XCTAssertTrue(values.contains { $0 == ("// note", .comment) }, name)
            XCTAssertEqual(values.filter { $0.1 == .comment }.count, 1, name)
        }
        XCTAssertTrue(tokens("@import url(\"//x\");", "scss").contains { $0 == ("\"//x\"", .string) })
    }

    func testYAMLFlowMappingKeys() {
        let values = tokens("value: { enabled: true, other: null, nested: { my-key: 1 } }\n{ \"top\": yes }\nlist: [a, b]", "yaml")
        for key in ["value", "enabled", "other", "nested", "my-key", "\"top\"", "list"] {
            XCTAssertTrue(values.contains { $0 == (key, .attribute) }, key)
        }
        XCTAssertTrue(values.contains { $0 == ("true", .keyword) })
        XCTAssertTrue(values.contains { $0 == ("yes", .keyword) })
        XCTAssertFalse(values.contains { $0.0 == "a" || $0.0 == "b" })
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
            // 変数名の `of`、非 null アサーション `x!` の後ろは除算。`for (x of /re/)` と前置の `!` の後ろは正規表現。
            let contextual = tokens("const of = 12; const q = of / b / g\nconst r = x! / c / g\nfor (const m of /[ab]/.exec(s)) {}\nconst n = !/d/.test(s)", name)
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
        // Ruby・Perl のコマンド呼び出しの引数。`a / b`、`$x /2` は除算。
        let command = tokens("puts /a#b/\nx = a / b / c\ny = @n /2 # note", "ruby")
        XCTAssertTrue(command.contains { $0 == ("/a#b/", .string) })
        XCTAssertEqual(command.filter { $0.1 == .string }.count, 1)
        XCTAssertTrue(command.contains { $0 == ("# note", .comment) })
        XCTAssertTrue(tokens("print /a#b/;\nmy $y = $x /2; # note", "perl").contains { $0 == ("/a#b/", .string) })
        XCTAssertTrue(tokens("my $y = $x /2; # note", "perl").contains { $0 == ("# note", .comment) })
        // Ruby と Perl の正規表現の中の `#` はコメントではない。
        // 代入済みのローカル変数、ブロック・メソッドの引数の後ろは除算。
        let locals = tokens("a = 12; x = a /2/3\nitems.each { |n| y = n /2/1 }\ndef f(k) k /2/1 end\ndef g k; k /2/1 end\nputs /a#b/", "ruby")
        XCTAssertEqual(locals.filter { $0.1 == .string }.map(\.0), ["/a#b/"])
        // メソッドの中のローカル変数は、外側の同じ名前のメソッド呼び出しに影響しない。
        let scopes = tokens("def f\n  puts = 1\n  if puts > 0\n    x = puts /2/1\n  end\n  y = 3 if puts\nend\nputs /a#b/\nclass C\n  def g; puts = 2; end\nend\nputs /c#d/", "ruby")
        XCTAssertEqual(scopes.filter { $0.1 == .string }.map(\.0), ["/a#b/", "/c#d/"])
        // Ruby は改行で文が終わる。括弧の中や行末の `\` は継続。
        let lines = tokens("x = 1\n/a#b/.match(s)\ny = (2\n/ 3)\nz = 4 \\\n/ 5 # note", "ruby")
        XCTAssertEqual(lines.filter { $0.1 == .string }.map(\.0), ["/a#b/"])
        XCTAssertTrue(lines.contains { $0 == ("# note", .comment) })
        let ruby = tokens("if cond then /a#b/ else nil end", "ruby")
        XCTAssertTrue(ruby.contains { $0 == ("/a#b/", .string) })
        XCTAssertTrue(ruby.contains { $0 == ("end", .keyword) })
        XCTAssertTrue(tokens("x =~ /a#b/ if y", "ruby").contains { $0 == ("/a#b/", .string) })
        XCTAssertTrue(tokens("x =~ /a#b/ if y", "ruby").contains { $0 == ("if", .keyword) })
        XCTAssertTrue(tokens("if ($x =~ /a#b/) { print 1 }", "perl").contains { $0 == ("print", .keyword) })
    }

    func testTOMLQuotedKeysMayContainEqualsAndHash() {
        let values = tokens("'a=b' = 1\n\"c#d\" = 2\na.\"e=f\".g = 3 # note", "toml")
        for key in ["'a=b'", "\"c#d\"", "a.\"e=f\".g"] {
            XCTAssertTrue(values.contains { $0 == (key, .attribute) }, key)
        }
        XCTAssertTrue(values.contains { $0 == ("# note", .comment) })
        XCTAssertEqual(values.filter { $0.1 == .comment }.count, 1)
    }

    func testTOMLBareKeysStartingWithDigitsOrDashes() {
        let values = tokens("1234 = \"value\"\n- = true\nbare-key_1 = 2\n'lit' = 3", "toml")
        for key in ["1234", "-", "bare-key_1", "'lit'"] {
            XCTAssertTrue(values.contains { $0 == (key, .attribute) }, key)
        }
        XCTAssertFalse(values.contains { $0 == ("1234", .number) })
    }

    func testPHPAttributesAreNotComments() {
        let values = tokens("#[Route(\"/x\")]\npublic function index() {} # note", "php")
        XCTAssertTrue(values.contains { $0 == ("#[Route(\"/x\")]", .attribute) })
        XCTAssertTrue(values.contains { $0 == ("public", .keyword) })
        XCTAssertTrue(values.contains { $0 == ("# note", .comment) })
    }

    func testPowerShellBacktickEscapes() {
        let values = tokens("$m = \"message: `\"return`\"\"; $p = \"C:\\\"; if ($x) {}", "powershell")
        XCTAssertTrue(values.contains { $0 == ("\"message: `\"return`\"\"", .string) })
        XCTAssertTrue(values.contains { $0 == ("\"C:\\\"", .string) })
        XCTAssertTrue(values.contains { $0 == ("if", .keyword) })
        XCTAssertFalse(values.contains { $0.0 == "return" })
    }

    func testHashCommentBoundariesPerDialect() {
        // YAML と INI は直前に空白が必要。
        XCTAssertFalse(tokens("url: https://host/#fragment", "yaml").contains { $0.1 == .comment })
        XCTAssertTrue(tokens("url: https://host/ #note", "yaml").contains { $0 == ("#note", .comment) })
        XCTAssertFalse(tokens("key=a/#b", "ini").contains { $0.1 == .comment })
        // シェルは単語の先頭なら演算子の直後でもコメント。
        XCTAssertTrue(tokens("ls;#note", "bash").contains { $0 == ("#note", .comment) })
        XCTAssertFalse(tokens("echo a/#b ${#x}", "bash").contains { $0.1 == .comment })
        // Perl は `$#` 以外。
        XCTAssertTrue(tokens("print a#note", "perl").contains { $0 == ("#note", .comment) })
    }

    func testSQLKeywordsIgnoreCase() {
        let values = tokens("SELECT id FROM users WHERE name = 'a' -- note", "sql")

        XCTAssertTrue(values.contains { $0 == ("SELECT", .keyword) })
        XCTAssertTrue(values.contains { $0 == ("FROM", .keyword) })
        XCTAssertTrue(values.contains { $0 == ("'a'", .string) })
        XCTAssertTrue(values.contains { $0 == ("-- note", .comment) })
    }

    func testJSONKeysAndYAMLKeysAreAttributes() {
        let json = tokens("{\"name\": \"value\", \"n\": 1}", "json")
        XCTAssertTrue(json.contains { $0 == ("\"name\"", .attribute) })
        XCTAssertTrue(json.contains { $0 == ("\"value\"", .string) })
        XCTAssertTrue(json.contains { $0 == ("1", .number) })

        let yaml = tokens("server:\n  - host: example.com # main\n    enabled: true\nurl: http://x", "yml")
        XCTAssertTrue(yaml.contains { $0 == ("server", .attribute) })
        XCTAssertTrue(yaml.contains { $0 == ("host", .attribute) })
        XCTAssertTrue(yaml.contains { $0 == ("enabled", .attribute) })
        XCTAssertTrue(yaml.contains { $0 == ("true", .keyword) })
        XCTAssertTrue(yaml.contains { $0 == ("# main", .comment) })
        XCTAssertFalse(yaml.contains { $0.0.contains("//x") })
    }

    func testMarkupTagsAttributesAndComments() {
        let values = tokens("<!-- c -->\n<a href=\"/x\" data-id=7>&amp;</a>", "html")

        XCTAssertTrue(values.contains { $0 == ("<!-- c -->", .comment) })
        XCTAssertTrue(values.contains { $0 == ("a", .keyword) })
        XCTAssertTrue(values.contains { $0 == ("href", .attribute) })
        XCTAssertTrue(values.contains { $0 == ("\"/x\"", .string) })
        XCTAssertTrue(values.contains { $0 == ("data-id", .attribute) })
        XCTAssertTrue(values.contains { $0 == ("7", .string) })
        XCTAssertTrue(values.contains { $0 == ("&amp;", .variable) })
        // 閉じタグも名前だけを色分けする。
        XCTAssertEqual(values.filter { $0.1 == .keyword }.map(\.0), ["a", "a"])
    }

    func testCSSSelectorsPropertiesAndValues() {
        let values = tokens(".box:hover { margin: 4px; color: #fff !important; }", "css")

        XCTAssertTrue(values.contains { $0 == (".box", .type) })
        XCTAssertTrue(values.contains { $0 == (":hover", .type) })
        XCTAssertTrue(values.contains { $0 == ("margin", .attribute) })
        XCTAssertTrue(values.contains { $0 == ("4px", .number) })
        XCTAssertTrue(values.contains { $0 == ("#fff", .number) })
        XCTAssertTrue(values.contains { $0 == ("!important", .keyword) })
    }

    func testDiffLines() {
        let values = tokens("--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n same", "diff")

        XCTAssertTrue(values.contains { $0 == ("--- a/x", .keyword) })
        XCTAssertTrue(values.contains { $0 == ("@@ -1 +1 @@", .attribute) })
        XCTAssertTrue(values.contains { $0 == ("-old", .deleted) })
        XCTAssertTrue(values.contains { $0 == ("+new", .inserted) })
        XCTAssertFalse(values.contains { $0.0 == " same" })
    }

    func testDiffHunkLinesStartingWithDashesAreChangesNotHeaders() {
        let diff = """
            diff --git a/q.sql b/q.sql
            --- a/q.sql
            +++ b/q.sql
            @@ -1,2 +1,2 @@
            --- old comment
            +++ new line
             same
            --- a/next.sql
            +++ b/next.sql
            @@ -3 +3 @@
            -x
            +y
            """
        let values = tokens(diff, "diff")
        XCTAssertTrue(values.contains { $0 == ("--- a/q.sql", .keyword) })
        XCTAssertTrue(values.contains { $0 == ("--- old comment", .deleted) })
        XCTAssertTrue(values.contains { $0 == ("+++ new line", .inserted) })
        // ハンクの行数を使い切った後は、次のファイルの見出しとして扱う。
        XCTAssertTrue(values.contains { $0 == ("--- a/next.sql", .keyword) })
        XCTAssertTrue(values.contains { $0 == ("+++ b/next.sql", .keyword) })
        XCTAssertTrue(values.contains { $0 == ("-x", .deleted) })
        XCTAssertTrue(values.contains { $0 == ("+y", .inserted) })
    }

    func testUnterminatedConstructsStopAtBlockEndAndRangesStayInBounds() {
        let sources = ["\"open", "/* open", "'", "#", "@", "0x", "<a href=", "<!--", "${", "#[", "`"]
        for name in Set(CodeSyntaxLanguages.aliases.values) {
            for source in sources {
                let length = (source as NSString).length
                for token in CodeSyntaxTokenizer.tokens(in: source, language: name) {
                    XCTAssertGreaterThan(token.range.length, 0, "\(name) \(source)")
                    XCTAssertLessThanOrEqual(NSMaxRange(token.range), length, "\(name) \(source)")
                }
            }
        }
    }

    func testTokensAreOrderedAndUseUTF16Offsets() {
        let source = "let 😀 = \"日本語\" // 説明"
        let result = CodeSyntaxTokenizer.tokens(in: source, language: "swift")
        XCTAssertEqual(result.map(\.range.location), result.map(\.range.location).sorted())
        let text = source as NSString
        XCTAssertTrue(result.contains { text.substring(with: $0.range) == "\"日本語\"" && $0.token == .string })
        XCTAssertTrue(result.contains { text.substring(with: $0.range) == "// 説明" && $0.token == .comment })
    }

    func testRendererUsesFenceLanguageAndPreservesPlainFallback() throws {
        let highlighted = MarkdownRenderer.render("```swift\nlet x = 1\n```")
        let plain = MarkdownRenderer.render("```unknown\nlet x = 1\n```")
        let keyword = (highlighted.string as NSString).range(of: "let")
        XCTAssertEqual(highlighted.attribute(.foregroundColor, at: keyword.location,
                                             effectiveRange: nil) as? NSColor,
                       CodeSyntaxPalette.color(for: .keyword))
        XCTAssertEqual(highlighted.attribute(.codeSyntaxToken, at: keyword.location,
                                             effectiveRange: nil) as? String, "keyword")
        XCTAssertEqual(plain.attribute(.foregroundColor, at: keyword.location,
                                       effectiveRange: nil) as? NSColor, .textColor)
        XCTAssertEqual(highlighted.string, plain.string)
        XCTAssertNotNil(highlighted.attribute(.font, at: keyword.location, effectiveRange: nil))
    }

    func testPaperThemeRecolorsTokensAndExtensionThemeKeepsCodeColor() throws {
        let rendered = CodeSyntaxHighlighter.render("let x = \"a\"", language: "swift")
        let paper = PreviewTypography.themed(rendered, kind: .codeBlock, theme: .paper)
        XCTAssertEqual(paper.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       CodeSyntaxPalette.color(CodeSyntaxPalette.paper[.keyword]!))
        XCTAssertEqual(paper.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor,
                       PreviewTheme.paper.codeColor)

        let theme = DeclarativeExtension.Theme(name: "Ink", background: "#FFFFFF", body: "#000000",
                                               heading: "#000000", code: "#111111", link: "#000080",
                                               codeBackground: "#F0F0F0")
        let custom = PreviewTypography.themed(rendered, kind: .codeBlock, theme: .extensionTheme(theme))
        XCTAssertEqual(custom.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       theme.color(\.code))
    }

    func testPalettesMeetTextContrastAgainstCodeBackgrounds() throws {
        let backgrounds: [(String, [CodeSyntaxToken: String], [String])] = [
            // システムの白・暗い背景と、HTML の `pre` が文字色を 8% 混ぜた背景。
            ("light", CodeSyntaxPalette.light, ["#FFFFFF", "#EBEBEB"]),
            ("dark", CodeSyntaxPalette.dark, ["#1E1E1E", "#323232"]),
            ("paper", CodeSyntaxPalette.paper, ["#E8DEC9"])
        ]
        for (name, palette, colors) in backgrounds {
            XCTAssertEqual(Set(palette.keys), Set(CodeSyntaxToken.allCases), name)
            for (token, hex) in palette {
                for background in colors {
                    let ratio = PreviewTypography.contrastRatio(CodeSyntaxPalette.color(hex),
                                                                CodeSyntaxPalette.color(background))
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name) \(token) on \(background)")
                }
            }
        }
    }

    func testDynamicColorsFollowAppearance() throws {
        let color = CodeSyntaxPalette.color(for: .keyword)
        for (appearance, hex) in [(NSAppearance.Name.aqua, CodeSyntaxPalette.light[.keyword]!),
                                  (.darkAqua, CodeSyntaxPalette.dark[.keyword]!)] {
            var resolved: NSColor?
            try XCTUnwrap(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
                resolved = color.usingColorSpace(.sRGB)
            }
            let expected = CodeSyntaxPalette.color(hex)
            XCTAssertEqual(resolved?.redComponent ?? -1, expected.redComponent, accuracy: 0.01)
            XCTAssertEqual(resolved?.blueComponent ?? -1, expected.blueComponent, accuracy: 0.01)
        }
    }

    // MARK: - HTML

    func testHTMLExportWrapsTokensInEscapedSpans() {
        let html = MarkdownHTMLExporter.render("```cpp\nif (a < b) return \"<x>\";\n```", documentURL: nil)

        XCTAssertTrue(html.contains("<code class=\"language-cpp\"><span class=\"tok-keyword\">if</span> (a &lt; b) "
                                    + "<span class=\"tok-keyword\">return</span> "
                                    + "<span class=\"tok-string\">&quot;&lt;x&gt;&quot;</span>;</code>"), html)
        XCTAssertTrue(html.contains(".tok-keyword { color: \(CodeSyntaxPalette.light[.keyword]!); }"))
        XCTAssertTrue(html.contains("prefers-color-scheme: dark) { .tok-keyword { color: \(CodeSyntaxPalette.dark[.keyword]!); }"))
    }

    func testHTMLExportLeavesPlainAndUnknownCodeUnchanged() {
        let html = MarkdownHTMLExporter.render("```text\nif <x>\n```\n\n```\nlet y\n```", documentURL: nil)
        XCTAssertTrue(html.contains("<code class=\"language-text\">if &lt;x&gt;</code>"), html)
        XCTAssertTrue(html.contains("<pre><code>let y</code></pre>"), html)
        XCTAssertFalse(html.contains("<span class=\"tok-"))
    }

    func testPrintLayoutUsesOnlyLightTokenColors() throws {
        let styles = MarkdownHTMLExporter.codeTokenStyles(printLayout: true)
        XCTAssertFalse(styles.contains("prefers-color-scheme"))

        let view = try MarkdownPDFExporter.printableView("```swift\nlet x = 1\n```", documentURL: nil,
                                                          printInfo: NSPrintInfo())
        let storage = try XCTUnwrap(view.textStorage)
        let keyword = (storage.string as NSString).range(of: "let")
        let color = try XCTUnwrap(storage.attribute(.foregroundColor, at: keyword.location,
                                                    effectiveRange: nil) as? NSColor).usingColorSpace(.sRGB)
        let expected = CodeSyntaxPalette.color(CodeSyntaxPalette.light[.keyword]!)
        XCTAssertEqual(color?.redComponent ?? -1, expected.redComponent, accuracy: 0.02)
        XCTAssertEqual(color?.greenComponent ?? -1, expected.greenComponent, accuracy: 0.02)
    }

    private func tokens(_ source: String, _ language: String?) -> [(String, CodeSyntaxToken)] {
        let text = source as NSString
        return CodeSyntaxTokenizer.tokens(in: source, language: language).map {
            (text.substring(with: $0.range), $0.token)
        }
    }
}
