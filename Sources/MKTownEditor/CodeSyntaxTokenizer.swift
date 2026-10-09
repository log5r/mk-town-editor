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
    enum LineKeys: Sendable { case none, yaml, ini }

    struct Delimiter: Sendable {
        let open: [UInt16]
        let close: [UInt16]
        var escapes = true
        var multiline = true

        init(_ open: String, _ close: String? = nil, escapes: Bool = true, multiline: Bool = true) {
            self.open = Array(open.utf16)
            self.close = Array((close ?? open).utf16)
            self.escapes = escapes
            self.multiline = multiline
        }
    }

    let name: String
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
    /// `#` と `;` の行コメントを単語の先頭でだけ認める（シェルの `$#` や `a#b` はコメントではない）。
    /// Python などは識別子の直後でもコメントになるため、シェル系の言語だけで有効にする。
    var commentsNeedWordBoundary = false
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

    /// `commentsNeedWordBoundary` の言語では、`#` や `;` の行コメントは識別子や `$` の直後では始まらない。
    private func commentBoundary(at offset: Int, marker: [UInt16]) -> Bool {
        guard language.commentsNeedWordBoundary, marker.count == 1,
              marker[0] == Unit.hash || marker[0] == Unit.semicolon else { return true }
        guard let previous = unit(offset - 1) else { return true }
        return Self.isWhitespace(previous) || (marker[0] == Unit.hash && !isIdentifierPart(previous)
            && previous != Unit.dollar && previous != Unit.closeBrace)
    }

    // MARK: - プログラミング言語

    mutating func scanCode() {
        var atLineStart = true
        while index < count {
            let value = units[index]
            if value == Unit.newline {
                atLineStart = true
                index += 1
                continue
            }
            if Self.isWhitespace(value) {
                index += 1
                continue
            }
            let lineStart = atLineStart
            atLineStart = false
            if lineStart, language.lineKeys != .none, scanLineKey() { continue }
            if lineStart, language.preprocessor, value == Unit.hash {
                scanPreprocessor()
                continue
            }
            if scanMarker() || scanBlockComment() || scanLineComment() || scanString() { continue }
            if Self.isDigit(value) || (value == Unit.dot && unit(index + 1).map(Self.isDigit) == true
                                       && unit(index - 1).map(isIdentifierPart) != true) {
                scanNumber()
                continue
            }
            if scanPrefixedIdentifier() || scanBracketAttribute() { continue }
            if isIdentifierStart(index) {
                scanIdentifier()
                continue
            }
            if language.css {
                scanCSSPunctuation(value)
                continue
            }
            index += 1
        }
    }

    private mutating func scanMarker() -> Bool {
        guard let marker = language.markers.first(where: { matches($0.text, at: index) }) else { return false }
        emit(index, index + marker.text.count, marker.token)
        index += marker.text.count
        return true
    }

    private mutating func scanBlockComment() -> Bool {
        guard let delimiter = language.blockComments.first(where: { matches($0.open, at: index) }) else {
            return false
        }
        let start = index
        var depth = 1
        index += delimiter.open.count
        while index < count {
            if matches(delimiter.close, at: index) {
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

    private mutating func scanString(from prefixStart: Int? = nil) -> Bool {
        if language.charLiterals, units[index] == Unit.apostrophe {
            return scanCharLiteral()
        }
        guard let delimiter = language.strings.first(where: { matches($0.open, at: index) }) else { return false }
        let start = prefixStart ?? index
        index += delimiter.open.count
        while index < count {
            if delimiter.escapes && units[index] == Unit.backslash {
                index = min(count, index + 2)
                continue
            }
            if matches(delimiter.close, at: index) {
                index += delimiter.close.count
                break
            }
            if !delimiter.multiline && units[index] == Unit.newline { break }
            index += 1
        }
        let isKey = language.stringKeys && unit(nextNonSpace(from: index)) == Unit.colon
        emit(start, index, isKey ? .attribute : .string)
        return true
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
        var depth = 0
        var end = open
        while end < count && units[end] != Unit.newline {
            if units[end] == Unit.openBracket { depth += 1 }
            if units[end] == Unit.closeBracket {
                depth -= 1
                if depth == 0 {
                    end += 1
                    break
                }
            }
            end += 1
        }
        emit(index, end, .attribute)
        index = end
        return true
    }

    private mutating func scanIdentifier() {
        let start = index
        let end = identifierEnd(from: index)
        index = end
        if let next = unit(end), next == Unit.quote || next == Unit.apostrophe,
           language.stringPrefixes.contains(String(decoding: units[start..<end], as: UTF16.self)),
           language.strings.contains(where: { matches($0.open, at: end) }) {
            _ = scanString(from: start)
            return
        }
        let text = word(start, end)
        if language.macroBang, unit(end) == Unit.bang, unit(end + 1) != Unit.equal {
            emit(start, end + 1, .attribute)
            index = end + 1
        } else if language.css {
            classifyCSSIdentifier(start, end, text)
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
        case .yaml: return scanYAMLKey()
        }
    }

    private mutating func scanINIKey() -> Bool {
        let end = lineEnd(from: index)
        if units[index] == Unit.openBracket {
            var close = index + 1
            while close < end && units[close] != Unit.closeBracket { close += 1 }
            while close < end && units[close] == Unit.closeBracket { close += 1 }
            emit(index, close, .type)
            index = close
            return true
        }
        guard isIdentifierStart(index) || units[index] == Unit.quote else { return false }
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

    mutating func scanDiff() {
        let headers = ["+++", "---", "diff ", "index "].map { Array($0.utf16) }
        let hunk = Array("@@".utf16)
        while index < count {
            let end = lineEnd(from: index)
            if headers.contains(where: { matches($0, at: index) }) {
                emit(index, end, .keyword)
            } else if matches(hunk, at: index) {
                emit(index, end, .attribute)
            } else if units[index] == Unit.plus {
                emit(index, end, .inserted)
            } else if units[index] == Unit.minus {
                emit(index, end, .deleted)
            } else if units[index] == Unit.backslash {
                emit(index, end, .comment)
            }
            index = end + 1
        }
    }
}
