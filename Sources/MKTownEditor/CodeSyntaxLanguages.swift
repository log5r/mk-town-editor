import Foundation

/// フェンスの言語名ごとの字句規則。キーワードは各言語の予約語と、よく使う文脈キーワードに限る。
enum CodeSyntaxLanguages {
    /// フェンスに書かれる名前・拡張子から正規名への対応。`text` などは色分けしない指定として `nil` 側に置く。
    static let aliases: [String: String] = {
        let groups: [String: [String]] = [
            "c": ["c", "h"],
            "cpp": ["cpp", "c++", "cc", "cxx", "hpp", "hxx", "hh", "cplusplus", "arduino", "ino"],
            "csharp": ["csharp", "cs", "c#"],
            "java": ["java"],
            "kotlin": ["kotlin", "kt", "kts"],
            "scala": ["scala", "sc"],
            "swift": ["swift"],
            "objectivec": ["objectivec", "objective-c", "objc", "m", "mm", "objective-c++", "objc++"],
            "go": ["go", "golang"],
            "rust": ["rust", "rs"],
            "dart": ["dart"],
            "javascript": ["javascript", "js", "jsx", "mjs", "cjs", "node"],
            "typescript": ["typescript", "ts", "tsx", "mts", "cts"],
            "python": ["python", "py", "python3", "py3", "pyw"],
            "ruby": ["ruby", "rb", "rake", "gemspec"],
            "php": ["php"],
            "lua": ["lua"],
            "perl": ["perl", "pl", "pm"],
            "shell": ["shell", "sh", "bash", "zsh", "ksh", "shellscript", "shell-script"],
            "powershell": ["powershell", "ps1", "psm1", "pwsh", "ps"],
            "sql": ["sql", "postgresql", "postgres", "psql", "sqlite", "plsql", "tsql"],
            "mysql": ["mysql", "mariadb"],
            "json": ["json", "jsonc", "geojson"],
            "json5": ["json5"],
            "yaml": ["yaml", "yml"],
            "toml": ["toml"],
            "ini": ["ini", "cfg", "editorconfig"],
            "properties": ["properties"],
            "markup": ["html", "htm", "xhtml", "xml", "svg", "plist", "xsl", "xslt", "rss", "atom", "vue", "storyboard", "xib"],
            "css": ["css"],
            "scss": ["scss", "less"],
            "diff": ["diff", "patch"],
            "dockerfile": ["dockerfile", "docker", "containerfile"],
            "haskell": ["haskell", "hs"]
        ]
        var result: [String: String] = [:]
        for (canonical, names) in groups {
            for name in names { result[name] = canonical }
        }
        return result
    }()

    /// 色分けしない指定。未対応の言語と同じく原文の色で表示する。
    static let plainText: Set<String> = ["text", "txt", "plain", "plaintext", "none", "nohighlight", "output"]

    static let all: [String: CodeSyntaxLanguage] = {
        Dictionary(uniqueKeysWithValues: definitions.map { ($0.name, $0) })
    }()

