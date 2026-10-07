import Combine
import Foundation
import NaturalLanguage

enum WordCountMode: String, Codable, CaseIterable, Sendable {
    case whitespace
    case japanese
    case english

    var title: String {
        switch self {
        case .whitespace: String(localized: "空白区切り")
        case .japanese: String(localized: "日本語の単語分割")
        case .english: String(localized: "英語の単語分割")
        }
    }

    var explanation: String {
        switch self {
        case .whitespace: String(localized: "空白・改行で分けたまとまりを数えます。")
        case .japanese: String(localized: "日本語として単語に分け、句読点や空白を除いて数えます。")
        case .english: String(localized: "英語として単語に分け、句読点や空白を除いて数えます。")
        }
    }

    func count(in text: String) -> Int {
        if self == .whitespace {
            return text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        }
        return count(in: text, checkCancellation: {})
    }

    /// Returning false from NLTokenizer's callback stops traversal immediately.
    func count<Failure>(in text: String,
                        checkCancellation: () throws(Failure) -> Void) throws(Failure) -> Int {
        try checkCancellation()
        if self == .whitespace {
            return try DocumentStatistics.scan(text, checkCancellation: checkCancellation).words
        }
        guard !text.isEmpty else { return 0 }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(self == .japanese ? .japanese : .english)
        tokenizer.string = text
        var count = 0
        var failure: Failure?
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { _, _ in
            do throws(Failure) { try checkCancellation() }
            catch { failure = error; return false }
            count += 1
            return true
        }
        if let failure { throw failure }
        try checkCancellation()
        return count
    }
}

enum ReadingLanguage: String, Codable, CaseIterable, Sendable {
    case japanese
    case english

    var title: String { self == .japanese ? String(localized: "日本語") : String(localized: "英語") }
    var unit: String { self == .japanese ? String(localized: "文字/分") : String(localized: "語/分") }
}

struct ReadingEstimateSettings: Codable, Equatable, Sendable {
    var language: ReadingLanguage = .japanese
    var japaneseReadingRate = 600
    var japaneseSpeakingRate = 300
    var englishReadingRate = 200
    var englishSpeakingRate = 130

    var readingRate: Int {
        language == .japanese ? japaneseReadingRate : englishReadingRate
    }

    var speakingRate: Int {
        language == .japanese ? japaneseSpeakingRate : englishSpeakingRate
    }

    func estimatedMinutes(for text: String, spoken: Bool) -> Int? {
        let amount = language == .japanese
            ? DocumentStatistics(text: text).nonWhitespaceCharacters
            : WordCountMode.english.count(in: text)
        guard amount > 0 else { return nil }
        let rate = max(1, spoken ? speakingRate : readingRate)
        return (amount + rate - 1) / rate
    }
}

struct DocumentStatistics: Equatable, Sendable {
    let characters: Int
    let nonWhitespaceCharacters: Int
    let words: Int
    let lines: Int

    private init(characters: Int, nonWhitespaceCharacters: Int, words: Int, lines: Int) {
        self.characters = characters
        self.nonWhitespaceCharacters = nonWhitespaceCharacters
        self.words = words
        self.lines = lines
    }

    static let empty = DocumentStatistics(text: "")

    init(text: String) {
        self = DocumentStatistics.scan(text) {}
    }

    /// Scans `text` on the current task and throws `CancellationError` once the task is cancelled,
    /// so superseded background scans stop early instead of traversing the whole text.
    static func scanObservingCancellation(_ text: String) throws -> DocumentStatistics {
        try scan(text) { try Task.checkCancellation() }
    }

    /// Characters scanned between cancellation checks.
    static let cancellationCheckInterval = 4096

    /// Single-pass scan that calls `checkCancellation` before the first character and after every
    /// `cancellationCheckInterval` characters. A non-throwing closure makes the scan non-throwing.
    static func scan<Failure>(_ text: String,
                               checkCancellation: () throws(Failure) -> Void) throws(Failure) -> DocumentStatistics {
        var characters = 0
        var nonWhitespace = 0
        var words = 0
        var lines = text.isEmpty ? 0 : 1
        var inWord = false
        var untilCheck = cancellationCheckInterval
        try checkCancellation()
        for character in text {
            untilCheck -= 1
            if untilCheck == 0 {
                try checkCancellation()
                untilCheck = cancellationCheckInterval
            }
            characters += 1
            let whitespace = character.isWhitespace || character.isNewline
            if !whitespace {
                nonWhitespace += 1
                if !inWord { words += 1 }
            }
            inWord = !whitespace
            for scalar in character.unicodeScalars where CharacterSet.newlines.contains(scalar) {
                lines += 1
            }
        }
        return DocumentStatistics(characters: characters, nonWhitespaceCharacters: nonWhitespace,
                                  words: words, lines: lines)
    }

    static func selection(in text: String, range: NSRange) -> DocumentStatistics? {
        selection(in: text, range: range) {}
    }

    static func selection(in text: String, ranges: [NSRange]) -> DocumentStatistics? {
        selection(in: text, ranges: ranges) {}
    }

    /// Selection statistics that stop at the next cancellation check of the current task.
    static func selectionObservingCancellation(in text: String, ranges: [NSRange]) throws -> DocumentStatistics? {
        try selection(in: text, ranges: ranges) { try Task.checkCancellation() }
    }

