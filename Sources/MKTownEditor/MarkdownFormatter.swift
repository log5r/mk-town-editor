import Foundation

enum MarkdownInlineSyntax {
    static func codeSpanRanges(in text: String) -> [NSRange] {
        let source = text as NSString
        var ranges: [NSRange] = []
        var cursor = 0
        while cursor < source.length {
            guard source.character(at: cursor) == 96 else {
                cursor += 1
                continue
            }
            var backslashes = 0
            var before = cursor - 1
            while before >= 0 && source.character(at: before) == 92 {
                backslashes += 1
                before -= 1
            }
            if backslashes % 2 == 1 {
                cursor += 1
                continue
            }
            let opening = cursor
            while cursor < source.length && source.character(at: cursor) == 96 { cursor += 1 }
            let length = cursor - opening
            var search = cursor
            var closing: Int?
            while search < source.length {
                guard source.character(at: search) == 96 else {
                    search += 1
                    continue
                }
                let runStart = search
                while search < source.length && source.character(at: search) == 96 { search += 1 }
                if search - runStart == length {
                    closing = search
                    break
                }
            }
            if let closing {
                ranges.append(NSRange(location: opening, length: closing - opening))
                cursor = closing
            }
        }
        return ranges
    }
}

enum MarkdownFormattingStyle {
    case bold
    case italic
    case strikethrough
    case inlineCode
    case link
    case heading(level: Int)
    case quote
    case unorderedList
    case orderedList
    case taskList
    case codeBlock(language: MarkdownCodeLanguage?)
}

enum MarkdownCodeLanguage: String, CaseIterable, Hashable {
    case swift
    case javascript
    case typescript
    case python
    case json
    case bash
    case markdown

    var title: String {
        switch self {
        case .swift: "Swift"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .python: "Python"
        case .json: "JSON"
        case .bash: "Bash"
        case .markdown: "Markdown"
        }
    }
}

struct MarkdownEdit: Equatable {
    let range: NSRange
    let replacement: String
    let selection: NSRange

    func applying(to text: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: replacement)
    }
}

