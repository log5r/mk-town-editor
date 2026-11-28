import Foundation

/// Source ranges refer to the LF-normalized editor text, including for CRLF files.
struct DocumentSaveWarnings: Sendable {
    struct Input: Equatable, Sendable {
        let source: String
        let encoding: MarkdownTextEncoding
        let format: MarkdownTextFormat

        init?(document: MarkdownDocument) {
            guard document.format.hasMixedNewlines || !document.encoding.representsAllUnicode else { return nil }
            source = document.text
            encoding = document.encoding
            format = document.format
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.encoding == rhs.encoding && lhs.format == rhs.format &&
                MarkdownTextFormat.identicalText(lhs.source, rhs.source)
        }
    }

    enum Item: Identifiable, Sendable {
        case character(MarkdownEncodingLoss.Occurrence)
        case newline(MarkdownTextFormat.NewlineWarning, expected: MarkdownTextFormat.Newline)

        var id: Int { range.location }
        var range: NSRange {
            switch self {
            case let .character(item): item.range
            case let .newline(item, _): item.range
            }
        }

        var title: String {
            switch self {
            case let .character(item): String(localized: "\(item.line)行目の「\(item.character)」")
            case let .newline(item, _): String(localized: "\(item.line)行目の改行")
            }
        }

        var detail: String {
            switch self {
            case let .character(item): String(localized: "\(item.codePoints)（置換後は「\(item.replacement)」）")
            case let .newline(item, expected): String(localized: "\(item.newline.title)（書類は\(expected.title)）")
            }
        }
    }

    let input: Input
    let encodingLoss: MarkdownEncodingLoss?
    let items: [Item]

    init(input: Input) {
        self.input = input
        encodingLoss = input.encoding.representsAllUnicode ? nil :
            MarkdownEncodingLoss(source: input.source, encoding: input.encoding)
        var items = input.format.newlineWarnings(in: input.source).map {
            Item.newline($0, expected: input.format.newline)
        }
        if let encodingLoss {
            items += encodingLoss.occurrences.map(Item.character)
            items.sort { $0.range.location < $1.range.location }
        }
        self.items = items
    }
}

private extension MarkdownTextEncoding {
    var representsAllUnicode: Bool {
        switch self {
        case .utf8, .utf16LE, .utf16BE: true
        case .shiftJIS, .eucJP, .iso2022JP, .latin1: false
        }
    }
}
