import Foundation

/// コードブロック内の字句の種類。色は表示先（プレビュー、編集画面、HTML）ごとに割り当てる。
enum CodeSyntaxToken: String, CaseIterable, Sendable {
    case keyword, type, string, comment, number, attribute, variable, inserted, deleted
}

struct CodeSyntaxTokenRange: Equatable, Sendable {
    let range: NSRange
    let token: CodeSyntaxToken
}

/// フェンスの言語名に対応する字句規則。正規表現を使わず、UTF-16 単位で1回走査する。
struct CodeSyntaxLanguage: Sendable {
    enum Mode: Sendable { case code, markup, diff }
    /// 行頭のキーを属性として扱う形式。
    enum LineKeys: Sendable { case none, yaml, ini, properties }
    /// 区切りを選べる生文字列。中の引用符で文字列を終えない。
    enum RawStrings: Sendable {
        case none
        /// `r"..."`、`r#"..."#`、`br##"..."##`
        case rust
        /// `#"..."#`、`##"""..."""##`
        case swift
        /// `R"(...)"`、`R"tag(...)tag"`
        case cpp
    }
    /// `#`・`;` の行コメントが成り立つ条件。
    enum HashComments: Sendable {
        /// Python、Ruby、PHP、TOML など：文字列の外ならどこでもコメント（`x=1#note`）。
        case anywhere
        /// YAML、INI：直前が空白か行頭の場合だけ（`https://host/#frag` はコメントではない）。
        case afterWhitespace
        /// シェル、Dockerfile：単語の先頭（空白か `;&|()<>` の直後）だけ（`$#`、`a#b` はコメントではない）。
        case wordStart
        /// Perl：`$#array` 以外はコメント。
        case notAfterDollar
        /// Dockerfile：行の最初の空白以外の文字の場合だけ。`ENV A b # c` の `#` は引数。
        case lineStart
    }
    /// `--` の行コメントが成り立つ条件。
    enum DashComments: Sendable {
        case always
        /// MySQL：`--` の直後に空白か制御文字が必要（`1--2` は式）。
        case whitespaceAfter
        /// Haskell：`-->` のように記号が続く場合は演算子。
        case notOperator
    }

    struct Delimiter: Sendable {
        let open: [UInt16]
        let close: [UInt16]
        var escapes = true
        /// エスケープに使う文字。PowerShell は `` ` ``。
        var escape = UInt16(0x5C)
        var multiline = true
        /// `nil` は SQL の `"name"` のような引用符付き識別子。中を色分けせず、字句も付けない。
        var token: CodeSyntaxToken?
        /// Ruby の `=begin`・`=end` のように、開きと閉じが行頭（0桁目）にある場合だけ区切りとする。
        var atLineStart = false

        init(_ open: String, _ close: String? = nil, escapes: Bool = true, escape: Unicode.Scalar = "\\",
             multiline: Bool = true, token: CodeSyntaxToken? = .string, atLineStart: Bool = false) {
            self.open = Array(open.utf16)
            self.close = Array((close ?? open).utf16)
            self.escapes = escapes
            self.escape = UInt16(escape.value)
            self.atLineStart = atLineStart
            self.multiline = multiline
            self.token = token
        }
    }

    private(set) var name: String
    var mode = Mode.code
    var keywords: Set<String> = []
    var types: Set<String> = []
    /// SQL などの大文字・小文字を区別しない言語。キーワードは小文字で登録する。
    var caseInsensitive = false
    /// 先頭が大文字で小文字を含む識別子を型名とみなす（`ALL_CAPS` の定数は除く）。
    var capitalizedTypes = false
    var lineComments: [[UInt16]] = []
    var blockComments: [Delimiter] = []
    var nestedBlockComments = false
    /// 長い区切りから順に並べる（`"""` を `"` より先に照合する）。
    var strings: [Delimiter] = []
    /// `'` を1文字の文字リテラルとしてだけ扱う（Rust のライフタイムなどを文字列にしない）。
    var charLiterals = false
    /// 直後の引用符と合わせて文字列とする接頭辞（Python の `f"..."` など）。
    var stringPrefixes: Set<String> = []
    /// 直後の引用符と合わせて、バックスラッシュをエスケープとしない文字列にする接頭辞（Dart の `r"..."`）。
    var rawStringPrefixes: Set<String> = []
    /// C# の逐語的文字列 `@"..."`（`$@"..."` を含む）。`""` が引用符を表す。
    var verbatimStrings = false
    /// JavaScript・Ruby・Perl の正規表現リテラル `/[//]/`。値の後ろの `/` は除算とする。
    var regexLiterals = false
    /// C# の生文字列 `""""…""""` のように、開きの引用符の数で閉じ記号が決まる。
    var quoteRunStrings = false
    /// 直後の識別子と合わせて色分けする記号（`@Override`、`$name` など）。
    var prefixedIdentifiers: [UInt16: CodeSyntaxToken] = [:]
    /// 行頭の `#include` などのプリプロセッサ指令。
    var preprocessor = false
    /// Rust の `#[derive(...)]`。
    var bracketAttributes = false
    /// Rust の `println!` のようなマクロ呼び出し。
    var macroBang = false
    /// シェルの `$1`、`${name}` など。
    var shellVariables = false
    var identifierExtras: Set<UInt16> = []
    var hashComments = HashComments.anywhere
    var dashComments = DashComments.always
    var rawStrings = RawStrings.none
    /// Lua の `[[...]]`、`[==[...]==]` と、`--` を前に付けた長いコメント。
    var longBrackets = false
    /// JSON5 のように、`:` が続く識別子をキーとして扱う。
    var identifierKeys = false
    var lineKeys = LineKeys.none
    /// JSON のように、`:` が続く文字列をキーとして扱う。
    var stringKeys = false
    var css = false
    /// PHP の `<?php` のように、そのまま照合する記号列。
    var markers: [(text: [UInt16], token: CodeSyntaxToken)] = []