enum MarkdownFormatter {
    private static let headingExpression = try! NSRegularExpression(pattern: #"^( {0,3})(#{1,6})(?:[ \t]+|$)"#)
    private static let taskLineExpression = try! NSRegularExpression(
        pattern: #"^(?:[ \t]*>[ \t]*)*[ \t]*(?:[-+*]|[0-9]{1,9}[.)])[ \t]+\[([ xX])\](?:[ \t]|$)"#
    )

    static func apply(
        _ style: MarkdownFormattingStyle,
        to text: String,
        selection: NSRange
    ) -> MarkdownEdit {
        let safeSelection = clamped(selection, in: text)

        switch style {
        case .bold:
            return wrap(text, selection: safeSelection, prefix: "**", suffix: "**", placeholder: "太字")
        case .italic:
            return wrap(text, selection: safeSelection, prefix: "_", suffix: "_", placeholder: "斜体")
        case .strikethrough:
            return wrap(text, selection: safeSelection, prefix: "~~", suffix: "~~", placeholder: "取り消し線")
        case .inlineCode:
            return wrap(text, selection: safeSelection, prefix: "`", suffix: "`", placeholder: "コード")
        case .link:
            return link(text, selection: safeSelection)
        case let .heading(level):
            return heading(text, selection: safeSelection, level: level)
        case .quote:
            return prefixLines(text, selection: safeSelection, prefix: "> ")
        case .unorderedList:
            return convertList(text, selection: safeSelection, target: .unordered)
        case .orderedList:
            return convertList(text, selection: safeSelection, target: .ordered)
        case .taskList:
            return convertList(text, selection: safeSelection, target: .task)
        case let .codeBlock(language):
            return fencedCodeBlock(text, selection: safeSelection, language: language)
        }
    }

    private static func fencedCodeBlock(_ text: String, selection: NSRange,
                                        language: MarkdownCodeLanguage?) -> MarkdownEdit {
        let source = text as NSString
        let selected = source.substring(with: selection)
        var longestRun = 0
        var currentRun = 0
        for character in selected.utf16 {
            if character == 96 {
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 0
            }
        }
        let fence = String(repeating: "`", count: max(3, longestRun + 1))
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let startsInsideLine = selection.location > 0 &&
            source.character(at: selection.location - 1) != 10 &&
            source.character(at: selection.location - 1) != 13
        let endsInsideLine = NSMaxRange(selection) < source.length &&
            source.character(at: NSMaxRange(selection)) != 10 &&
            source.character(at: NSMaxRange(selection)) != 13
        let leading = startsInsideLine ? newline : ""
        let trailing = endsInsideLine ? newline : ""
        let opening = fence + (language?.rawValue ?? "") + newline
        let contentEnding = selected.hasSuffix("\n") || selected.hasSuffix("\r") ? "" : newline
        let replacement = leading + opening + selected + contentEnding + fence + trailing
        return MarkdownEdit(
            range: selection,
            replacement: replacement,
            selection: NSRange(location: selection.location + (leading as NSString).length +
                               (opening as NSString).length, length: (selected as NSString).length)
        )
    }

    static func toggleTasks(in text: String, selection: NSRange) -> MarkdownEdit? {
        let source = text as NSString
        let safeSelection = clamped(selection, in: text)
        let selectedLines = source.lineRange(for: safeSelection)
        let analysis = MarkdownAnalysis(text)
        var states: [(location: Int, checked: Bool)] = []
        var seenLines = Set<Int>()
        for block in analysis.blocks where block.task != nil {
            let lineRange = source.lineRange(for: NSRange(location: block.sourceRange.location, length: 0))
            guard NSIntersectionRange(lineRange, selectedLines).length > 0,
                  seenLines.insert(lineRange.location).inserted else { continue }
            let line = source.substring(with: lineRange)
            guard let match = taskLineExpression.firstMatch(in: line,
                range: NSRange(location: 0, length: (line as NSString).length)) else { continue }
            let stateRange = match.range(at: 1)
            let state = (line as NSString).substring(with: stateRange)
            states.append((lineRange.location + stateRange.location, state == "x" || state == "X"))
        }
        guard !states.isEmpty else { return nil }
        let newState = states.allSatisfy(\.checked) ? " " : "x"
        let replacement = NSMutableString(string: source.substring(with: selectedLines))
        for state in states.sorted(by: { $0.location > $1.location }) {
            replacement.replaceCharacters(in: NSRange(location: state.location - selectedLines.location, length: 1),
                                          with: newState)
        }
        return MarkdownEdit(range: selectedLines, replacement: replacement as String,
                            selection: safeSelection)
    }

    private static func wrap(
        _ text: String,
        selection: NSRange,
        prefix: String,
        suffix: String,
        placeholder: String
    ) -> MarkdownEdit {
        let nsText = text as NSString
        let markerLength = (prefix as NSString).length
        let markers: [String]
        switch prefix {
        case "**": markers = ["**", "__"]
        case "_": markers = ["_", "*"]
        default: markers = [prefix]
        }
        let spans = formattingSpans(in: text, markers: markers)
        if let enclosing = spans.filter({
            if selection.length == 0 {
                return selection.location >= $0.innerRange.location &&
                    selection.location <= NSMaxRange($0.innerRange)
            }
            return selection.location >= $0.innerRange.location &&
                NSMaxRange(selection) <= NSMaxRange($0.innerRange)
        }).min(by: { $0.range.length < $1.range.length }) {
            let inner = nsText.substring(with: enclosing.innerRange)
            let start = min(max(selection.location, enclosing.innerRange.location),
                            NSMaxRange(enclosing.innerRange))
            let end = min(max(NSMaxRange(selection), enclosing.innerRange.location),
                          NSMaxRange(enclosing.innerRange))
            return MarkdownEdit(
                range: enclosing.range,
                replacement: inner,
                selection: NSRange(location: enclosing.range.location + start - enclosing.innerRange.location,
                                   length: end - start)
            )
        }

        var editRange = selection
        if selection.length > 0 {
            for span in spans where NSIntersectionRange(span.range, editRange).length > 0 {
                editRange = NSUnionRange(editRange, span.range)
            }
        }
        let selected = nsText.substring(with: editRange)
        let contained = spans.filter {
            $0.range.location >= editRange.location && NSMaxRange($0.range) <= NSMaxRange(editRange)
        }
        if !contained.isEmpty {
            let unwrapped = NSMutableString(string: selected)
            let markerRanges = contained.flatMap { span in
                [NSRange(location: span.range.location - editRange.location, length: span.markerLength),
                 NSRange(location: NSMaxRange(span.innerRange) - editRange.location,
                         length: span.markerLength)]
            }.sorted { $0.location > $1.location }
            for range in markerRanges {
                unwrapped.replaceCharacters(in: range, with: "")
            }
            let content = unwrapped as String
            let uncovered = NSMutableString(string: selected)
            let outerSpans = contained.filter { span in
                !contained.contains { other in
                    other.range.location <= span.range.location &&
                        NSMaxRange(other.range) >= NSMaxRange(span.range) &&
                        !NSEqualRanges(other.range, span.range)
                }
            }
            for span in outerSpans.reversed() {
                uncovered.replaceCharacters(in: NSRange(location: span.range.location - editRange.location,
                                                       length: span.range.length), with: "")
            }
            let shouldRemove = (uncovered as String)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let replacement = shouldRemove ? content : prefix + content + suffix
            return MarkdownEdit(
                range: editRange,
                replacement: replacement,
                selection: NSRange(location: editRange.location + (shouldRemove ? 0 : markerLength),
                                   length: (content as NSString).length)
            )
        }
        let content = selected.isEmpty ? placeholder : selected
        let replacement = prefix + content + suffix
        let contentLength = (content as NSString).length
        return MarkdownEdit(
            range: editRange,
            replacement: replacement,
            selection: NSRange(location: editRange.location + markerLength, length: contentLength)
        )
    }

    private struct FormattingSpan {
        let range: NSRange
        let innerRange: NSRange
        let markerLength: Int
    }

    private static func formattingSpans(in text: String, markers: [String]) -> [FormattingSpan] {
        let source = text as NSString
        let codeSpans = MarkdownInlineSyntax.codeSpanRanges(in: text)
        if markers == ["`"] {
            return codeSpans.map { range in
                let markerLength = (0..<range.length)
                    .prefix(while: { source.character(at: range.location + $0) == 96 }).count
                return FormattingSpan(
                    range: range,
                    innerRange: NSRange(location: range.location + markerLength,
                                        length: range.length - markerLength * 2),
                    markerLength: markerLength
                )
            }
        }
        var spans: [FormattingSpan] = []
        for marker in markers {
            let escaped = NSRegularExpression.escapedPattern(for: marker)
            let boundary = marker.count == 1 ? "(?<!\(escaped))" : ""
            let after = marker.count == 1 ? "(?!\(escaped))" : ""
            let pattern = try! NSRegularExpression(
                pattern: boundary + escaped + after + #"([\s\S]+?)"# + boundary + escaped + after
            )
            spans += pattern.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match in
                let inner = match.range(at: 1)
                let endMarker = NSMaxRange(inner)
                guard !isEscaped(in: source, at: match.range.location),
                      !isEscaped(in: source, at: endMarker),
                      !codeSpans.contains(where: { code in
                          NSIntersectionRange(code, NSRange(location: match.range.location,
                                                            length: (marker as NSString).length)).length > 0 ||
                              NSIntersectionRange(code, NSRange(location: endMarker,
                                                                length: (marker as NSString).length)).length > 0
                      })
                else { return nil }
                return FormattingSpan(range: match.range, innerRange: inner,
                                      markerLength: (marker as NSString).length)
            }
        }
        return spans.sorted { $0.range.location < $1.range.location }
    }

