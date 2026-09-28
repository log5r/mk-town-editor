import Foundation

struct MarkdownTableDraft: Identifiable {
    let id = UUID()
    let range: NSRange
    let originalText: String
}

enum MarkdownTableInsertion {
    static func draft(in text: String, selection: NSRange) -> MarkdownTableDraft {
        let length = (text as NSString).length
        let location = min(max(selection.location, 0), length)
        let safe = NSRange(location: location,
                           length: min(max(selection.length, 0), length - location))
        return MarkdownTableDraft(range: safe, originalText: text)
    }

    static func edit(in text: String, draft: MarkdownTableDraft,
                     rows: Int, columns: Int) -> MarkdownEdit? {
        let source = text as NSString
        guard text == draft.originalText,
              (1...20).contains(rows), (1...12).contains(columns),
              draft.range.location <= source.length,
              NSMaxRange(draft.range) <= source.length else { return nil }
        let newline = text.contains("\r\n") ? "\r\n" : text.contains("\r") ? "\r" : "\n"
        let before = source.substring(to: draft.range.location)
        let after = source.substring(from: NSMaxRange(draft.range))
        let leading = spacing(before: before, newline: newline)
        let trailing = spacing(after: after, newline: newline)
        let header = "| " + (1...columns).map { "列\($0)" }.joined(separator: " | ") + " |"
        let delimiter = "| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |"
        let row = "| " + Array(repeating: " ", count: columns).joined(separator: " | ") + " |"
        let table = ([header, delimiter] + Array(repeating: row, count: rows)).joined(separator: newline)
        let replacement = leading + table + trailing
        return MarkdownEdit(range: draft.range, replacement: replacement,
                            selection: NSRange(location: draft.range.location + (leading as NSString).length + 2,
                                               length: ("列1" as NSString).length))
    }

    private static func spacing(before text: String, newline: String) -> String {
        if text.isEmpty || text.hasSuffix(newline + newline) { return "" }
        return text.hasSuffix(newline) ? newline : newline + newline
    }

    private static func spacing(after text: String, newline: String) -> String {
        if text.isEmpty || text.hasPrefix(newline + newline) { return "" }
        return text.hasPrefix(newline) ? newline : newline + newline
    }
}

enum MarkdownTableOperation: Equatable {
    case insertRow
    case deleteRow
    case insertColumn
    case deleteColumn
    case alignColumn(MarkdownTable.Alignment)
}

enum MarkdownTableTabAction: Equatable {
    case select(NSRange)
    case edit(MarkdownEdit)
}

enum MarkdownTableEditing {
    static func tabAction(in text: String, selection: NSRange,
                          backwards: Bool, addsRowAtEnd: Bool) -> MarkdownTableTabAction? {
        let source = text as NSString
        guard selection.location >= 0, selection.location < source.length,
              let block = MarkdownAnalysis(text).blocks.first(where: {
                  $0.kind == .table && NSLocationInRange(selection.location, $0.sourceRange)
              }), let table = block.table else { return nil }
        let header = source.lineRange(for: NSRange(location: block.sourceRange.location, length: 0))
        let delimiter = source.lineRange(for: NSRange(location: NSMaxRange(header), length: 0))
        let rows = [header] + table.rowRanges
        let currentLine = source.lineRange(for: NSRange(location: selection.location, length: 0))
        let currentRow = rows.firstIndex(of: currentLine)
        let currentColumn: Int
        if let currentRow {
            let content = lineContent(source.substring(with: rows[currentRow])).content
            guard let currentCells = cells(in: content, expected: table.header.count) else { return nil }
            currentColumn = columnIndex(at: selection.location - rows[currentRow].location,
                                        cells: currentCells)
        } else if currentLine == delimiter {
            currentColumn = backwards ? 0 : table.header.count - 1
        } else {
            return nil
        }
        let targetRow: Int
        let targetColumn: Int
        if backwards {
            targetRow = currentColumn > 0 ? (currentRow ?? 1) : max(0, (currentRow ?? 1) - 1)
            targetColumn = currentColumn > 0 ? currentColumn - 1 : table.header.count - 1
            if currentRow == 0 && currentColumn == 0 {
                return .select(cellRange(in: source, row: header, column: 0,
                                         count: table.header.count) ?? selection)
            }
        } else if currentColumn + 1 < table.header.count {
            targetRow = currentRow ?? 0
            targetColumn = currentColumn + 1
        } else {
            targetRow = (currentRow ?? 0) + 1
            targetColumn = 0
        }
        if targetRow < rows.count {
            if let target = cellRange(in: source, row: rows[targetRow], column: targetColumn,
                                      count: table.header.count) {
                return .select(target)
            }
            return normalizedRow(in: source, row: rows[targetRow], column: targetColumn,
                                 count: table.header.count).map(MarkdownTableTabAction.edit)
        }
        if backwards { return nil }
        if addsRowAtEnd,
           let edit = edit(in: text, selection: selection, operation: .insertRow) {
            return .edit(edit)
        }
        return .select(NSRange(location: NSMaxRange(block.sourceRange), length: 0))
    }

