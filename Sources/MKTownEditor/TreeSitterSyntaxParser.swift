import Foundation
import SwiftTreeSitter
import TreeSitterJavaScript
import TreeSitterRuby
import TreeSitterTSX
import TreeSitterTypeScript

/// Tree-sitter で解析する文法。フェンスの言語名ごとに1つ対応する。
enum TreeSitterGrammar: String, CaseIterable, Sendable {
    case javascript, typescript, tsx, ruby

    private static let javascriptLanguage = Language(tree_sitter_javascript())
    private static let typescriptLanguage = Language(tree_sitter_typescript())
    private static let tsxLanguage = Language(tree_sitter_tsx())
    private static let rubyLanguage = Language(tree_sitter_ruby())

    var language: Language {
        switch self {
        case .javascript: Self.javascriptLanguage
        case .typescript: Self.typescriptLanguage
        case .tsx: Self.tsxLanguage
        case .ruby: Self.rubyLanguage
        }
    }

    /// 文法パッケージのバージョン（Package.swift の固定値と合わせる）。
    var packageVersion: String {
        switch self {
        case .javascript: "0.23.1"
        case .typescript, .tsx: "0.23.2"
        case .ruby: "0.23.1"
        }
    }

    /// このアプリが持つ色分けクエリ。上流の highlights.scm は述語（`#match?` など）に依存するため使わない。
    var highlightsQuery: String {
        switch self {
        case .javascript: TreeSitterHighlightQueries.javascript
        case .typescript, .tsx: TreeSitterHighlightQueries.typescript
        case .ruby: TreeSitterHighlightQueries.ruby
        }
    }

    /// クエリを変更したら増やす。キャッシュの鍵に含まれ、古い結果を使い回さない。
    static let queryRevision = 1

    /// 解析結果のキャッシュ鍵に入れる版。エンジン名、文法パッケージの版、クエリの版を連結する。
    var cacheVersion: String {
        "tree-sitter:\(rawValue)@\(packageVersion):q\(Self.queryRevision)"
    }

    /// `keyword.builtin` として色を付ける識別子。Ruby の `require` や `private` は構文上はただのメソッド呼び出し。
    var builtinKeywords: Set<String> {
        switch self {
        case .javascript, .typescript, .tsx: []
        case .ruby:
            ["require", "require_relative", "attr_accessor", "attr_reader", "attr_writer", "private", "protected",
             "public", "include", "extend", "raise", "lambda", "proc", "module_function", "prepend"]
        }
    }
}

/// コンパイル済みクエリの文法ごとのキャッシュ。コンパイルは高価なので1回だけ行い、失敗も覚えて再試行しない。
private final class TreeSitterQueryStore: @unchecked Sendable {
    static let shared = TreeSitterQueryStore()

    private let lock = NSLock()
    private var queries: [TreeSitterGrammar: Result<Query, Error>] = [:]

    func query(for grammar: TreeSitterGrammar) -> Query? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = queries[grammar] { return try? cached.get() }
        let result = Result { try Query(language: grammar.language, data: Data(grammar.highlightsQuery.utf8)) }
        queries[grammar] = result
        return try? result.get()
    }

    /// テスト用。コンパイルエラーの内容を調べる。
    func compileError(for grammar: TreeSitterGrammar) -> Error? {
        lock.lock()
        defer { lock.unlock() }
        if queries[grammar] == nil {
            queries[grammar] = Result { try Query(language: grammar.language, data: Data(grammar.highlightsQuery.utf8)) }
        }
        if case .failure(let error) = queries[grammar]! { return error }
        return nil
    }
}

/// Tree-sitter の構文木から `CodeSyntaxTokenRange` を作る。どのスレッドからでも呼べる。
enum TreeSitterSyntaxParser {
    /// これを超える長さ（UTF-16 単位）の入力は解析しない。
    static let maximumSourceLength = 1_000_000
    /// 1回の解析にかける時間の上限（秒）。超えたら単色にする。
    static let parseTimeout: TimeInterval = 0.5

    typealias Capture = (range: NSRange, token: CodeSyntaxToken, patternIndex: Int)