    private static func isEscaped(in source: NSString, at location: Int) -> Bool {
        var backslashes = 0
        var cursor = location - 1
        while cursor >= 0 && source.character(at: cursor) == 92 {
            backslashes += 1
            cursor -= 1
        }
        return backslashes % 2 == 1
    }

    private static func link(_ text: String, selection: NSRange) -> MarkdownEdit {
        let nsText = text as NSString
        let selected = nsText.substring(with: selection)
        let label = selected.isEmpty ? "リンク" : selected
        let replacement = "[\(label)](https://)"
        let urlStart = selection.location + ("[\(label)](" as NSString).length
        return MarkdownEdit(range: selection, replacement: replacement, selection: NSRange(location: urlStart, length: 8))
    }

    private static func prefixLines(_ text: String, selection: NSRange, prefix: String) -> MarkdownEdit {
        let nsText = text as NSString
        let lineRange = nsText.lineRange(for: selection)
        let lines = nsText.substring(with: lineRange)
        let endsWithNewline = lines.hasSuffix("\n")
        let body = endsWithNewline ? String(lines.dropLast()) : lines
        let replacement = body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { prefix + $0 }
            .joined(separator: "\n") + (endsWithNewline ? "\n" : "")
        return MarkdownEdit(
            range: lineRange,
            replacement: replacement,
            selection: NSRange(location: lineRange.location, length: (replacement as NSString).length)
        )
    }

