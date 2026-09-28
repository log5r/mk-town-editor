import Foundation

enum MarkdownLineBreak: Equatable {
    case soft
    case hard
}

struct MarkdownTable: Equatable {
    enum Alignment: Equatable {
        case leading
        case center
        case trailing
    }

    let header: [String]
    let alignments: [Alignment]
    let rows: [[String]]
    let rowRanges: [NSRange]
}

struct MarkdownTask: Equatable {
    let isChecked: Bool
    let content: String
}

struct MarkdownReference: Equatable {
    let destination: String
    let title: String?
    let sourceRange: NSRange
}

struct MarkdownBlock: Equatable {
    enum Kind: Equatable {
        case paragraph
        case heading(level: Int)
        case quote
        case unorderedList
        case orderedList(number: Int)
        case codeBlock
        case table
        case horizontalRule
        case blank
    }

    let id: Int
    let parentID: Int?
    let kind: Kind
    let content: String
    let sourceRange: NSRange
    let codeLanguage: String?
    let codeFenceMarker: Character?
    let codeFenceLength: Int?
    let table: MarkdownTable?
    let lineBreaks: [MarkdownLineBreak]
    let sourceIndent: String?
    let nestingDepth: Int

    var task: MarkdownTask? {
        switch kind {
        case .unorderedList, .orderedList: break
        default: return nil
        }
        let text = content.drop(while: { $0 == " " || $0 == "\t" })
        guard text.count >= 3, text.first == "[" else { return nil }
        let marker = text[text.index(after: text.startIndex)]
        guard marker == " " || marker == "\t" || marker == "x" || marker == "X",
              text[text.index(text.startIndex, offsetBy: 2)] == "]" else { return nil }
        var remainder = text.dropFirst(3)
        guard remainder.isEmpty || remainder.first?.isWhitespace == true else { return nil }
        while remainder.first == " " || remainder.first == "\t" {
            remainder = remainder.dropFirst()
        }
        return MarkdownTask(isChecked: marker == "x" || marker == "X", content: String(remainder))
    }
}

/// One snapshot of a document. Every block refers to the unchanged source text.
struct MarkdownAnalysis {
    let blocks: [MarkdownBlock]
    let positionMap: MarkdownPositionMap
    let references: [String: MarkdownReference]

    init(_ markdown: String) {
        positionMap = MarkdownPositionMap(markdown)
        let parsed = Self.parse(markdown)
        blocks = parsed.blocks
        references = parsed.references
    }

    var rootBlocks: [MarkdownBlock] { blocks.filter { $0.parentID == nil } }

    func children(of block: MarkdownBlock) -> [MarkdownBlock] {
        blocks.filter { $0.parentID == block.id }
    }

    private struct SourceLine {
        let text: String
        let range: NSRange
    }

    private struct Fence {
        let marker: Character
        let length: Int
        let language: String?
        let indentation: Int
    }

    private static let listPattern = try! NSRegularExpression(pattern: #"^([ \t]*)([-+*]|[0-9]{1,9}[.)])[ \t]+(.*)$"#)
    private static let referencePattern = try! NSRegularExpression(
        pattern: #"^[ \t]{0,3}\[([^\]]+)\]:[ \t]*(?:<([^<>]*)>|([^\s]+))(?:[ \t]+(?:\"([^\"]*)\"|'([^']*)'|\(([^)]*)\)))?[ \t]*$"#
    )

    private static func parse(_ markdown: String) ->
        (blocks: [MarkdownBlock], references: [String: MarkdownReference]) {
        var nextID = 0
        var references: [String: MarkdownReference] = [:]
        let blocks = parseLines(sourceLines(markdown), parentID: nil,
                                nextID: &nextID, references: &references)
        return (blocks, references)
    }

    private static func parseLines(
        _ lines: [SourceLine],
        parentID: Int?,
        nextID: inout Int,
        references: inout [String: MarkdownReference]
    ) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        var listAncestors: [(indent: Int, contentIndent: Int, id: Int, depth: Int)] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)