    init(_ name: String, configure: (inout CodeSyntaxLanguage) -> Void = { _ in }) {
        self.name = name
        configure(&self)
    }

    /// 方言のように、既存の言語の規則を一部だけ変えた言語を作る。
    init(_ name: String, basedOn base: CodeSyntaxLanguage, configure: (inout CodeSyntaxLanguage) -> Void) {
        self = base
        self.name = name
        configure(&self)
    }
}

enum CodeSyntaxTokenizer {
    /// フェンスの情報文字列から言語を求める。`ruby:app.rb`（ファイル名付き）や `{.python}` も受け付ける。
    /// 未対応の言語と `text` などのプレーンテキスト指定は `nil`。
    static func language(named info: String?) -> CodeSyntaxLanguage? {
        guard var name = info?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty else {
            return nil
        }
        if name.hasPrefix("{") { name = String(name.dropFirst().prefix(while: { $0 != "}" })) }
        if name.hasPrefix(".") { name.removeFirst() }
        if name.hasPrefix("language-") { name.removeFirst("language-".count) }
        if let colon = name.firstIndex(of: ":") { name = String(name[..<colon]) }
        if CodeSyntaxLanguages.plainText.contains(name) { return nil }
        if let canonical = CodeSyntaxLanguages.aliases[name] {
            return CodeSyntaxLanguages.all[canonical]
        }
        // `main.cpp` のようにファイル名だけを書いた場合は拡張子で判定する。
        if let dot = name.lastIndex(of: "."), let canonical = CodeSyntaxLanguages.aliases[String(name[name.index(after: dot)...])] {
            return CodeSyntaxLanguages.all[canonical]
        }
        return nil
    }

    static func tokens(in source: String, language name: String?) -> [CodeSyntaxTokenRange] {
        guard let language = language(named: name) else { return [] }
        return tokens(in: source, language: language)
    }

    static func tokens(in source: String, language: CodeSyntaxLanguage) -> [CodeSyntaxTokenRange] {
        var scanner = CodeSyntaxScanner(units: Array(source.utf16), language: language)
        switch language.mode {
        case .code: scanner.scanCode()
        case .markup: scanner.scanMarkup()
        case .diff: scanner.scanDiff()
        }
        return scanner.result
    }
}

private enum Unit {
    static let tab: UInt16 = 0x09, newline: UInt16 = 0x0A, carriageReturn: UInt16 = 0x0D, space: UInt16 = 0x20
    static let bang: UInt16 = 0x21, quote: UInt16 = 0x22, hash: UInt16 = 0x23, dollar: UInt16 = 0x24
    static let ampersand: UInt16 = 0x26, apostrophe: UInt16 = 0x27, plus: UInt16 = 0x2B, minus: UInt16 = 0x2D
    static let dot: UInt16 = 0x2E, slash: UInt16 = 0x2F, colon: UInt16 = 0x3A, semicolon: UInt16 = 0x3B
    static let less: UInt16 = 0x3C, equal: UInt16 = 0x3D, greater: UInt16 = 0x3E, question: UInt16 = 0x3F
    static let at: UInt16 = 0x40, openBracket: UInt16 = 0x5B, backslash: UInt16 = 0x5C, closeBracket: UInt16 = 0x5D
    static let underscore: UInt16 = 0x5F, backtick: UInt16 = 0x60, openBrace: UInt16 = 0x7B, closeBrace: UInt16 = 0x7D
    static let percent: UInt16 = 0x25
}

private struct CodeSyntaxScanner {
    let units: [UInt16]
    let language: CodeSyntaxLanguage
    var result: [CodeSyntaxTokenRange] = []
    private var index = 0
    private var braceDepth = 0
    /// 次の `/` が正規表現を始められるか。値（識別子、数値、文字列、`)` など）の直後では除算。
    private var regexAllowed = true
    private var lineStartOffset = 0
    /// YAML のフローコレクション（`{…}`・`[…]`）の深さ。中では `:` が続く識別子をキーとする。
    private var flowDepth = 0
    /// YAML のブロックスカラー（`|`・`>`）を始めた行の字下げ。これより深い行は本文として色分けしない。
    private var yamlBlockIndent: Int?

    init(units: [UInt16], language: CodeSyntaxLanguage) {
        self.units = units
        self.language = language
    }

    private var count: Int { units.count }

    private func unit(_ offset: Int) -> UInt16? {
        offset >= 0 && offset < count ? units[offset] : nil
    }

    private func matches(_ text: [UInt16], at offset: Int) -> Bool {
        guard !text.isEmpty, offset + text.count <= count else { return false }
        for (position, value) in text.enumerated() where units[offset + position] != value { return false }
        return true
    }

    private mutating func emit(_ start: Int, _ end: Int, _ token: CodeSyntaxToken) {
        guard end > start else { return }
        result.append(CodeSyntaxTokenRange(range: NSRange(location: start, length: end - start), token: token))
    }