    private static let listMarkerExpression = try! NSRegularExpression(
        pattern: #"^([ \t]*)(?:[-+*][ \t]+|([0-9]{1,9})[.)][ \t]+)(.*)$"#
    )
    private static let taskMarkerExpression = try! NSRegularExpression(
        pattern: #"^\[([ xX])\](?:[ \t]+(.*))?$"#
    )

    private enum ListTarget: Equatable {
        case unordered
        case ordered
        case task

        var marker: String {
            switch self {
            case .unordered: "- "
            case .ordered: "1. "
            case .task: "- [ ] "
            }
        }
    }

    private struct EditableListLine {
        let indent: String
        let content: String
        let ending: String
        let start: Int?
        let taskState: String?
        let hadMarker: Bool
    }

    private static func convertList(_ text: String, selection: NSRange, target: ListTarget) -> MarkdownEdit {
        let source = text as NSString
        let lineRange = source.lineRange(for: selection)
        if lineRange.length == 0 {
            return MarkdownEdit(range: lineRange, replacement: target.marker,
                                selection: NSRange(location: lineRange.location +
                                                   (target.marker as NSString).length, length: 0))
        }
        var lines: [EditableListLine] = []
        var cursor = lineRange.location
        repeat {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            source.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                                for: NSRange(location: cursor, length: 0))
            let raw = source.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
            let ending = source.substring(with: NSRange(location: contentsEnd, length: lineEnd - contentsEnd))
            if let match = listMarkerExpression.firstMatch(in: raw,
                                                           range: NSRange(location: 0, length: (raw as NSString).length)) {
                let nsRaw = raw as NSString
                let numberRange = match.range(at: 2)
                let markedContent = nsRaw.substring(with: match.range(at: 3))
                let taskMatch = taskMarkerExpression.firstMatch(in: markedContent,
                    range: NSRange(location: 0, length: (markedContent as NSString).length))
                let taskState = taskMatch.map { (markedContent as NSString).substring(with: $0.range(at: 1)) }
                let content: String
                if let taskMatch {
                    let taskContentRange = taskMatch.range(at: 2)
                    content = taskContentRange.location == NSNotFound ? ""
                        : (markedContent as NSString).substring(with: taskContentRange)
                } else {
                    content = markedContent
                }
                lines.append(EditableListLine(indent: nsRaw.substring(with: match.range(at: 1)),
                                              content: content, ending: ending,
                                              start: numberRange.location == NSNotFound ? nil : Int(nsRaw.substring(with: numberRange)),
                                              taskState: taskState, hadMarker: true))
            } else {
                let indent = String(raw.prefix(while: { $0 == " " || $0 == "\t" }))
                lines.append(EditableListLine(indent: indent, content: String(raw.dropFirst(indent.count)),
                                              ending: ending, start: nil, taskState: nil, hadMarker: false))
            }
            cursor = lineEnd
        } while cursor < NSMaxRange(lineRange)