    private static func cellRange(in source: NSString, row: NSRange,
                                  column: Int, count: Int) -> NSRange? {
        let content = lineContent(source.substring(with: row)).content
        guard let ranges = cells(in: content, expected: count), column < ranges.count else { return nil }
        if ranges[column].length == 0 && ranges[column].location == (content as NSString).length {
            return nil
        }
        let line = content as NSString
        var start = ranges[column].location
        var end = NSMaxRange(ranges[column])
        while start < end && (line.character(at: start) == 32 || line.character(at: start) == 9) {
            start += 1
        }
        while end > start && (line.character(at: end - 1) == 32 || line.character(at: end - 1) == 9) {
            end -= 1
        }
        return NSRange(location: row.location + start, length: end - start)
    }

    private static func normalizedRow(in source: NSString, row: NSRange,
                                      column: Int, count: Int) -> MarkdownEdit? {
        let content = lineContent(source.substring(with: row)).content
        guard let ranges = cells(in: content, expected: count) else { return nil }
        let raw = content as NSString
        let values = ranges.map { raw.substring(with: $0).trimmingCharacters(in: .whitespaces) }
        let prefix = tablePrefix(content)
        let replacement = prefix + "| " + values.joined(separator: " | ") + " |"
        let preceding = values.prefix(column)
        let offset = (prefix as NSString).length + 2 + preceding.reduce(0) {
            $0 + ($1 as NSString).length + 3
        }
        return MarkdownEdit(range: NSRange(location: row.location, length: raw.length),
                            replacement: replacement,
                            selection: NSRange(location: row.location + offset,
                                               length: (values[column] as NSString).length))
    }

    static func alignment(in text: String, selection: NSRange) -> MarkdownTable.Alignment? {
        let source = text as NSString
        guard selection.location >= 0, selection.location < source.length,
              let block = MarkdownAnalysis(text).blocks.first(where: {
                  $0.kind == .table && NSLocationInRange(selection.location, $0.sourceRange)
              }), let table = block.table else { return nil }
        let lineRange = source.lineRange(for: NSRange(location: selection.location, length: 0))
        guard let selectedCells = cells(in: lineContent(source.substring(with: lineRange)).content,
                                        expected: table.header.count) else { return nil }
        let column = columnIndex(at: selection.location - lineRange.location, cells: selectedCells)
        return table.alignments[column]
    }

