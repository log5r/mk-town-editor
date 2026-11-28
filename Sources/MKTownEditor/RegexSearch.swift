import Foundation

enum RegexSearchError: Error, Equatable, LocalizedError, Sendable {
    case emptyPattern
    case invalidPattern(String)
    case invalidCapture(Int)
    case invalidScope

    var errorDescription: String? {
        switch self {
        case .emptyPattern: String(localized: "検索パターンを入力してください。")
        case let .invalidPattern(message): String(localized: "正規表現が無効です: \(message)")
        case let .invalidCapture(number): String(localized: "置換文字列の参照 $\(number) が存在しません。")
        case .invalidScope: String(localized: "選択範囲が現在の本文と一致しません。")
        }
    }
}

enum RegexSearch {
    static func nextMatch(in matches: [NSRange], after selection: NSRange) -> NSRange? {
        DocumentSearch.nextMatch(in: matches, after: selection, wraps: true)
    }

    static func replacementTarget(in matches: [NSRange], selection: NSRange) -> NSRange? {
        matches.first(where: { $0 == selection }) ?? nextMatch(in: matches, after: selection)
    }

    static func matches(in source: String, pattern: String,
                        caseSensitive: Bool = false, scope: NSRange? = nil) throws -> [NSRange] {
        let regex = try compile(pattern, caseSensitive: caseSensitive)
        let range = try validScope(scope, in: source)
        var found: [NSRange] = []
        // 一致がなくても途中で呼ばれるようにし、パターンが変わって取り消された検索を止める。
        regex.enumerateMatches(in: source, options: .reportProgress, range: range) { match, _, stop in
            if let match { found.append(match.range) }
            if Task.isCancelled { stop.pointee = true }
        }
        return found
    }

    static func replacementEdit(in source: String, pattern: String, template: String,
                                caseSensitive: Bool = false, scope: NSRange? = nil,
                                onlyMatch: NSRange? = nil) throws -> MarkdownEdit? {
        let regex = try compile(pattern, caseSensitive: caseSensitive)
        let sourceText = source as NSString
        var chosen: [NSTextCheckingResult] = []
        regex.enumerateMatches(in: source, options: .reportProgress, range: try validScope(scope, in: source)) {
            match, _, stop in
            if let match, onlyMatch == nil || match.range == onlyMatch {
                chosen.append(match)
                if onlyMatch != nil { stop.pointee = true }
            }
            if Task.isCancelled { stop.pointee = true }
        }
        try Task.checkCancellation()
        return try replacementEdit(in: sourceText, matches: chosen, range: \.range) { match in
            try expand(template, for: match, in: sourceText, captureCount: regex.numberOfCaptureGroups)
        }
    }

    fileprivate static func replacementEdit<Match>(
        in source: NSString, matches: [Match], range: (Match) -> NSRange,
        replacementFor: (Match) throws -> String
    ) throws -> MarkdownEdit? {
        guard let first = matches.first, let last = matches.last else { return nil }
        let start = range(first).location
        let editRange = NSRange(location: start, length: NSMaxRange(range(last)) - start)
        var replacement = ""
        var cursor = start
        for match in matches {
            try Task.checkCancellation()
            let range = range(match)
            replacement += source.substring(with: NSRange(location: cursor, length: range.location - cursor))
            replacement += try replacementFor(match)
            cursor = NSMaxRange(range)
        }
        return MarkdownEdit(range: editRange, replacement: replacement,
                            selection: NSRange(location: editRange.location + (replacement as NSString).length,
                                               length: 0))
    }

    private static func compile(_ pattern: String, caseSensitive: Bool) throws -> NSRegularExpression {
        guard !pattern.isEmpty else { throw RegexSearchError.emptyPattern }
        do {
            return try NSRegularExpression(pattern: pattern,
                options: caseSensitive ? [] : [.caseInsensitive])
        } catch {
            throw RegexSearchError.invalidPattern(error.localizedDescription)
        }
    }

    fileprivate static func validScope(_ scope: NSRange?, in source: String) throws -> NSRange {
        let length = (source as NSString).length
        guard let scope else {
            return NSRange(location: 0, length: length)
        }
        guard scope.location >= 0, scope.location <= length,
              scope.length >= 0, scope.length <= length - scope.location else {
            throw RegexSearchError.invalidScope
        }
        return scope
    }

