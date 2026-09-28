import XCTest
@testable import MKTownEditor

@MainActor
final class DocumentAnalysisStoreTests: XCTestCase {
    func testSnapshotSharesSourceAcrossAnalysisStatisticsAndHighlighting() {
        let source = "# 見出し\n\n- [x] 完了"
        let snapshot = DocumentSnapshot(source: source)

        XCTAssertEqual(snapshot.source, source)
        XCTAssertEqual(snapshot.analysis.rootBlocks.first?.kind, .heading(level: 1))
        XCTAssertEqual(snapshot.statistics.lines, 3)
        XCTAssertTrue(snapshot.syntaxSpans.contains { $0.role == .heading })
        XCTAssertEqual(snapshot.syntaxSpans, MarkdownSyntaxHighlighter.spans(in: source))
        XCTAssertEqual(MarkdownRenderer.render(snapshot.analysis).string,
                       MarkdownRenderer.render(source).string)
    }

    func testLateResultFromOldGenerationCannotReplaceNewerSnapshot() async throws {
        let store = DocumentAnalysisStore { source in
            if source == "old" {
                try? await Task.sleep(for: .milliseconds(100))
            } else {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return DocumentSnapshot(source: source)
        }
        store.update(source: "old")
        store.update(source: "new")

        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(store.snapshot?.source, "new")
        XCTAssertEqual(store.snapshot?.statistics.characters, 3)
    }

    func testCancellationPreventsPendingResultFromPublishing() async throws {
        let store = DocumentAnalysisStore { source in
            try? await Task.sleep(for: .milliseconds(30))
            return DocumentSnapshot(source: source)
        }
        store.update(source: "temporary")
        store.cancel()

        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(store.snapshot)
    }

    func testAnalysisRunsAwayFromMainThreadAndCoalescesRepeatedSource() async throws {
        let probe = AnalysisExecutionProbe()
        let store = DocumentAnalysisStore { source in
            await probe.record(isMainThread: isExecutingOnMainThread())
            return DocumentSnapshot(source: source)
        }
        store.update(source: "# title")
        store.update(source: "# title")

        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(store.snapshot?.source, "# title")
        let result = await probe.result()
        XCTAssertEqual(result.count, 1)
        XCTAssertFalse(result.isMainThread)
    }

    func testRevertingToPublishedSourceInvalidatesInFlightResult() async throws {
        let store = DocumentAnalysisStore { source in
            if source == "changed" { try? await Task.sleep(for: .milliseconds(80)) }
            return DocumentSnapshot(source: source)
        }
        store.update(source: "original")
        for _ in 0..<50 where store.snapshot?.source != "original" {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(store.snapshot?.source, "original")

        store.update(source: "changed")
        store.update(source: "original")
        try await Task.sleep(for: .milliseconds(110))
        XCTAssertEqual(store.snapshot?.source, "original")
    }
}

private func isExecutingOnMainThread() -> Bool {
    Thread.isMainThread
}

private actor AnalysisExecutionProbe {
    private var count = 0
    private var isMainThread = true

    func record(isMainThread: Bool) {
        count += 1
        self.isMainThread = isMainThread
    }

    func result() -> (count: Int, isMainThread: Bool) {
        (count, isMainThread)
    }
}
