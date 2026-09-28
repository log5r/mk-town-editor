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
    case plainBlock
    case removeFormatting
    case tableOfContents
    case renumberList
    case duplicateLines
    case moveLinesUp
    case moveLinesDown
    case deleteLines
    case comment
    case unorderedList
    case orderedList
    case taskList
    case codeBlock(language: MarkdownCodeLanguage?)
    case horizontalRule
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

struct MarkdownSnippetPlan {
    let edit: MarkdownEdit
    let placeholders: [NSRange]
    let finalCaret: Int

    static func make(_ snippet: EditorSnippet, in text: String, selection: NSRange) -> Self? {
        guard !snippet.template.isEmpty else { return nil }
        let source = text as NSString
        guard selection.location >= 0, NSMaxRange(selection) <= source.length else { return nil }
        var replacementRange = selection
        if selection.length == 0, !snippet.trigger.isEmpty {
            let before = source.substring(to: selection.location) as NSString
            let triggerLength = (snippet.trigger as NSString).length
            if before.length >= triggerLength &&
                before.substring(from: before.length - triggerLength) == snippet.trigger &&
                (before.length == triggerLength || {
                    let previous = before.substring(with: NSRange(location:
                        before.length - triggerLength - 1, length: 1))
                    return !previous.unicodeScalars.contains {
                        CharacterSet.alphanumerics.contains($0) || $0 == "_"
                    }
                }()) {
                replacementRange = NSRange(location: selection.location - triggerLength,
                    length: triggerLength)
            }
        }
        let pattern = try! NSRegularExpression(pattern: #"\$\{([1-9][0-9]*):([^}]*)\}|\$0"#)
        let template = snippet.template as NSString
        let matches = pattern.matches(in: snippet.template,
            range: NSRange(location: 0, length: template.length))
        var result = ""
        var previous = 0
        var positions: [(order: Int, range: NSRange)] = []
        var finalCaret: Int?
        for match in matches {
            result += template.substring(with: NSRange(location: previous,
                length: match.range.location - previous))
            if match.range(at: 1).location != NSNotFound {
                let value = template.substring(with: match.range(at: 2))
                positions.append((Int(template.substring(with: match.range(at: 1))) ?? 1,
                    NSRange(location: replacementRange.location + (result as NSString).length,
                        length: (value as NSString).length)))
                result += value
            } else {
                finalCaret = replacementRange.location + (result as NSString).length
            }
            previous = NSMaxRange(match.range)
        }
        result += template.substring(from: previous)
        let ordered = positions.sorted { $0.order < $1.order }.map(\.range)
        let caret = finalCaret ?? replacementRange.location + (result as NSString).length
        let first = ordered.first ?? NSRange(location: caret, length: 0)
        return MarkdownSnippetPlan(edit: MarkdownEdit(range: replacementRange,
            replacement: result, selection: first), placeholders: ordered, finalCaret: caret)
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
            return wrap(text, selection: safeSelection, prefix: "**", suffix: "**", placeholder: String(localized: "太字"))
        case .italic:
            return wrap(text, selection: safeSelection, prefix: "_", suffix: "_", placeholder: String(localized: "斜体"))
        case .strikethrough:
            return wrap(text, selection: safeSelection, prefix: "~~", suffix: "~~", placeholder: String(localized: "取り消し線"))
        case .inlineCode:
            return wrap(text, selection: safeSelection, prefix: "`", suffix: "`", placeholder: String(localized: "コード"))
        case .link:
            return link(text, selection: safeSelection)
        case let .heading(level):
            return heading(text, selection: safeSelection, level: level)
        case .quote:
            return toggleQuote(text, selection: safeSelection)
        case .plainBlock:
            return removeBlockMarkers(text, selection: safeSelection)
        case .removeFormatting:
            return removeFormatting(text, selection: safeSelection)
        case .tableOfContents:
            return tableOfContents(text, selection: safeSelection)
        case .renumberList:
            return renumberList(text, selection: safeSelection)
        case .duplicateLines:
            return editLines(text, selection: safeSelection, operation: .duplicate)
        case .moveLinesUp:
            return editLines(text, selection: safeSelection, operation: .moveUp)
        case .moveLinesDown:
            return editLines(text, selection: safeSelection, operation: .moveDown)
        case .deleteLines:
            return editLines(text, selection: safeSelection, operation: .delete)
        case .comment:
            return commentEdit(in: text, selection: safeSelection) ?? unchangedEdit(text, selection: safeSelection)
        case .unorderedList:
            return convertList(text, selection: safeSelection, target: .unordered)
        case .orderedList:
            return convertList(text, selection: safeSelection, target: .ordered)
        case .taskList:
            return convertList(text, selection: safeSelection, target: .task)
        case let .codeBlock(language):
            return fencedCodeBlock(text, selection: safeSelection, language: language)
        case .horizontalRule:
            return horizontalRule(text, selection: safeSelection)
        }
    }