    private func isColumnZero(_ offset: Int) -> Bool {
        offset == 0 || units[offset - 1] == Unit.newline
    }

    private func lineEnd(from offset: Int) -> Int {
        var cursor = offset
        while cursor < count && units[cursor] != Unit.newline { cursor += 1 }
        return cursor
    }

    private static func isASCIILetter(_ value: UInt16) -> Bool {
        (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value)
    }

    private static func isDigit(_ value: UInt16) -> Bool { (0x30...0x39).contains(value) }

    private static func isWhitespace(_ value: UInt16) -> Bool {
        value == Unit.space || value == Unit.tab || value == Unit.newline || value == Unit.carriageReturn
            || value == 0xA0 || value == 0x3000
    }

    private func isIdentifierStart(_ offset: Int) -> Bool {
        guard let value = unit(offset) else { return false }
        if Self.isASCIILetter(value) || value == Unit.underscore { return true }
        if value >= 0x80 { return !Self.isWhitespace(value) }
        // CSS の `-webkit-box` のように、記号から始まる識別子は直後が英字の場合だけ認める。
        if language.identifierExtras.contains(value), value != Unit.apostrophe {
            return unit(offset + 1).map { Self.isASCIILetter($0) || $0 == value } ?? false
        }
        return false
    }

    private func isIdentifierPart(_ value: UInt16) -> Bool {
        Self.isASCIILetter(value) || Self.isDigit(value) || value == Unit.underscore
            || (value >= 0x80 && !Self.isWhitespace(value)) || language.identifierExtras.contains(value)
    }

    private func identifierEnd(from offset: Int) -> Int {
        var cursor = offset + 1
        while cursor < count && isIdentifierPart(units[cursor]) { cursor += 1 }
        return cursor
    }

    private func word(_ start: Int, _ end: Int) -> String {
        let text = String(decoding: units[start..<end], as: UTF16.self)
        return language.caseInsensitive ? text.lowercased() : text
    }

    private func nextNonSpace(from offset: Int) -> Int {
        var cursor = offset
        while cursor < count && (units[cursor] == Unit.space || units[cursor] == Unit.tab) { cursor += 1 }
        return cursor
    }

    private static let haskellSymbols = Set("!#$%&*+./<=>?@\\^|~:".utf16)

    /// 行コメントが `offset` から始まるか。方言ごとの `--`・`//`・`#`・`;` の条件を確かめる。
    private func commentBoundary(at offset: Int, marker: [UInt16]) -> Bool {
        if marker == [Unit.minus, Unit.minus] {
            switch language.dashComments {
            case .always: return true
            case .whitespaceAfter:
                return unit(offset + 2).map { $0 <= Unit.space } ?? true
            case .notOperator:
                var cursor = offset
                while unit(cursor) == Unit.minus { cursor += 1 }
                return unit(cursor).map { !Self.haskellSymbols.contains($0) } ?? true
            }
        }
        if language.css, marker.first == Unit.slash {
            // `url(http://…)` の `//` はコメントではない。
            return unit(offset - 1) != Unit.colon
        }
        guard marker.count == 1, marker[0] == Unit.hash || marker[0] == Unit.semicolon else { return true }
        // PHP 8 と Rust の `#[...]` は属性。
        if marker[0] == Unit.hash, language.bracketAttributes, unit(offset + 1) == Unit.openBracket { return false }
        guard let previous = unit(offset - 1) else { return true }
        switch language.hashComments {
        case .anywhere: return true
        case .afterWhitespace: return Self.isWhitespace(previous)
        case .wordStart: return Self.isWhitespace(previous) || Self.shellOperators.contains(previous)
        case .notAfterDollar: return previous != Unit.dollar
        case .lineStart:
            var cursor = offset - 1
            while let value = unit(cursor), value != Unit.newline {
                if !Self.isWhitespace(value) { return false }
                cursor -= 1
            }
            return true
        }
    }

    private static let shellOperators = Set(";&|()<>".utf16)

    // MARK: - プログラミング言語

    mutating func scanCode() {
        var atLineStart = true
        while index < count {
            let value = units[index]
            if value == Unit.newline {
                atLineStart = true
                index += 1
                lineStartOffset = index
                continue
            }
            if Self.isWhitespace(value) {
                index += 1
                continue
            }
            let lineStart = atLineStart
            atLineStart = false
            if lineStart, language.lineKeys == .yaml {
                let indent = index - lineStartOffset
                let end = lineEnd(from: index)
                if let blockIndent = yamlBlockIndent, indent > blockIndent {
                    index = end
                    continue
                }
                yamlBlockIndent = startsYAMLBlockScalar(from: index, to: end) ? indent : nil
            }
            if lineStart, language.lineKeys != .none, scanLineKey() { continue }
            if lineStart, language.preprocessor, value == Unit.hash {
                scanPreprocessor()
                continue
            }
            if scanMarker() { continue }
            // コメントは式の文脈を変えない（`= /* c */ /re/` の `/` は正規表現）。
            if scanRegexLiteral() || scanLongBracket() || scanSwiftRawString() || scanVerbatimString() {
                regexAllowed = false
                continue
            }
            if scanBlockComment() || scanLineComment() { continue }
            if scanString() {
                regexAllowed = false
                continue
            }
            if Self.isDigit(value) || (value == Unit.dot && unit(index + 1).map(Self.isDigit) == true
                                       && unit(index - 1).map(isIdentifierPart) != true) {
                scanNumber()
                regexAllowed = false
                continue
            }
            if scanPrefixedIdentifier() || scanBracketAttribute() {
                regexAllowed = false
                continue
            }
            if isIdentifierStart(index) {
                scanIdentifier()
                continue
            }
            if language.css {
                scanCSSPunctuation(value)
                continue
            }
            if language.lineKeys == .yaml {
                if value == Unit.openBrace || value == Unit.openBracket { flowDepth += 1 }
                if value == Unit.closeBrace || value == Unit.closeBracket { flowDepth = max(0, flowDepth - 1) }
            }
            if (value == Unit.plus || value == Unit.minus) && unit(index + 1) == value {
                // 値の後ろの `x++` は値のまま、`++x` の前は式の途中のまま。
                index += 2
                continue
            }
            regexAllowed = !Self.valueClosingPunctuation.contains(value)
            index += 1
        }
    }

