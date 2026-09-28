import Foundation

enum RegexSearchError: Error, Equatable, LocalizedError, Sendable {
    case emptyPattern
    case invalidPattern(String)
    case invalidCapture(Int)

    var errorDescription: String? {
        switch self {
        case .emptyPattern: "検索パターンを入力してください。"
        case let .invalidPattern(message): "正規表現が無効です: \(message)"
        case let .invalidCapture(number): "置換文字列の参照 $\(number) が存在しません。"
        }
    }
}

enum RegexSearch {
    static func nextMatch(in matches: [NSRange], after selection: NSRange) -> NSRange? {
        matches.first {
            $0.location >= NSMaxRange(selection) && $0 != selection
        } ?? matches.first
    }

    static func replacementTarget(in matches: [NSRange], selection: NSRange) -> NSRange? {
        matches.first(where: { $0 == selection }) ?? nextMatch(in: matches, after: selection)
    }

    static func matches(in source: String, pattern: String,
                        caseSensitive: Bool = false, scope: NSRange? = nil) throws -> [NSRange] {
        let regex = try compile(pattern, caseSensitive: caseSensitive)
        let range = validScope(scope, in: source)
        return regex.matches(in: source, range: range).map(\.range)
    }

    static func replacementEdit(in source: String, pattern: String, template: String,
                                caseSensitive: Bool = false, scope: NSRange? = nil,
                                onlyMatch: NSRange? = nil) throws -> MarkdownEdit? {
        let regex = try compile(pattern, caseSensitive: caseSensitive)
        let sourceText = source as NSString
        let found = regex.matches(in: source, range: validScope(scope, in: source))
        let chosen = onlyMatch.map { range in found.filter { $0.range == range } } ?? found
        guard let first = chosen.first, let last = chosen.last else { return nil }
        let editRange = NSRange(location: first.range.location,
                                length: NSMaxRange(last.range) - first.range.location)
        var replacement = ""
        var cursor = editRange.location
        for match in chosen {
            replacement += sourceText.substring(with: NSRange(location: cursor,
                length: match.range.location - cursor))
            replacement += try expand(template, for: match, in: sourceText,
                                      captureCount: regex.numberOfCaptureGroups)
            cursor = NSMaxRange(match.range)
        }
        replacement += sourceText.substring(with: NSRange(location: cursor,
            length: NSMaxRange(editRange) - cursor))
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

    private static func validScope(_ scope: NSRange?, in source: String) -> NSRange {
        let length = (source as NSString).length
        guard let scope, scope.location >= 0, scope.location <= length,
              scope.length >= 0, scope.length <= length - scope.location else {
            return NSRange(location: 0, length: length)
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