    private static func horizontalRule(_ text: String, selection: NSRange) -> MarkdownEdit {
        let source = text as NSString
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let before = source.substring(to: selection.location)
        let after = source.substring(from: NSMaxRange(selection))
        let leading: String
        if before.isEmpty || before.hasSuffix(newline + newline) {
            leading = ""
        } else if before.hasSuffix(newline) {
            leading = newline
        } else {
            leading = newline + newline
        }
        let trailing: String
        if after.isEmpty || after.hasPrefix(newline + newline) {
            trailing = ""
        } else if after.hasPrefix(newline) {
            trailing = newline
        } else {
            trailing = newline + newline
        }
        let replacement = leading + "***" + trailing
        return MarkdownEdit(range: selection, replacement: replacement,
                            selection: NSRange(location: selection.location +
                                               (replacement as NSString).length, length: 0))
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
        let label = selected.isEmpty ? String(localized: "リンク") : selected
        let replacement = MarkdownLinkSyntax.makeLink(label: label, destination: "https://")
        let urlStart = selection.location + (replacement as NSString).range(of: "https://").location
        return MarkdownEdit(range: selection, replacement: replacement, selection: NSRange(location: urlStart, length: 8))
    }

    private static func tableOfContents(_ text: String, selection: NSRange) -> MarkdownEdit {
        let source = text as NSString
        let remainingText = source.replacingCharacters(in: selection, with: "")
        let anchors = MarkdownHeadingIndex(analysis: MarkdownAnalysis(remainingText)).anchors
        guard let minimumLevel = anchors.map(\.entry.level).min() else {
            return MarkdownEdit(range: selection, replacement: source.substring(with: selection),
                selection: selection)
        }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let lines = anchors.map { anchor in
            let indent = String(repeating: "  ", count: anchor.entry.level - minimumLevel)
            let title = MarkdownHeadingIndex.visibleText(anchor.entry.title)
            return indent + "- " + MarkdownLinkSyntax.makeLink(label: title,
                destination: "#" + anchor.slug)
        }.joined(separator: newline)
        let before = source.substring(to: selection.location)
        let after = source.substring(from: NSMaxRange(selection))
        let prefix = selection.length == 0 && !before.isEmpty && !before.hasSuffix(newline + newline)
            ? (before.hasSuffix(newline) ? newline : newline + newline) : ""
        let suffix = selection.length == 0 && !after.isEmpty && !after.hasPrefix(newline + newline)
            ? (after.hasPrefix(newline) ? newline : newline + newline) : ""
        let replacement = prefix + lines + suffix
        return MarkdownEdit(range: selection, replacement: replacement,
            selection: NSRange(location: selection.location + (prefix as NSString).length,
                length: (lines as NSString).length))
    }