    private static let valueClosingPunctuation = Set(")]}".utf16)

    private mutating func scanMarker() -> Bool {
        guard let marker = language.markers.first(where: { matches($0.text, at: index) }) else { return false }
        emit(index, index + marker.text.count, marker.token)
        index += marker.text.count
        return true
    }

    /// Lua の長い括弧。`--` が前にあればコメント、なければ文字列。
    private mutating func scanLongBracket() -> Bool {
        guard language.longBrackets else { return false }
        let isComment = units[index] == Unit.minus && unit(index + 1) == Unit.minus
        var cursor = isComment ? index + 2 : index
        guard unit(cursor) == Unit.openBracket else { return false }
        cursor += 1
        var level = 0
        while unit(cursor) == Unit.equal {
            level += 1
            cursor += 1
        }
        guard unit(cursor) == Unit.openBracket else { return false }
        let close = [Unit.closeBracket] + Array(repeating: Unit.equal, count: level) + [Unit.closeBracket]
        let start = index
        index = cursor + 1
        while index < count && !matches(close, at: index) { index += 1 }
        index = min(count, index + close.count)
        emit(start, index, isComment ? .comment : .string)
        return true
    }

    /// `#` の数で区切りを選ぶ生文字列。`hashStart` から `#` を数え、直後の `"` から同じ数の `#` が続く `"` までを文字列にする。
    private mutating func scanHashDelimitedString(from start: Int, hashStart: Int) -> Bool {
        var quote = hashStart
        while unit(quote) == Unit.hash { quote += 1 }
        guard unit(quote) == Unit.quote else { return false }
        // Swift の `#"""…"""#` は閉じ側も3つの引用符。`#""#` は空文字列なので1つとして扱う。
        let quotes = language.rawStrings == .swift && matches(Self.tripleQuote, at: quote) ? 3 : 1
        let close = Array(repeating: Unit.quote, count: quotes) + Array(repeating: Unit.hash, count: quote - hashStart)
        index = quote + quotes
        while index < count && !matches(close, at: index) { index += 1 }
        index = min(count, index + close.count)
        emit(start, index, .string)
        return true
    }

    private static let tripleQuote = [Unit.quote, Unit.quote, Unit.quote]

    private mutating func scanSwiftRawString() -> Bool {
        guard language.rawStrings == .swift, units[index] == Unit.hash else { return false }
        return scanHashDelimitedString(from: index, hashStart: index)
    }

    /// C++ の `R"tag(...)tag"`。区切りは最大16文字。
    private mutating func scanCppRawString(from start: Int, quote: Int) -> Bool {
        var paren = quote + 1
        while paren < min(count, quote + 18), units[paren] != 0x28 {
            let value = units[paren]
            if value == Unit.space || value == Unit.backslash || value == 0x29 || value == Unit.newline { return false }
            paren += 1
        }
        guard unit(paren) == 0x28 else { return false }
        let close = [0x29] + Array(units[(quote + 1)..<paren]) + [Unit.quote]
        index = paren + 1
        while index < count && !matches(close, at: index) { index += 1 }
        index = min(count, index + close.count)
        emit(start, index, .string)
        return true
    }

    /// 正規表現の前に置ける語。`this` や `nil` のような値の語、`obj.in` のようなメンバー名の後ろの `/` は除算。
    private static let regexPrecedingWords: Set<String> = [
        "return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw", "case", "default", "do",
        "else", "yield", "await", "if", "elsif", "unless", "while", "until", "when", "then", "and", "or", "not",
        "split", "grep"
    ]

    /// 式の始まりにある `/` から始まる1行の正規表現リテラル。文字クラス `[...]` の中の `/` では閉じない。
    private mutating func scanRegexLiteral() -> Bool {
        guard language.regexLiterals, regexAllowed, units[index] == Unit.slash,
              let next = unit(index + 1), next != Unit.slash, next != 0x2A, next != Unit.newline else { return false }
        var cursor = index + 1
        var inClass = false
        while cursor < count {
            let value = units[cursor]
            if value == Unit.newline { return false }
            if value == Unit.backslash {
                cursor += 2
                continue
            }
            if value == Unit.openBracket { inClass = true }
            if value == Unit.closeBracket { inClass = false }
            if value == Unit.slash && !inClass { break }
            cursor += 1
        }
        guard cursor < count else { return false }
        cursor += 1
        while let flag = unit(cursor), Self.isASCIILetter(flag) { cursor += 1 }
        emit(index, cursor, .string)
        index = cursor
        return true
    }