    private static func expand(_ template: String, for match: NSTextCheckingResult,
                               in source: NSString, captureCount: Int) throws -> String {
        let characters = Array(template)
        var result = ""
        var cursor = 0
        while cursor < characters.count {
            let character = characters[cursor]
            if character == "\\", cursor + 1 < characters.count,
               characters[cursor + 1] == "$" || characters[cursor + 1] == "\\" {
                result.append(characters[cursor + 1])
                cursor += 2
                continue
            }
            if character == "$", cursor + 1 < characters.count,
               characters[cursor + 1].isASCII && characters[cursor + 1].isNumber {
                var end = cursor + 1
                while end < characters.count, characters[end].isASCII && characters[end].isNumber {
                    end += 1
                }
                let number = Int(String(characters[(cursor + 1)..<end])) ?? Int.max
                guard number <= captureCount else { throw RegexSearchError.invalidCapture(number) }
                let range = match.range(at: number)
                if range.location != NSNotFound { result += source.substring(with: range) }
                cursor = end
                continue
            }
            result.append(character)
            cursor += 1
        }
        return result
    }
}

enum DocumentSearchMode: Hashable, Sendable {
    case plain
    case regex
}

struct DocumentSearchOptions: Hashable, Sendable {
    var caseSensitive = false
    var ignoresWidth = false
    var ignoresKana = false
    var ignoresDiacritics = false
    var wholeWords = false
}

struct DocumentSearchMatch: Equatable, Sendable {
    let range: NSRange
    let lineNumber: Int
    let snippet: String
}

enum DocumentSearch {
    static func matches(in source: String, pattern: String, mode: DocumentSearchMode,
                        options: DocumentSearchOptions = .init(),
                        scope: NSRange? = nil) throws -> [DocumentSearchMatch] {
        let ranges = switch mode {
        case .plain:
            try plainRanges(in: source, pattern: pattern, options: options, scope: scope)
        case .regex:
            try RegexSearch.matches(in: source, pattern: pattern, caseSensitive: options.caseSensitive,
                                    scope: scope)
        }
        try Task.checkCancellation()
        guard let last = ranges.last else { return [] }
        let lines = MarkdownLineIndex(source, through: NSMaxRange(last) + 1)
        let text = source as NSString
        return try ranges.map { range in
            try Task.checkCancellation()
            let lineNumber = lines.line(containingUTF16Offset: range.location)
            return DocumentSearchMatch(range: range, lineNumber: lineNumber,
                                       snippet: snippet(in: text, around: range, lines: lines, line: lineNumber))
        }
    }

    static func nextMatch(in ranges: [NSRange], after selection: NSRange, wraps: Bool) -> NSRange? {
        var index = firstIndex(in: ranges) { $0.location >= NSMaxRange(selection) }
        if ranges.indices.contains(index), ranges[index] == selection { index += 1 }
        return ranges.indices.contains(index) ? ranges[index] : (wraps ? ranges.first : nil)
    }

    static func previousMatch(in ranges: [NSRange], before selection: NSRange, wraps: Bool) -> NSRange? {
        var index = firstIndex(in: ranges) { NSMaxRange($0) > selection.location } - 1
        if ranges.indices.contains(index), ranges[index] == selection { index -= 1 }
        return ranges.indices.contains(index) ? ranges[index] : (wraps ? ranges.last : nil)
    }

    static func index(of range: NSRange, in ranges: [NSRange]) -> Int? {
        let index = firstIndex(in: ranges) { $0.location >= range.location }
        return ranges.indices.contains(index) && ranges[index] == range ? index : nil
    }

    private static func firstIndex(in ranges: [NSRange], where isAtOrAfter: (NSRange) -> Bool) -> Int {
        var low = 0
        var high = ranges.count
        while low < high {
            let middle = (low + high) / 2
            if isAtOrAfter(ranges[middle]) { high = middle }
            else { low = middle + 1 }
        }
        return low
    }

    static func replacementEdit(in source: String, pattern: String, template: String,
                                mode: DocumentSearchMode, options: DocumentSearchOptions = .init(),
                                scope: NSRange? = nil, onlyMatch: NSRange? = nil) throws -> MarkdownEdit? {
        switch mode {
        case .plain:
            let chosen = try plainRanges(in: source, pattern: pattern, options: options, scope: scope,
                                         onlyMatch: onlyMatch)
            return try RegexSearch.replacementEdit(in: source as NSString, matches: chosen, range: { $0 }) {
                _ in template
            }
        case .regex:
            return try RegexSearch.replacementEdit(in: source, pattern: pattern, template: template,
                                                   caseSensitive: options.caseSensitive,
                                                   scope: scope, onlyMatch: onlyMatch)
        }
    }

