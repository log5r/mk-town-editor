import Foundation

struct MarkdownMultiSelectionPlan {
    let edit: MarkdownEdit
    let selections: [NSRange]

    static func make(style: MarkdownFormattingStyle, source: String,
                     selections: [NSRange]) -> Self? {
        guard style.supportsMultipleSelections, selections.count > 1 else { return nil }
        let length = (source as NSString).length
        let ranges = selections.sorted { $0.location < $1.location }
        guard ranges.allSatisfy({ $0.location >= 0 && $0.length >= 0 &&
            $0.location <= length && $0.length <= length - $0.location }) else { return nil }
        let edits = ranges.map { MarkdownFormatter.apply(style, to: source, selection: $0) }
        guard edits.indices.dropFirst().allSatisfy({ index in
            let previous = edits[index - 1].range
            let current = edits[index].range
            return NSMaxRange(previous) <= current.location &&
                !(previous.length == 0 && current.length == 0 && previous.location == current.location)
        }) else { return nil }

        let original = source as NSString
        let start = edits[0].range.location
        let end = NSMaxRange(edits[edits.count - 1].range)
        var cursor = start
        var replacement = ""
        var delta = 0
        var finalSelections: [NSRange] = []
        for edit in edits {
            replacement += original.substring(with: NSRange(location: cursor,
                                                              length: edit.range.location - cursor))
            replacement += edit.replacement
            finalSelections.append(NSRange(location: edit.selection.location + delta,
                                           length: edit.selection.length))
            delta += (edit.replacement as NSString).length - edit.range.length
            cursor = NSMaxRange(edit.range)
        }
        replacement += original.substring(with: NSRange(location: cursor, length: end - cursor))
        return Self(edit: MarkdownEdit(range: NSRange(location: start, length: end - start),
                                       replacement: replacement, selection: finalSelections[0]),
                    selections: finalSelections)
    }
}

enum MarkdownSelectionOccurrences {
    static func addingNext(in source: String, selections: [NSRange]) -> [NSRange]? {
        guard let first = selections.first, first.length > 0 else { return nil }
        let text = source as NSString
        let ranges = selections.sorted { $0.location < $1.location }
        guard ranges.allSatisfy({ $0.location >= 0 && $0.length == first.length &&
            NSMaxRange($0) <= text.length &&
            text.substring(with: $0) == text.substring(with: first) }) else { return nil }
        let needle = text.substring(with: first)
        let searchStart = NSMaxRange(ranges[ranges.count - 1])
        let intervals = [NSRange(location: searchStart, length: text.length - searchStart),
                         NSRange(location: 0, length: searchStart)]
        for interval in intervals where interval.length >= first.length {
            var cursor = interval.location
            while cursor + first.length <= NSMaxRange(interval) {
                let found = text.range(of: needle, options: [],
                                       range: NSRange(location: cursor,
                                                      length: NSMaxRange(interval) - cursor))
                if found.location == NSNotFound { break }
                if !ranges.contains(where: { NSIntersectionRange($0, found).length > 0 }) {
                    return (ranges + [found]).sorted { $0.location < $1.location }
                }
                cursor = NSMaxRange(found)
            }
        }
        return nil
    }
}

extension MarkdownFormattingStyle {
    var supportsMultipleSelections: Bool {
        switch self {
        case .bold, .italic, .strikethrough, .inlineCode: true
        default: false
        }
    }
}