    private mutating func scanBlockComment() -> Bool {
        guard let delimiter = language.blockComments.first(where: {
            matches($0.open, at: index) && (!$0.atLineStart || isColumnZero(index))
        }) else { return false }
        let start = index
        var depth = 1
        index += delimiter.open.count
        while index < count {
            if matches(delimiter.close, at: index), !delimiter.atLineStart || isColumnZero(index) {
                index += delimiter.close.count
                depth -= 1
                if depth == 0 || !language.nestedBlockComments { break }
            } else if language.nestedBlockComments && matches(delimiter.open, at: index) {
                index += delimiter.open.count
                depth += 1
            } else {
                index += 1
            }
        }
        emit(start, index, .comment)
        return true
    }

    private mutating func scanLineComment() -> Bool {
        guard language.lineComments.contains(where: {
            matches($0, at: index) && commentBoundary(at: index, marker: $0)
        }) else { return false }
        let end = lineEnd(from: index)
        emit(index, end, .comment)
        index = end
        return true
    }

    /// `raw` はバックスラッシュをエスケープとしない。`doubledQuotes` は閉じ記号を2つ重ねると文字として扱う。
    private mutating func scanString(from prefixStart: Int? = nil, raw: Bool = false,
                                     doubledQuotes: Bool = false) -> Bool {
        if language.charLiterals, units[index] == Unit.apostrophe {
            return scanCharLiteral()
        }
        guard var delimiter = language.strings.first(where: { matches($0.open, at: index) }) else { return false }
        let start = prefixStart ?? index
        if language.quoteRunStrings, delimiter.open == Self.tripleQuote {
            // C# の生文字列は3つ以上の引用符で区切り、開きと同じ数で閉じる。
            var run = index
            while unit(run) == Unit.quote { run += 1 }
            delimiter = CodeSyntaxLanguage.Delimiter(String(repeating: "\"", count: run - index), escapes: false,
                                                     token: delimiter.token)
        }
        index += delimiter.open.count
        while index < count {
            if delimiter.escapes && !raw && units[index] == delimiter.escape {
                index = min(count, index + 2)
                continue
            }
            if matches(delimiter.close, at: index) {
                index += delimiter.close.count
                if doubledQuotes && matches(delimiter.close, at: index) {
                    index += delimiter.close.count
                    continue
                }
                break
            }
            // C# の逐語的文字列は改行を含められる。
            if !delimiter.multiline && !doubledQuotes && units[index] == Unit.newline { break }
            index += 1
        }
        guard let token = delimiter.token else { return true }
        let isKey = language.stringKeys && unit(nextNonSpace(from: index)) == Unit.colon
        emit(start, index, isKey ? .attribute : token)
        return true
    }

    private mutating func scanVerbatimString() -> Bool {
        guard language.verbatimStrings else { return false }
        let start = index
        var quote = index
        // `@"`、`$@"`、`@$"`、`$$@"` など
        while let value = unit(quote), value == Unit.at || value == Unit.dollar, quote - start < 4 { quote += 1 }
        guard quote > start, unit(quote) == Unit.quote, units[start..<quote].contains(Unit.at) else { return false }
        index = quote
        return scanString(from: start, raw: true, doubledQuotes: true)
    }

    private mutating func scanCharLiteral() -> Bool {
        var end: Int?
        if unit(index + 1) == Unit.backslash {
            var cursor = index + 2
            while cursor < min(count, index + 14) && units[cursor] != Unit.newline {
                if units[cursor] == Unit.apostrophe && cursor > index + 2 {
                    end = cursor + 1
                    break
                }
                cursor += 1
            }
        } else if let next = unit(index + 1), next != Unit.newline, next != Unit.apostrophe {
            let width = UTF16.isLeadSurrogate(next) ? 2 : 1
            if unit(index + 1 + width) == Unit.apostrophe { end = index + 2 + width }
        }
        guard let end else {
            // Rust のライフタイム `'a` や Haskell の `x'` は文字列にしない。
            index += 1
            return true
        }
        emit(index, end, .string)
        index = end
        return true
    }

    private mutating func scanNumber() {
        let start = index
        let hexadecimal = units[index] == 0x30 && (unit(index + 1) == 0x78 || unit(index + 1) == 0x58)
        index += 1
        while index < count {
            let value = units[index]
            if isIdentifierPart(value) && value != Unit.dollar && value != Unit.minus {
                index += 1
            } else if value == Unit.dot, unit(index + 1).map(Self.isDigit) == true {
                index += 1
            } else if (value == Unit.plus || value == Unit.minus), !hexadecimal,
                      let previous = unit(index - 1), previous == 0x65 || previous == 0x45,
                      unit(index + 1).map(Self.isDigit) == true {
                index += 1
            } else if language.css && value == Unit.percent {
                index += 1
                break
            } else {
                break
            }
        }
        emit(start, index, .number)
    }

    private mutating func scanPrefixedIdentifier() -> Bool {
        let value = units[index]
        guard let token = language.prefixedIdentifiers[value] else { return false }
        if let previous = unit(index - 1), isIdentifierPart(previous) || previous == value { return false }
        if language.shellVariables && value == Unit.dollar {
            if unit(index + 1) == Unit.openBrace {
                var end = index + 2
                while end < count && units[end] != Unit.closeBrace && units[end] != Unit.newline { end += 1 }
                end = min(count, end + 1)
                emit(index, end, token)
                index = end
                return true
            }
            if let next = unit(index + 1), Self.isDigit(next) || [0x40, 0x2A, 0x23, 0x3F, 0x24, 0x21, 0x2D].contains(next) {
                emit(index, index + 2, token)
                index += 2
                return true
            }
        }
        guard isIdentifierStart(index + 1) else { return false }
        let end = identifierEnd(from: index + 1)
        emit(index, end, token)
        index = end
        return true
    }