    private static func selection<Failure>(in text: String, range: NSRange,
                                    checkCancellation: () throws(Failure) -> Void) throws(Failure) -> DocumentStatistics? {
        let source = text as NSString
        guard range.length > 0, range.location >= 0, range.location <= source.length,
              range.length <= source.length - range.location else { return nil }
        try checkCancellation()
        return try scan(source.substring(with: range), checkCancellation: checkCancellation)
    }

    private static func selection<Failure>(in text: String, ranges: [NSRange],
                                    checkCancellation: () throws(Failure) -> Void) throws(Failure) -> DocumentStatistics? {
        var parts: [DocumentStatistics] = []
        for range in ranges {
            if let part = try selection(in: text, range: range, checkCancellation: checkCancellation) {
                parts.append(part)
            }
        }
        guard !parts.isEmpty else { return nil }
        return DocumentStatistics(characters: parts.reduce(0) { $0 + $1.characters },
                                  nonWhitespaceCharacters: parts.reduce(0) { $0 + $1.nonWhitespaceCharacters },
                                  words: parts.reduce(0) { $0 + $1.words },
                                  lines: parts.reduce(0) { $0 + $1.lines })
    }

    static func sectionRange(at location: Int, in analysis: MarkdownAnalysis,
                             documentLength: Int) -> NSRange? {
        sectionRange(at: location, in: MarkdownOutline.entries(in: analysis), documentLength: documentLength)
    }

    static func sectionRange(at location: Int, in entries: [MarkdownOutlineEntry],
                             documentLength: Int) -> NSRange? {
        guard let current = entries.last(where: { $0.sourceRange.location <= location }),
              let index = entries.firstIndex(where: { $0.id == current.id }) else { return nil }
        let end = entries.dropFirst(index + 1).first { $0.level <= current.level }?
            .sourceRange.location ?? documentLength
        return NSRange(location: current.sourceRange.location,
                       length: max(0, end - current.sourceRange.location))
    }
}

/// Selection and section scans run only when the source snapshot or selection changes.
/// Section statistics are cached per section range, so moving the caret inside a section publishes
/// synchronously, and superseded background scans stop at their next cancellation check.
@MainActor
final class DocumentStatusStore: ObservableObject {
    /// Background scans that ran to completion, including superseded ones whose result is
    /// discarded. Cancellation-aware scans keep this close to the number of published results.
    final class ScanCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var completed: Int { lock.withLock { count } }
        func record() { lock.withLock { count += 1 } }
    }
    let scanCounter = ScanCounter()

    @Published private(set) var selection: DocumentStatistics?
    @Published private(set) var section: (title: String, value: DocumentStatistics)?
    private var generation = 0
    private var task: Task<Void, Never>?
    private var source: String?
    private var dialect: MarkdownDialect?
    private var ranges: [NSRange] = []
    private var sectionCache: [NSRange: DocumentStatistics] = [:]

    func update(snapshot: DocumentSnapshot?, selections: [NSRange]) {
        guard let snapshot else { return }
        let sourceChanged = source != snapshot.source || dialect != snapshot.dialect
        guard sourceChanged || ranges != selections else { return }
        if sourceChanged { sectionCache.removeAll() }
        source = snapshot.source
        dialect = snapshot.dialect
        ranges = selections
        generation += 1
        let requested = generation
        task?.cancel()
        task = nil

        let location = selections.first?.location ?? 0
        let title = MarkdownOutline.currentSection(at: location, in: snapshot.outlineEntries)?.title
        let sectionRange = DocumentStatistics.sectionRange(at: location, in: snapshot.outlineEntries,
                                                           documentLength: snapshot.source.utf16.count)
        let cachedValue = sectionRange.flatMap { sectionCache[$0] }
        let needsSelection = selections.contains { $0.length > 0 }
        let needsSectionScan = sectionRange != nil && cachedValue == nil
        if !needsSelection, !needsSectionScan {
            publish(selection: nil, title: title, section: cachedValue, generation: requested)
            return
        }

        let counter = scanCounter
        task = Task.detached(priority: .utility) { [weak self] in
            do {
                let selection = needsSelection
                    ? try DocumentStatistics.selectionObservingCancellation(in: snapshot.source, ranges: selections)
                    : nil
                let section: DocumentStatistics?
                if let cachedValue {
                    section = cachedValue
                } else if let sectionRange {
                    try Task.checkCancellation()
                    section = try DocumentStatistics.scanObservingCancellation(
                        (snapshot.source as NSString).substring(with: sectionRange))
                } else {
                    section = nil
                }
                counter.record()
                try Task.checkCancellation()
                await self?.receive(selection: selection, title: title, sectionRange: sectionRange,
                                    section: section, generation: requested)
            } catch {
                // Superseded by a newer update; its own task publishes the current state.
            }
        }
    }

    private func receive(selection: DocumentStatistics?, title: String?, sectionRange: NSRange?,
                         section: DocumentStatistics?, generation: Int) {
        guard self.generation == generation else { return }
        if let sectionRange, let section { sectionCache[sectionRange] = section }
        publish(selection: selection, title: title, section: section, generation: generation)
    }

    private func publish(selection: DocumentStatistics?, title: String?,
                         section: DocumentStatistics?, generation: Int) {
        guard self.generation == generation else { return }
        if self.selection != selection { self.selection = selection }
        let next = title.flatMap { title in section.map { (title: title, value: $0) } }
        if self.section?.title != next?.title || self.section?.value != next?.value { self.section = next }
    }
}
