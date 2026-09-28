import Foundation

struct MarkdownTableDraft: Identifiable {
    let id = UUID()
    let range: NSRange
    let originalText: String
}

struct MarkdownTableConversion {
    let edit: MarkdownEdit
    let hasMultilineCells: Bool
}

enum MarkdownTableInsertion {
    static func conversion(in text: String, selection: NSRange,
                           delimitedText: String) -> MarkdownTableConversion? {
        let source = text as NSString
        guard selection.location >= 0, selection.location <= source.length,
              selection.length >= 0, selection.length <= source.length - selection.location,
              let parsed = parseDelimited(delimitedText) else { return nil }
        let width = parsed.rows.map(\.count).max() ?? 0
        guard width > 0, width <= 100, parsed.rows.count <= 10_000 else { return nil }
        let newline = text.contains("\r\n") ? "\r\n" : text.contains("\r") ? "\r" : "\n"
        let before = source.substring(to: selection.location)
        let after = source.substring(from: NSMaxRange(selection))
        let leading = spacing(before: before, newline: newline)
        let trailing = spacing(after: after, newline: newline)
        let lines = parsed.rows.enumerated().map { index, row in
            let cells = row + Array(repeating: "", count: width - row.count)
            let body = "| " + cells.map(escapedCell).joined(separator: " | ") + " |"
            if index == 0 {
                return [body, "| " + Array(repeating: "---", count: width).joined(separator: " | ") + " |"]
            }
            return [body]
        }.flatMap { $0 }
        let replacement = leading + lines.joined(separator: newline) + trailing
        let firstCell = escapedCell(parsed.rows[0][0])
        let location = selection.location + (leading as NSString).length + 2
        let edit = MarkdownEdit(range: selection, replacement: replacement,
                                selection: NSRange(location: location,
                                                   length: (firstCell as NSString).length))
        return MarkdownTableConversion(edit: edit, hasMultilineCells: parsed.hasMultilineCells)
    }

    private static func escapedCell(_ value: String) -> String {
        var result = ""
        for character in value {
            switch character {
            case "\n", "\r": result += "<br>"
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\\", "|", "*", "_", "`", "[", "]": result += "\\" + String(character)
            default: result.append(character)
            }
        }
        return result
    }

    private static func parseDelimited(_ input: String) ->
        (rows: [[String]], hasMultilineCells: Bool)? {
        guard !input.isEmpty else { return nil }
        let characters = Array(input.unicodeScalars)
        let separator = delimiter(in: characters)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var afterQuote = false
        var multiline = false
        var index = 0
        var lastWasNewline = false
        while index < characters.count {
            let character = characters[index]
            if quoted {
                if character == "\"" {
                    if index + 1 < characters.count && characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 2
                        continue
                    }
                    quoted = false
                    afterQuote = true
                } else if character == "\r" || character == "\n" {
                    field.append("\n")
                    multiline = true
                    if character == "\r" && index + 1 < characters.count && characters[index + 1] == "\n" {
                        index += 1
                    }
                } else {
                    field.unicodeScalars.append(character)
                }
            } else if character == separator {
                row.append(field)
                field = ""
                afterQuote = false
                lastWasNewline = false
            } else if character == "\r" || character == "\n" {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
                afterQuote = false
                lastWasNewline = true
                if character == "\r" && index + 1 < characters.count && characters[index + 1] == "\n" {
                    index += 1
                }
            } else if character == "\"" && field.isEmpty && !afterQuote {
                quoted = true
                lastWasNewline = false
            } else if character == "\"" || afterQuote {
                return nil
            } else {
                field.unicodeScalars.append(character)
                lastWasNewline = false
            }
            index += 1
        }
        guard !quoted else { return nil }
        if !lastWasNewline || !row.isEmpty || !field.isEmpty {
            row.append(field)
            rows.append(row)
        }
        guard !rows.isEmpty, rows.count > 1 || rows[0].count > 1 else { return nil }
        return (rows, multiline)
    }

    private static func delimiter(in characters: [Unicode.Scalar]) -> Unicode.Scalar {
        var quoted = false
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if quoted && index + 1 < characters.count && characters[index + 1] == "\"" {
                    index += 2
                    continue
                }
                quoted.toggle()
            } else if !quoted {
                if character == "\t" { return "\t" }
                if character == "\r" || character == "\n" { break }
            }
            index += 1
        }
        return ","
    }

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
    case formatTable
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
        case .formatTable:
            let selectedColumn = column
            let sourceLines = ranges.map { lineContent(source.substring(with: $0)) }
            let values = sourceLines.map { line -> [String]? in
                guard let rowCells = cells(in: line.content, expected: table.header.count) else { return nil }
                let raw = line.content as NSString
                return rowCells.map { raw.substring(with: $0).trimmingCharacters(in: .whitespaces) }
            }
            guard values.allSatisfy({ $0 != nil }) else { return nil }
            let rows = values.compactMap { $0 }
            let widths = table.header.indices.map { column in
                let minimum = switch table.alignments[column] {
                case .leading: 3
                case .center: 5
                case .trailing: 4
                }
                return max(minimum, rows.enumerated().filter { $0.offset != 1 }
                    .map { displayWidth($0.element[column]) }.max() ?? 0)
            }
            var replacement = ""
            var selectedLocation = 0
            var selectedLength = 0
            for (index, line) in sourceLines.enumerated() {
                let prefix = tablePrefix(line.content)
                var rebuilt = prefix + "|"
                for column in widths.indices {
                    let value = rows[index][column]
                    let formatted: String
                    let contentLeading: Int
                    if index == 1 {
                        let width = widths[column]
                        switch table.alignments[column] {
                        case .leading: formatted = String(repeating: "-", count: width)
                        case .center: formatted = ":" + String(repeating: "-", count: max(1, width - 2)) + ":"
                        case .trailing: formatted = String(repeating: "-", count: max(1, width - 1)) + ":"
                        }
                        contentLeading = 0
                    } else {
                        let padding = max(0, widths[column] - displayWidth(value))
                        let leading: Int
                        switch table.alignments[column] {
                        case .leading: leading = 0
                        case .center: leading = padding / 2
                        case .trailing: leading = padding
                        }
                        formatted = String(repeating: " ", count: leading) + value +
                            String(repeating: " ", count: padding - leading)
                        contentLeading = leading
                    }
                    if index == rowIndex && column == selectedColumn {
                        selectedLocation = (replacement as NSString).length + (rebuilt as NSString).length +
                            1 + contentLeading
                        selectedLength = ((index == 1 ? formatted : value) as NSString).length
                    }
                    rebuilt += " " + formatted + " |"
                }
                replacement += rebuilt + line.ending
            }
            return MarkdownEdit(range: block.sourceRange, replacement: replacement,
                                selection: NSRange(location: block.sourceRange.location + selectedLocation,
                                                   length: selectedLength))
        }
    }

    private static func displayWidth(_ text: String) -> Int {
        text.reduce(0) { width, character in
            guard let scalar = character.unicodeScalars.first else { return width }
            let value = scalar.value
            let wide = (0x1100...0x115F).contains(value) || (0x2E80...0xA4CF).contains(value) ||
                (0xAC00...0xD7A3).contains(value) || (0xF900...0xFAFF).contains(value) ||
                (0xFE10...0xFE6F).contains(value) || (0xFF00...0xFF60).contains(value) ||
                (0xFFE0...0xFFE6).contains(value) || (0x1F300...0x1FAFF).contains(value)
            return width + (wide ? 2 : 1)
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
