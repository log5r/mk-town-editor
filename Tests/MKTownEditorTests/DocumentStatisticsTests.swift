import XCTest
@testable import MKTownEditor

final class DocumentStatisticsTests: XCTestCase {
    func testSinglePassMatchesOriginalDefinitionsForUnicodeAndNewlines() {
        for text in ["", "a\r\nb\rc\nd\u{85}e\u{2028}f\u{2029}", "🙂e\u{301} 家族👨‍👩‍👧‍👦 \tword", " \n\n"] {
            let value = DocumentStatistics(text: text)
            XCTAssertEqual(value.characters, text.count)
            XCTAssertEqual(value.nonWhitespaceCharacters, text.filter { !$0.isWhitespace && !$0.isNewline }.count)
            XCTAssertEqual(value.words, text.split { $0.isWhitespace || $0.isNewline }.count)
            XCTAssertEqual(value.lines, text.isEmpty ? 0 : text.components(separatedBy: .newlines).count)
        }
    }

    @MainActor
    func testStatusKeepsPreviousValuesUntilBackgroundUpdateAndIgnoresRepeatedSelection() async throws {
        let store = DocumentStatusStore()
        let snapshot = DocumentSnapshot(source: "# One\nabc\n# Two\ndef")
        store.update(snapshot: snapshot, selections: [NSRange(location: 6, length: 3)])
        for _ in 0..<100 where store.selection == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.selection?.characters, 3)
        XCTAssertEqual(store.section?.title, "One")
        var changes = 0
        let observation = store.objectWillChange.sink { changes += 1 }
        store.update(snapshot: snapshot, selections: [NSRange(location: 6, length: 3)])
        store.update(snapshot: nil, selections: [NSRange(location: 0, length: 0)])
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(store.selection?.characters, 3)
        withExtendedLifetime(observation) {}
        XCTAssertEqual(snapshot.wordCounts[.english], WordCountMode.english.count(in: snapshot.source))
    }

    @MainActor
    func testSectionStatisticsRefreshWhenDialectChangesWithSameSourceAndSelection() async throws {
        let store = DocumentStatusStore()
        let text = "---\n# Metadata\n---\nbody"
        let selections = [NSRange(location: text.utf16.count - 1, length: 0)]
        store.update(snapshot: DocumentSnapshot(source: text, dialect: .basic), selections: selections)
        for _ in 0..<100 where store.section == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(store.section)
        store.update(snapshot: DocumentSnapshot(source: text, dialect: .extended), selections: selections)
        for _ in 0..<100 where store.section != nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNil(store.section)
    }

    func testScanObservingCancellationThrowsOnceTheTaskIsCancelled() async throws {
        let text = String(repeating: "word ", count: DocumentStatistics.cancellationCheckInterval)
        let completed = try await Task.detached { try DocumentStatistics.scanObservingCancellation(text) }.value
        XCTAssertEqual(completed, DocumentStatistics(text: text))

        let cancelled = Task.detached {
            await withUnsafeContinuation { continuation in continuation.resume() }
            return Result { try DocumentStatistics.scanObservingCancellation(text) }
        }
        cancelled.cancel()
        let result = await cancelled.value
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }

        let selection = Task.detached {
            Result { try DocumentStatistics.selectionObservingCancellation(
                in: text, ranges: [NSRange(location: 0, length: 5)]) }
        }
        selection.cancel()
        let selectionResult = await selection.value
        XCTAssertThrowsError(try selectionResult.get()) { XCTAssertTrue($0 is CancellationError) }
    }

    func testScanObservingCancellationStopsMidwayThroughLargeText() async throws {
        let text = String(repeating: "lorem ipsum ", count: 400_000)
        let clock = ContinuousClock()
        let fullScan = clock.measure { _ = DocumentStatistics(text: text) }
        let (started, signal) = AsyncStream<Void>.makeStream()
        let scan = Task.detached(priority: .utility) {
            signal.yield()
            signal.finish()
            return Result { try DocumentStatistics.scanObservingCancellation(text) }
        }
        for await _ in started { break }
        let cancelledAt = clock.now
        scan.cancel()
        let result = await scan.value
        let elapsed = clock.now - cancelledAt
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertLessThan(elapsed, max(fullScan / 2, .milliseconds(50)))
    }

    @MainActor
    func testCaretMovesBetweenScannedSectionsPublishSynchronouslyUntilSourceChanges() async throws {
        let store = DocumentStatusStore()
        let text = "# One\nabc\n# Two\ndefgh"
        let snapshot = DocumentSnapshot(source: text)
        let source = text as NSString
        store.update(snapshot: snapshot, selections: [NSRange(location: source.range(of: "abc").location, length: 0)])
        for _ in 0..<100 where store.section == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.section?.title, "One")
        XCTAssertEqual(store.section?.value.nonWhitespaceCharacters, 7)
        store.update(snapshot: snapshot, selections: [NSRange(location: source.range(of: "def").location, length: 0)])
        for _ in 0..<100 where store.section?.title != "Two" { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.section?.value.nonWhitespaceCharacters, 9)

        var changes = 0
        let observation = store.objectWillChange.sink { changes += 1 }
        store.update(snapshot: snapshot, selections: [NSRange(location: source.range(of: "bc").location, length: 0)])
        XCTAssertEqual(store.section?.title, "One")
        XCTAssertEqual(store.section?.value.nonWhitespaceCharacters, 7)
        XCTAssertEqual(changes, 1)
        store.update(snapshot: snapshot, selections: [NSRange(location: source.range(of: "fgh").location, length: 0)])
        XCTAssertEqual(store.section?.title, "Two")
        XCTAssertEqual(changes, 2)
        store.update(snapshot: snapshot, selections: [NSRange(location: source.range(of: "gh").location, length: 0)])
        XCTAssertEqual(changes, 2)
        withExtendedLifetime(observation) {}

        let edited = DocumentSnapshot(source: "# One\nabc\n# Two\ndefghij")
        store.update(snapshot: edited, selections: [NSRange(location: source.range(of: "gh").location, length: 0)])
        XCTAssertEqual(store.section?.value.nonWhitespaceCharacters, 9)
        for _ in 0..<100 where store.section?.value.nonWhitespaceCharacters != 11 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(store.section?.title, "Two")
        XCTAssertEqual(store.section?.value.nonWhitespaceCharacters, 11)
    }

    @MainActor
    func testRapidSelectionChangesInLargeSectionDoNotAccumulateFullScans() async throws {
        let body = String(repeating: "lorem ipsum dolor sit amet\n", count: 20_000)
        let text = "# Large\n" + body
        let snapshot = DocumentSnapshot(source: text)
        let store = DocumentStatusStore()
        let updates = 320
        let length = text.utf16.count
        for step in 0..<updates {
            store.update(snapshot: snapshot, selections: [NSRange(location: 8, length: length - 8 - step)])
        }
        for _ in 0..<2000 where store.selection == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.selection?.characters, (text as NSString).substring(
            with: NSRange(location: 8, length: length - 7 - updates)).count)
        XCTAssertEqual(store.section?.title, "Large")
        // Counting completed scans instead of timing them keeps this independent of machine
        // load. Superseded scans used to run to completion: all 320 of them.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertLessThanOrEqual(store.scanCounter.completed, 4)
    }

    func testCountsCharactersWordsAndLines() {
        let statistics = DocumentStatistics(text: "Hello Markdown\nこんにちは 世界")

        XCTAssertEqual(statistics.characters, 23)
        XCTAssertEqual(statistics.words, 4)
        XCTAssertEqual(statistics.lines, 2)
    }

    func testEmptyDocumentHasNoLines() {
        let statistics = DocumentStatistics(text: "")

        XCTAssertEqual(statistics.characters, 0)
        XCTAssertEqual(statistics.words, 0)
        XCTAssertEqual(statistics.lines, 0)
    }

    func testWhitespaceAndUTF16SelectionCountsGraphemeCharacters() {
        let text = "A🙂 \nB"
        let total = DocumentStatistics(text: text)
        XCTAssertEqual(total.characters, 5)
        XCTAssertEqual(total.nonWhitespaceCharacters, 3)
        let emoji = DocumentStatistics.selection(in: text, range: NSRange(location: 1, length: 2))
        XCTAssertEqual(emoji?.characters, 1)
        XCTAssertEqual(emoji?.nonWhitespaceCharacters, 1)
        XCTAssertNil(DocumentStatistics.selection(in: text,
                                                  range: NSRange(location: NSNotFound, length: 1)))
        XCTAssertNil(DocumentStatistics.selection(in: text, range: NSRange(location: 0, length: 0)))
    }

    func testCurrentSectionEndsAtNextHeadingOfSameOrHigherLevel() throws {
        let text = "# One\nalpha\n## Inner\nbeta\n# Two\ngamma"
        let analysis = MarkdownAnalysis(text)
        let source = text as NSString
        let first = try XCTUnwrap(DocumentStatistics.sectionRange(
            at: source.range(of: "alpha").location, in: analysis, documentLength: source.length))
        XCTAssertEqual(source.substring(with: first), "# One\nalpha\n## Inner\nbeta\n")
        let nested = try XCTUnwrap(DocumentStatistics.sectionRange(
            at: source.range(of: "beta").location, in: analysis, documentLength: source.length))
        XCTAssertEqual(source.substring(with: nested), "## Inner\nbeta\n")
    }

    func testJapaneseTokenizationDiffersFromWhitespaceCounting() {
        let text = "今日は晴れです。 明日も晴れ。"
        XCTAssertEqual(WordCountMode.whitespace.count(in: text), 2)
        XCTAssertGreaterThan(WordCountMode.japanese.count(in: text), 2)
        XCTAssertEqual(WordCountMode.japanese.count(in: "  \n。!?"), 0)
    }

    func testEnglishTokenizationOmitsPunctuation() {
        XCTAssertEqual(WordCountMode.english.count(in: "Hello, world!"), 2)
        XCTAssertEqual(WordCountMode.english.count(in: ""), 0)
    }

    func testReadingAndSpeakingEstimatesUseLanguageSpecificUnitsAndRates() {
        var settings = ReadingEstimateSettings()
        settings.japaneseReadingRate = 4
        settings.japaneseSpeakingRate = 2
        XCTAssertEqual(settings.estimatedMinutes(for: "日本語です。", spoken: false), 2)
        XCTAssertEqual(settings.estimatedMinutes(for: "日本語です。", spoken: true), 3)
        XCTAssertNil(settings.estimatedMinutes(for: "  \n", spoken: false))

        settings.language = .english
        settings.englishReadingRate = 2
        settings.englishSpeakingRate = 1
        XCTAssertEqual(settings.estimatedMinutes(for: "One, two, three!", spoken: false), 2)
        XCTAssertEqual(settings.estimatedMinutes(for: "One, two, three!", spoken: true), 3)
    }
}