    private static let wordBoundary = try! NSRegularExpression(pattern: #"\b"#, options: [.useUnicodeWordBoundaries])

    private static func plainRanges(in source: String, pattern: String, options: DocumentSearchOptions,
                                    scope: NSRange?, onlyMatch: NSRange? = nil) throws -> [NSRange] {
        guard !pattern.isEmpty else { throw RegexSearchError.emptyPattern }
        let scope = try RegexSearch.validScope(scope, in: source)
        let original = source as NSString
        let fold = try FoldedSearchText(source, options: options)
        let needle = try FoldedSearchText(pattern, options: options).text
        let text = fold.text as NSString
        let compare: NSString.CompareOptions = options.caseSensitive ? [] : [.caseInsensitive]
        let boundaries = options.wholeWords ? try wordBoundaries(in: source, near: scope) : []
        let limit = NSMaxRange(scope)
        var cursor = fold.foldedOffset(at: scope.location, roundingUp: true)
        let end = fold.foldedOffset(at: limit, roundingUp: false)
        var ranges: [NSRange] = []
        while cursor < end {
            try Task.checkCancellation()
            let match = text.range(of: needle, options: compare,
                                   range: NSRange(location: cursor, length: end - cursor))
            guard match.location != NSNotFound, match.length > 0 else { break }
            if let range = fold.originalRange(for: match),
               original.rangeOfComposedCharacterSequences(for: range) == range,
               !options.wholeWords || (boundaries.contains(range.location) && boundaries.contains(NSMaxRange(range))) {
                if let onlyMatch {
                    if range == onlyMatch { return [range] }
                    if range.location >= onlyMatch.location { break }
                    cursor = NSMaxRange(match)
                    continue
                }
                ranges.append(range)
                cursor = NSMaxRange(match)
            } else {
                cursor = NSMaxRange(text.rangeOfComposedCharacterSequence(at: match.location))
            }
        }
        try Task.checkCancellation()
        return ranges
    }

    private static func wordBoundaries(in source: String, near scope: NSRange) throws -> Set<Int> {
        var offsets: Set<Int> = []
        wordBoundary.enumerateMatches(in: source, options: [.withTransparentBounds, .withoutAnchoringBounds, .reportProgress],
                                      range: scope) { match, _, stop in
            if let match { offsets.insert(match.range.location) }
            if Task.isCancelled { stop.pointee = true }
        }
        try Task.checkCancellation()
        return offsets
    }

    private static func snippet(in source: NSString, around match: NSRange,
                                lines: MarkdownLineIndex, line: Int) -> String {
        let lineStart = lines.starts[line - 1]
        let matchEnd = NSMaxRange(match)
        let finalLine = lines.line(containingUTF16Offset: max(match.location, matchEnd - 1))
        var lineEnd = finalLine < lines.lineCount ? lines.starts[finalLine] : source.length
        while lineEnd > matchEnd {
            let unit = source.character(at: lineEnd - 1)
            guard unit == 10 || unit == 13 else { break }
            lineEnd -= 1
        }
        let start = max(lineStart, match.location - 28)
        let end = min(lineEnd, matchEnd + 28)
        var preview = start > lineStart ? "…" : ""
        if match.length > 96 {
            preview += excerpt(in: source, from: start, to: match.location + 48)
            preview += "…"
            preview += excerpt(in: source, from: matchEnd - 48, to: end)
        } else {
            preview += excerpt(in: source, from: start, to: end)
        }
        if end < lineEnd { preview += "…" }
        return preview.isEmpty ? String(localized: "空位置") : preview
    }

    private static func excerpt(in source: NSString, from start: Int, to end: Int) -> String {
        guard start < end else { return "" }
        let requested = NSRange(location: start, length: end - start)
        let composed = source.rangeOfComposedCharacterSequences(for: requested)
        let range: NSRange
        if composed.length <= requested.length + 24 {
            range = composed
        } else {
            // A long sequence of combining marks can exceed the entire snippet budget.
            let scalarStart = (0xDC00...0xDFFF).contains(source.character(at: start)) ? start - 1 : start
            let scalarEnd = (0xD800...0xDBFF).contains(source.character(at: end - 1)) ? end + 1 : end
            range = NSRange(location: scalarStart, length: scalarEnd - scalarStart)
        }
        return source.substring(with: range)
            .replacingOccurrences(of: "\r\n", with: "↵")
            .replacingOccurrences(of: "\r", with: "↵")
            .replacingOccurrences(of: "\n", with: "↵")
    }
}

/// Records only the offsets that change when a composed character folds to a different UTF-16 length.
private struct FoldedSearchText {
    private struct Change {
        let original: NSRange
        let folded: NSRange
    }

    private static let widthScalars = (0xFF00...0xFFEF).map { value in
        // Foundation folds halfwidth Hangul into modern Jamo. Keep the Unicode width
        // pairs with Compatibility Jamo so the option does not change the spelling.
        let hangul: Int? = switch value {
        case 0xFFA0: 0x3164
        case 0xFFA1...0xFFBE: value - 0xCE70
        case 0xFFC2...0xFFC7: value - 0xCE73
        case 0xFFCA...0xFFCF: value - 0xCE75
        case 0xFFD2...0xFFD7: value - 0xCE77
        case 0xFFDA...0xFFDC: value - 0xCE79
        default: nil
        }
        if let hangul { return Unicode.Scalar(hangul)! }
        let scalar = Unicode.Scalar(value)!
        return String(scalar).folding(options: .widthInsensitive, locale: nil).unicodeScalars.first ?? scalar
    }

