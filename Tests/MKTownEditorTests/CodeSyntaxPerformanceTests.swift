import XCTest
import Darwin
@testable import MKTownEditor

/// コード色分けの性能計測。通常のテスト実行では飛ばす。
///
///     MKTOWN_PERF=1 swift test -c release --filter CodeSyntaxPerformanceTests 2>&1 | grep PERF
///
/// Debug ビルドの値は Release の数倍になるため、必ず `-c release` で測る。
final class CodeSyntaxPerformanceTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MKTOWN_PERF"] == "1", "MKTOWN_PERF=1 のときだけ計測する")
    }

    private static let javascript = """
    // 合計を求める
    function sum(items, scale = 1) {
      const re = /^[a-z]+\\\\d*$/i;
      let total = 0;
      for (const item of items) { total += item.value / scale; }
      return `total: ${total} ${re.test("a1") ? "ok" : "ng"}`;
    }
    class Box { constructor(x) { this.x = x ?? 0; } get double() { return this.x * 2; } }

    """

    private static let typescript = """
    // 合計を求める
    interface Item { value: number; label?: string }
    function sum<T extends Item>(items: T[], scale: number = 1): string {
      const re = /^[a-z]+\\\\d*$/i;
      let total: number = 0;
      for (const item of items) { total += item.value / scale; }
      return `total: ${total} ${re.test("a1") ? "ok" : "ng"}`;
    }
    type Pair = [string, number];

    """

    private static let ruby = """
    # 合計を求める
    class Box
      attr_reader :items
      def initialize(items) = @items = items
      def sum(scale = 1)
        total = @items.sum { |i| i[:value] / scale }
        "total: #{total} #{/^[a-z]+\\\\d*$/i.match?("a1") ? 'ok' : 'ng'}"
      end
    end

    """

    private static let c = """
    // 合計を求める
    #include <stdio.h>
    static int sum(const int *items, int count, int scale) {
      int total = 0;
      for (int i = 0; i < count; i++) { total += items[i] / scale; }
      printf("total: %d\\\\n", total);
      return total; /* done */
    }

    """

    private static func repeated(_ snippet: String, lines: Int) -> String {
        let perCopy = snippet.split(separator: "\n", omittingEmptySubsequences: false).count - 1
        return String(repeating: snippet, count: max(lines / perCopy, 1))
    }

    /// 1 回の空打ちのあと 5 回測った中央値（ミリ秒）。
    private func median(_ body: () -> Void) -> Double {
        body()
        var samples: [Double] = []
        for _ in 0..<5 {
            let start = ContinuousClock.now
            body()
            let d = ContinuousClock.now - start
            samples.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
        }
        return samples.sorted()[2]
    }

    private func report(_ name: String, _ ms: Double) {
        print("PERF \(name): \(String(format: "%.2f", ms)) ms")
    }

    private func measureAnalysis(_ name: String, language: String, source: String) {
        let selection = CodeSyntaxAnalyzer.language(named: language)!
        let units = source.utf16.count
        let cold = median { _ = CodeSyntaxAnalyzer.tokens(in: source, language: selection, cache: CodeSyntaxTokenCache()) }
        let cache = CodeSyntaxTokenCache()
        _ = CodeSyntaxAnalyzer.tokens(in: source, language: selection, cache: cache)
        let hit = median { _ = CodeSyntaxAnalyzer.tokens(in: source, language: selection, cache: cache) }
        let count = CodeSyntaxAnalyzer.tokens(in: source, language: selection, cache: CodeSyntaxTokenCache()).count
        report("\(name) 5000行(\(units)字, 字句\(count)) 初回", cold)
        report("\(name) 5000行 キャッシュ命中", hit)
    }

    func testBlockAnalysis() {
        measureAnalysis("javascript(Tree-sitter)", language: "js", source: Self.repeated(Self.javascript, lines: 5000))
        measureAnalysis("typescript(Tree-sitter)", language: "ts", source: Self.repeated(Self.typescript, lines: 5000))
        measureAnalysis("ruby(Tree-sitter)", language: "ruby", source: Self.repeated(Self.ruby, lines: 5000))
        measureAnalysis("c(走査器)", language: "c", source: Self.repeated(Self.c, lines: 5000))
    }

    private func document(codeSuffix: String = "") -> String {
        let code = Self.repeated(Self.javascript, lines: 5000) + codeSuffix
        var text = "```js\n\(code)```\n\n"
        for i in 0..<500 {
            text += "## 節 \(i)\n\nこれは節 \(i) の本文です。**強調**と`code`と[リンク](https://example.com/\(i))を含みます。\n\n"
        }
        return text
    }

    func testDocumentAnalysis() {
        let text = document()
        print("PERF 文書: \(text.utf16.count)字")
        let analysis = MarkdownAnalysis(text)
        let tokens = CodeSyntaxAnalyzer.tokens(forCodeBlocksIn: analysis, cache: CodeSyntaxTokenCache(), checkCancellation: {})
        report("MarkdownSyntaxHighlighter.spans(字句は計算済み)", median {
            _ = MarkdownSyntaxHighlighter.spans(in: text, analysis: analysis, codeSyntaxTokens: tokens)
        })
        let plain = text.replacingOccurrences(of: "```js", with: "```")
        let plainAnalysis = MarkdownAnalysis(plain)
        report("MarkdownSyntaxHighlighter.spans(言語なしのコードブロック)", median {
            _ = MarkdownSyntaxHighlighter.spans(in: plain, analysis: plainAnalysis, codeSyntaxTokens: [:])
        })
        report("字句の解析のみ(初回)", median {
            _ = CodeSyntaxAnalyzer.tokens(forCodeBlocksIn: analysis, cache: CodeSyntaxTokenCache(), checkCancellation: {})
        })
        // DocumentSnapshot は共有キャッシュを使う。初回は空にしてから測る。
        report("DocumentSnapshot 全体(初回)", median {
            CodeSyntaxAnalyzer.sharedCache.removeAll()
            _ = DocumentSnapshot(source: text)
        })
        _ = DocumentSnapshot(source: text)
        report("DocumentSnapshot 全体(キャッシュ命中)", median { _ = DocumentSnapshot(source: text) })
    }

    /// 入力 1 文字ごとの `DocumentSnapshot`。コードブロックは本文が変わるので毎回キャッシュを外し、他の解析は毎回行う。
    func testEditLatencyProxy() {
        _ = DocumentSnapshot(source: document())
        var counter = 0
        var samples: [Double] = []
        for run in 0..<6 {
            counter += 1
            let edited = document(codeSuffix: String(repeating: "x", count: counter))
            let start = ContinuousClock.now
            _ = DocumentSnapshot(source: edited)
            let d = ContinuousClock.now - start
            if run > 0 { samples.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15) }
        }
        report("DocumentSnapshot 1文字追加後(コードブロックだけ再解析)", samples.sorted()[2])
    }

    @MainActor
    func testMainThreadRender() {
        let source = Self.repeated(Self.javascript, lines: 5000)
        let selection = CodeSyntaxAnalyzer.language(named: "js")!
        let precomputed = CodeSyntaxAnalyzer.tokens(in: source, language: selection, cache: CodeSyntaxTokenCache())
        report("render(tokens: 計算済み)", median { _ = CodeSyntaxHighlighter.render(source, language: "js", tokens: precomputed) })
        _ = CodeSyntaxAnalyzer.tokens(in: source, language: selection)
        report("render(tokens: nil, キャッシュ命中)", median { _ = CodeSyntaxHighlighter.render(source, language: "js", tokens: nil) })
        report("render(tokens: nil, キャッシュ空)", median {
            CodeSyntaxAnalyzer.sharedCache.removeAll()
            _ = CodeSyntaxHighlighter.render(source, language: "js", tokens: nil)
        })
    }

    private func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    func testMemory() {
        var source = Self.repeated(Self.javascript, lines: 30000)
        source = String(source.prefix(1_000_000))
        XCTAssertEqual(source.utf16.count, 1_000_000)
        let cache = CodeSyntaxTokenCache()
        let selection = CodeSyntaxAnalyzer.language(named: "js")!
        func mb(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        let before = footprint()
        let tokens = CodeSyntaxAnalyzer.tokens(in: source, language: selection, cache: cache)
        let after = footprint()
        print("PERF メモリ: 字句\(tokens.count)件, 解析前 \(mb(before)), 解析後(キャッシュ保持) \(mb(after)), 差 \(mb(after - before))")
        cache.removeAll()
        let released = footprint()
        print("PERF メモリ: removeAll 後 \(mb(released)), 解析前との差 \(mb(released - before)), キャッシュ上限 \(CodeSyntaxTokenCache.defaultCapacity)件/\(CodeSyntaxTokenCache.defaultLengthBudget)字")
    }
}