    private mutating func scanBracketAttribute() -> Bool {
        guard language.bracketAttributes, units[index] == Unit.hash else { return false }
        var open = index + 1
        if unit(open) == Unit.bang { open += 1 }
        guard unit(open) == Unit.openBracket else { return false }
        // 属性は複数行にわたってよい。閉じ括弧がなければ行末までとする。
        let end = matchingBracketEnd(from: open, limit: count) ?? lineEnd(from: index)
        emit(index, end, .attribute)
        index = end
        return true
    }

    /// `open` の `[` に対応する `]` の直後の位置。引用符の中の括弧は数えない。見つからなければ `nil`。
    private func matchingBracketEnd(from open: Int, limit: Int) -> Int? {
        var depth = 0
        var quote: UInt16?
        var cursor = open
        while cursor < limit {
            let value = units[cursor]
            if let current = quote {
                if value == Unit.backslash {
                    cursor += 2
                    continue
                }
                // 引用符の中の文字列は行をまたがない。
                if value == current || value == Unit.newline { quote = nil }
            } else if value == Unit.quote || value == Unit.apostrophe {
                quote = value
            } else if value == Unit.openBracket {
                depth += 1
            } else if value == Unit.closeBracket {
                depth -= 1
                if depth == 0 { return cursor + 1 }
            }
            cursor += 1
        }
        return nil
    }

    private mutating func scanIdentifier() {
        let start = index
        let end = identifierEnd(from: index)
        index = end
        var before = start - 1
        while let value = unit(before), value == Unit.space || value == Unit.tab { before -= 1 }
        let isMember = unit(before) == Unit.dot
        regexAllowed = language.regexLiterals && !isMember
            && Self.regexPrecedingWords.contains(String(decoding: units[start..<end], as: UTF16.self))
        let prefix = String(decoding: units[start..<end], as: UTF16.self)
        switch language.rawStrings {
        case .rust where ["r", "br", "cr"].contains(prefix) && (unit(end) == Unit.hash || unit(end) == Unit.quote):
            if scanHashDelimitedString(from: start, hashStart: end) { return }
            index = end
        case .cpp where prefix.hasSuffix("R") && unit(end) == Unit.quote:
            if scanCppRawString(from: start, quote: end) { return }
            index = end
        default: break
        }
        if let next = unit(end), next == Unit.quote || next == Unit.apostrophe,
           language.stringPrefixes.contains(prefix) || language.rawStringPrefixes.contains(prefix),
           language.strings.contains(where: { matches($0.open, at: end) }) {
            _ = scanString(from: start, raw: language.rawStringPrefixes.contains(prefix))
            return
        }
        let text = word(start, end)
        if language.macroBang, unit(end) == Unit.bang, unit(end + 1) != Unit.equal {
            emit(start, end + 1, .attribute)
            index = end + 1
        } else if language.css {
            classifyCSSIdentifier(start, end, text)
        } else if language.identifierKeys || (language.lineKeys == .yaml && flowDepth > 0),
                  unit(nextNonSpace(from: end)) == Unit.colon {
            emit(start, end, .attribute)
        } else if language.keywords.contains(text) {
            emit(start, end, .keyword)
        } else if language.types.contains(text) {
            emit(start, end, .type)
        } else if language.capitalizedTypes, (0x41...0x5A).contains(units[start]),
                  units[start..<end].contains(where: { (0x61...0x7A).contains($0) }) {
            emit(start, end, .type)
        }
    }

    private mutating func scanPreprocessor() {
        let start = index
        let nameStart = nextNonSpace(from: index + 1)
        let nameEnd = isIdentifierStart(nameStart) ? identifierEnd(from: nameStart) : nameStart
        emit(start, nameEnd, .attribute)
        index = nameEnd
        let directive = word(nameStart, nameEnd)
        let pathStart = nextNonSpace(from: nameEnd)
        if (directive == "include" || directive == "import"), unit(pathStart) == Unit.less {
            var end = pathStart + 1
            while end < count && units[end] != Unit.greater && units[end] != Unit.newline { end += 1 }
            if unit(end) == Unit.greater { end += 1 }
            emit(pathStart, end, .string)
            index = end
        }
    }

    // MARK: - CSS

    private mutating func classifyCSSIdentifier(_ start: Int, _ end: Int, _ text: String) {
        if text.lowercased() == "url", unit(end) == 0x28 {
            // 引用符のない `url(//cdn/a.png)` の中身は、`//` を含めて1つの文字列とする。
            let open = nextNonSpace(from: end + 1)
            if let first = unit(open), first != Unit.quote, first != Unit.apostrophe {
                var close = open
                while close < count, units[close] != 0x29, units[close] != Unit.newline { close += 1 }
                emit(open, close, .string)
                index = close
            }
            return
        }
        if braceDepth == 0 {
            emit(start, end, .type)
        } else if unit(nextNonSpace(from: end)) == Unit.colon {
            emit(start, end, .attribute)
        } else if language.keywords.contains(text) {
            emit(start, end, .keyword)
        }
    }