    /// 色分けの結果。解析できなかった場合（長すぎる、タイムアウト、クエリの不具合）は `nil`。
    /// 解析できて何も該当しなければ `[]`。
    static func tokens(in source: String, grammar: TreeSitterGrammar) -> [CodeSyntaxTokenRange]? {
        let text = source as NSString
        let length = text.length
        guard length <= maximumSourceLength else { return nil }
        guard let query = TreeSitterQueryStore.shared.query(for: grammar) else { return nil }
        // Parser はスレッド間で共有できないので毎回作る。
        let parser = Parser()
        parser.timeout = parseTimeout
        guard (try? parser.setLanguage(grammar.language)) != nil,
              let tree = parser.parse(source), let root = tree.rootNode else { return nil }

        var captures: [Capture] = []
        let cursor = query.execute(node: root, in: tree)
        while let capture = cursor.nextCapture() {
            guard let name = capture.name,
                  let token = token(forCapture: name, range: capture.range, text: text, grammar: grammar) else { continue }
            captures.append((capture.range, token, capture.patternIndex))
        }
        return normalize(captures, length: length)
    }

    /// キャプチャ名を字句の種類へ変換する。名前は `CodeSyntaxToken` の値と同じで、2つだけ特別扱いする。
    /// - `type.capitalized`: 先頭が大文字の ASCII で小文字を含む名前だけ型（`ALL_CAPS` の定数は除く。旧走査器と同じ規則）。
    /// - `keyword.builtin`: 文法ごとの組み込みメソッド名だけキーワード。
    /// 未知の名前は `nil`（無視）。
    static func token(forCapture name: String, range: NSRange, text: NSString, grammar: TreeSitterGrammar) -> CodeSyntaxToken? {
        switch name {
        case "keyword": return .keyword
        case "type": return .type
        case "string": return .string
        case "comment": return .comment
        case "number": return .number
        case "attribute": return .attribute
        case "variable": return .variable
        case "type.capitalized":
            guard range.length > 0, NSMaxRange(range) <= text.length else { return nil }
            guard (0x41...0x5A).contains(text.character(at: range.location)) else { return nil }
            for offset in range.location..<NSMaxRange(range) where (0x61...0x7A).contains(text.character(at: offset)) {
                return .type
            }
            return nil
        case "keyword.builtin":
            guard range.length > 0, NSMaxRange(range) <= text.length else { return nil }
            return grammar.builtinKeywords.contains(text.substring(with: range)) ? .keyword : nil
        default: return nil
        }
    }

    /// キャプチャを、位置順・重なりなし・空でない範囲の列にそろえる。不変条件を満たせなければ `nil`。
    ///
    /// Tree-sitter のキャプチャは互いに離れているか、入れ子になっている。
    /// - 入れ子は内側を優先し、外側は内側の前後に分けて残す（`"a#{1}b"` は文字列・数値・文字列）。
    /// - 同じ範囲なら `patternIndex` が小さい（クエリの先にある）方を優先する。
    /// - 入れ子にならない部分的な重なりは、先に始まる方を残して後の方を捨てる。
    /// - 長さ0の範囲と `0..<length` の外の範囲は捨てる。
    /// - 隣り合う同じ種類の範囲は1つにまとめる（`@` と `Component`）。
    static func normalize(_ captures: [Capture], length: Int) -> [CodeSyntaxTokenRange]? {
        let valid = captures.filter { $0.range.length > 0 && $0.range.location >= 0 && NSMaxRange($0.range) <= length }
        // 開始が早い順、同じ開始なら長い順（外側が先）、同じ範囲なら patternIndex の小さい順。
        let sorted = valid.sorted {
            if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
            if $0.range.length != $1.range.length { return $0.range.length > $1.range.length }
            return $0.patternIndex < $1.patternIndex
        }

        struct Open { var end: Int; var token: CodeSyntaxToken; var emitted: Int }
        var stack: [Open] = []
        var pieces: [CodeSyntaxTokenRange] = []

        func emit(_ start: Int, _ end: Int, _ token: CodeSyntaxToken) {
            if end > start { pieces.append(CodeSyntaxTokenRange(range: NSRange(location: start, length: end - start), token: token)) }
        }
        func closeTop() {
            let top = stack.removeLast()
            emit(top.emitted, top.end, top.token)
        }

        var previous: NSRange?
        for capture in sorted {
            let range = capture.range
            if let previous, NSEqualRanges(previous, range) { continue }  // 同じ範囲は最初（patternIndex が最小）だけ
            previous = range
            while let top = stack.last, top.end <= range.location { closeTop() }
            if let top = stack.last {
                if NSMaxRange(range) > top.end { continue }  // 入れ子にならない重なり
                emit(top.emitted, range.location, top.token)
                stack[stack.count - 1].emitted = NSMaxRange(range)
            }
            stack.append(Open(end: NSMaxRange(range), token: capture.token, emitted: range.location))
        }
        while !stack.isEmpty { closeTop() }

        pieces.sort { $0.range.location < $1.range.location }
        var merged: [CodeSyntaxTokenRange] = []
        for piece in pieces {
            if let last = merged.last, last.token == piece.token, NSMaxRange(last.range) == piece.range.location {
                merged[merged.count - 1] = CodeSyntaxTokenRange(
                    range: NSRange(location: last.range.location, length: last.range.length + piece.range.length),
                    token: piece.token)
            } else {
                merged.append(piece)
            }
        }
        return isValid(merged, length: length) ? merged : nil
    }