    private static func words(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: \.isWhitespace).map(String.init))
    }

    private static func units(_ texts: String...) -> [[UInt16]] {
        texts.map { Array($0.utf16) }
    }

    private typealias Delimiter = CodeSyntaxLanguage.Delimiter

    private static let cStyleComments = (line: units("//"), block: [Delimiter("/*", "*/")])
    private static let quotedStrings = [Delimiter("\"", multiline: false), Delimiter("'", multiline: false)]
    private static func ascii(_ scalar: Unicode.Scalar) -> UInt16 { UInt16(scalar.value) }
    private static let at = ascii("@"), dollar = ascii("$"), hash = ascii("#")

    private static let cKeywords = """
        auto break case const continue default do else enum extern for goto if inline register restrict \
        return sizeof static struct switch typedef union volatile while _Alignas _Alignof _Atomic _Generic \
        _Noreturn _Static_assert _Thread_local true false NULL
        """
    private static let cTypes = """
        char double float int long short signed unsigned void bool _Bool _Complex size_t ssize_t ptrdiff_t \
        intptr_t uintptr_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t wchar_t FILE
        """
    private static let javaScriptKeywords = """
        await break case catch class const continue debugger default delete do else export extends false \
        finally for function if import in instanceof let new null of return static super switch this throw \
        true try typeof undefined var void while with yield async get set from as
        """

    private static let sql = CodeSyntaxLanguage("sql") {
        $0.keywords = words("""
            select from where and or not insert into values update set delete create table drop alter add \
            column index view as join inner left right outer full cross on group by order having limit offset \
            union all distinct case when then else end is null like ilike in between exists primary key \
            foreign references default constraint unique check if begin commit rollback transaction with \
            recursive returning asc desc true false grant revoke database schema procedure function trigger \
            declare replace natural using over partition window
            """)
        $0.types = words("""
            int integer bigint smallint tinyint decimal numeric float real double precision char varchar text \
            nvarchar nchar date time timestamp timestamptz datetime interval boolean bool blob bytea json jsonb \
            uuid serial bigserial
            """)
        $0.caseInsensitive = true
        $0.lineComments = units("--")
        $0.blockComments = cStyleComments.block
        // 標準 SQL の `"name"` は識別子。中のキーワードを色分けしない。
        $0.strings = [Delimiter("'", escapes: false), Delimiter("\"", token: nil)]
    }

    /// MySQL は `#` もコメントにする（PostgreSQL では演算子のため既定の SQL には含めない）。
    private static let mysql = CodeSyntaxLanguage("mysql", basedOn: sql) {
        $0.lineComments = units("--", "#")
        $0.dashComments = .whitespaceAfter
        $0.strings = [Delimiter("'"), Delimiter("\""), Delimiter("`", token: nil)]
    }

    private static let json = CodeSyntaxLanguage("json") {
        $0.keywords = ["true", "false", "null"]
        $0.lineComments = cStyleComments.line
        $0.blockComments = cStyleComments.block
        $0.strings = [Delimiter("\"", multiline: false)]
        $0.stringKeys = true
    }

    /// JSON5 は単一引用符の文字列と、引用符のないキーを書ける。
    private static let json5 = CodeSyntaxLanguage("json5", basedOn: json) {
        $0.keywords.formUnion(["Infinity", "NaN"])
        $0.strings = [Delimiter("\""), Delimiter("'")]
        $0.identifierKeys = true
    }

    /// TOML は文字列の外の `#` を、直前の文字によらずコメントにする（`key=1#note`）。
    private static let toml = CodeSyntaxLanguage("toml") {
        $0.keywords = ["true", "false"]
        $0.lineComments = units("#")
        $0.strings = [Delimiter("\"\"\""), Delimiter("'''", escapes: false),
                      Delimiter("\"", multiline: false), Delimiter("'", escapes: false, multiline: false)]
        $0.lineKeys = .ini
    }

    /// INI は `;` もコメントだが、値の途中の `a;b` や `a#b` はコメントにしない。
    private static let ini = CodeSyntaxLanguage("ini", basedOn: toml) {
        $0.lineComments = units("#", ";")
        $0.hashComments = .afterWhitespace
    }

    private static let css = CodeSyntaxLanguage("css") {
        $0.keywords = words("""
            auto none inherit initial unset revert normal bold italic block inline flex grid absolute relative \
            fixed sticky solid dashed hidden visible transparent
            """)
        $0.blockComments = cStyleComments.block
        $0.strings = quotedStrings
        $0.identifierExtras = [ascii("-")]
        $0.prefixedIdentifiers = [at: .keyword, dollar: .variable]
        $0.css = true
    }

    /// SCSS と Less は `//` の行コメントも書ける。`url(http://…)` の `//` はコメントにしない。
    private static let scss = CodeSyntaxLanguage("scss", basedOn: css) {
        $0.lineComments = cStyleComments.line
    }

    private static let definitions: [CodeSyntaxLanguage] = [
        CodeSyntaxLanguage("c") {
            $0.keywords = words(cKeywords)
            $0.types = words(cTypes)
            $0.lineComments = cStyleComments.line
            $0.blockComments = cStyleComments.block
            $0.strings = [Delimiter("\"", multiline: false)]
            $0.charLiterals = true
            $0.stringPrefixes = ["L", "u", "U", "u8"]
            $0.preprocessor = true
        },
        CodeSyntaxLanguage("cpp") {
            $0.keywords = words(cKeywords + " " + """
                alignas alignof and and_eq asm bitand bitor catch class compl concept consteval constexpr \
                constinit const_cast co_await co_return co_yield decltype delete dynamic_cast explicit export \
                friend mutable namespace new noexcept not not_eq nullptr operator or or_eq override final \
                private protected public reinterpret_cast requires static_assert static_cast template this \
                thread_local throw try typeid typename using virtual xor xor_eq import module
                """)
            $0.types = words(cTypes + " char8_t char16_t char32_t std string string_view vector array map " +
                             "unordered_map set unordered_set pair tuple optional unique_ptr shared_ptr weak_ptr")
            $0.lineComments = cStyleComments.line
            $0.blockComments = cStyleComments.block
            $0.strings = [Delimiter("\"", multiline: false)]
            $0.charLiterals = true
            $0.stringPrefixes = ["L", "u", "U", "u8"]
            $0.rawStrings = .cpp
            $0.preprocessor = true
        },
        CodeSyntaxLanguage("csharp") {
            $0.keywords = words("""
                abstract as base break case catch checked class const continue default delegate do else enum \
                event explicit extern false finally fixed for foreach goto if implicit in interface internal is \
                lock namespace new null operator out override params private protected public readonly ref \
                return sealed sizeof stackalloc static struct switch this throw true try typeof unchecked unsafe \
                using virtual volatile while add alias ascending async await by descending equals from get \
                global group init into join let nameof notnull on orderby partial record remove required select \
                set unmanaged value var when where with yield
                """)
            $0.types = words("bool byte char decimal double float int long object sbyte short string uint ulong ushort void nint nuint dynamic")
            $0.capitalizedTypes = true
            $0.lineComments = cStyleComments.line
            $0.blockComments = cStyleComments.block
            // `"""` の生文字列はバックスラッシュをエスケープとしない。
            $0.strings = [Delimiter("\"\"\"", escapes: false), Delimiter("\"", multiline: false)]
            $0.verbatimStrings = true
            $0.charLiterals = true
            $0.preprocessor = true
        },
        CodeSyntaxLanguage("java") {
            $0.keywords = words("""
                abstract assert break case catch class const continue default do else enum extends final finally \
                for goto if implements import instanceof interface native new package private protected public \
                return static strictfp super switch synchronized this throw throws transient try volatile while \
                var record sealed permits yield true false null
                """)
            $0.types = words("boolean byte char double float int long short void")
            $0.capitalizedTypes = true
            $0.lineComments = cStyleComments.line
            $0.blockComments = cStyleComments.block
            $0.strings = [Delimiter("\"\"\""), Delimiter("\"", multiline: false)]
            $0.charLiterals = true
            $0.prefixedIdentifiers = [at: .attribute]
        },
        CodeSyntaxLanguage("kotlin") {
            $0.keywords = words("""
                as break class continue do else false for fun if in interface is null object package return \
                super this throw true try typealias typeof val var when while by catch constructor delegate \
                dynamic field file finally get import init param property receiver set setparam where actual \
                abstract annotation companion const crossinline data enum expect external final infix inline \
                inner internal lateinit noinline open operator out override private protected public reified \
                sealed suspend tailrec vararg value
                """)
            $0.capitalizedTypes = true
            $0.lineComments = cStyleComments.line
            $0.blockComments = cStyleComments.block
            $0.nestedBlockComments = true
            $0.strings = [Delimiter("\"\"\"", escapes: false), Delimiter("\"", multiline: false)]
            $0.charLiterals = true
            $0.prefixedIdentifiers = [at: .attribute]
        },
        CodeSyntaxLanguage("scala") {
            $0.keywords = words("""
                abstract case catch class def do else extends false final finally for forSome if implicit import \
                lazy match new null object override package private protected return sealed super this throw \
                trait try true type val var while with yield given using enum export then end extension
                """)
            $0.capitalizedTypes = true
            $0.lineComments = cStyleComments.line
            $0.blockComments = cStyleComments.block
            $0.nestedBlockComments = true
            $0.strings = [Delimiter("\"\"\"", escapes: false), Delimiter("\"", multiline: false)]
            $0.charLiterals = true
            $0.stringPrefixes = ["s", "f", "raw"]
            $0.prefixedIdentifiers = [at: .attribute]
        },
        CodeSyntaxLanguage("swift") {
            $0.keywords = words("""
                associatedtype class deinit enum extension fileprivate func import init inout internal let open \
                operator private precedencegroup protocol public rethrows static struct subscript typealias var \
                break case catch continue default defer do else fallthrough for guard if in repeat return throw \
                switch where while as Any false is nil self Self super throws true try await async actor some \
                any isolated nonisolated consume borrowing consuming mutating nonmutating lazy weak unowned \
                override required convenience dynamic final optional indirect get set willSet didSet package \
                sending macro
                """)
            $0.capitalizedTypes = true
            $0.lineComments = cStyleComments.line
            $0.blockComments = cStyleComments.block
            $0.nestedBlockComments = true
            $0.strings = [Delimiter("\"\"\""), Delimiter("\"", multiline: false)]
            $0.rawStrings = .swift
            $0.prefixedIdentifiers = [at: .attribute, hash: .attribute]
        },
        CodeSyntaxLanguage("objectivec") {
            $0.keywords = words(cKeywords + " self super nil Nil YES NO id instancetype SEL BOOL IMP Class " +
                                "__block __weak __strong __unsafe_unretained nonatomic atomic strong weak copy " +
                                "assign readonly readwrite nullable nonnull")
            $0.types = words(cTypes)
            $0.capitalizedTypes = true
            $0.lineComments = cStyleComments.line
            $0.blockComments = cStyleComments.block
            $0.strings = [Delimiter("\"", multiline: false)]
            $0.charLiterals = true
            $0.preprocessor = true
            $0.prefixedIdentifiers = [at: .keyword]
        },
        CodeSyntaxLanguage("go") {
            $0.keywords = words("""
                break case chan const continue default defer else fallthrough for func go goto if import interface \
                map package range return select struct switch type var true false nil iota
                """)
            $0.types = words("""
                bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint \
                uint8 uint16 uint32 uint64 uintptr any comparable
                """)
            $0.lineComments = cStyleComments.line
            $0.blockComments = cStyleComments.block
            $0.strings = [Delimiter("`", escapes: false), Delimiter("\"", multiline: false)]
            $0.charLiterals = true
        },
        CodeSyntaxLanguage("rust") {
            $0.keywords = words("""
                as async await break const continue crate dyn else enum extern false fn for if impl in let loop \
                match mod move mut pub ref return self Self static struct super trait true type unsafe use where \
                while union yield macro_rules
                """)
            $0.types = words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str")
            $0.capitalizedTypes = true
            $0.lineComments = cStyleComments.line
            $0.blockComments = cStyleComments.block
            $0.nestedBlockComments = true
            $0.strings = [Delimiter("\"")]
            $0.charLiterals = true
            $0.stringPrefixes = ["b", "c"]
            $0.rawStrings = .rust
            $0.bracketAttributes = true
            $0.macroBang = true
        },
        CodeSyntaxLanguage("dart") {
            $0.keywords = words("""
                abstract as assert async await base break case catch class const continue covariant default \
                deferred do dynamic else enum export extends extension external factory false final finally for \
                get hide if implements import in interface is late library mixin new null on operator part \
                required rethrow return sealed set show static super switch sync this throw true try typedef var \
                when while with yield
                """)
            $0.types = words("int double num bool void")
            $0.capitalizedTypes = true
            $0.lineComments = cStyleComments.line
            $0.blockComments = cStyleComments.block
            $0.strings = [Delimiter("'''"), Delimiter("\"\"\"")] + quotedStrings
            $0.rawStringPrefixes = ["r"]
            $0.prefixedIdentifiers = [at: .attribute]
        },
        CodeSyntaxLanguage("javascript") {
            $0.keywords = words(javaScriptKeywords)
            $0.capitalizedTypes = true
            $0.lineComments = cStyleComments.line
            $0.blockComments = cStyleComments.block
            $0.strings = [Delimiter("`")] + quotedStrings
            $0.identifierExtras = [dollar]
            $0.prefixedIdentifiers = [at: .attribute]
        },
        CodeSyntaxLanguage("typescript") {
            $0.keywords = words(javaScriptKeywords + " " + """
                abstract as asserts declare enum implements infer interface is keyof module namespace private \
                protected public readonly require satisfies type unique override accessor
                """)
            $0.types = words("any bigint boolean never number object string symbol unknown void")
            $0.capitalizedTypes = true
            $0.lineComments = cStyleComments.line
            $0.blockComments = cStyleComments.block
            $0.strings = [Delimiter("`")] + quotedStrings
            $0.identifierExtras = [dollar]
            $0.prefixedIdentifiers = [at: .attribute]
        },
        CodeSyntaxLanguage("python") {
            $0.keywords = words("""
                False None True and as assert async await break class continue def del elif else except finally \
                for from global if import in is lambda nonlocal not or pass raise return try while with yield \
                match case
                """)
            $0.types = words("int float complex str bytes bytearray bool list dict set frozenset tuple object type")
            $0.capitalizedTypes = true
            $0.lineComments = units("#")
            $0.strings = [Delimiter("\"\"\""), Delimiter("'''")] + quotedStrings
            $0.stringPrefixes = words("r u b f rb br fr rf R U B F Rb bR Fr fR RB BR FR RF t T")
            $0.prefixedIdentifiers = [at: .attribute]
        },
        CodeSyntaxLanguage("ruby") {
            $0.keywords = words("""
                BEGIN END alias and begin break case class def defined? do else elsif end ensure false for if in \
                module next nil not or redo rescue retry return self super then true undef unless until when \
                while yield require require_relative attr_accessor attr_reader attr_writer private protected \
                public include extend raise lambda proc
                """)
            $0.capitalizedTypes = true
            $0.lineComments = units("#")
            $0.blockComments = [Delimiter("=begin", "=end")]
            $0.strings = [Delimiter("\""), Delimiter("'"), Delimiter("`")]
            $0.prefixedIdentifiers = [at: .variable, dollar: .variable, ascii(":"): .variable]
        },
        CodeSyntaxLanguage("php") {
            $0.keywords = words("""
                abstract and array as break callable case catch class clone const continue declare default do \
                echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile enum extends final \
                finally fn for foreach function global goto if implements include include_once instanceof \
                insteadof interface isset list match namespace new or print private protected public readonly \
                require require_once return static switch throw trait try unset use var while xor yield true \
                false null self parent
                """)
            $0.types = words("int float string bool object mixed void never iterable")
            $0.caseInsensitive = true
            $0.lineComments = units("//", "#")
            $0.bracketAttributes = true
            $0.blockComments = cStyleComments.block
            $0.strings = [Delimiter("\""), Delimiter("'"), Delimiter("`")]
            $0.prefixedIdentifiers = [dollar: .variable]
            $0.markers = [(Array("<?php".utf16), .keyword), (Array("<?=".utf16), .keyword), (Array("?>".utf16), .keyword)]
        },
        CodeSyntaxLanguage("lua") {
            $0.keywords = words("""
                and break do else elseif end false for function goto if in local nil not or repeat return then \
                true until while
                """)
            $0.lineComments = units("--")
            $0.longBrackets = true
            $0.strings = quotedStrings
        },
        CodeSyntaxLanguage("perl") {
            $0.hashComments = .notAfterDollar
            $0.keywords = words("""
                my our local sub if elsif else unless while until for foreach do last next redo return use no \
                package require undef and or not eq ne lt gt le ge cmp qw print die
                """)
            $0.lineComments = units("#")
            $0.strings = [Delimiter("\""), Delimiter("'"), Delimiter("`")]
            $0.prefixedIdentifiers = [dollar: .variable, at: .variable]
        },
        CodeSyntaxLanguage("shell") {
            $0.hashComments = .wordStart
            $0.keywords = words("""
                if then else elif fi for in do done case esac while until function select return break continue \
                export local readonly declare unset shift source alias exit set eval exec trap time
                """)
            $0.lineComments = units("#")
            $0.strings = [Delimiter("\""), Delimiter("'", escapes: false), Delimiter("`")]
            $0.prefixedIdentifiers = [dollar: .variable]
            $0.shellVariables = true
        },
        CodeSyntaxLanguage("powershell") {
            $0.keywords = words("""
                begin break catch class continue data define do dynamicparam else elseif end enum exit filter \
                finally for foreach from function hidden if in param process return static switch throw trap try \
                until using var while workflow
                """)
            $0.caseInsensitive = true
            $0.lineComments = units("#")
            $0.blockComments = [Delimiter("<#", "#>")]
            // 二重引用符の中は `` ` `` でエスケープする。バックスラッシュは普通の文字。
            $0.strings = [Delimiter("\"", escape: "`"), Delimiter("'", escapes: false)]
            $0.prefixedIdentifiers = [dollar: .variable]
            $0.shellVariables = true
        },
        sql,
        mysql,
        json,
        json5,
        CodeSyntaxLanguage("yaml") {
            $0.hashComments = .afterWhitespace
            $0.keywords = ["true", "false", "null", "yes", "no", "on", "off", "~"]
            $0.caseInsensitive = true
            $0.lineComments = units("#")
            $0.strings = [Delimiter("\"", multiline: false), Delimiter("'", escapes: false, multiline: false)]
            $0.lineKeys = .yaml
            $0.prefixedIdentifiers = [ascii("&"): .variable, ascii("*"): .variable]
        },
        toml,
        ini,
        CodeSyntaxLanguage("properties") {
            // Java の properties。行頭の `#`・`!` がコメントで、キーは `=`・`:`・空白で区切る。
            $0.lineKeys = .properties
        },
        CodeSyntaxLanguage("markup") { $0.mode = .markup },
        css,
        scss,
        CodeSyntaxLanguage("diff") { $0.mode = .diff },
        CodeSyntaxLanguage("dockerfile") {
            $0.hashComments = .wordStart
            $0.keywords = words("""
                from as run cmd label maintainer expose env add copy entrypoint volume user workdir arg onbuild \
                stopsignal healthcheck shell
                """)
            $0.caseInsensitive = true
            $0.lineComments = units("#")
            $0.strings = [Delimiter("\"", multiline: false), Delimiter("'", escapes: false, multiline: false)]
            $0.prefixedIdentifiers = [dollar: .variable]
            $0.shellVariables = true
        },
        CodeSyntaxLanguage("haskell") {
            $0.keywords = words("""
                case class data default deriving do else foreign if import in infix infixl infixr instance let \
                module newtype of then type where qualified as hiding forall family
                """)
            $0.capitalizedTypes = true
            $0.lineComments = units("--")
            $0.dashComments = .notOperator
            $0.blockComments = [Delimiter("{-", "-}")]
            $0.nestedBlockComments = true
            $0.strings = [Delimiter("\"", multiline: false)]
            $0.charLiterals = true
            $0.identifierExtras = [ascii("'")]
        }
    ]
}