    private static let orderedMarkerExpression = try! NSRegularExpression(
        pattern: #"^((?:[ \t]*>[ \t]*)*[ \t]*)([0-9]{1,9})([.)])(?=[ \t]+)"#)

    private static func renumberList(_ text: String, selection: NSRange) -> MarkdownEdit {
        let source = text as NSString
        let blocks = MarkdownAnalysis(text).blocks
        let selectedIDs = Set(blocks.filter { block in
            guard case .orderedList = block.kind else { return false }
            return selection.length == 0
                ? selection.location >= block.sourceRange.location &&
                    selection.location <= NSMaxRange(block.sourceRange)
                : NSIntersectionRange(selection, block.sourceRange).length > 0
        }.map(\.id))
        guard !selectedIDs.isEmpty else {
            return MarkdownEdit(range: selection, replacement: source.substring(with: selection),
                selection: selection)
        }
        var changes: [(range: NSRange, number: String)] = []
        for parent in Set(blocks.map(\.parentID)) {
            let siblings = blocks.filter { $0.parentID == parent }
            var run: [MarkdownBlock] = []
            func finishRun() {
                defer { run.removeAll() }
                guard !run.isEmpty, run.contains(where: { selectedIDs.contains($0.id) }),
                      case let .orderedList(start) = run[0].kind else { return }
                for (offset, block) in run.enumerated() {
                    let line = source.substring(with: source.lineRange(for:
                        NSRange(location: block.sourceRange.location, length: 0)))
                    guard let marker = orderedMarkerExpression.firstMatch(in: line,
                        range: NSRange(location: 0, length: (line as NSString).length)) else { continue }
                    let numberRange = NSRange(location: block.sourceRange.location + marker.range(at: 2).location,
                        length: marker.range(at: 2).length)
                    changes.append((numberRange, String(start + offset)))
                }
            }
            for sibling in siblings {
                if case .orderedList = sibling.kind {
                    run.append(sibling)
                } else {
                    finishRun()
                }
            }
            finishRun()
        }
        guard let first = changes.map(\.range.location).min(),
              let last = changes.map({ NSMaxRange($0.range) }).max() else {
            return MarkdownEdit(range: selection, replacement: source.substring(with: selection),
                selection: selection)
        }
        let range = NSRange(location: first, length: last - first)
        var replacement = source.substring(with: range)
        for change in changes.sorted(by: { $0.range.location > $1.range.location }) {
            let local = NSRange(location: change.range.location - first, length: change.range.length)
            replacement = (replacement as NSString).replacingCharacters(in: local, with: change.number)
        }
        return MarkdownEdit(range: range, replacement: replacement,
            selection: NSRange(location: first, length: (replacement as NSString).length))
    }

    private enum LineOperation { case duplicate, moveUp, moveDown, delete }

    private static func editLines(_ text: String, selection: NSRange,
                                  operation: LineOperation) -> MarkdownEdit {
        let source = text as NSString
        let endInsideSelection = selection.length > 0 ? selection.length - 1 : 0
        let lines = source.lineRange(for: NSRange(location: selection.location,
            length: endInsideSelection))
        let selected = source.substring(with: lines)
        let selectedParts = splitLineEnding(selected)
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        switch operation {
        case .duplicate:
            let inserted = (selectedParts.ending.isEmpty ? newline : "") + selected
            let start = NSMaxRange(lines)
            return MarkdownEdit(range: NSRange(location: start, length: 0), replacement: inserted,
                selection: NSRange(location: start +
                    (selectedParts.ending.isEmpty ? (newline as NSString).length : 0),
                    length: (selected as NSString).length))
        case .delete:
            var removed = lines
            if NSMaxRange(lines) == source.length && selectedParts.ending.isEmpty && lines.location > 0 {
                let before = source.substring(to: lines.location)
                let separatorLength = before.hasSuffix("\r\n") ? 2 : 1
                removed = NSRange(location: lines.location - separatorLength,
                    length: lines.length + separatorLength)
            }
            return MarkdownEdit(range: removed, replacement: "",
                selection: NSRange(location: removed.location, length: 0))
        case .moveUp:
            guard lines.location > 0 else { return unchangedEdit(text, selection: selection) }
            let previous = source.lineRange(for: NSRange(location: lines.location - 1, length: 0))
            let before = splitLineEnding(source.substring(with: previous))
            let replacement = selectedParts.body + before.ending + before.body + selectedParts.ending
            return MarkdownEdit(range: NSRange(location: previous.location,
                length: NSMaxRange(lines) - previous.location), replacement: replacement,
                selection: NSRange(location: previous.location,
                    length: ((selectedParts.body + before.ending) as NSString).length))
        case .moveDown:
            guard NSMaxRange(lines) < source.length else {
                return unchangedEdit(text, selection: selection)
            }
            let next = source.lineRange(for: NSRange(location: NSMaxRange(lines), length: 0))
            let after = splitLineEnding(source.substring(with: next))
            let replacement = after.body + selectedParts.ending + selectedParts.body + after.ending
            let movedStart = lines.location + ((after.body + selectedParts.ending) as NSString).length
            return MarkdownEdit(range: NSRange(location: lines.location,
                length: NSMaxRange(next) - lines.location), replacement: replacement,
                selection: NSRange(location: movedStart,
                    length: ((selectedParts.body + after.ending) as NSString).length))
        }
    }

    private static func splitLineEnding(_ text: String) -> (body: String, ending: String) {
        if text.hasSuffix("\r\n") { return (String(text.dropLast(2)), "\r\n") }
        if text.hasSuffix("\n") || text.hasSuffix("\r") {
            return (String(text.dropLast()), String(text.suffix(1)))
        }
        return (text, "")
    }

    private static func unchangedEdit(_ text: String, selection: NSRange) -> MarkdownEdit {
        MarkdownEdit(range: selection, replacement: (text as NSString).substring(with: selection),
            selection: selection)
    }

    private static let commentExpression = try! NSRegularExpression(pattern: #"<!--[\s\S]*?-->"#)

    static func commentEdit(in text: String, selection: NSRange) -> MarkdownEdit? {
        let source = text as NSString
        let selection = clamped(selection, in: text)
        let matches = commentExpression.matches(in: text,
            range: NSRange(location: 0, length: source.length))
        if let existing = matches.first(where: { match in
            selection.length == 0
                ? selection.location > match.range.location && selection.location < NSMaxRange(match.range)
                : selection.location >= match.range.location &&
                    NSMaxRange(selection) <= NSMaxRange(match.range)
        }) {
            let inner = source.substring(with: NSRange(location: existing.range.location + 4,
                length: existing.range.length - 7))
            let content = inner.hasPrefix(" ") && inner.hasSuffix(" ")
                ? String(inner.dropFirst().dropLast()) : inner
            return MarkdownEdit(range: existing.range, replacement: content,
                selection: NSRange(location: existing.range.location,
                    length: (content as NSString).length))
        }
        let selected = source.substring(with: selection)
        guard !selected.contains("--"), !selected.contains("<!--") else { return nil }
        let replacement = "<!-- " + selected + " -->"
        let innerStart = selection.location + 5
        return MarkdownEdit(range: selection, replacement: replacement,
            selection: NSRange(location: innerStart,
                length: (selected as NSString).length))
    }

    private static func removeFormatting(_ text: String, selection: NSRange) -> MarkdownEdit {
        let source = text as NSString
        let fencedCode = MarkdownAnalysis(text).blocks.filter { $0.kind == .codeBlock }.map(\.sourceRange)
        let codeRanges = MarkdownInlineSyntax.codeSpanRanges(in: text)
        let links = MarkdownLinkSyntax.inlineLinks(in: text).filter { link in
            !codeRanges.contains { NSIntersectionRange($0, link.range).length > 0 } &&
                !fencedCode.contains { NSIntersectionRange($0, link.range).length > 0 }
        }
        let inlineSpans = ["**", "__", "~~", "*", "_", "`"].flatMap {
            formattingSpans(in: text, markers: [$0]).map(\.range)
        }.filter { span in !fencedCode.contains { NSIntersectionRange($0, span).length > 0 } }
        let candidates = links.map(\.range) + inlineSpans
        let target: NSRange
        if let enclosing = candidates.filter({ range in
            selection.length == 0
                ? selection.location > range.location && selection.location < NSMaxRange(range)
                : selection.location >= range.location && NSMaxRange(selection) <= NSMaxRange(range)
        }).min(by: { $0.length < $1.length }) {
            target = enclosing
        } else {
            target = selection
        }
        let raw = source.substring(with: target) as NSString
        var fragment = ""
        var cursor = 0
        for range in fencedCode.compactMap({ code -> NSRange? in
            let intersection = NSIntersectionRange(code, target)
            return intersection.length == 0 ? nil : NSRange(
                location: intersection.location - target.location, length: intersection.length)
        }).sorted(by: { $0.location < $1.location }) {
            fragment += strippingInlineFormatting(raw.substring(with:
                NSRange(location: cursor, length: range.location - cursor)))
            fragment += raw.substring(with: range)
            cursor = NSMaxRange(range)
        }
        fragment += strippingInlineFormatting(raw.substring(from: cursor))
        return MarkdownEdit(range: target, replacement: fragment,
            selection: NSRange(location: target.location, length: (fragment as NSString).length))
    }

    private static func strippingInlineFormatting(_ text: String) -> String {
        let source = text as NSString
        let codeRanges = MarkdownInlineSyntax.codeSpanRanges(in: text)
        let links = MarkdownLinkSyntax.inlineLinks(in: text).filter { link in
            !codeRanges.contains { NSIntersectionRange($0, link.range).length > 0 }
        }
        guard !links.isEmpty else { return strippingEmphasis(text) }
        var result = ""
        var cursor = 0
        for link in links {
            result += strippingEmphasis(source.substring(with:
                NSRange(location: cursor, length: link.range.location - cursor)))
            let label = source.substring(with: link.labelRange)
                .replacingOccurrences(of: #"\([\[\]_*`])"#, with: "$1",
                    options: .regularExpression)
            result += strippingEmphasis(label)
            if !link.destination.isEmpty { result += " (\(link.destination))" }
            cursor = NSMaxRange(link.range)
        }
        result += strippingEmphasis(source.substring(from: cursor))
        return result
    }

    private static func strippingEmphasis(_ text: String) -> String {
        var fragment = text
        let markers = ["**", "__", "~~", "*", "_", "`"]
        for _ in 0..<max(1, fragment.count) {
            let spans = markers.flatMap { formattingSpans(in: fragment, markers: [$0]) }
            guard let span = spans.min(by: { $0.range.location < $1.range.location ||
                ($0.range.location == $1.range.location && $0.range.length > $1.range.length) }) else { break }
            let current = fragment as NSString
            fragment = current.replacingCharacters(in: span.range,
                with: current.substring(with: span.innerRange))
        }
        return fragment
    }

    private static let quoteMarkerExpression = try! NSRegularExpression(pattern: #"^([ \t]*)>[ \t]?"#)

    private static func toggleQuote(_ text: String, selection: NSRange) -> MarkdownEdit {
        let lines = selectedLines(in: text, selection: selection)
        let nonblank = lines.parts.filter { !$0.content.trimmingCharacters(in: .whitespaces).isEmpty }
        let allQuoted = !nonblank.isEmpty && nonblank.allSatisfy { quoteMarker(in: $0.content) != nil }
        let allListed = !nonblank.isEmpty && nonblank.allSatisfy { listMarker(in: $0.content) != nil }
        let replacement = lines.parts.map { part in
            let content: String
            if allQuoted, let marker = quoteMarker(in: part.content) {
                content = strippingQuote(part.content, marker: marker)
            } else if allListed, let marker = listMarker(in: part.content) {
                let source = part.content as NSString
                content = source.substring(with: marker.range(at: 1)) + "> " +
                    source.substring(with: marker.range(at: 3))
            } else if !allQuoted && quoteMarker(in: part.content) == nil {
                content = "> " + part.content
            } else {
                content = part.content
            }
            return content + part.ending
        }.joined()
        return MarkdownEdit(range: lines.range, replacement: replacement,
            selection: NSRange(location: lines.range.location, length: (replacement as NSString).length))
    }

    private static func removeBlockMarkers(_ text: String, selection: NSRange) -> MarkdownEdit {
        let lines = selectedLines(in: text, selection: selection)
        let replacement = lines.parts.map { part in
            var content = part.content
            if let marker = quoteMarker(in: content) {
                content = strippingQuote(content, marker: marker)
            } else if let marker = listMarker(in: content) {
                let source = content as NSString
                content = source.substring(with: marker.range(at: 1)) +
                    source.substring(with: marker.range(at: 3))
            } else if let marker = headingExpression.firstMatch(in: content,
                range: NSRange(location: 0, length: (content as NSString).length)) {
                let source = content as NSString
                content = source.substring(with: marker.range(at: 1)) +
                    source.substring(from: NSMaxRange(marker.range))
            }
            return content + part.ending
        }.joined()
        return MarkdownEdit(range: lines.range, replacement: replacement,
            selection: NSRange(location: lines.range.location, length: (replacement as NSString).length))
    }

    private static func quoteMarker(in content: String) -> NSTextCheckingResult? {
        quoteMarkerExpression.firstMatch(in: content,
            range: NSRange(location: 0, length: (content as NSString).length))
    }

    private static func listMarker(in content: String) -> NSTextCheckingResult? {
        listMarkerExpression.firstMatch(in: content,
            range: NSRange(location: 0, length: (content as NSString).length))
    }

    private static func strippingQuote(_ content: String, marker: NSTextCheckingResult) -> String {
        let source = content as NSString
        return source.substring(with: marker.range(at: 1)) +
            source.substring(from: NSMaxRange(marker.range))
    }

    private static func selectedLines(in text: String, selection: NSRange) ->
        (range: NSRange, parts: [(content: String, ending: String)]) {
        let source = text as NSString
        let lineRange = source.lineRange(for: selection)
        var parts: [(String, String)] = []
        var cursor = lineRange.location
        repeat {
            var start = 0
            var end = 0
            var contentEnd = 0
            source.getLineStart(&start, end: &end, contentsEnd: &contentEnd,
                for: NSRange(location: cursor, length: 0))
            parts.append((source.substring(with: NSRange(location: start, length: contentEnd - start)),
                          source.substring(with: NSRange(location: contentEnd, length: end - contentEnd))))
            cursor = end
        } while cursor < NSMaxRange(lineRange)
        return (lineRange, parts)
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
        let selected = selectedLines(in: text, selection: selection)
        let quoteScope = selected.parts.filter { !$0.content.trimmingCharacters(in: .whitespaces).isEmpty }
            .allSatisfy { quoteMarker(in: $0.content) != nil }
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
            let original = source.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
            let raw: String
            if quoteScope, let marker = quoteMarker(in: original) {
                raw = strippingQuote(original, marker: marker)
            } else {
                raw = original
            }
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

struct MarkdownAutoFormatChange: Equatable {
    let line: Int
    let before: String
    let after: String
}

struct MarkdownAutoFormatPlan: Equatable {
    let source: String
    let edit: MarkdownEdit
    let changes: [MarkdownAutoFormatChange]
}

enum MarkdownAutoFormat {
    private static let listMarker = try! NSRegularExpression(pattern: #"^([ \t]*)[+*][ \t]+"#)
    private static let headingSpace = try! NSRegularExpression(pattern: #"^( {0,3}#{1,6})[ \t]+"#)

    static func plan(_ source: String, selection: NSRange? = nil) -> MarkdownAutoFormatPlan? {
        let text = source as NSString
        let fullRange = NSRange(location: 0, length: text.length)
        let scope: NSRange
        if let selection {
            guard selection.location >= 0, selection.location <= text.length,
                  selection.length >= 0,
                  selection.length <= text.length - selection.location else { return nil }
            scope = text.lineRange(for: selection)
        } else {
            scope = fullRange
        }
        let analysis = MarkdownAnalysis(source)
        let codeRanges = analysis.blocks.filter { $0.kind == .codeBlock }.map(\.sourceRange)
        let listStarts = Set(analysis.blocks.filter { $0.kind == .unorderedList }
            .map(\.sourceRange.location))
        let frontMatterEnd = frontMatterEnd(in: source)
        let starts = MarkdownLineIndex(source).starts
        var replacement = ""
        var changes: [MarkdownAutoFormatChange] = []
        for (index, start) in starts.enumerated() {
            guard start >= scope.location, start < NSMaxRange(scope) else { continue }
            let end = index + 1 < starts.count ? starts[index + 1] : text.length
            let complete = text.substring(with: NSRange(location: start, length: end - start))
            let content = complete.trimmingCharacters(in: .newlines)
            let newline = String(complete.dropFirst(content.count))
            let protected = start < frontMatterEnd || codeRanges.contains { NSLocationInRange(start, $0) }
            let formatted = protected ? content : formatLine(content, isList: listStarts.contains(start))
            if content != formatted {
                changes.append(MarkdownAutoFormatChange(line: index + 1,
                                                       before: content, after: formatted))
            }
            replacement += formatted + newline
        }
        guard !changes.isEmpty else { return nil }
        let edit = MarkdownEdit(range: scope, replacement: replacement,
            selection: NSRange(location: scope.location + (replacement as NSString).length, length: 0))
        return MarkdownAutoFormatPlan(source: source, edit: edit, changes: changes)
    }

    private static func formatLine(_ line: String, isList: Bool) -> String {
        let whitespace = line.reversed().prefix { $0 == " " || $0 == "\t" }
        let trimmed = whitespace.count >= 2 && whitespace.allSatisfy { $0 == " " }
            ? line : String(line.dropLast(whitespace.count))
        let range = NSRange(location: 0, length: (trimmed as NSString).length)
        if isList, let match = listMarker.firstMatch(in: trimmed, range: range) {
            let prefix = (trimmed as NSString).substring(with: match.range(at: 1))
            return prefix + "- " + (trimmed as NSString).substring(from: NSMaxRange(match.range))
        }
        if let match = headingSpace.firstMatch(in: trimmed, range: range) {
            let prefix = (trimmed as NSString).substring(with: match.range(at: 1))
            return prefix + " " + (trimmed as NSString).substring(from: NSMaxRange(match.range))
        }
        return trimmed
    }

    private static func frontMatterEnd(in source: String) -> Int {
        let starts = MarkdownLineIndex(source).starts
        let text = source as NSString
        guard starts.count > 1 else { return 0 }
        func line(at index: Int) -> String {
            let start = starts[index]
            let end = index + 1 < starts.count ? starts[index + 1] : text.length
            return text.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .newlines)
        }
        guard line(at: 0) == "---" else { return 0 }
        for index in 1..<starts.count where line(at: index) == "---" || line(at: index) == "..." {
            return index + 1 < starts.count ? starts[index + 1] : text.length
        }
        return text.length
    }
}

enum MarkdownFootnoteInsertion {
    private static let identifierPattern = try! NSRegularExpression(pattern: #"\[\^([^\]\n]+)\]"#)

    static func plan(in text: String, selection: NSRange) -> MarkdownEdit? {
        let source = text as NSString
        guard selection.location >= 0, selection.location <= source.length,
              selection.length >= 0,
              selection.length <= source.length - selection.location else { return nil }
        let full = NSRange(location: 0, length: source.length)
        let used = Set(identifierPattern.matches(in: text, range: full).map {
            source.substring(with: $0.range(at: 1)).lowercased()
        })
        var number = 1
        while used.contains("fn\(number)") { number += 1 }
        let id = "fn\(number)"
        let reference = "[^\(id)]"
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let insertion = NSMaxRange(selection)
        let suffix = source.substring(from: insertion)
        let bodyAfterReference = source.substring(to: insertion) + reference + suffix
        let separator: String
        if bodyAfterReference.hasSuffix(newline + newline) { separator = "" }
        else if bodyAfterReference.hasSuffix(newline) { separator = newline }
        else { separator = newline + newline }
        let definition = "[^\(id)]: "
        let replacement = reference + suffix + separator + definition
        return MarkdownEdit(range: NSRange(location: insertion, length: source.length - insertion),
            replacement: replacement,
            selection: NSRange(location: insertion + (replacement as NSString).length, length: 0))
    }
}
