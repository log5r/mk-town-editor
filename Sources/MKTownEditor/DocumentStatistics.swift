import Foundation
import NaturalLanguage

enum WordCountMode: String, Codable, CaseIterable, Sendable {
    case whitespace
    case japanese
    case english

    var title: String {
        switch self {
        case .whitespace: "空白区切り"
        case .japanese: "日本語の単語分割"
        case .english: "英語の単語分割"
        }
    }

    var explanation: String {
        switch self {
        case .whitespace: "空白・改行で分けたまとまりを数えます。"
        case .japanese: "日本語として単語に分け、句読点や空白を除いて数えます。"
        case .english: "英語として単語に分け、句読点や空白を除いて数えます。"
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

struct DocumentStatistics: Equatable, Sendable {
    let characters: Int
    let nonWhitespaceCharacters: Int
    let words: Int
    let lines: Int

    init(text: String) {
        characters = text.count
        nonWhitespaceCharacters = text.filter { !$0.isWhitespace && !$0.isNewline }.count
        words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        lines = text.isEmpty ? 0 : text.components(separatedBy: .newlines).count
    }

    static func selection(in text: String, range: NSRange) -> DocumentStatistics? {
        let source = text as NSString
        guard range.length > 0, range.location >= 0, range.location <= source.length,
              range.length <= source.length - range.location else { return nil }
        return DocumentStatistics(text: source.substring(with: range))
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