            if parseQuote(line.text) != nil {
                let quoteID = nextID
                nextID += 1
                let firstLine = line
                var quoteLines: [SourceLine] = []
                var allowsLazyContinuation = false
                var activeFence: Fence?
                while index < lines.count {
                    let current = lines[index]
                    if parseQuote(current.text) != nil {
                        let inner = removeFirstQuoteMarker(current.text)
                        quoteLines.append(SourceLine(text: inner, range: current.range))
                        if let fence = activeFence {
                            if isClosingFence(inner, for: fence) { activeFence = nil }
                            allowsLazyContinuation = false
                        } else if let fence = openingFence(inner) {
                            activeFence = fence
                            allowsLazyContinuation = false
                        } else {
                            allowsLazyContinuation = indentationWidth(inner) < 4 &&
                                isParagraphContinuation(inner)
                        }
                    } else if allowsLazyContinuation && indentationWidth(current.text) < 4 &&
                        isParagraphContinuation(current.text) {
                        quoteLines.append(current)
                    } else {
                        break
                    }
                    index += 1
                }
                let lastRange = quoteLines[quoteLines.count - 1].range
                result.append(MarkdownBlock(
                    id: quoteID, parentID: parentID, kind: .quote,
                    content: quoteLines.map(\.text).joined(separator: "\n"),
                    sourceRange: NSRange(location: firstLine.range.location,
                                         length: NSMaxRange(lastRange) - firstLine.range.location),
                    codeLanguage: nil, codeFenceMarker: nil, codeFenceLength: nil,
                    table: nil,
                    lineBreaks: [], sourceIndent: nil, nestingDepth: 0
                ))
                result.append(contentsOf: parseLines(quoteLines, parentID: quoteID,
                                                     nextID: &nextID, references: &references))
                listAncestors.removeAll()
                continue
            }

            if let definition = parseReferenceDefinition(line.text),
                result.last(where: { $0.parentID == parentID })?.kind != .paragraph {
                if references[definition.key] == nil {
                    references[definition.key] = MarkdownReference(
                        destination: definition.destination, title: definition.title,
                        sourceRange: line.range
                    )
                }
                index += 1
                continue
            }

            if let fence = openingFence(line.text) {
                let id = nextID
                nextID += 1
                index += 1
                var codeLines: [String] = []
                while index < lines.count && !isClosingFence(lines[index].text, for: fence) {
                    codeLines.append(removingUpToSpaces(lines[index].text, count: fence.indentation))
                    index += 1
                }
                if index < lines.count { index += 1 }
                let end = lines[index - 1].range
                result.append(MarkdownBlock(
                    id: id, parentID: parentID, kind: .codeBlock,
                    content: codeLines.joined(separator: "\n"),
                    sourceRange: NSRange(location: line.range.location, length: NSMaxRange(end) - line.range.location),
                    codeLanguage: fence.language, codeFenceMarker: fence.marker,
                    codeFenceLength: fence.length, table: nil,
                    lineBreaks: [], sourceIndent: nil, nestingDepth: 0
                ))
                listAncestors.removeAll()
                continue
            }

            let codeIndent = (listAncestors.last?.contentIndent ?? 0) + 4
            if indentationWidth(line.text) >= codeIndent && !trimmed.isEmpty &&
                (listAncestors.last != nil ||
                 result.last(where: { $0.parentID == parentID })?.kind != .paragraph) {
                let id = nextID
                nextID += 1
                let start = index
                var codeLines: [String] = []
                var lastContentIndex = index
                while index < lines.count {
                    let current = lines[index]
                    if current.text.trimmingCharacters(in: .whitespaces).isEmpty {
                        codeLines.append("")
                    } else if indentationWidth(current.text) >= codeIndent {
                        codeLines.append(removingIndentColumns(current.text, count: codeIndent))
                        lastContentIndex = index
                    } else {
                        break
                    }
                    index += 1
                }
                codeLines.removeLast(codeLines.count - (lastContentIndex - start + 1))
                let end = lines[lastContentIndex].range
                result.append(MarkdownBlock(
                    id: id, parentID: listAncestors.last?.id ?? parentID, kind: .codeBlock,
                    content: codeLines.joined(separator: "\n"),
                    sourceRange: NSRange(location: line.range.location,
                                         length: NSMaxRange(end) - line.range.location),
                    codeLanguage: nil, codeFenceMarker: nil, codeFenceLength: nil,
                    table: nil,
                    lineBreaks: [], sourceIndent: String(line.text.prefix(while: { $0 == " " || $0 == "\t" })),
                    nestingDepth: listAncestors.last.map { $0.depth + 1 } ?? 0
                ))
                index = lastContentIndex + 1
                continue
            }

