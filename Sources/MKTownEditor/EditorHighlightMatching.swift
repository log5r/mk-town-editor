import CoreFoundation
import Foundation

enum EditorHighlightMatching {
    private static let openingBrackets = "([{「『（［｛【〈《〔〖〘〚｢"
    private static let closingBrackets = ")]}」』）］｝】〉》〕〗〙〛｣"
    private static let bracketCharacters = CharacterSet(charactersIn: openingBrackets + closingBrackets)
    private static let closingForOpening = Dictionary(uniqueKeysWithValues:
        zip(openingBrackets.utf16, closingBrackets.utf16))
    private static let openingForClosing = Dictionary(uniqueKeysWithValues:
        zip(closingBrackets.utf16, openingBrackets.utf16))

    static func crossedBracket(in source: NSString, from old: Int, to new: Int) -> Int? {
        guard (0...source.length).contains(old), (0...source.length).contains(new),
              abs(new - old) == 1 else { return nil }
        let offset = min(old, new)
        let character = source.character(at: offset)
        return closingForOpening[character] != nil || openingForClosing[character] != nil ? offset : nil
    }

    static func matchingBracket(in source: NSString, at offset: Int, codeRanges: [NSRange],
                                isCancelled: () -> Bool = { false }) -> NSRange? {
        guard (0..<source.length).contains(offset), !isCancelled() else { return nil }
        let bracket = source.character(at: offset)
        let forward = closingForOpening[bracket] != nil
        let pairs = forward ? closingForOpening : openingForClosing
        guard let expected = pairs[bracket] else { return nil }

        let code = disjointCodeRanges(codeRanges, in: source)
        let containingCode = codeRange(containing: offset, in: code)
        guard containingCode != nil || !isMarkdownEscape(in: source, at: offset) else { return nil }
        let lower = containingCode?.location ?? 0
        let upper = containingCode.map(NSMaxRange) ?? source.length
        var expectedBrackets = [expected]
        var cursor = forward ? offset + 1 : offset

        // Search in chunks so navigation can cancel a long search. A code span
        // forms its own bracket scope, while a prose pair may enclose that span.
        while forward ? cursor < upper : cursor > lower {
            guard !isCancelled() else { return nil }
            let chunkLength = min(4096, forward ? upper - cursor : cursor - lower)
            let chunk = NSRange(location: forward ? cursor : cursor - chunkLength, length: chunkLength)
            let candidate = source.rangeOfCharacter(from: bracketCharacters, options: forward ? [] : [.backwards],
                                                    range: chunk)
            guard candidate.location != NSNotFound else {
                cursor += forward ? chunkLength : -chunkLength
                continue
            }
            cursor = forward ? NSMaxRange(candidate) : candidate.location
            if containingCode == nil {
                if let skipped = codeRange(containing: candidate.location, in: code) {
                    cursor = forward ? NSMaxRange(skipped) : skipped.location
                    continue
                }
                if isMarkdownEscape(in: source, at: candidate.location) { continue }
            }
            let character = source.character(at: candidate.location)
            if let partner = pairs[character] {
                expectedBrackets.append(partner)
            } else {
                guard expectedBrackets.popLast() == character else { return nil }
                if expectedBrackets.isEmpty { return candidate }
            }
        }
        return nil
    }

    static func selectedWord(in source: NSString, selection: NSRange) -> String? {
        guard isValidScope(selection, in: source),
              let tokenizer = wordTokenizer(in: source),
              CFStringTokenizerGoToTokenAtIndex(tokenizer, selection.location) != [],
              currentWordRange(in: tokenizer) == selection,
              source.rangeOfComposedCharacterSequences(for: selection) == selection else { return nil }
        let selected = source.substring(with: selection)
        return selected.contains { $0.isLetter || $0.isNumber } ? selected : nil
    }

    /// Returns whole tokens overlapping the scope, including words clipped by a viewport edge.
    static func wordOccurrences(in source: NSString, word: String, within scope: NSRange) -> [NSRange] {
        guard !word.isEmpty, isValidScope(scope, in: source),
              let tokenizer = wordTokenizer(in: source) else { return [] }
        var token = CFStringTokenizerGoToTokenAtIndex(tokenizer, scope.location)
        let end = NSMaxRange(scope)
        var ranges: [NSRange] = []
        while token != [] {
            let range = currentWordRange(in: tokenizer)
            guard range.location < end else { break }
            if source.compare(word, options: [], range: range) == .orderedSame {
                ranges.append(range)
            }
            token = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }
        return ranges
    }

    private static func wordTokenizer(in source: NSString) -> CFStringTokenizer? {
        CFStringTokenizerCreate(nil, source as CFString, CFRange(location: 0, length: source.length),
                                kCFStringTokenizerUnitWordBoundary, nil)
    }

    private static func currentWordRange(in tokenizer: CFStringTokenizer) -> NSRange {
        let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
        return NSRange(location: range.location, length: range.length)
    }

    private static func isValidScope(_ range: NSRange, in source: NSString) -> Bool {
        range.location >= 0 && range.location <= source.length &&
            range.length > 0 && range.length <= source.length - range.location
    }

    private static func disjointCodeRanges(_ ranges: [NSRange], in source: NSString) -> [NSRange] {
        var disjoint: [NSRange] = []
        for range in ranges.filter({ isValidScope($0, in: source) }).sorted(by: { $0.location < $1.location }) {
            if let last = disjoint.last, NSMaxRange(last) > range.location {
                disjoint[disjoint.count - 1] = NSUnionRange(last, range)
            } else {
                disjoint.append(range)
            }
        }
        return disjoint
    }

    private static func codeRange(containing offset: Int, in ranges: [NSRange]) -> NSRange? {
        var lower = 0
        var upper = ranges.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if NSMaxRange(ranges[middle]) <= offset {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower < ranges.count, NSLocationInRange(offset, ranges[lower]) else { return nil }
        return ranges[lower]
    }

    private static func isMarkdownEscape(in source: NSString, at offset: Int) -> Bool {
        // Markdown backslash escapes apply to ASCII punctuation.
        guard source.character(at: offset) < 128 else { return false }
        var cursor = offset
        while cursor > 0, source.character(at: cursor - 1) == 92 { cursor -= 1 }
        return (offset - cursor) % 2 == 1
    }
}
