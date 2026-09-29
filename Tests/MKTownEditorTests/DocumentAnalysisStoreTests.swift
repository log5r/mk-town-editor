import XCTest
@testable import MKTownEditor

@MainActor
final class DocumentAnalysisStoreTests: XCTestCase {
    func testPreviewKeepsCompletedSourceDuringTypingAndUpdatesWhenAnalysisFinishes() async throws {
        let store = DocumentAnalysisStore()
        store.update(source: "# Before")
        for _ in 0..<100 where store.snapshot?.source != "# Before" {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(store.snapshot?.source, "# Before")

        for source in ["# After", "# After typing", ""] {
            let previousSource = store.snapshot?.source
            store.update(source: source)
            // No main-actor suspension: publication cannot have happened yet.
            let pending = PreviewPresentation(snapshot: store.snapshot,
                requestedSource: source, currentSource: source, dialect: .extended)
            XCTAssertNotNil(pending.snapshot, "Typing must not return to the loading indicator")
            XCTAssertEqual(pending.source, previousSource)
            XCTAssertEqual(pending.snapshot?.source, pending.source)
            XCTAssertFalse(pending.isCurrent, "Stale source offsets must not be interactive")

            for _ in 0..<100 where store.snapshot?.source != source {
                try await Task.sleep(for: .milliseconds(5))
            }
            let completed = PreviewPresentation(snapshot: store.snapshot,
                requestedSource: source, currentSource: source, dialect: .extended)
            XCTAssertEqual(completed.source, source)
            XCTAssertTrue(completed.isCurrent)
        }
    }

    func testPreviewRequiresInitialAnalysisAndMatchingDialect() {
        let initial = PreviewPresentation(snapshot: nil, requestedSource: "new",
            currentSource: "new", dialect: .extended)
        XCTAssertNil(initial.snapshot)
        XCTAssertFalse(initial.isCurrent)

        let changedDialect = PreviewPresentation(snapshot: DocumentSnapshot(source: "new"),
            requestedSource: "new", currentSource: "new", dialect: .basic)
        XCTAssertNil(changedDialect.snapshot)
        XCTAssertFalse(changedDialect.isCurrent)
    }

    func testPausedPreviewUsesSnapshotSourceUntilRefreshCompletes() {
        let presentation = PreviewPresentation(snapshot: DocumentSnapshot(source: "frozen"),
            requestedSource: "refresh requested", currentSource: "live", dialect: .extended)
        XCTAssertEqual(presentation.source, "frozen")
        XCTAssertEqual(presentation.snapshot?.source, presentation.source)
        XCTAssertFalse(presentation.isCurrent)
    }

    func testSameSourceReanalyzesWhenDialectChanges() async throws {
        let store = DocumentAnalysisStore()
        let source = "| A |\n| --- |\n| B |"
        store.update(source: source, dialect: .extended)
        for _ in 0..<100 where store.snapshot?.dialect != .extended {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(store.snapshot?.analysis.blocks.contains { $0.kind == .table } == true)
        store.update(source: source, dialect: .basic)
        for _ in 0..<100 where store.snapshot?.dialect != .basic {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(store.snapshot?.analysis.blocks.contains { $0.kind == .table } == true)
    }
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
