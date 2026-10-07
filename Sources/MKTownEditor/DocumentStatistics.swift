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
        guard !text.isEmpty else { return 0 }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(self == .japanese ? .japanese : .english)
        tokenizer.string = text
        var count = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { _, _ in
            count += 1
            return true
        }
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
        var characters = 0
        var nonWhitespace = 0
        var words = 0
        var lines = text.isEmpty ? 0 : 1
        var inWord = false
        for character in text {
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
        self.characters = characters
        nonWhitespaceCharacters = nonWhitespace
        self.words = words
        self.lines = lines
    }

    static func selection(in text: String, range: NSRange) -> DocumentStatistics? {
        let source = text as NSString
        guard range.length > 0, range.location >= 0, range.location <= source.length,
              range.length <= source.length - range.location else { return nil }
        return DocumentStatistics(text: source.substring(with: range))
    }

    static func selection(in text: String, ranges: [NSRange]) -> DocumentStatistics? {
        let parts = ranges.compactMap { selection(in: text, range: $0) }
        guard !parts.isEmpty else { return nil }
        return DocumentStatistics(characters: parts.reduce(0) { $0 + $1.characters },
                                  nonWhitespaceCharacters: parts.reduce(0) { $0 + $1.nonWhitespaceCharacters },
                                  words: parts.reduce(0) { $0 + $1.words },
                                  lines: parts.reduce(0) { $0 + $1.lines })
    }

    static func sectionRange(at location: Int, in analysis: MarkdownAnalysis,
                             documentLength: Int) -> NSRange? {
        let entries = MarkdownOutline.entries(in: analysis)
        guard let current = entries.last(where: { $0.sourceRange.location <= location }),
              let index = entries.firstIndex(where: { $0.id == current.id }) else { return nil }
        let end = entries.dropFirst(index + 1).first { $0.level <= current.level }?
            .sourceRange.location ?? documentLength
        return NSRange(location: current.sourceRange.location,
                       length: max(0, end - current.sourceRange.location))
    }
}

/// Selection and section scans run only when the source snapshot or selection changes.
@MainActor
final class DocumentStatusStore: ObservableObject {
    @Published private(set) var selection: DocumentStatistics?
    @Published private(set) var section: (title: String, value: DocumentStatistics)?
    private var generation = 0
    private var task: Task<Void, Never>?
    private var source: String?
    private var dialect: MarkdownDialect?
    private var ranges: [NSRange] = []

    func update(snapshot: DocumentSnapshot?, selections: [NSRange]) {
        guard let snapshot, source != snapshot.source || ranges != selections || dialect != snapshot.dialect else { return }
        source = snapshot.source
        dialect = snapshot.dialect
        ranges = selections
        generation += 1
        let requested = generation
        task?.cancel()
        task = Task.detached(priority: .utility) { [weak self] in
            let selection = DocumentStatistics.selection(in: snapshot.source, ranges: selections)
            let location = selections.first?.location ?? 0
            let heading = MarkdownOutline.currentSection(at: location, in: snapshot.outlineEntries)
            let range = DocumentStatistics.sectionRange(at: location, in: snapshot.analysis,
                documentLength: snapshot.source.utf16.count)
            let section = range.map {
                DocumentStatistics(text: (snapshot.source as NSString).substring(with: $0))
            }
            guard !Task.isCancelled else { return }
            await self?.publish(selection: selection, title: heading?.title, section: section, generation: requested)
        }
    }

    private func publish(selection: DocumentStatistics?, title: String?,
                         section: DocumentStatistics?, generation: Int) {
        guard self.generation == generation else { return }
        if self.selection != selection { self.selection = selection }
        let next = title.flatMap { title in section.map { (title: title, value: $0) } }
        if self.section?.title != next?.title || self.section?.value != next?.value { self.section = next }
    }
}