    private mutating func scanCSSPunctuation(_ value: UInt16) {
        if value == Unit.openBrace {
            braceDepth += 1
        } else if value == Unit.closeBrace {
            braceDepth = max(0, braceDepth - 1)
        } else if value == Unit.bang, isIdentifierStart(index + 1) {
            // `!important`
            let end = identifierEnd(from: index + 1)
            emit(index, end, .keyword)
            index = end
            return
        } else if value == Unit.hash, braceDepth > 0, unit(index + 1).map(isIdentifierPart) == true {
            // 宣言内の `#fff` は色の値。
            let end = identifierEnd(from: index + 1)
            emit(index, end, .number)
            index = end
            return
        } else if braceDepth == 0, value == Unit.dot || value == Unit.hash || value == Unit.colon {
            // セレクタの `.class`、`#id`、`:hover`、`::before`
            var start = index + 1
            if value == Unit.colon && unit(start) == Unit.colon { start += 1 }
            if isIdentifierStart(start) {
                let end = identifierEnd(from: start)
                emit(index, end, .type)
                index = end
                return
            }
        }
        index += 1
    }

    // MARK: - 行頭のキー（YAML・INI・TOML）

    private mutating func scanLineKey() -> Bool {
        switch language.lineKeys {
        case .none: return false
        case .ini: return scanINIKey()
        case .properties: return scanPropertiesKey()
        case .yaml: return scanYAMLKey()
        }
    }

    private mutating func scanINIKey() -> Bool {
        let end = lineEnd(from: index)
        if units[index] == Unit.openBracket {
            // `[section]`、`[[array]]`、`["a]b"]`
            let close = matchingBracketEnd(from: index, limit: end) ?? end
            emit(index, close, .type)
            index = close
            return true
        }
        // TOML の裸のキーは英数字・`_`・`-`（`1234 = 1`、`- = true`）。引用符付きのキーも認める。
        let first = units[index]
        guard Self.isASCIILetter(first) || Self.isDigit(first) || first == Unit.underscore || first == Unit.minus
                || first == Unit.quote || first == Unit.apostrophe || first >= 0x80 else { return false }
        var cursor = index
        while cursor < end && units[cursor] != Unit.equal && units[cursor] != Unit.hash
                && units[cursor] != Unit.semicolon { cursor += 1 }
        guard cursor < end, units[cursor] == Unit.equal else { return false }
        var keyEnd = cursor
        while keyEnd > index && Self.isWhitespace(units[keyEnd - 1]) { keyEnd -= 1 }
        emit(index, keyEnd, .attribute)
        index = cursor
        return true
    }

    private mutating func scanPropertiesKey() -> Bool {
        let end = lineEnd(from: index)
        if continuesPreviousLine(at: index) {
            index = end
            return true
        }
        if units[index] == Unit.hash || units[index] == Unit.bang {
            emit(index, end, .comment)
            index = end
            return true
        }
        var cursor = index
        while cursor < end {
            let value = units[cursor]
            if value == Unit.backslash {
                cursor += 2
                continue
            }
            if value == Unit.equal || value == Unit.colon || Self.isWhitespace(value) { break }
            cursor += 1
        }
        cursor = min(cursor, end)
        emit(index, cursor, .attribute)
        // 値は区切りの後ろから行末までの文字列。
        index = end
        return true
    }

    /// 前の行が奇数個の `\` で終わる継続行か。
    private func continuesPreviousLine(at offset: Int) -> Bool {
        var cursor = offset - 1
        while cursor >= 0 && units[cursor] != Unit.newline { cursor -= 1 }
        var backslashes = 0
        cursor -= 1
        if unit(cursor) == Unit.carriageReturn { cursor -= 1 }
        while cursor >= 0 && units[cursor] == Unit.backslash {
            backslashes += 1
            cursor -= 1
        }
        return backslashes % 2 == 1
    }

    /// `key: |`、`- >-`、`|2` のようにブロックスカラーを始める行か。行末のコメントは除いて判定する。
    private func startsYAMLBlockScalar(from start: Int, to end: Int) -> Bool {
        var text = String(decoding: units[start..<end], as: UTF16.self)
        if let comment = text.range(of: " #") { text = String(text[..<comment.lowerBound]) }
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let indicator = parts.last, let first = indicator.first, first == "|" || first == ">",
              indicator.dropFirst().count <= 2,
              indicator.dropFirst().allSatisfy({ $0 == "+" || $0 == "-" || $0.isNumber }) else { return false }
        guard parts.count > 1 else { return true }
        let previous = parts[parts.count - 2]
        return previous == "-" || previous.hasSuffix(":")
    }

    private mutating func scanYAMLKey() -> Bool {
        let origin = index
        var start = index
        // シーケンスの `- key: value`
        while unit(start) == Unit.minus, let next = unit(start + 1), next == Unit.space || next == Unit.tab {
            start = nextNonSpace(from: start + 1)
        }
        let end = lineEnd(from: start)
        guard start < end else {
            index = end
            return true
        }
        let first = units[start]
        if first == Unit.hash || first == Unit.openBracket || first == Unit.openBrace
            || first == Unit.ampersand || first == Unit.bang {
            index = origin
            return false
        }
        var cursor = start
        if first == Unit.quote || first == Unit.apostrophe {
            cursor += 1
            while cursor < end && units[cursor] != first { cursor += 1 }
            cursor += 1
        }
        while cursor < end {
            if units[cursor] == Unit.colon, cursor + 1 == end || Self.isWhitespace(units[cursor + 1]) { break }
            if units[cursor] == Unit.hash, Self.isWhitespace(units[cursor - 1]) {
                cursor = end
                break
            }
            cursor += 1
        }
        guard cursor < end, cursor > start else {
            index = origin
            return false
        }
        emit(start, cursor, .attribute)
        index = cursor + 1
        return true
    }