        if selection.length == 0, lines.count == 1, lines[0].content.isEmpty, !lines[0].hadMarker {
            let replacement = lines[0].indent + target.marker + lines[0].ending
            return MarkdownEdit(range: lineRange, replacement: replacement,
                                selection: NSRange(location: lineRange.location +
                                                   (lines[0].indent as NSString).length +
                                                   (target.marker as NSString).length, length: 0))
        }

        var number = lines.first(where: { $0.hadMarker || !$0.content.isEmpty })?.start ?? 1
        let replacement = lines.map { line in
            guard line.hadMarker || !line.content.isEmpty else { return line.indent + line.ending }
            let marker: String
            switch target {
            case .unordered:
                marker = "- "
            case .ordered:
                marker = "\(number). "
                number += 1
            case .task:
                marker = "- [\(line.taskState ?? " ")] "
            }
            let content = target == .ordered
                ? line.taskState.map { "[\($0)] " + line.content } ?? line.content
                : line.content
            return line.indent + marker + content + line.ending
        }.joined()
        let newSelection = NSRange(location: lineRange.location, length: (replacement as NSString).length)
        return MarkdownEdit(range: lineRange, replacement: replacement, selection: newSelection)
    }

    private static func heading(_ text: String, selection: NSRange, level: Int) -> MarkdownEdit {
        precondition((0...6).contains(level))
        let source = text as NSString
        let lineRange = source.lineRange(for: selection)
        var replacement = ""
        var cursor = lineRange.location
        let upper = NSMaxRange(lineRange)

        repeat {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            source.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                                for: NSRange(location: cursor, length: 0))
            let content = source.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
            let ending = source.substring(with: NSRange(location: contentsEnd, length: lineEnd - contentsEnd))
            replacement += headingLine(content, level: level) + ending
            cursor = lineEnd
        } while cursor < upper

        let newSelection: NSRange
        if selection.length == 0 && lineRange.length == 0 && level > 0 {
            newSelection = NSRange(location: lineRange.location + level + 1, length: 0)
        } else {
            newSelection = NSRange(location: lineRange.location, length: (replacement as NSString).length)
        }
        return MarkdownEdit(range: lineRange, replacement: replacement, selection: newSelection)
    }

    private static func headingLine(_ line: String, level: Int) -> String {
        let nsLine = line as NSString
        guard let match = headingExpression.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) else {
            return level == 0 ? line : String(repeating: "#", count: level) + " " + line
        }
        let indentation = nsLine.substring(with: match.range(at: 1))
        var content = nsLine.substring(from: NSMaxRange(match.range))
        content = content.replacingOccurrences(of: #"[ \t]+#+[ \t]*$"#, with: "", options: .regularExpression)
        return indentation + (level == 0 ? "" : String(repeating: "#", count: level) + " ") + content
    }

    private static func clamped(_ selection: NSRange, in text: String) -> NSRange {
        let length = (text as NSString).length
        let location = min(max(selection.location, 0), length)
        return NSRange(location: location, length: min(max(selection.length, 0), length - location))
    }
}