            if index + 1 < lines.count, indentationWidth(line.text) < 4,
                parseHeading(line.text) == nil, parseList(line.text) == nil,
                !isThematicBreak(line.text),
                let table = parseTableHeader(line.text, delimiter: lines[index + 1].text) {
                let id = nextID
                nextID += 1
                index += 2
                var rows: [[String]] = []
                var rowRanges: [NSRange] = []
                while index < lines.count {
                    let row = lines[index]
                    if row.text.trimmingCharacters(in: .whitespaces).isEmpty ||
                        openingFence(row.text) != nil || parseQuote(row.text) != nil ||
                        parseHeading(row.text) != nil || isThematicBreak(row.text) ||
                        parseList(row.text) != nil { break }
                    var cells = splitTableRow(row.text).cells
                    if cells.count > table.header.count {
                        cells = Array(cells.prefix(table.header.count))
                    }
                    cells += Array(repeating: "", count: table.header.count - cells.count)
                    rows.append(cells)
                    rowRanges.append(row.range)
                    index += 1
                }
                let end = lines[index - 1].range
                result.append(MarkdownBlock(
                    id: id, parentID: listAncestors.last?.id ?? parentID, kind: .table,
                    content: "", sourceRange: NSRange(location: line.range.location,
                        length: NSMaxRange(end) - line.range.location),
                    codeLanguage: nil, codeFenceMarker: nil, codeFenceLength: nil,
                    table: MarkdownTable(header: table.header, alignments: table.alignments,
                                         rows: rows, rowRanges: rowRanges),
                    lineBreaks: [], sourceIndent: nil,
                    nestingDepth: listAncestors.last.map { $0.depth + 1 } ?? 0
                ))
                continue
            }

            let id = nextID
            nextID += 1
            var blockParentID = parentID
            var kind: MarkdownBlock.Kind
            var content = line.text
            var sourceRange = line.range
            var lineBreaks: [MarkdownLineBreak] = []
            var advance = 1
            var sourceIndent: String?
            var nestingDepth = 0

