import Foundation

enum MarkdownIndentation {
    enum Direction { case indent, outdent }

    struct Detection: Equatable {
        let style: EditorIndentationStyle
        let width: Int?
    }

    private struct Change {
        let range: NSRange
        let replacement: String
    }

    private static let quotePattern = try! NSRegularExpression(pattern: #"^[ \t]*>[ \t]?(?:[ \t]*>[ \t]?)*"#)
    // Markdown interprets tabs at four-column stops, regardless of their editor display width.
    private static let markdownTabWidth = 4

    static func detect(in text: String) -> Detection? {
        let source = text as NSString
        var tabLines = 0
        var spaceLines = 0
        var exactWidths = Array(repeating: 0, count: 9)
        var compatibleWidths = exactWidths
        var nextLine = 0
        while nextLine < source.length {
            let start = nextLine
            var contentEnd = 0
            source.getLineStart(nil, end: &nextLine, contentsEnd: &contentEnd,
                                for: NSRange(location: start, length: 0))
            var offset = start
            var hasTab = false
            while offset < contentEnd {
                let character = source.character(at: offset)
                guard character == 32 || character == 9 else { break }
                if character == 9 { hasTab = true }
                offset += 1
            }
            let width = offset - start
            guard width > 0, offset < contentEnd else { continue }
            if source.character(at: start) == 9 {
                tabLines += 1
            } else if !hasTab, width >= 2 {
                spaceLines += 1
                if width <= 8 { exactWidths[width] += 1 }
                for candidate in 2...8 where width.isMultiple(of: candidate) {
                    compatibleWidths[candidate] += 1
                }
            }
        }
        if tabLines > spaceLines { return Detection(style: .tabs, width: nil) }
        guard spaceLines > tabLines,
              let width = (2...8).max(by: {
                  (compatibleWidths[$0], exactWidths[$0], $0) < (compatibleWidths[$1], exactWidths[$1], $1)
              }), compatibleWidths[width] > spaceLines / 2 else { return nil }
        return Detection(style: .spaces, width: width)
    }

    static func edit(in text: String, selection: NSRange, direction: Direction,
                     listIndentWidth: Int = 2, codeIndentWidth: Int = 4,
                     tabWidth: Int = 4, style: EditorIndentationStyle = .spaces,
                     includesPlainText: Bool = false, analysis: MarkdownAnalysis? = nil,
                     allowsAnalysis: Bool = true, dialect: MarkdownDialect = .extended) -> MarkdownEdit? {
        guard (2...8).contains(listIndentWidth), (2...8).contains(codeIndentWidth),
              (2...8).contains(tabWidth) else { return nil }
        let source = text as NSString
        guard isValid(selection: selection, in: source) else { return nil }
        let blocks = (analysis ?? (allowsAnalysis ? MarkdownAnalysis(text, dialect: dialect) : nil))?.blocks ?? []
        let lineRange = selectedLineRange(in: source, selection: selection)
        let selectedLines = lineStarts(in: source, range: lineRange)
        let listBlocks = blocks.filter { block in
            guard isList(block.kind) else { return false }
            let overlap = NSIntersectionRange(lineRange, block.sourceRange)
            guard overlap.length > 0 else { return false }
            let firstLine = source.lineRange(for: NSRange(location: overlap.location, length: 0))
            let firstStart = firstLine.location == overlap.location ? overlap.location : NSMaxRange(firstLine)
            guard firstStart < NSMaxRange(overlap) else { return false }
            guard direction == .outdent else { return true }
            let position = indentationStart(in: source, lineStart: block.sourceRange.location)
            return change(at: position, in: source, amount: listIndentWidth, style: style,
                          direction: .outdent) != nil
        }
        let selectedIDs = Set(listBlocks.map(\.id))
        var listLines = Set<Int>()
        if !selectedIDs.isEmpty {
            let blocksByID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
            for block in blocks where selectedIDs.contains(block.id) || isDescendant(block, of: selectedIDs, in: blocksByID) {
                listLines.formUnion(lineStarts(in: source, range: block.sourceRange))
            }
        }
        var codeLines = Set<Int>()
        for block in blocks where block.kind == .codeBlock {
            let overlap = NSIntersectionRange(block.sourceRange, lineRange)
            if overlap.length > 0 {
                codeLines.formUnion(lineStarts(in: source, range: overlap).filter {
                    NSLocationInRange($0, block.sourceRange)
                })
            }
        }
        codeLines.subtract(listLines)
        guard includesPlainText || !listLines.isEmpty || !codeLines.isEmpty else { return nil }

        if selection.length == 0, listLines.isEmpty, direction == .indent {
            let insertion = prefix(style: style, width: codeLines.isEmpty ? tabWidth : codeIndentWidth)
            return MarkdownEdit(range: selection, replacement: insertion,
                                selection: NSRange(location: selection.location + insertion.utf16.count, length: 0))
        }

        var changes: [Change] = []
        for line in listLines {
            let fullLine = source.lineRange(for: NSRange(location: line, length: 0))
            guard !source.substring(with: fullLine).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            let position = indentationStart(in: source, lineStart: line)
            if let change = change(at: position, in: source, amount: listIndentWidth, style: style,
                                   direction: direction) {
                changes.append(change)
            }
        }
        for line in codeLines {
            if let change = change(at: line, in: source, amount: codeIndentWidth, style: style,
                                   direction: direction) {
                changes.append(change)
            }
        }
        if includesPlainText {
            for line in selectedLines where !listLines.contains(line) && !codeLines.contains(line) {
                if let change = change(at: line, in: source, amount: tabWidth, style: style,
                                       direction: direction) {
                    changes.append(change)
                }
            }
        }
        return edit(in: source, selection: selection, changes: changes)
    }

    static func conversionEdit(in text: String, selection: NSRange,
                               to style: EditorIndentationStyle) -> MarkdownEdit? {
        let source = text as NSString
        guard isValid(selection: selection, in: source), selection.length > 0 else { return nil }
        let lines = lineStarts(in: source, range: selectedLineRange(in: source, selection: selection))
        let changes = lines.compactMap { line -> Change? in
            var end = line
            var columns = 0
            while end < source.length {
                let character = source.character(at: end)
                guard character == 32 || character == 9 else { break }
                columns += character == 9 ? markdownTabWidth - columns % markdownTabWidth : 1
                end += 1
            }
            guard end > line else { return nil }
            let range = NSRange(location: line, length: end - line)
            let replacement = indentation(columns: columns, style: style)
            guard replacement != source.substring(with: range) else { return nil }
            return Change(range: range, replacement: replacement)
        }
        return edit(in: source, selection: selection, changes: changes)
    }

    private static func isValid(selection: NSRange, in source: NSString) -> Bool {
        selection.location >= 0 && selection.location <= source.length &&
            selection.length >= 0 && selection.length <= source.length - selection.location
    }

    private static func edit(in source: NSString, selection: NSRange, changes: [Change]) -> MarkdownEdit? {
        let changes = changes.sorted { $0.range.location < $1.range.location }
        guard let first = changes.first, let last = changes.last else { return nil }
        let start = first.range.location
        let end = NSMaxRange(last.range)
        let range = NSRange(location: start, length: end - start)
        var replacement = ""
        var position = start
        for change in changes {
            if position < change.range.location {
                replacement.append(source.substring(with: NSRange(location: position,
                                                                   length: change.range.location - position)))
            }
            replacement.append(change.replacement)
            position = NSMaxRange(change.range)
        }
        let newStart = mapped(selection.location, through: changes)
        let newEnd = mapped(NSMaxRange(selection), through: changes)
        return MarkdownEdit(range: range, replacement: replacement,
                            selection: NSRange(location: newStart, length: max(0, newEnd - newStart)))
    }

    private static func selectedLineRange(in source: NSString, selection: NSRange) -> NSRange {
        let finalLocation = selection.length == 0 ? selection.location : NSMaxRange(selection) - 1
        let first = source.lineRange(for: NSRange(location: selection.location, length: 0))
        let last = source.lineRange(for: NSRange(location: finalLocation, length: 0))
        return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
    }

    private static func lineStarts(in source: NSString, range: NSRange) -> [Int] {
        var result: [Int] = []
        var cursor = range.location
        while cursor < NSMaxRange(range) {
            let line = source.lineRange(for: NSRange(location: cursor, length: 0))
            result.append(line.location)
            cursor = NSMaxRange(line)
        }
        return result
    }

    private static func isList(_ kind: MarkdownBlock.Kind) -> Bool {
        switch kind {
        case .unorderedList, .orderedList: true
        default: false
        }
    }

    private static func isDescendant(_ block: MarkdownBlock, of ids: Set<Int>,
                                     in blocks: [Int: MarkdownBlock]) -> Bool {
        var parent = block.parentID
        while let id = parent {
            if ids.contains(id) { return true }
            parent = blocks[id]?.parentID
        }
        return false
    }

    private static func indentationStart(in source: NSString, lineStart: Int) -> Int {
        let line = source.lineRange(for: NSRange(location: lineStart, length: 0))
        let text = source.substring(with: line)
        let match = quotePattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        return lineStart + (match.map { NSMaxRange($0.range) } ?? 0)
    }

    private static func prefix(style: EditorIndentationStyle, width: Int) -> String {
        style == .tabs ? "\t" : String(repeating: " ", count: width)
    }

    private static func indentation(columns: Int, style: EditorIndentationStyle) -> String {
        switch style {
        case .spaces: String(repeating: " ", count: columns)
        case .tabs: String(repeating: "\t", count: columns / markdownTabWidth) +
                    String(repeating: " ", count: columns % markdownTabWidth)
        }
    }

    private static func change(at start: Int, in source: NSString, amount: Int, style: EditorIndentationStyle,
                               direction: Direction) -> Change? {
        if direction == .indent {
            return Change(range: NSRange(location: start, length: 0),
                          replacement: prefix(style: style, width: amount))
        }
        var end = start
        while end < source.length && end - start < amount && source.character(at: end) == 32 {
            end += 1
        }
        if end == start && start < source.length && source.character(at: start) == 9 { end += 1 }
        guard end > start else { return nil }
        if source.character(at: start) == 32 {
            var offset = end
            var columns = end - start
            var containsTab = false
            while offset < source.length {
                let character = source.character(at: offset)
                guard character == 32 || character == 9 else { break }
                if character == 9 { containsTab = true }
                columns += character == 9 ? markdownTabWidth - columns % markdownTabWidth : 1
                offset += 1
            }
            if containsTab {
                // Removing only the spaces before a tab can leave it at the same column.
                let removal = style == .tabs ? markdownTabWidth : amount
                return Change(range: NSRange(location: start, length: offset - start),
                              replacement: indentation(columns: max(0, columns - removal), style: style))
            }
        }
        return Change(range: NSRange(location: start, length: end - start), replacement: "")
    }

    private static func mapped(_ position: Int, through changes: [Change]) -> Int {
        var offset = 0
        for change in changes {
            let delta = (change.replacement as NSString).length - change.range.length
            if position >= NSMaxRange(change.range) {
                offset += delta
            } else if position > change.range.location {
                return change.range.location + offset + (change.replacement as NSString).length
            } else {
                break
            }
        }
        return position + offset
    }
}
