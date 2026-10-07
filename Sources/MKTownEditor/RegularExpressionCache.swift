import Foundation

/// 実行時に組み立てるパターンのコンパイル結果を共有する。
///
/// 固定パターンは各型の `static let` に置く。このキャッシュは、強調記号やHTMLタグ、
/// コードの言語のように、有限の組み合わせから呼び出し時に組み立てるパターンだけに使う。
final class RegularExpressionCache: @unchecked Sendable {
    static let shared = RegularExpressionCache()

    private let lock = NSLock()
    private var expressions: [String: NSRegularExpression] = [:]
    private var invalidPatterns: Set<String> = []

    /// パターンが不正な場合は `nil` を返し、その結果も記憶して再コンパイルしない。
    func expression(_ pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = expressions[pattern] { return cached }
        if invalidPatterns.contains(pattern) { return nil }
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            invalidPatterns.insert(pattern)
            return nil
        }
        expressions[pattern] = expression
        return expression
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return expressions.count
    }
}
