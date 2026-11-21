import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import MKTownEditor

/// 構造化プレビューの文字列を `NSTextView` で描く性能を測る。
///
///     MKTOWN_PERF=1 swift test -c release --filter PreviewTextBackendPerformanceTests 2>&1 | grep PERF
///
/// Debug ビルドの値は Release と大きく異なるため、必ず `-c release` で測る。
/// 測るのはレイアウトと表示の確定までで、画面への合成は含まない。
/// SwiftUI の `Text` と比べた結果は docs/preview-text-backend-performance.md にある。
@MainActor
final class PreviewTextBackendPerformanceTests: XCTestCase {
    nonisolated override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MKTOWN_PERF"] == "1", "MKTOWN_PERF=1 のときだけ計測する")
    }

    private static let viewport = NSSize(width: 800, height: 900)
    /// ウインドウを閉じたあと、`NSTextView` の解放を待つ秒数の上限。
    private static let teardownWait = 60

    // MARK: - 文書

    /// 強調もリンクも持たない段落だけの文書。
    private func plainDocument(paragraphs: Int) -> String {
        (0..<paragraphs).map { index in
            "段落\(index)。プレビューの描画にかかる時間を測るための文章で、" +
            "折り返しが起きる長さにしてある。The quick brown fox jumps over the lazy dog, " +
            "and the paragraph keeps going so that it wraps onto several lines in the preview."
        }.joined(separator: "\n\n") + "\n"
    }

    /// 見出し、強調やコードを含む段落、リンクのある段落、入れ子のリストが混ざった文書。
    private func mixedDocument(sections: Int) -> String {
        (0..<sections).map { index in
            """
            ## 節\(index)の見出し

            この段落には**強調**と`コード`と*斜体*がある。折り返しが起きる長さにするため、\
            文章をもう少し続ける。The quick brown fox jumps over the lazy dog.

            素の段落。装飾を持たない文章。\
            The paragraph keeps going so that it wraps onto several lines in the preview.

            [リンク](https://example.com/\(index))を含む段落。

            - 項目A
              - 入れ子の項目B
            - 項目C

            """
        }.joined(separator: "\n")
    }

    // MARK: - 表示

    private struct Mounted {
        let window: NSWindow
        let host: NSHostingView<AnyView>

        @MainActor func close() {
            window.orderOut(nil)
            window.contentView = nil
        }
    }

    private func mount(_ source: String) -> Mounted {
        var preview = MarkdownPreview(markdown: source, documentContext: DocumentContext(fileURL: nil))
        // 分割表示と同じく、構造化プレビュー（`LazyVStack` の経路）を通す。
        preview.onRevealSource = { _ in }
        let host = NSHostingView(rootView: AnyView(preview))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.viewport),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = window.contentView?.bounds ?? .zero
        window.orderFrontRegardless()
        settle(host)
        return Mounted(window: window, host: host)
    }

    /// レイアウトと表示を確定させ、実行ループに積まれた SwiftUI の更新を1回分進める。
    private func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        CATransaction.flush()
        RunLoop.main.run(until: Date())
        host.layoutSubtreeIfNeeded()
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(of: $0, as: type) }
    }

    /// プレビュー全体を縦にスクロールするビュー。表の横スクロールなどより文書が長いものを選ぶ。
    private func previewScrollView(in host: NSView) throws -> NSScrollView {
        try XCTUnwrap(descendants(of: host, as: NSScrollView.self)
            .filter { !($0.documentView is NSTextView) }
            .max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
    }

    // MARK: - 計測

    private struct Sample {
        var initialDisplay = 0.0
        var scrollTotal = 0.0
        var scrollWorstStep = 0.0
        var scrollSteps = 0
        var resize = 0.0
        var documentHeight = 0.0
        var textViews = 0
        var liveTextViews = 0
        var idleTextViews = 0
        var leftTextViews = 0
        var footprint = 0.0
        var teardown = 0.0
    }

    private func milliseconds(_ body: () throws -> Void) rethrows -> Double {
        let start = ContinuousClock.now
        try body()
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    private func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// 初回表示、末尾までのスクロール、幅の変更、解放を1回ずつ測る。
    private func sample(_ source: String) throws -> Sample {
        var sample = Sample()
        let before = footprint()
        var mounted: Mounted?
        sample.initialDisplay = milliseconds { mounted = mount(source) }
        // スクロールの途中で作られた `NSTextView` を弱参照で覚え、行が画面外へ出たあとも生きている数を数える。
        let created = NSHashTable<NSTextView>.weakObjects()
        func liveCount() -> Int { autoreleasepool { created.allObjects.count } }
        // ビューへの参照をこの中だけにとどめ、あとで解放までの時間を測れるようにする。
        try autoreleasepool {
            let view = try XCTUnwrap(mounted)
            try measureScrollAndResize(view, created: created, into: &sample)
            sample.footprint = footprint() - before
        }
        sample.liveTextViews = liveCount()
        // 操作のない時間を置いても解放されないかを確かめる。計測中は実行ループが休まないため。
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        sample.idleTextViews = liveCount()

        // ウインドウを閉じ、`NSTextView` の解放が止まるまでを測る。解放は実行ループの後始末で起きる。
        // 閉じた時点で画面上にあった分などは残り続けることがあるため、1秒間減らなくなったら打ち切り、残った数を報告する。
        let start = ContinuousClock.now
        var lastDecrease = start
        var remaining = liveCount()
        mounted?.close()
        mounted = nil
        while remaining > 0, ContinuousClock.now - lastDecrease < .seconds(1),
              ContinuousClock.now - start < .seconds(Self.teardownWait) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            let count = liveCount()
            if count < remaining {
                remaining = count
                lastDecrease = ContinuousClock.now
            }
        }
        let elapsed = lastDecrease - start
        sample.teardown = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        sample.leftTextViews = remaining
        return sample
    }

    private func measureScrollAndResize(_ view: Mounted, created: NSHashTable<NSTextView>,
                                        into sample: inout Sample) throws {
        func remember() {
            autoreleasepool { descendants(of: view.host, as: NSTextView.self).forEach(created.add) }
        }
        remember()
        let scroll = try previewScrollView(in: view.host)
        let clip = scroll.contentView

        // 表示領域1つ分ずつ末尾まで進める。`LazyVStack` は見えた行だけを作るため、文書の高さは進むにつれて変わる。
        while sample.scrollSteps < 20_000 {
            let limit = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
            guard clip.bounds.origin.y < limit - 0.5 else { break }
            let next = min(limit, clip.bounds.origin.y + clip.bounds.height)
            let step = milliseconds {
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: next))
                scroll.reflectScrolledClipView(clip)
                settle(view.host)
            }
            sample.scrollTotal += step
            sample.scrollWorstStep = max(sample.scrollWorstStep, step)
            sample.scrollSteps += 1
            remember()
        }
        sample.documentHeight = Double(scroll.documentView?.frame.height ?? 0)
        sample.textViews = descendants(of: view.host, as: NSTextView.self).count

        // 作り終えた行を持ったまま幅を変え、折り返しのやり直しにかかる時間を測る。
        sample.resize = milliseconds {
            view.window.setContentSize(NSSize(width: 600, height: Self.viewport.height))
            settle(view.host)
            view.window.setContentSize(Self.viewport)
            settle(view.host)
        }
    }

    /// `swift test` はテストの標準出力を終了時にまとめて渡す。途中経過を見るときは、
    /// `MKTOWN_PERF_LOG` に既存のファイルのパスを渡すと、そこへも1行ずつ追記する。
    private func report(_ line: String) {
        print("PERF \(line)")
        fflush(stdout)
        if let path = ProcessInfo.processInfo.environment["MKTOWN_PERF_LOG"],
           let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data("PERF \(line)\n".utf8))
            try? handle.close()
        }
    }

    private func median(_ values: [Double]) -> Double {
        values.sorted()[values.count / 2]
    }

    private func measure(_ name: String, _ source: String) throws {
        report("\(name): \(source.utf16.count)字")
        _ = try sample(source)
        let samples = try (0..<3).map { _ in try sample(source) }
        let last = try XCTUnwrap(samples.last)
        XCTAssertGreaterThan(last.scrollSteps, 0, "プレビューをスクロールできていない")
        func ms(_ value: KeyPath<Sample, Double>) -> String {
            String(format: "%.1f", median(samples.map { $0[keyPath: value] }))
        }
        report("\(name) 初回表示: \(ms(\.initialDisplay)) ms")
        report("\(name) 末尾までスクロール: \(ms(\.scrollTotal)) ms" +
               "（\(last.scrollSteps)回、最長の1回 \(ms(\.scrollWorstStep)) ms）")
        report("\(name) 幅の変更の往復: \(ms(\.resize)) ms")
        report("\(name) メモリの増分: \(ms(\.footprint)) MB、" +
               "NSTextView \(last.textViews)個、文書の高さ \(Int(last.documentHeight)) pt")
        report("\(name) 閉じてからNSTextViewの解放まで: \(ms(\.teardown)) ms" +
               "（スクロール後に生きていた数 \(last.liveTextViews)個、うち画面上 \(last.textViews)個、" +
               "1.5秒待ったあと \(last.idleTextViews)個、解放されずに残った数 \(last.leftTextViews)個）")
    }

    func testPlainParagraphs() throws {
        try measure("素の段落250個", plainDocument(paragraphs: 250))
        try measure("素の段落1000個", plainDocument(paragraphs: 1000))
        try measure("素の段落3000個", plainDocument(paragraphs: 3000))
    }

    func testMixedDocument() throws {
        try measure("混在50節", mixedDocument(sections: 50))
        try measure("混在200節", mixedDocument(sections: 200))
    }
}