    let text: String
    private var changes: [Change] = []

    init(_ source: String, options: DocumentSearchOptions) throws {
        guard options.ignoresWidth || options.ignoresKana || options.ignoresDiacritics else {
            text = source
            return
        }
        var output = ""
        output.reserveCapacity(source.utf8.count)
        var originalOffset = 0
        var foldedOffset = 0
        for (index, character) in source.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            if character.isASCII {
                output.append(character)
                let length = character == "\r\n" ? 2 : 1
                originalOffset += length
                foldedOffset += length
                continue
            }
            let original = String(character)
            var folded = original
            if options.ignoresWidth || options.ignoresKana {
                folded = String(String.UnicodeScalarView(original.unicodeScalars.map { scalar in
                    let width = options.ignoresWidth ? Self.foldWidth(scalar) : scalar
                    return options.ignoresKana ? Self.foldKana(width) : width
                }))
            }
            if options.ignoresDiacritics {
                let decomposed = folded.decomposedStringWithCanonicalMapping.unicodeScalars
                let stripped = decomposed.filter { scalar in
                    !(scalar.properties.isDiacritic && CharacterSet.nonBaseCharacters.contains(scalar))
                }
                if !stripped.isEmpty, stripped.count != decomposed.count {
                    folded = String(String.UnicodeScalarView(stripped)).precomposedStringWithCanonicalMapping
                }
            }
            let originalLength = original.utf16.count
            let foldedLength = folded.utf16.count
            if originalLength != foldedLength {
                changes.append(Change(original: NSRange(location: originalOffset, length: originalLength),
                                      folded: NSRange(location: foldedOffset, length: foldedLength)))
            }
            output.append(contentsOf: folded)
            originalOffset += originalLength
            foldedOffset += foldedLength
        }
        try Task.checkCancellation()
        text = output
    }

    private static func foldWidth(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        if scalar.value == 0x3000 { return " " }
        if (0xFF00...0xFFEF).contains(scalar.value) { return widthScalars[Int(scalar.value) - 0xFF00] }
        return scalar
    }

    private static func foldKana(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        if (0x3041...0x3096).contains(scalar.value) || (0x309D...0x309E).contains(scalar.value) {
            return Unicode.Scalar(scalar.value + 0x60)!
        }
        return scalar
    }

    func foldedOffset(at position: Int, roundingUp: Bool) -> Int {
        let index = firstChangeEnding(after: position, in: \.original)
        if index < changes.count, position > changes[index].original.location {
            return roundingUp ? NSMaxRange(changes[index].folded) : changes[index].folded.location
        }
        guard index > 0 else { return position }
        let previous = changes[index - 1]
        return position - NSMaxRange(previous.original) + NSMaxRange(previous.folded)
    }

    func originalRange(for range: NSRange) -> NSRange? {
        guard let start = originalOffset(at: range.location),
              let end = originalOffset(at: NSMaxRange(range)) else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private func originalOffset(at position: Int) -> Int? {
        let index = firstChangeEnding(after: position, in: \.folded)
        if index < changes.count, position > changes[index].folded.location { return nil }
        guard index > 0 else { return position }
        let previous = changes[index - 1]
        return position - NSMaxRange(previous.folded) + NSMaxRange(previous.original)
    }

    private func firstChangeEnding(after offset: Int, in keyPath: KeyPath<Change, NSRange>) -> Int {
        var low = 0
        var high = changes.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(changes[middle][keyPath: keyPath]) <= offset { low = middle + 1 }
            else { high = middle }
        }
        return low
    }
}

struct RegexSelectionScope: Equatable {
    private(set) var range: NSRange

    init?(_ range: NSRange) {
        guard range.location >= 0, range.length > 0 else { return nil }
        self.range = range
    }

    mutating func apply(_ edit: MarkdownEdit) -> Bool {
        guard edit.range.location >= 0, edit.range.length >= 0,
              edit.range.location <= Int.max - edit.range.length else { return false }
        let delta = (edit.replacement as NSString).length - edit.range.length
        if edit.range.location >= range.location,
           NSMaxRange(edit.range) <= NSMaxRange(range) {
            range.length += delta
            return range.length >= 0
        }
        if NSMaxRange(edit.range) <= range.location {
            range.location += delta
            return range.location >= 0
        }
        if edit.range.location >= NSMaxRange(range) { return true }
        return false
    }
}