    // MARK: - HTML・XML

    mutating func scanMarkup() {
        let commentOpen = Array("<!--".utf16), commentClose = Array("-->".utf16)
        let dataOpen = Array("<![CDATA[".utf16), dataClose = Array("]]>".utf16)
        while index < count {
            if matches(commentOpen, at: index) {
                scanUntil(commentClose, token: .comment)
            } else if matches(dataOpen, at: index) {
                scanUntil(dataClose, token: .string)
            } else if units[index] == Unit.less, let next = unit(index + 1),
                      Self.isASCIILetter(next) || next == Unit.slash || next == Unit.bang || next == Unit.question {
                scanTag()
            } else if units[index] == Unit.ampersand {
                var end = index + 1
                while end < min(count, index + 12), isIdentifierPart(units[end]) || units[end] == Unit.hash {
                    end += 1
                }
                if unit(end) == Unit.semicolon, end > index + 1 {
                    emit(index, end + 1, .variable)
                    index = end + 1
                } else {
                    index += 1
                }
            } else {
                index += 1
            }
        }
    }

    private mutating func scanUntil(_ close: [UInt16], token: CodeSyntaxToken) {
        let start = index
        while index < count && !matches(close, at: index) { index += 1 }
        index = min(count, index + close.count)
        emit(start, index, token)
    }

    private mutating func scanTag() {
        var nameStart = index + 1
        if let value = unit(nameStart), value == Unit.slash || value == Unit.bang || value == Unit.question {
            nameStart += 1
        }
        var nameEnd = nameStart
        while nameEnd < count, isMarkupName(units[nameEnd]) { nameEnd += 1 }
        emit(nameStart, nameEnd, .keyword)
        index = nameEnd
        while index < count {
            let value = units[index]
            if value == Unit.greater {
                index += 1
                return
            }
            if value == Unit.less { return }
            if value == Unit.equal {
                // 引用符のない属性値 `width=100`
                let start = nextNonSpace(from: index + 1)
                var end = start
                while end < count, !Self.isWhitespace(units[end]), units[end] != Unit.greater,
                      units[end] != Unit.quote, units[end] != Unit.apostrophe { end += 1 }
                emit(start, end, .string)
                index = max(end, index + 1)
            } else if value == Unit.quote || value == Unit.apostrophe {
                let start = index
                index += 1
                while index < count && units[index] != value { index += 1 }
                index = min(count, index + 1)
                emit(start, index, .string)
            } else if isMarkupName(value) && !Self.isDigit(value) && value != Unit.minus && value != Unit.dot {
                let start = index
                while index < count && isMarkupName(units[index]) { index += 1 }
                emit(start, index, .attribute)
            } else {
                index += 1
            }
        }
    }

    private func isMarkupName(_ value: UInt16) -> Bool {
        Self.isASCIILetter(value) || Self.isDigit(value) || value == Unit.underscore || value == Unit.minus
            || value == Unit.colon || value == Unit.dot || value >= 0x80
    }

    // MARK: - 差分

    /// ファイル見出し（`---`・`+++`）は、ハンクの外でだけ認める。ハンク内の `--- x` は削除行。
    mutating func scanDiff() {
        let headers = ["+++", "---", "diff ", "index "].map { Array($0.utf16) }
        let fileStart = Array("diff ".utf16)
        let hunk = Array("@@".utf16)
        var oldRemaining = 0, newRemaining = 0
        while index < count {
            let end = lineEnd(from: index)
            let inHunk = oldRemaining > 0 || newRemaining > 0
            if matches(fileStart, at: index) {
                oldRemaining = 0
                newRemaining = 0
                emit(index, end, .keyword)
            } else if matches(hunk, at: index) {
                (oldRemaining, newRemaining) = hunkLengths(from: index, to: end)
                emit(index, end, .attribute)
            } else if !inHunk, headers.contains(where: { matches($0, at: index) }) {
                emit(index, end, .keyword)
            } else if units[index] == Unit.plus {
                newRemaining = max(0, newRemaining - 1)
                emit(index, end, .inserted)
            } else if units[index] == Unit.minus {
                oldRemaining = max(0, oldRemaining - 1)
                emit(index, end, .deleted)
            } else if units[index] == Unit.backslash {
                emit(index, end, .comment)
            } else if inHunk {
                oldRemaining = max(0, oldRemaining - 1)
                newRemaining = max(0, newRemaining - 1)
            }
            index = end + 1
        }
    }

    /// `@@ -1,3 +1,4 @@` の旧・新の行数。数を省略した範囲は1行。読めない場合は見出しの判定を続けないよう大きな値にする。
    private func hunkLengths(from start: Int, to end: Int) -> (Int, Int) {
        let header = String(decoding: units[start..<end], as: UTF16.self)
        func length(after marker: Character) -> Int? {
            guard let range = header.split(separator: " ").first(where: { $0.first == marker })?.dropFirst() else {
                return nil
            }
            let parts = range.split(separator: ",", omittingEmptySubsequences: false)
            guard Int(parts[0]) != nil else { return nil }
            return parts.count > 1 ? Int(parts[1]) : 1
        }
        guard let old = length(after: "-"), let new = length(after: "+") else { return (.max, .max) }
        return (old, new)
    }
}