    static func edit(in text: String, selection: NSRange,
                     operation: MarkdownTableOperation) -> MarkdownEdit? {
        let source = text as NSString
        guard selection.location >= 0, selection.location < source.length,
              let block = MarkdownAnalysis(text).blocks.first(where: {
                  $0.kind == .table && NSLocationInRange(selection.location, $0.sourceRange)
              }), let table = block.table else { return nil }
        let headerRange = source.lineRange(for: NSRange(location: block.sourceRange.location, length: 0))
        let delimiterRange = source.lineRange(for: NSRange(location: NSMaxRange(headerRange), length: 0))
        let ranges = [headerRange, delimiterRange] + table.rowRanges
        guard let rowIndex = ranges.firstIndex(where: { NSLocationInRange(selection.location, $0) }),
              let selectedCells = cells(in: lineContent(source.substring(with: ranges[rowIndex])).content,
                                expected: table.header.count) else { return nil }
        let column = columnIndex(at: selection.location - ranges[rowIndex].location, cells: selectedCells)
        switch operation {
        case .insertRow:
            let preceding = max(rowIndex, 1)
            let position = NSMaxRange(ranges[preceding])
            let previous = lineContent(source.substring(with: ranges[preceding]))
            let newline = previous.ending.isEmpty ? preferredNewline(in: text) : previous.ending
            let prefix = tablePrefix(previous.content)
            let row = prefix + "| " + Array(repeating: " ", count: table.header.count).joined(separator: " | ") + " |"
            let replacement = (previous.ending.isEmpty ? newline : "") + row +
                (previous.ending.isEmpty ? "" : newline)
            let start = position + (previous.ending.isEmpty ? (newline as NSString).length : 0)
            return MarkdownEdit(range: NSRange(location: position, length: 0), replacement: replacement,
                                selection: NSRange(location: start + (prefix as NSString).length + 2,
                                                   length: 0))
        case .deleteRow:
            guard rowIndex >= 2 else { return nil }
            let range = ranges[rowIndex]
            return MarkdownEdit(range: range, replacement: "",
                                selection: NSRange(location: range.location, length: 0))
        case .insertColumn, .deleteColumn:
            guard operation != .deleteColumn || table.header.count > 1 else { return nil }
            var replacement = ""
            var selectedLocation = 0
            for (index, range) in ranges.enumerated() {
                let line = lineContent(source.substring(with: range))
                guard let original = cells(in: line.content, expected: table.header.count) else { return nil }
                var values = original.map { (line.content as NSString).substring(with: $0)
                    .trimmingCharacters(in: .whitespaces) }
                if operation == .insertColumn {
                    values.insert(index == 1 ? "---" : "", at: column + 1)
                } else {
                    values.remove(at: column)
                }
                let prefix = tablePrefix(line.content)
                let rebuilt = prefix + "| " + values.joined(separator: " | ") + " |"
                if index == rowIndex {
                    let before = values.prefix(operation == .insertColumn ? column + 1 : min(column, values.count))
                    selectedLocation = (replacement as NSString).length + (prefix as NSString).length + 2 +
                        (before.joined(separator: " | ") as NSString).length + (before.isEmpty ? 0 : 3)
                }
                replacement += rebuilt + line.ending
            }
            return MarkdownEdit(range: block.sourceRange, replacement: replacement,
                                selection: NSRange(location: block.sourceRange.location + selectedLocation,
                                                   length: 0))
        case let .alignColumn(alignment):
            let line = lineContent(source.substring(with: delimiterRange))
            guard let delimiters = cells(in: line.content, expected: table.header.count) else { return nil }
            let cell = delimiters[column]
            let marker: String
            switch alignment {
            case .leading: marker = "---"
            case .center: marker = ":---:"
            case .trailing: marker = "---:"
            }
            let replacement = " " + marker + " "
            let range = NSRange(location: delimiterRange.location + cell.location, length: cell.length)
            let location: Int
            if selection.location >= NSMaxRange(range) {
                location = selection.location + (replacement as NSString).length - range.length
            } else if selection.location >= range.location {
                location = range.location + 1
            } else {
                location = selection.location
            }
            return MarkdownEdit(range: range, replacement: replacement,
                                selection: NSRange(location: location, length: 0))
        }
    }

    private static func preferredNewline(in text: String) -> String {
        text.contains("\r\n") ? "\r\n" : text.contains("\r") ? "\r" : "\n"
    }

    private static func lineContent(_ line: String) -> (content: String, ending: String) {
        if line.hasSuffix("\r\n") { return (String(line.dropLast(2)), "\r\n") }
        if line.hasSuffix("\n") { return (String(line.dropLast()), "\n") }
        if line.hasSuffix("\r") { return (String(line.dropLast()), "\r") }
        return (line, "")
    }

    private static func tablePrefix(_ line: String) -> String {
        let source = line as NSString
        var cursor = 0
        while cursor < source.length {
            let unit = source.character(at: cursor)
            if unit == 32 || unit == 9 || unit == 62 { cursor += 1 } else { break }
        }
        return source.substring(to: cursor)
    }

    private static func cells(in line: String, expected: Int) -> [NSRange]? {
        let source = line as NSString
        var boundaries: [Int] = []
        var cursor = (tablePrefix(line) as NSString).length
        let start = cursor
        var end = source.length
        while end > start && (source.character(at: end - 1) == 32 ||
                              source.character(at: end - 1) == 9) {
            end -= 1
        }
        while cursor < end {
            if source.character(at: cursor) == 124 {
                var escapes = 0
                var previous = cursor - 1
                while previous >= start && source.character(at: previous) == 92 {
                    escapes += 1
                    previous -= 1
                }
                if escapes % 2 == 0 { boundaries.append(cursor) }
            }
            cursor += 1
        }
        var result: [NSRange] = []
        var cellStart = start
        for (index, boundary) in boundaries.enumerated() {
            if index == 0 && boundary == start {
                cellStart = boundary + 1
                continue
            }
            result.append(NSRange(location: cellStart, length: boundary - cellStart))
            cellStart = boundary + 1
        }
        if boundaries.last != end - 1 || boundaries.isEmpty {
            result.append(NSRange(location: cellStart, length: end - cellStart))
        }
        guard !result.isEmpty, result.count <= expected else { return nil }
        result += Array(repeating: NSRange(location: end, length: 0),
                        count: expected - result.count)
        return result
    }

    private static func columnIndex(at offset: Int, cells: [NSRange]) -> Int {
        for (index, range) in cells.enumerated() where offset < NSMaxRange(range) { return index }
        return cells.count - 1
    }
}