            if trimmed.isEmpty {
                kind = .blank
                content = ""
                if let parent = listAncestors.last, index + 1 < lines.count,
                   indentationWidth(lines[index + 1].text) > parent.indent {
                    blockParentID = parent.id
                    nestingDepth = parent.depth + 1
                }
            } else if let heading = parseHeading(line.text) {
                kind = .heading(level: heading.level)
                content = heading.content
            } else if isThematicBreak(line.text) {
                kind = .horizontalRule
                content = ""
            } else if let list = parseList(line.text) {
                kind = list.kind
                var parts = [list.content]
                var next = index + 1
                while next < lines.count && isParagraphContinuation(lines[next].text) &&
                    indentationWidth(lines[next].text) > list.indent &&
                    indentationWidth(lines[next].text) < list.contentIndent + 4 &&
                    !(next + 1 < lines.count &&
                      parseTableHeader(lines[next].text, delimiter: lines[next + 1].text) != nil) {
                    lineBreaks.append(lineBreak(after: parts[parts.count - 1]))
                    parts.append(withoutLeadingIndent(lines[next].text))
                    next += 1
                }
                content = parts.joined(separator: "\n")
                sourceRange = NSRange(location: line.range.location,
                                      length: NSMaxRange(lines[next - 1].range) - line.range.location)
                advance = next - index
                while let last = listAncestors.last, last.indent >= list.indent {
                    listAncestors.removeLast()
                }
                blockParentID = listAncestors.last?.id ?? parentID
                nestingDepth = listAncestors.count
                sourceIndent = list.sourceIndent
                listAncestors.append((list.indent, list.contentIndent, id, nestingDepth))
            } else {
                kind = .paragraph
                if let parent = listAncestors.last, indentationWidth(line.text) > parent.indent {
                    blockParentID = parent.id
                    nestingDepth = parent.depth + 1
                }
                let isListContinuation = blockParentID != parentID
                var parts = [isListContinuation ? withoutLeadingIndent(line.text) : line.text]
                var next = index + 1
                while next < lines.count &&
                    (isParagraphContinuation(lines[next].text) ||
                     (!isListContinuation && indentationWidth(lines[next].text) >= 4 &&
                      !lines[next].text.trimmingCharacters(in: .whitespaces).isEmpty)) &&
                    (!isListContinuation ||
                     (indentationWidth(lines[next].text) > listAncestors.last!.indent &&
                      indentationWidth(lines[next].text) < listAncestors.last!.contentIndent + 4)) &&
                    !(next + 1 < lines.count &&
                      parseTableHeader(lines[next].text, delimiter: lines[next + 1].text) != nil) {
                    lineBreaks.append(lineBreak(after: parts[parts.count - 1]))
                    parts.append(!isListContinuation ? lines[next].text :
                        withoutLeadingIndent(lines[next].text))
                    next += 1
                }
                if !isListContinuation, next < lines.count,
                    let level = setextUnderlineLevel(lines[next].text) {
                    kind = .heading(level: level)
                    next += 1
                }
                content = parts.joined(separator: "\n")
                sourceRange = NSRange(location: line.range.location,
                                      length: NSMaxRange(lines[next - 1].range) - line.range.location)
                advance = next - index
            }