    /// 位置順、重なりなし、空でなく、`0..<length` に収まっているか。
    static func isValid(_ tokens: [CodeSyntaxTokenRange], length: Int) -> Bool {
        var end = 0
        for token in tokens {
            guard token.range.length > 0, token.range.location >= end, NSMaxRange(token.range) <= length else { return false }
            end = NSMaxRange(token.range)
        }
        return true
    }

    /// テスト用。クエリのコンパイルエラーを返す（成功なら `nil`）。
    static func queryCompileError(for grammar: TreeSitterGrammar) -> Error? {
        TreeSitterQueryStore.shared.compileError(for: grammar)
    }
}

/// 文法ごとの色分けクエリ。キャプチャ名は `CodeSyntaxToken` の値と、`type.capitalized`・`keyword.builtin`。
/// 述語（`#match?` など）は評価されないので使わない。同じ範囲に複数のキャプチャがある場合は先に書いた方が勝つ。
enum TreeSitterHighlightQueries {
    private static let javaScriptKeywordList = """
        "await" "break" "case" "catch" "class" "const" "continue" "debugger" "default" "delete" "do" "else" "export" \
        "extends" "finally" "for" "function" "if" "import" "in" "instanceof" "let" "new" "of" "return" "static" \
        "switch" "throw" "try" "typeof" "var" "void" "while" "with" "yield" "async" "get" "set" "from" "as"
        """

    /// JavaScript と TypeScript に共通するリテラル・コメント・デコレーター・キーワード。
    private static let scriptCommon = """
        (comment) @comment
        (html_comment) @comment
        (hash_bang_line) @comment
        (string) @string
        (template_string) @string
        (regex) @string
        (number) @number

        (decorator "@" @attribute)
        (decorator (identifier) @attribute)
        (decorator (member_expression object: (identifier) @attribute property: (property_identifier) @attribute))
        (decorator (call_expression function: (identifier) @attribute))
        (decorator (call_expression function: (member_expression object: (identifier) @attribute property: (property_identifier) @attribute)))

        [\(javaScriptKeywordList)] @keyword
        [(true) (false) (null) (undefined) (this) (super)] @keyword

        """

    /// 先頭が大文字で小文字を含む名前を型にする。他のキャプチャに負けるよう最後に置く。
    private static let capitalized = """
        (identifier) @type.capitalized
        (property_identifier) @type.capitalized
        """

    static let javascript = scriptCommon + capitalized

    /// TypeScript の型は、`void` のように型にもキーワードにもなる語を型として扱うため、キーワードより前に置く。
    static let typescript = """
        (type_identifier) @type
        (predefined_type) @type

        """ + scriptCommon + """
        ["abstract" "accessor" "asserts" "declare" "enum" "implements" "infer" "interface" "is" "keyof" "module" \
        "namespace" "override" "private" "protected" "public" "readonly" "require" "satisfies" "type"] @keyword

        """ + capitalized

    static let ruby = """
        (comment) @comment

        ["alias" "and" "begin" "break" "case" "class" "def" "defined?" "do" "else" "elsif" "end" "ensure" "for" "if" \
        "in" "module" "next" "not" "or" "redo" "rescue" "retry" "return" "then" "undef" "unless" "until" "when" \
        "while" "yield" "BEGIN" "END"] @keyword
        [(self) (super) (nil) (true) (false)] @keyword

        [(string) (heredoc_beginning) (heredoc_body) (subshell) (regex) (character)] @string
        [(integer) (float) (rational) (complex)] @number
        (constant) @type.capitalized
        [(instance_variable) (class_variable) (global_variable) (simple_symbol) (delimited_symbol) (hash_key_symbol)] @variable

        (call method: (identifier) @keyword.builtin)
        (identifier) @keyword.builtin
        """
}
