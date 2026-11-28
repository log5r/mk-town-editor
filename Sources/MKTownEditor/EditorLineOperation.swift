import Foundation

struct EditorLineSortOptions: Equatable, Sendable {
    enum Key: Equatable, Sendable {
        case wholeLine
        case column(separator: String, number: Int)
        case regularExpression(pattern: String, capture: Int)

        static func == (left: Key, right: Key) -> Bool {
            switch (left, right) {
            case (.wholeLine, .wholeLine): true
            case let (.column(a, first), .column(b, second)),
                 let (.regularExpression(a, first), .regularExpression(b, second)):
                first == second && MarkdownTextFormat.identicalText(a, b)
            default: false
            }
        }
    }

    private enum InvalidKey: LocalizedError {
        case emptySeparator
        case columnNumber
        case regularExpression
        case captureNumber(maximum: Int)

        var errorDescription: String? {
            switch self {
            case .emptySeparator: String(localized: "区切り文字を入力してください。")
            case .columnNumber: String(localized: "列番号には1以上の整数を指定してください。")
            case .regularExpression: String(localized: "有効な正規表現を入力してください。")
            case let .captureNumber(maximum):
                String(localized: "キャプチャ番号には0から\(maximum)までの整数を指定してください。")
            }
        }
    }

    var key: Key = .wholeLine
    var ignoresCase = false
    var numeric = false
    var localized = false
    var descending = false
    var keepsFirstLine = false

    func makeKeyExtractor() throws -> (String) -> String? {
        switch key {
        case .wholeLine:
            return { $0 }
        case let .column(separator, number):
            guard !separator.isEmpty else { throw InvalidKey.emptySeparator }
            guard number > 0 else { throw InvalidKey.columnNumber }
            return { line in
                let columns = line.components(separatedBy: separator)
                return number <= columns.count ? columns[number - 1] : nil
            }
        case let .regularExpression(pattern, capture):
            guard !pattern.isEmpty, let expression = try? NSRegularExpression(pattern: pattern) else {
                throw InvalidKey.regularExpression
            }
            guard (0...expression.numberOfCaptureGroups).contains(capture) else {
                throw InvalidKey.captureNumber(maximum: expression.numberOfCaptureGroups)
            }
            return { line in
                let source = line as NSString
                let lineRange = NSRange(location: 0, length: source.length)
                var capturedRange: NSRange?
                expression.enumerateMatches(in: line, options: .reportProgress, range: lineRange) {
                    match, _, stop in
                    if Task.isCancelled {
                        stop.pointee = true
                    } else if let match {
                        capturedRange = match.range(at: capture)
                        stop.pointee = true
                    }
                }
                guard let capturedRange, capturedRange.location != NSNotFound else { return nil }
                return source.substring(with: capturedRange)
            }
        }
    }

    fileprivate func sorted(_ rows: [String]) throws -> [String] {
        let extract = try makeKeyExtractor()
        var comparisonOptions: String.CompareOptions = []
        if ignoresCase { comparisonOptions.insert(.caseInsensitive) }
        if numeric { comparisonOptions.insert(.numeric) }
        if localized { comparisonOptions.insert(.widthInsensitive) }
        let locale: Locale? = localized ? .current : nil
        let header = rows.prefix(keepsFirstLine ? 1 : 0)
        let keyed = try rows.dropFirst(header.count).enumerated().map {
            try Task.checkCancellation()
            return (index: $0.offset, row: $0.element, key: extract($0.element))
        }
        let sorted = try keyed.sorted { left, right in
            try Task.checkCancellation()
            switch (left.key, right.key) {
            case let (leftKey?, rightKey?):
                let order = leftKey.compare(rightKey, options: comparisonOptions, locale: locale)
                if order == .orderedSame { return left.index < right.index }
                return order == (descending ? .orderedDescending : .orderedAscending)
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return left.index < right.index
            }
        }
        try Task.checkCancellation()
        return Array(header) + sorted.map(\.row)
    }
}

enum EditorLineOperation: Sendable {
    case reverse
    case removeDuplicates
    case join
    case sort(EditorLineSortOptions)

    static var sortAscending: Self { .sort(EditorLineSortOptions()) }

    func replacement(for lines: [(content: String, ending: String)],
                     afterCarriageReturn: Bool) throws -> String? {
        let contents = lines.map(\.content)
        let reordered: [String]
        switch self {
        case .reverse:
            reordered = Array(contents.reversed())
        case .removeDuplicates:
            guard lines.count > 1, let finalEnding = lines.last?.ending else { return nil }
            var seen = Set<MarkdownSourceText>()
            var unique = lines.filter { seen.insert(MarkdownSourceText($0.content)).inserted }
            unique[unique.count - 1].ending = finalEnding
            return Self.serialize(unique, afterCarriageReturn: afterCarriageReturn)
        case .join:
            guard lines.count > 1, let finalEnding = lines.last?.ending else { return nil }
            return Self.serialize([(Self.joined(contents), finalEnding)],
                                  afterCarriageReturn: afterCarriageReturn)
        case let .sort(options):
            reordered = try options.sorted(contents)
        }
        guard reordered.count > 1 else { return nil }
        return Self.serialize(Array(zip(reordered, lines.map(\.ending))),
                              afterCarriageReturn: afterCarriageReturn)
    }

    private static func serialize(_ lines: [(String, String)], afterCarriageReturn: Bool) -> String {
        var result = ""
        var previousWasCR = afterCarriageReturn
        for (content, ending) in lines {
            // Keep two breaks when an empty row puts a CR next to an LF.
            if previousWasCR && content.isEmpty && ending == "\n" { result.append("\r") }
            result.append(content)
            result.append(ending)
            previousWasCR = ending == "\r"
        }
        return result
    }

    private static let japaneseCharacter = try! NSRegularExpression(
        pattern: #"^[\p{scx=Han}\p{scx=Hiragana}\p{scx=Katakana}？！（）]"#)

    private static func isJapanese(_ character: Character) -> Bool {
        let text = String(character)
        return japaneseCharacter.firstMatch(in: text,
            range: NSRange(location: 0, length: text.utf16.count)) != nil
    }

    private static func joined(_ lines: [String]) -> String {
        var result = lines[0]
        var crossedBlankLine = false
        for line in lines.dropFirst() {
            while result.last?.isWhitespace == true { result.removeLast() }
            let body = line.drop(while: \.isWhitespace)
            guard let next = body.first else {
                crossedBlankLine = true
                continue
            }
            if let previous = result.last,
               crossedBlankLine || !(isJapanese(previous) && isJapanese(next)) {
                result.append(" ")
            }
            result.append(contentsOf: body)
            crossedBlankLine = false
        }
        return result
    }
}
