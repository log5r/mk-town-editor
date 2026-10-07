import XCTest
@testable import MKTownEditor

@MainActor
final class DocumentAnalysisStoreTests: XCTestCase {
    func testRapidEditsStopSupersededSnapshotInsideWordCounting() async throws {
        let gate = SnapshotWordCountGate()
        defer { gate.release.signal() }
        let obsolete = String(repeating: "word ", count: 1_200)
        let store = DocumentAnalysisStore { source in
            if source == obsolete {
                return try DocumentSnapshot(source: source, dialect: .extended) {
                    try Task.checkCancellation()
                    if gate.recordCheck() == 20 {
                        _ = gate.release.wait(timeout: .now() + 5)
                    }
                    try Task.checkCancellation()
                }
            }
            return try DocumentSnapshot.observingCancellation(source: source)
        }
        store.update(source: obsolete)
        for _ in 0..<200 where gate.checks < 20 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(gate.checks, 20, "the scan must reach the tokenizer before being superseded")
        for index in 0..<12 { store.update(source: "Latest \(index)") }
        gate.release.signal()
        for _ in 0..<200 where store.snapshot?.source != "Latest 11" {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(store.snapshot?.source, "Latest 11")
        XCTAssertEqual(gate.checks, 20, "obsolete token scans must stop rather than visit all 1,200 words")
        XCTAssertEqual(store.snapshot?.wordCounts, DocumentSnapshot(source: "Latest 11").wordCounts)
    }

    func testCancelledSnapshotStopsBeforeParsingInBothDialects() async throws {
        for dialect in MarkdownDialect.allCases {
            let task = Task.detached {
                withUnsafeCurrentTask { $0?.cancel() }
                return try DocumentSnapshot.observingCancellation(source: "# Cancelled", dialect: dialect)
            }
            do { _ = try await task.value; XCTFail("Expected cancellation") }
            catch is CancellationError { }
        }
    }

    func testTokenizersStopWhenCancellationOccursDuringTraversal() async throws {
        for mode in [WordCountMode.japanese, .english, .whitespace] {
            let task = Task.detached {
                var checks = 0
                do {
                    _ = try mode.count(in: String(repeating: "word 日本語 ", count: 1_000)) {
                        checks += 1
                        if checks == 3 { withUnsafeCurrentTask { $0?.cancel() } }
                        try Task.checkCancellation()
                    }
                    XCTFail("Expected cancellation")
                } catch is CancellationError { }
                return checks
            }
            let checks = try await task.value
            XCTAssertEqual(checks, 3)
        }
    }

    func testPresentationIDsMapCurrentSourceBlocksAfterInsertion() throws {
        let source = "# Heading\n\nParagraph\n\n# Heading"
        let before = MarkdownAnalysis(source)
        let after = MarkdownAnalysis("Inserted\n\n" + source)
        let originalIDs = PreviewBlockIdentity.identifiers(in: before)
        let currentIDs = PreviewBlockIdentity.identifiers(in: after)
        let oldHeadings = before.blocks.filter { $0.kind == .heading(level: 1) }
        let newHeadings = after.blocks.filter { $0.kind == .heading(level: 1) }
        XCTAssertNotEqual(oldHeadings.map(\.id), newHeadings.map(\.id))
        XCTAssertEqual(oldHeadings.map { originalIDs[$0.id] }, newHeadings.map { currentIDs[$0.id] })
        XCTAssertNotEqual(currentIDs[newHeadings[0].id], currentIDs[newHeadings[1].id])
        XCTAssertEqual(currentIDs, DocumentSnapshot(source: "Inserted\n\n" + source).blockPresentationIDs)
    }

    func testNavigationTargetResolvesBySourceLocationAfterBlocksShift() throws {
        let source = "# First\n\nBody\n\n## Second\n\nTail"
        let edited = "Inserted paragraph\n\n" + source
        let before = DocumentSnapshot(source: source)
        let after = DocumentSnapshot(source: edited)
        let headingLocation = (edited as NSString).range(of: "## Second").location
        let target = PreviewNavigationTarget(sourceLocation: headingLocation, sequence: 1)
        let oldHeading = try XCTUnwrap(before.analysis.blocks.first { $0.kind == .heading(level: 2) })
        XCTAssertEqual(target.presentationID(in: after.analysis, presentationIDs: after.blockPresentationIDs),
                       before.blockPresentationIDs[oldHeading.id],
                       "The same heading keeps its presentation identity and is found by location")
        let inBody = PreviewNavigationTarget(sourceLocation: (edited as NSString).range(of: "Tail").location + 2,
                                             sequence: 2)
        let tail = try XCTUnwrap(after.analysis.blocks.last { $0.kind == .paragraph })
        XCTAssertEqual(inBody.presentationID(in: after.analysis, presentationIDs: after.blockPresentationIDs),
                       after.blockPresentationIDs[tail.id])
    }

    func testAnalysisBoundaryNormalizesBridgedText() async throws {
        let text = NSMutableString(string: String(repeating: "日本語🙂\n", count: 100)) as String
        let store = DocumentAnalysisStore(analyze: { source in
            XCTAssertTrue(source.isContiguousUTF8)
            return DocumentSnapshot(source: source)
        })
        store.update(source: text)
        for _ in 0..<100 where store.snapshot == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(store.snapshot?.source, text)
        XCTAssertEqual(store.snapshot?.source.isContiguousUTF8, true)
    }

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
    func testSnapshotValidityRequiresBothSourceAndDialect() {
        let source = "# Heading"
        for dialect in [MarkdownDialect.basic, .extended] {
            let snapshot = DocumentSnapshot(source: source, dialect: dialect)
            XCTAssertTrue(snapshot.matches(source: source, dialect: dialect))
            XCTAssertFalse(snapshot.matches(source: "# Changed", dialect: dialect))
            let other: MarkdownDialect = dialect == .basic ? .extended : .basic
            XCTAssertFalse(snapshot.matches(source: source, dialect: other))
        }
    }

    func testDialectSwitchRejectsPreviousOutlineUntilMatchingSnapshotArrives() async throws {
        let source = "---\n# Hidden\nkey: value\n---\n# Visible\nbody\n# Next\nend"
        let store = DocumentAnalysisStore()
        for dialect in [MarkdownDialect.basic, .extended, .basic] {
            let previous = store.snapshot
            store.update(source: source, dialect: dialect)
            // No main-actor suspension: the same-source, old-dialect snapshot
            // remains published, but must not enable outline actions/navigation.
            if let previous {
                XCTAssertEqual(store.snapshot?.dialect, previous.dialect)
                XCTAssertFalse(previous.matches(source: source, dialect: dialect))
            }
            for _ in 0..<100 where store.snapshot?.dialect != dialect {
                try await Task.sleep(for: .milliseconds(5))
            }
            let snapshot = try XCTUnwrap(store.snapshot)
            XCTAssertTrue(snapshot.matches(source: source, dialect: dialect))
            XCTAssertEqual(snapshot.outlineEntries.contains { $0.title == "Hidden" }, dialect == .basic)
        }
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

    func testLargeOutlineReusesBackgroundSnapshotActionsDuringRepeatedRequests() async throws {
        let source = (0..<400).map { index in
            "## Heading \(index)\n" + String(repeating: "本文🙂 content ", count: 60)
        }.joined(separator: "\n\n")
        let probe = AnalysisExecutionProbe()
        let store = DocumentAnalysisStore { source in
            await probe.record(isMainThread: isExecutingOnMainThread())
            return DocumentSnapshot(source: source)
        }
        store.update(source: source)
        for _ in 0..<1_000 where store.snapshot == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let snapshot = try XCTUnwrap(store.snapshot)
        XCTAssertEqual(snapshot.outlineEntries.count, 400)
        XCTAssertEqual(snapshot.sectionActions.count, 400)
        // Selection/scroll-driven rebuilds read the same snapshot. Four lookups
        // per row replace the old four full-document edits/analyses per row.
        for _ in 0..<10 {
            store.update(source: source)
            for (index, entry) in snapshot.outlineEntries.enumerated() {
                let actions = try XCTUnwrap(store.snapshot?.sectionActions[entry.id])
                XCTAssertEqual(actions.canMoveUp, index > 0)
                XCTAssertEqual(actions.canMoveDown, index < 399)
                XCTAssertTrue(actions.canPromote)
                XCTAssertTrue(actions.canDemote)
            }
        }
        let result = await probe.result()
        XCTAssertEqual(result.count, 1)
        XCTAssertFalse(result.isMainThread)
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

private final class SnapshotWordCountGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0
    var checks: Int { lock.lock(); defer { lock.unlock() }; return count }
    func recordCheck() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }

    func testNavigationRequestedBeforeAnalysisCatchesUpIsReplayedOnce() {
        let edited = "Inserted\n\n# Heading"
        let target = PreviewNavigationTarget(sourceLocation: (edited as NSString).range(of: "# Heading").location,
                                             sequence: 3, source: edited)
        XCTAssertFalse(target.isSettled(byDisplayedSource: "# Heading"),
                       "A preview still showing the previous text must apply the target again later")
        XCTAssertTrue(target.isSettled(byDisplayedSource: edited))
        XCTAssertTrue(PreviewNavigationTarget(sourceLocation: 0, sequence: 1)
            .isSettled(byDisplayedSource: "anything"))
    }
}
