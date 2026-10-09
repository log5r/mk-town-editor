import Foundation

/// 言語ごとの解析エンジン。
enum CodeSyntaxEngine: Sendable {
    case treeSitter(TreeSitterGrammar)
    case scanner(CodeSyntaxLanguage)

    /// キャッシュ鍵に入れる版。解析結果が変わりうる更新（文法・クエリ・走査規則）で値を変える。
    /// 走査器の版は、JavaScript・TypeScript・Ruby の定義と推定を取り除いた時点で 2 にした。走査規則を変えたら上げる。
    var cacheVersion: String {
        switch self {
        case .treeSitter(let grammar): grammar.cacheVersion
        case .scanner: "scanner:2"
        }
    }
}

/// フェンスの情報文字列から決めた言語と、その解析エンジン。
struct CodeSyntaxLanguageSelection: Sendable {
    /// 正規名（`ts` や `jsx` ではなく `typescript`・`javascript`）。
    let name: String
    let engine: CodeSyntaxEngine
}

/// 解析結果の LRU キャッシュ。鍵は言語の正規名・エンジンの版・本文のハッシュで、本文そのものも保持し、
/// 一致を確かめてから返す（ハッシュの衝突で別の結果を返さない）。
/// 色や原文中の絶対位置は持たない（保存するのは本文に対する UTF-16 範囲と種類だけ）。
/// `NSCache` は追い出しが非決定的でテストが不安定になるため使わない。
final class CodeSyntaxTokenCache: @unchecked Sendable {
    private struct Key: Hashable {
        let language: String
        let version: String
        let hash: Int
    }
    private struct Entry {
        let content: String
        let length: Int
        let tokens: [CodeSyntaxTokenRange]
    }

    static let defaultCapacity = 128
    static let defaultLengthBudget = 2_000_000

    let capacity: Int
    let lengthBudget: Int
    private let hasher: @Sendable (String) -> Int
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    /// 先頭が最も古い。
    private var order: [Key] = []
    private var totalLength = 0
    private var hitCount = 0
    private var missCount = 0

    init(capacity: Int = CodeSyntaxTokenCache.defaultCapacity,
         lengthBudget: Int = CodeSyntaxTokenCache.defaultLengthBudget,
         hash: @escaping @Sendable (String) -> Int = { $0.hashValue }) {
        self.capacity = max(capacity, 0)
        self.lengthBudget = max(lengthBudget, 0)
        self.hasher = hash
    }

    /// 保存済みの結果。なければ `nil`（結果が空配列の場合は `[]`）。
    func tokens(for source: String, language: String, version: String) -> [CodeSyntaxTokenRange]? {
        let key = Key(language: language, version: version, hash: hasher(source))
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key], entry.content == source else {
            missCount += 1
            return nil
        }
        hitCount += 1
        if let index = order.lastIndex(of: key) {
            order.remove(at: index)
            order.append(key)
        }
        return entry.tokens
    }

    func store(_ tokens: [CodeSyntaxTokenRange], for source: String, language: String, version: String) {
        let length = source.utf16.count
        guard length <= lengthBudget, capacity > 0 else { return }
        let key = Key(language: language, version: version, hash: hasher(source))
        lock.lock()
        defer { lock.unlock() }
        if let old = entries[key] {
            totalLength -= old.length
            order.removeAll { $0 == key }
        }
        entries[key] = Entry(content: source, length: length, tokens: tokens)
        order.append(key)
        totalLength += length
        while entries.count > capacity || totalLength > lengthBudget, let oldest = order.first {
            order.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) { totalLength -= removed.length }
        }
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        order.removeAll()
        totalLength = 0
    }

    /// テスト用の観測値。
    var hits: Int { lock.withLock { hitCount } }
    var misses: Int { lock.withLock { missCount } }
    var count: Int { lock.withLock { entries.count } }
    var contentLength: Int { lock.withLock { totalLength } }
    func resetCounters() { lock.withLock { hitCount = 0; missCount = 0 } }
}

