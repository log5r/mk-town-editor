import Foundation

enum MarkdownIndentation {
    enum Direction { case indent, outdent }

    private struct Change {
        let range: NSRange
        let replacement: String
    }

    private static let quotePattern = try! NSRegularExpression(pattern: #"^[ \t]*(?:>[ \t]*)+"#)

    static func edit(in text: String, selection: NSRange, direction: Direction) -> MarkdownEdit? {
        let source = text as NSString
        guard selection.location <= source.length,
              selection.length <= source.length - selection.location else { return nil }
        let analysis = MarkdownAnalysis(text)
        let selectedLines = lineStarts(in: source, range: selectedLineRange(in: source, selection: selection))
        let listBlocks = analysis.blocks.filter { block in
            guard isList(block.kind),
                  selectedLines.contains(where: { NSLocationInRange($0, block.sourceRange) }) else { return false }
            guard direction == .outdent else { return true }
            let position = indentationStart(in: source, lineStart: block.sourceRange.location)
            return change(at: position, in: source, amount: 2, direction: .outdent) != nil
        }
        let selectedIDs = Set(listBlocks.map(\.id))
        let blocksByID = Dictionary(uniqueKeysWithValues: analysis.blocks.map { ($0.id, $0) })
        var listLines = Set<Int>()
        for block in analysis.blocks where selectedIDs.contains(block.id) || isDescendant(block, of: selectedIDs, in: blocksByID) {
            listLines.formUnion(lineStarts(in: source, range: block.sourceRange))
        }
        let codeRanges = analysis.blocks.filter { $0.kind == .codeBlock }.map(\.sourceRange)
        let codeLines = selectedLines.filter { line in
            codeRanges.contains { NSLocationInRange(line, $0) } && !listLines.contains(line)
        }
        guard !listLines.isEmpty || !codeLines.isEmpty else { return nil }

        if selection.length == 0, listLines.isEmpty, !codeLines.isEmpty, direction == .indent {
            return MarkdownEdit(range: selection, replacement: "    ",
                                selection: NSRange(location: selection.location + 4, length: 0))
        }

        var changes: [Change] = []
        for line in listLines.sorted() {
            let fullLine = source.lineRange(for: NSRange(location: line, length: 0))
            guard !source.substring(with: fullLine).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            let position = indentationStart(in: source, lineStart: line)
            if let change = change(at: position, in: source, amount: 2, direction: direction) {
                changes.append(change)
            }
        }
        for line in codeLines.sorted() {
            if let change = change(at: line, in: source, amount: 4, direction: direction) {
                changes.append(change)
            }
        }
        guard !changes.isEmpty else { return nil }
        changes.sort { $0.range.location < $1.range.location }
        let start = changes[0].range.location
        let end = changes.map { NSMaxRange($0.range) }.max()!
        let range = NSRange(location: start, length: end - start)
        let replacement = NSMutableString(string: source.substring(with: range))
        for change in changes.reversed() {
            replacement.replaceCharacters(in: NSRange(location: change.range.location - start,
                                                      length: change.range.length),
                                          with: change.replacement)
        }
        let newStart = mapped(selection.location, through: changes)
        let newEnd = mapped(NSMaxRange(selection), through: changes)
        return MarkdownEdit(range: range, replacement: replacement as String,
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

    private static func change(at start: Int, in source: NSString, amount: Int,
                               direction: Direction) -> Change? {
        if direction == .indent {
            return Change(range: NSRange(location: start, length: 0),
                          replacement: String(repeating: " ", count: amount))
        }
        var end = start
        while end < source.length && end - start < amount && source.character(at: end) == 32 {
            end += 1
        }
        if end == start && start < source.length && source.character(at: start) == 9 { end += 1 }
        guard end > start else { return nil }
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