            if !isList(kind) && blockParentID == parentID { listAncestors.removeAll() }
            result.append(MarkdownBlock(
                id: id, parentID: blockParentID, kind: kind, content: content,
                sourceRange: sourceRange, codeLanguage: nil, codeFenceMarker: nil,
                codeFenceLength: nil, table: nil, lineBreaks: lineBreaks,
                sourceIndent: sourceIndent, nestingDepth: nestingDepth
            ))
            index += advance
        }
        return result
    }

    private static func sourceLines(_ text: String) -> [SourceLine] {
        let source = text as NSString
        guard source.length > 0 else { return [SourceLine(text: "", range: NSRange(location: 0, length: 0))] }
        var result: [SourceLine] = []
        var cursor = 0
        while cursor < source.length {
            var start = 0
            var end = 0
            var contentsEnd = 0
            source.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                                for: NSRange(location: cursor, length: 0))
            result.append(SourceLine(
                text: source.substring(with: NSRange(location: start, length: contentsEnd - start)),
                range: NSRange(location: start, length: end - start)
            ))
            cursor = end
        }
        if [10, 13].contains(Int(source.character(at: source.length - 1))) {
            result.append(SourceLine(text: "", range: NSRange(location: source.length, length: 0)))
        }
        return result
    }

    private static func openingFence(_ line: String) -> Fence? {
        let indentation = line.prefix(while: { $0 == " " }).count
        guard indentation <= 3 else { return nil }
        let remainder = line.dropFirst(indentation)
        let prefix = remainder.prefix(while: { $0 == "`" || $0 == "~" })
        guard prefix.count >= 3, let marker = prefix.first, prefix.allSatisfy({ $0 == marker }) else {
            return nil
        }
        let info = remainder.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        if marker == "`" && info.contains("`") { return nil }
        let language = info.split(whereSeparator: \.isWhitespace).first.map(String.init)
        return Fence(marker: marker, length: prefix.count, language: language, indentation: indentation)
    }

    private static func isClosingFence(_ line: String, for fence: Fence) -> Bool {
        let indentation = line.prefix(while: { $0 == " " }).count
        guard indentation <= 3 else { return false }
        let trimmed = line.dropFirst(indentation).trimmingCharacters(in: .whitespaces)
        let markerRun = trimmed.prefix(while: { $0 == fence.marker })
        return markerRun.count >= fence.length && trimmed.dropFirst(markerRun.count).isEmpty
    }

    private static func removingUpToSpaces(_ line: String, count: Int) -> String {
        var remainder = line[...]
        for _ in 0..<count where remainder.first == " " {
            remainder = remainder.dropFirst()
        }
        return String(remainder)
    }

    private static func removingIndentColumns(_ line: String, count: Int) -> String {
        var remainder = line[...]
        var width = 0
        while width < count, let first = remainder.first, first == " " || first == "\t" {
            let nextWidth = first == "\t" ? width + 4 - width % 4 : width + 1
            if nextWidth > count {
                return String(repeating: " ", count: nextWidth - count) + remainder.dropFirst()
            }
            width = nextWidth
            remainder = remainder.dropFirst()
        }
        return String(remainder)
    }

    private static func parseHeading(_ line: String) -> (level: Int, content: String)? {
        let indentation = line.prefix(while: { $0 == " " }).count
        guard indentation <= 3 else { return nil }
        let remainder = line.dropFirst(indentation)
        let marks = remainder.prefix(while: { $0 == "#" })
        guard (1...6).contains(marks.count) else { return nil }
        let afterOpening = remainder.dropFirst(marks.count)
        guard afterOpening.isEmpty || afterOpening.first == " " || afterOpening.first == "\t" else { return nil }
        var content = String(afterOpening).trimmingCharacters(in: .whitespaces)
        let closingCount = content.reversed().prefix(while: { $0 == "#" }).count
        if closingCount > 0 {
            let beforeClosing = content.dropLast(closingCount)
            if beforeClosing.last == " " || beforeClosing.last == "\t" {
                content = String(beforeClosing).trimmingCharacters(in: .whitespaces)
            }
        }
        return (marks.count, content)
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        let indentation = line.prefix(while: { $0 == " " }).count
        guard indentation <= 3 else { return false }
        let marks = line.dropFirst(indentation).filter { $0 != " " && $0 != "\t" }
        guard marks.count >= 3, let marker = marks.first, marker == "-" || marker == "*" || marker == "_" else {
            return false
        }
        return marks.allSatisfy { $0 == marker }
    }

    private static func setextUnderlineLevel(_ line: String) -> Int? {
        let indentation = line.prefix(while: { $0 == " " }).count
        guard indentation <= 3 else { return nil }
        let trimmed = line.dropFirst(indentation).trimmingCharacters(in: .whitespaces)
        guard let marker = trimmed.first, marker == "=" || marker == "-",
              trimmed.allSatisfy({ $0 == marker }) else { return nil }
        return marker == "=" ? 1 : 2
    }

    private static func parseTableHeader(
        _ headerLine: String,
        delimiter: String
    ) -> (header: [String], alignments: [MarkdownTable.Alignment])? {
        let header = splitTableRow(headerLine)
        let delimiterRow = splitTableRow(delimiter)
        guard header.hasPipe || delimiterRow.hasPipe,
              !header.cells.isEmpty, header.cells.count == delimiterRow.cells.count else { return nil }
        var alignments: [MarkdownTable.Alignment] = []
        for cell in delimiterRow.cells {
            let value = cell.trimmingCharacters(in: .whitespaces)
            let afterLeadingColon = value.hasPrefix(":") ? value.dropFirst() : value[...]
            let core = value.hasSuffix(":") ? afterLeadingColon.dropLast() : afterLeadingColon
            guard !core.isEmpty, core.allSatisfy({ $0 == "-" }) else { return nil }
            if value.hasPrefix(":") && value.hasSuffix(":") {
                alignments.append(.center)
            } else if value.hasSuffix(":") {
                alignments.append(.trailing)
            } else {
                alignments.append(.leading)
            }
        }
        return (header.cells, alignments)
    }

    static func normalizedReferenceLabel(_ label: String) -> String {
        label.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    private static func parseReferenceDefinition(_ line: String) ->
        (key: String, destination: String, title: String?)? {
        let source = line as NSString
        guard let match = referencePattern.firstMatch(in: line,
            range: NSRange(location: 0, length: source.length)) else { return nil }
        func group(_ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : source.substring(with: range)
        }
        guard let label = group(1), let destination = group(2) ?? group(3) else { return nil }
        let key = normalizedReferenceLabel(label)
        guard !key.isEmpty else { return nil }
        return (key, destination, group(4) ?? group(5) ?? group(6))
    }

    private static func splitTableRow(_ line: String) -> (cells: [String], hasPipe: Bool) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let characters = Array(trimmed)
        var cells: [String] = []
        var current = ""
        var index = 0
        var hasPipe = false
        while index < characters.count {
            let character = characters[index]
            if character == "\\" {
                let start = index
                while index < characters.count && characters[index] == "\\" { index += 1 }
                let count = index - start
                current += String(repeating: "\\", count: count)
                if count % 2 == 1 && index < characters.count && characters[index] == "|" {
                    current.append("|")
                    index += 1
                }
                continue
            }
            if character == "|" {
                hasPipe = true
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
            index += 1
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        if trimmed.first == "|" { cells.removeFirst() }
        let trailingBackslashes = characters.dropLast().reversed().prefix(while: { $0 == "\\" }).count
        if trimmed.last == "|", trailingBackslashes % 2 == 0 {
            cells.removeLast()
        }
        return (cells, hasPipe)
    }

    private static func isParagraphContinuation(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && openingFence(line) == nil && parseQuote(line) == nil &&
            parseHeading(line) == nil && !isThematicBreak(line) &&
            setextUnderlineLevel(line) == nil &&
            parseList(line) == nil
    }

    private static func lineBreak(after line: String) -> MarkdownLineBreak {
        let trailingSpaces = line.reversed().prefix(while: { $0 == " " }).count
        if trailingSpaces >= 2 { return .hard }
        let trailingBackslashes = line.reversed().prefix(while: { $0 == "\\" }).count
        return trailingBackslashes % 2 == 1 ? .hard : .soft
    }

    private static func parseQuote(_ line: String) -> (depth: Int, content: String)? {
        var remainder = line[...]
        var indentation = 0
        while remainder.first == " " && indentation < 4 {
            remainder = remainder.dropFirst()
            indentation += 1
        }
        guard indentation <= 3 else { return nil }
        var depth = 0
        while remainder.first == ">" {
            depth += 1
            remainder = remainder.dropFirst()
            if remainder.first == " " || remainder.first == "\t" { remainder = remainder.dropFirst() }
        }
        return depth > 0 ? (depth, String(remainder)) : nil
    }

    private static func removeFirstQuoteMarker(_ line: String) -> String {
        var remainder = line[...]
        while remainder.first == " " { remainder = remainder.dropFirst() }
        remainder = remainder.dropFirst()
        if remainder.first == " " || remainder.first == "\t" { remainder = remainder.dropFirst() }
        return String(remainder)
    }

    private static func parseList(_ line: String) ->
        (kind: MarkdownBlock.Kind, content: String, indent: Int, contentIndent: Int, sourceIndent: String)? {
        let source = line as NSString
        guard let match = listPattern.firstMatch(in: line, range: NSRange(location: 0, length: source.length)) else {
            return nil
        }
        let sourceIndent = source.substring(with: match.range(at: 1))
        let indent = indentationWidth(sourceIndent)
        let contentIndent = indent + match.range(at: 3).location - match.range(at: 2).location
        let marker = source.substring(with: match.range(at: 2))
        let content = source.substring(with: match.range(at: 3))
        if let number = Int(marker.dropLast()) {
            return (.orderedList(number: number), content, indent, contentIndent, sourceIndent)
        }
        return (.unorderedList, content, indent, contentIndent, sourceIndent)
    }

    private static func indentationWidth(_ line: String) -> Int {
        var width = 0
        for character in line.prefix(while: { $0 == " " || $0 == "\t" }) {
            width += character == "\t" ? 4 - width % 4 : 1
        }
        return width
    }

    private static func withoutLeadingIndent(_ line: String) -> String {
        String(line.drop(while: { $0 == " " || $0 == "\t" }))
    }

    private static func isList(_ kind: MarkdownBlock.Kind) -> Bool {
        switch kind {
        case .unorderedList, .orderedList: true
        default: false
        }
    }
}