/// 言語の判定と色分けの入口。解析エンジン（Tree-sitter か走査器）の違いはここで吸収する。
/// どのスレッドからでも呼べる。
enum CodeSyntaxAnalyzer {
    static let sharedCache = CodeSyntaxTokenCache()

    /// フェンスの情報文字列から言語とエンジンを求める。`ruby:app.rb`（ファイル名付き）や `{.python}` も受け付ける。
    /// 未対応の言語と `text` などのプレーンテキスト指定は `nil`。
    static func language(named info: String?) -> CodeSyntaxLanguageSelection? {
        guard var name = info?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty else {
            return nil
        }
        if name.hasPrefix("{") { name = String(name.dropFirst().prefix(while: { $0 != "}" })) }
        if name.hasPrefix(".") { name.removeFirst() }
        if name.hasPrefix("language-") { name.removeFirst("language-".count) }
        if let colon = name.firstIndex(of: ":") { name = String(name[..<colon]) }
        if CodeSyntaxLanguages.plainText.contains(name) { return nil }
        if let canonical = CodeSyntaxLanguages.aliases[name] {
            return selection(canonical: canonical)
        }
        // `main.cpp` のようにファイル名だけを書いた場合は拡張子で判定する。
        if let dot = name.lastIndex(of: "."), let canonical = CodeSyntaxLanguages.aliases[String(name[name.index(after: dot)...])] {
            return selection(canonical: canonical)
        }
        return nil
    }

    private static func selection(canonical: String) -> CodeSyntaxLanguageSelection? {
        if let grammar = TreeSitterGrammar(rawValue: canonical) {
            return CodeSyntaxLanguageSelection(name: canonical, engine: .treeSitter(grammar))
        }
        guard let language = CodeSyntaxLanguages.all[canonical] else { return nil }
        return CodeSyntaxLanguageSelection(name: canonical, engine: .scanner(language))
    }

    /// 解析結果に含まれる、色分け対象のコードブロックすべての字句を求める。鍵は `MarkdownBlock.id`。
    /// 対応言語のブロックは字句が空でも項目を持つ（項目がある＝解析済み）。
    /// 背景スレッドから呼ぶ。ブロックの合間に `checkCancellation` を呼び、古い解析を早く打ち切る。
    static func tokens<Failure>(forCodeBlocksIn analysis: MarkdownAnalysis,
                                cache: CodeSyntaxTokenCache = sharedCache,
                                checkCancellation: () throws(Failure) -> Void) throws(Failure) -> [Int: [CodeSyntaxTokenRange]] {
        var result: [Int: [CodeSyntaxTokenRange]] = [:]
        for block in analysis.blocks where block.kind == .codeBlock {
            try checkCancellation()
            guard let selection = language(named: block.codeLanguage) else { continue }
            result[block.id] = tokens(in: block.content, language: selection, cache: cache)
        }
        return result
    }

    static func tokens(in source: String, language name: String?, cache: CodeSyntaxTokenCache = sharedCache) -> [CodeSyntaxTokenRange] {
        guard let selection = language(named: name) else { return [] }
        return tokens(in: source, language: selection, cache: cache)
    }

    /// キャッシュにあればそれを返し、なければエンジンで解析して保存する。
    /// Tree-sitter が解析できなかった場合（長すぎる、タイムアウトなど）は単色（`[]`）で、その結果も保存する。
    static func tokens(in source: String, language selection: CodeSyntaxLanguageSelection,
                       cache: CodeSyntaxTokenCache = sharedCache) -> [CodeSyntaxTokenRange] {
        let version = selection.engine.cacheVersion
        if let cached = cache.tokens(for: source, language: selection.name, version: version) { return cached }
        let result: [CodeSyntaxTokenRange]
        switch selection.engine {
        case .treeSitter(let grammar):
            result = TreeSitterSyntaxParser.tokens(in: source, grammar: grammar) ?? []
        case .scanner(let language):
            result = CodeSyntaxTokenizer.tokens(in: source, language: language)
        }
        cache.store(result, for: source, language: selection.name, version: version)
        return result
    }
}
